// P2-17: The keyboard adapter (001 §2.2). Owns the tap thread and the KeyTapEngine that lives on it, and is the
// only way other threads reach the processor: every call hops onto the tap thread. Signals and status go to the
// main queue asynchronously, so the tap never waits for main.
//
// Who calls what:
// - main (P2-20): `start(mode:)` with the mode FeatureAvailability allows (caller chooses; nothing is upgraded
//   here), `stop()`, `perform(.reset(_:))` / `perform(.inputSourceChanged(…))` on a context or input-source change,
//   `checkSecureInputNow()` on an app change.
// - the replacement worker (P2-21): `claimPosting(gen:)` right before posting (false = abandon), then
//   `finishReplacement(gen:…)`. It never finishes the commit itself (001 §12 K1).
//
// The real backend comes from `KeyWatcher+Live.swift` (excluded from the test target, so no test can install a tap).

import Foundation

/// P2-47: what main may ask of the processor through `KeyWatcher.perform` (001 §2.2 contract step 4). Deliberately
/// narrow: `handle`, `pollFlush` and `finishReplacement` belong to the tap thread and the worker hop, and the mode
/// changes only through `start(mode:)` / `stop()`, so the processor's mode always matches the installed tap.
enum KeyWatcherOperation: Sendable, Equatable {
    /// Forget the word and abort a replacement (held keys flush); the tap thread adds the current modifier flags.
    case reset(ResetReason)
    /// Main saw the input source change (`isOurs`: our own after-convert switch, which keeps the buffer).
    case inputSourceChanged(to: InputSourceID?, isOurs: Bool)
}

final class KeyWatcher: @unchecked Sendable { // @unchecked: mutable state is guarded by `lock`; the engine is tap-thread confined
    /// Builds the backend for the tap thread's run loop. P2-47: called on the thread that calls `start` (main), right
    /// after the tap thread started; from then on the backend is used only on the tap thread.
    typealias BackendFactory = @Sendable (CFRunLoop) -> KeyTapBackend

    /// How long `start(mode:)` waits for the tap thread before it reports `.off`.
    static let defaultStartTimeout: TimeInterval = 1

    private let lock = NSLock()
    private let makeBackend: BackendFactory
    private let clock: any Clock
    private let startTimeout: TimeInterval
    private let onSignal: @Sendable (KeySignal) -> Void
    private let onStatus: @Sendable (KeyWatcherStatus) -> Void
    private let commit = HoldBackCommitLock()
    /// Before the first start (and after a stop), hops apply here so nothing set by main is lost.
    private var seed: KeyStreamProcessor
    private var thread: KeyTapThread?
    private var engine: KeyTapEngine?
    private var latestStatus = KeyWatcherStatus()

    init(processor: KeyStreamProcessor, clock: any Clock = SystemClock(),
         startTimeout: TimeInterval = KeyWatcher.defaultStartTimeout, makeBackend: @escaping BackendFactory,
         onSignal: @Sendable @escaping (KeySignal) -> Void,
         onStatus: @Sendable @escaping (KeyWatcherStatus) -> Void = { _ in }) {
        seed = processor
        self.clock = clock
        self.startTimeout = startTimeout
        self.makeBackend = makeBackend
        self.onSignal = onSignal
        self.onStatus = onStatus
    }

    deinit {
        stop()
    }

    /// The latest health counters (001 §7 B1/B4). Any thread.
    var health: TapHealth { lock.withLock { latestStatus.health } }
    var status: KeyWatcherStatus { lock.withLock { latestStatus } }

    /// Starts the tap thread if needed and installs the tap in `mode`. Returns the mode actually achieved:
    /// `.off` when the permission check fails, `tapCreate` fails, or the tap thread didn't answer in `startTimeout`.
    /// Calling it again switches modes (a permission was granted or revoked).
    ///
    /// P2-47: on a timeout the queued apply still runs later on the tap thread. It can't install a tap behind main's
    /// back: the `ModeRequest` decides atomically whether main got the answer, and if main gave up, the late apply
    /// ends in `.off` instead (skipped, or undone if it was already running), which is what main was told.
    @discardableResult
    func start(mode: TapMode) -> TapMode {
        let (thread, engine) = ensureRunning()
        if thread.isCurrent { return engine.applyMode(mode, userInitiated: true) }
        let request = ModeRequest()
        thread.async {
            guard !request.isAbandoned else {
                engine.applyMode(.off, userInitiated: true)
                return
            }
            let achieved = engine.applyMode(mode, userInitiated: true)
            if !request.deliver(achieved) { engine.applyMode(.off, userInitiated: true) }
        }
        return request.wait(timeout: startTimeout) ?? .off
    }

    /// Removes the tap (held keys are flushed first) and ends the tap thread.
    func stop() {
        let (thread, engine) = lock.withLock { (self.thread, self.engine) }
        guard let thread, let engine else { return }
        let processor = thread.sync { () -> KeyStreamProcessor in
            engine.shutdown()
            return engine.processor
        }
        thread.stopRunLoop()
        lock.withLock {
            if let processor { seed = processor }
            self.thread = nil
            self.engine = nil
        }
    }

    /// Main → tap thread (001 §2.1, contract step 4): runs `operation` on the processor, then the flush step.
    /// Before the first start (or after a stop) it applies to the processor the next start begins with.
    func perform(_ operation: KeyWatcherOperation) {
        guard let (thread, engine) = running() else {
            lock.withLock { Self.apply(operation, to: &seed) }
            return
        }
        thread.async { engine.perform(operation) }
    }

    /// A copy of the processor as the tap thread sees it once every hop queued before this call has run (nil if the
    /// tap thread didn't answer in 1 s). Read-only: a copy can't flush or finish anything. For tests and diagnostics.
    func processorSnapshot() -> KeyStreamProcessor? {
        guard let (thread, engine) = running() else { return lock.withLock { seed } }
        return thread.sync { engine.processor }
    }

    /// Worker, right before posting (B3). False = the deadline already flushed: abandon without posting.
    func claimPosting(gen: UInt64) -> Bool {
        commit.claimPosting(gen: gen)
    }

    /// Worker, when done (contract step 3). The tap thread replays the held keys, then finishes the commit.
    func finishReplacement(gen: UInt64, newRendering: InputSourceID?, bufferAfter: [Stroke]?) {
        guard let (thread, engine) = running() else { return }
        thread.async { engine.finishReplacement(gen: gen, newRendering: newRendering, bufferAfter: bufferAfter) }
    }

    /// Check Secure Input now (main calls this on every app change; the tap thread also polls every 1 s).
    func checkSecureInputNow() {
        guard let (thread, engine) = running() else { return }
        thread.async { engine.checkSecureInput(publishing: true) }
    }

    // MARK: - Private

    private func running() -> (KeyTapThread, KeyTapEngine)? {
        lock.withLock {
            guard let thread, let engine else { return nil }
            return (thread, engine)
        }
    }

    private func ensureRunning() -> (KeyTapThread, KeyTapEngine) {
        if let pair = running() { return pair }
        let thread = KeyTapThread()
        thread.startAndWait()
        let onSignal = onSignal, onStatus = onStatus
        // Built here, then used only on the tap thread (the lock below publishes it). CFRunLoop calls that add the
        // backend's timers to the tap thread's run loop are thread-safe.
        let engine = KeyTapEngine(
            processor: lock.withLock { seed }, commit: commit, backend: makeBackend(thread.runLoop), clock: clock,
            sendSignal: { signal in DispatchQueue.main.async { onSignal(signal) } },
            sendStatus: { [weak self] status in
                self?.storeStatus(status)
                DispatchQueue.main.async { onStatus(status) }
            })
        lock.withLock {
            self.thread = thread
            self.engine = engine
        }
        return (thread, engine)
    }

    /// Before the tap thread exists: the same operation on the seed (no device flags to read yet).
    private static func apply(_ operation: KeyWatcherOperation, to processor: inout KeyStreamProcessor) {
        switch operation {
        case let .reset(reason): processor.reset(reason)
        case let .inputSourceChanged(id, isOurs): processor.inputSourceChanged(to: id, isOurs: isOurs)
        }
    }

    private func storeStatus(_ status: KeyWatcherStatus) {
        lock.withLock { latestStatus = status }
    }

    /// P2-47: one `start(mode:)` hand-off. Main waits at most the start timeout; whether the tap thread's answer
    /// counted or main gave up first is decided under one lock, so the two can never disagree about the mode.
    private final class ModeRequest: @unchecked Sendable { // @unchecked: state is guarded by `lock`
        private let lock = NSLock()
        private let answered = DispatchSemaphore(value: 0)
        private var abandoned = false
        private var result: TapMode?

        /// Tap thread, before applying: main already gave up (apply `.off` instead).
        var isAbandoned: Bool { lock.withLock { abandoned } }

        /// Tap thread, after applying. False = main gave up meanwhile and reported `.off`: undo the apply.
        func deliver(_ mode: TapMode) -> Bool {
            lock.withLock {
                guard !abandoned else { return false }
                result = mode
                answered.signal()
                return true
            }
        }

        /// Main: the achieved mode, or nil after `timeout` (from then on the late apply ends in `.off`).
        func wait(timeout: TimeInterval) -> TapMode? {
            _ = answered.wait(timeout: .now() + timeout)
            return lock.withLock {
                if let result { return result } // answered, possibly right at the timeout
                abandoned = true
                return nil
            }
        }
    }
}
