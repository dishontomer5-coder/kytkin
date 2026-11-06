// P2-17: The keyboard adapter (001 §2.2). Owns the tap thread and the KeyTapEngine that lives on it, and is the
// only way other threads reach the processor: every call hops onto the tap thread. Signals and status go to the
// main queue asynchronously, so the tap never waits for main.
//
// Who calls what:
// - main (P2-20): `start(mode:)` with the mode FeatureAvailability allows (caller chooses; nothing is upgraded
//   here), `stop()`, `perform` / `reset` on a context or input-source change, `checkSecureInputNow()` on an app change.
// - the replacement worker (P2-21): `claimPosting(gen:)` right before posting (false = abandon), then
//   `finishReplacement(gen:…)`. It never finishes the commit itself (001 §12 K1).
//
// The real backend comes from `KeyWatcher+Live.swift` (excluded from the test target, so no test can install a tap).

import Foundation

final class KeyWatcher: @unchecked Sendable { // @unchecked: mutable state is guarded by `lock`; the engine is tap-thread confined
    /// Builds the backend on the tap thread, for that thread's run loop.
    typealias BackendFactory = @Sendable (CFRunLoop) -> KeyTapBackend

    private let lock = NSLock()
    private let makeBackend: BackendFactory
    private let clock: any Clock
    private let onSignal: @Sendable (KeySignal) -> Void
    private let onStatus: @Sendable (KeyWatcherStatus) -> Void
    private let commit = HoldBackCommitLock()
    /// Before the first start (and after a stop), hops apply here so nothing set by main is lost.
    private var seed: KeyStreamProcessor
    private var thread: KeyTapThread?
    private var engine: KeyTapEngine?
    private var latestStatus = KeyWatcherStatus()

    init(processor: KeyStreamProcessor, clock: any Clock = SystemClock(), makeBackend: @escaping BackendFactory,
         onSignal: @Sendable @escaping (KeySignal) -> Void,
         onStatus: @Sendable @escaping (KeyWatcherStatus) -> Void = { _ in }) {
        seed = processor
        self.clock = clock
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
    /// `.off` when the permission check fails, `tapCreate` fails, or the tap thread didn't answer within 1 s.
    /// Calling it again switches modes (a permission was granted or revoked).
    @discardableResult
    func start(mode: TapMode) -> TapMode {
        let (thread, engine) = ensureRunning()
        return thread.sync { engine.applyMode(mode, userInitiated: true) } ?? .off
    }

    /// Removes the tap (held keys are flushed first) and ends the tap thread.
    func stop() {
        let (thread, engine) = lock.withLock { (self.thread, self.engine) }
        guard let thread, let engine else { return }
        let processor = thread.sync { () -> KeyStreamProcessor in
            engine.applyMode(.off, userInitiated: true)
            return engine.processor
        }
        thread.stopRunLoop()
        lock.withLock {
            if let processor { seed = processor }
            self.thread = nil
            self.engine = nil
        }
    }

    /// Main/TextActor → tap thread (001 §2.1): runs `block` on the processor, then the flush step.
    func perform(_ block: @Sendable @escaping (inout KeyStreamProcessor) -> Void) {
        guard let (thread, engine) = running() else {
            lock.withLock { block(&seed) }
            return
        }
        thread.async { engine.perform(block) }
    }

    /// Reset with the current modifier flags read on the tap thread (contract step 4).
    func reset(_ reason: ResetReason) {
        guard let (thread, engine) = running() else {
            lock.withLock { seed.reset(reason) }
            return
        }
        thread.async { engine.reset(reason) }
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

    private func storeStatus(_ status: KeyWatcherStatus) {
        lock.withLock { latestStatus = status }
    }
}
