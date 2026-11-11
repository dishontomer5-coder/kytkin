// P2-17: The keyboard adapter (001 §2.2). Owns the tap thread and the KeyTapEngine that lives on it, and is the
// only way other threads reach the processor: every call hops onto the tap thread. Signals and status go to the
// main queue asynchronously, so the tap never waits for main.
//
// Who calls what:
// - main (P2-20), and main only (P2-50: `dispatchPrecondition`, so two calls can never race to create two tap
//   threads): `start(mode:)` with the mode FeatureAvailability allows (caller chooses; nothing is upgraded here),
//   `stop()`, `perform(.reset(_:))` / `perform(.inputSourceChanged(…))` on a context or input-source change,
//   `perform(.updateConfig(_:))` when the Convert / auto-fix settings change (001 §12 W6), `checkSecureInputNow()` on
//   an app change.
// - the replacement worker (P2-21, `@TextActor`), from any thread: `claimPosting(gen:)` right before posting
//   (false = abandon), then `finishReplacement(gen:…)`. It never finishes the commit itself (001 §12 K1).
//
// The real backend comes from `KeyWatcher+Live.swift` (excluded from the test target, so no test can install a tap).

import Foundation

final class KeyWatcher: @unchecked Sendable { // @unchecked: mutable state is guarded by `lock`; the engine is tap-thread confined
    /// Builds the backend for the tap thread's run loop. P2-47: called on the thread that calls `start` (main), right
    /// after the tap thread started; from then on the backend is used only on the tap thread.
    typealias BackendFactory = @Sendable (CFRunLoop) -> KeyTapBackend

    /// How long `start(mode:)` waits for the tap thread before it reports `.off`.
    static let defaultStartTimeout: TimeInterval = 1
    /// P2-50: how long `stop()` waits for the tap thread to shut the engine down.
    static let defaultStopTimeout: TimeInterval = 1

    private let lock = NSLock()
    private let makeBackend: BackendFactory
    private let clock: any Clock
    private let startTimeout: TimeInterval
    private let stopTimeout: TimeInterval
    private let onSignal: @Sendable (KeySignal) -> Void
    private let onStatus: @Sendable (KeyWatcherStatus) -> Void
    private let commit = HoldBackCommitLock()
    /// Before the first start (and after a stop), hops apply here so nothing set by main is lost.
    private var seed: KeyStreamProcessor
    private var thread: KeyTapThread?
    private var engine: KeyTapEngine?
    private var latestStatus = KeyWatcherStatus()
    /// P2-50: a tap thread whose `stop()` timed out, and its engine, kept alive until the thread has exited (its queued
    /// hops and the late shutdown still run on it). No new tap thread starts while it exists.
    private var retiring: (thread: KeyTapThread, engine: KeyTapEngine)?
    /// P2-50: after a timed-out stop, the late shutdown hands its processor back; until then main's operations are
    /// both applied to `seed` and recorded, so they can be re-applied to that processor.
    private var lateStop: LateStop = .none

    private enum LateStop {
        case none
        case awaiting(ops: [KeyWatcherOperation])
        case arrived(KeyStreamProcessor) // before main had recorded the timeout
    }

    init(processor: KeyStreamProcessor, clock: any Clock = SystemClock(),
         startTimeout: TimeInterval = KeyWatcher.defaultStartTimeout,
         stopTimeout: TimeInterval = KeyWatcher.defaultStopTimeout, makeBackend: @escaping BackendFactory,
         onSignal: @Sendable @escaping (KeySignal) -> Void,
         onStatus: @Sendable @escaping (KeyWatcherStatus) -> Void = { _ in }) {
        seed = processor
        self.clock = clock
        self.startTimeout = startTimeout
        self.stopTimeout = stopTimeout
        self.makeBackend = makeBackend
        self.onSignal = onSignal
        self.onStatus = onStatus
    }

    deinit {
        // P2-50: not `stop()`: the last reference may go on any thread, and no closure may capture `self` here.
        shutDownTapThread(adoptingLateProcessor: false)
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
    ///
    /// P2-50: main only. If an earlier `stop()` timed out, it first waits (≤ `startTimeout`) for that tap thread to
    /// exit, and returns `.off` without starting a second tap thread if it hasn't.
    @discardableResult
    func start(mode: TapMode) -> TapMode {
        dispatchPrecondition(condition: .onQueue(.main))
        guard waitForRetiringThread() else { return .off }
        let (thread, engine) = ensureRunning()
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

    /// Removes the tap (held keys are flushed first) and ends the tap thread. Main only (P2-50).
    ///
    /// P2-50: waits at most `stopTimeout`. If the tap thread doesn't answer in time, the shutdown still runs there
    /// later (it is queued ahead of the run-loop stop): the thread and its engine are kept in `retiring` until the
    /// thread exits, the next `start` waits for that exit, and the late shutdown's processor becomes the seed (with the
    /// operations main performed meanwhile applied on top), so no hop or setting is lost.
    func stop() {
        dispatchPrecondition(condition: .onQueue(.main))
        shutDownTapThread(adoptingLateProcessor: true)
    }

    /// Main → tap thread (001 §2.1, contract step 4): runs `operation` on the processor, then the flush step.
    /// Before the first start (or after a stop) it applies to the processor the next start begins with.
    /// Main only (P2-50): the order of operations is main's order.
    func perform(_ operation: KeyWatcherOperation) {
        dispatchPrecondition(condition: .onQueue(.main))
        guard let (thread, engine) = running() else {
            lock.withLock {
                Self.apply(operation, to: &seed)
                if case var .awaiting(ops) = lateStop {
                    ops.append(operation)
                    lateStop = .awaiting(ops: ops)
                }
            }
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

    /// Worker, when done (contract step 3), from any thread. The tap thread replays the held keys, then finishes the
    /// commit.
    /// P2-59: `bufferRenderedIn` passes through to the processor (001 §12.3 X5).
    func finishReplacement(gen: UInt64, newRendering: InputSourceID?, bufferAfter: [Stroke]?,
                           bufferRenderedIn: InputSourceID?) {
        guard let (thread, engine) = running() else { return }
        thread.async {
            engine.finishReplacement(gen: gen, newRendering: newRendering, bufferAfter: bufferAfter,
                                     bufferRenderedIn: bufferRenderedIn)
        }
    }

    /// Check Secure Input now (main calls this on every app change; the tap thread also polls every 1 s). Main only.
    func checkSecureInputNow() {
        dispatchPrecondition(condition: .onQueue(.main))
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

    /// P2-50: `stop()`'s work. `adoptingLateProcessor` is false from `deinit`, where no closure may capture `self`.
    private func shutDownTapThread(adoptingLateProcessor: Bool) {
        let (thread, engine) = lock.withLock { (self.thread, self.engine) }
        guard let thread, let engine else { return }
        let handoff = Handoff<KeyStreamProcessor>()
        var adopt: (@Sendable (KeyStreamProcessor) -> Void)?
        if adoptingLateProcessor {
            adopt = { [weak self] processor in self?.adoptLateProcessor(processor) }
        }
        let shutDown: @Sendable () -> Void = { [adopt] in
            engine.shutdown()
            let processor = engine.processor
            if !handoff.deliver(processor) { adopt?(processor) }
        }
        if thread.isCurrent { shutDown() } else { thread.async(shutDown) }
        thread.stopRunLoop()
        let processor = handoff.wait(timeout: stopTimeout)
        lock.withLock {
            self.thread = nil
            self.engine = nil
            if let processor {
                seed = processor
            } else if adoptingLateProcessor {
                retiring = (thread, engine)
                if case let .arrived(late) = lateStop { // it came in right after the timeout
                    seed = late
                    lateStop = .none
                } else {
                    lateStop = .awaiting(ops: [])
                }
            }
        }
        guard processor == nil, adoptingLateProcessor else { return }
        // Release the engine once the thread is gone (none of its queued blocks can run after that).
        thread.onExit(queue: .global(qos: .utility)) { [weak self] in self?.retiringThreadExited(thread) }
    }

    /// Tap thread, after a timed-out stop's late shutdown: that processor, plus what main did since, is the new seed.
    private func adoptLateProcessor(_ processor: KeyStreamProcessor) {
        lock.withLock {
            guard case let .awaiting(ops) = lateStop else {
                lateStop = .arrived(processor) // main hasn't recorded the timeout yet (so it can't have performed anything)
                return
            }
            var late = processor
            for op in ops { Self.apply(op, to: &late) }
            seed = late
            lateStop = .none
        }
    }

    private func retiringThreadExited(_ thread: KeyTapThread) {
        lock.withLock {
            guard retiring?.thread === thread else { return }
            retiring = nil
        }
    }

    /// P2-50: true when no earlier tap thread is still alive (waiting ≤ `startTimeout` for one that is exiting).
    private func waitForRetiringThread() -> Bool {
        guard let old = lock.withLock({ retiring?.thread }) else { return true }
        guard old.waitUntilExited(timeout: startTimeout) else { return false }
        retiringThreadExited(old)
        return true
    }

    /// Before the tap thread exists: the same operation on the seed (no device flags to read yet).
    private static func apply(_ operation: KeyWatcherOperation, to processor: inout KeyStreamProcessor) {
        switch operation {
        case let .reset(reason): processor.reset(reason)
        case let .inputSourceChanged(id, isOurs): processor.inputSourceChanged(to: id, isOurs: isOurs)
        case let .updateConfig(config): processor.updateConfig(config)
        case let .contextChanged(pid): processor.contextChanged(terminalPID: pid)   // P3-37 (b)
        }
    }

    private func storeStatus(_ status: KeyWatcherStatus) {
        lock.withLock { latestStatus = status }
    }

    /// P2-47: one `start(mode:)` hand-off. Main waits at most the start timeout; whether the tap thread's answer
    /// counted or main gave up first is decided under one lock, so the two can never disagree about the mode.
    private typealias ModeRequest = Handoff<TapMode>

    /// P2-47/P2-50: a tap-thread answer main waits for with a timeout (`start`'s mode, `stop`'s processor). Whether
    /// the answer counted or main gave up first is decided under one lock.
    private final class Handoff<Value: Sendable>: @unchecked Sendable { // @unchecked: state is guarded by `lock`
        private let lock = NSLock()
        private let answered = DispatchSemaphore(value: 0)
        private var abandoned = false
        private var result: Value?

        /// Tap thread, before acting: main already gave up.
        var isAbandoned: Bool { lock.withLock { abandoned } }

        /// Tap thread, after acting. False = main gave up meanwhile (`start`: undo the apply, ending in `.off`;
        /// `stop`: hand the processor over the late way).
        func deliver(_ value: Value) -> Bool {
            lock.withLock {
                guard !abandoned else { return false }
                result = value
                answered.signal()
                return true
            }
        }

        /// Main: the answer, or nil after `timeout` (from then on `deliver` returns false).
        func wait(timeout: TimeInterval) -> Value? {
            _ = answered.wait(timeout: .now() + timeout)
            return lock.withLock {
                if let result { return result } // answered, possibly right at the timeout
                abandoned = true
                return nil
            }
        }
    }
}
