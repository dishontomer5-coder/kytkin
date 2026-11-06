// P2-17: Everything KeyWatcher does on the tap thread, behind the KeyTapBackend seam so it is unit-tested with a
// fake (001 §2.2 "KeyWatcher adapter contract", binding; §7 B1–B4, B12; §12 K1).
//
// Per tap event (the callback, O(1), no AX/TIS/logging, allocation only when an event is held):
//   1. disabled-by-timeout / user-input notice → the B4 watchdog policy (re-enable, downgrade, off);
//   2. marker check first: `ours` passes untouched and never reaches the processor;
//   3. CGEvent → KeyEvent, `processor.handle`, apply the verdict (`.hold` keeps a CGEvent copy in a FIFO
//      parallel to the processor's queue);
//   4. a signal that starts a replacement arms the commit *before* it is sent off the tap thread;
//   5. the flush step (contract step 2): `claimFlush` before `pollFlush`, re-post marked `replay`, then
//      `commit.finish` — on the tap thread only, after the flush it belongs to.
// The worker's finish arrives through `finishReplacement`: replay, then `commit.finish`, then the flush step.
//
// Thread-confined: every method runs on the tap thread (`@unchecked Sendable` for that reason). Never log here.

import CoreGraphics
import Foundation

final class KeyTapEngine: @unchecked Sendable {
    typealias SignalSink = (KeySignal) -> Void
    typealias StatusSink = (KeyWatcherStatus) -> Void

    private(set) var processor: KeyStreamProcessor
    let commit: HoldBackCommitLock
    private(set) var status = KeyWatcherStatus()

    private let backend: KeyTapBackend
    private let clock: any Clock
    private let machNow: () -> UInt64
    private let sendSignal: SignalSink
    private let sendStatus: StatusSink
    private var policy = TapHealthPolicy()
    private var timestamps: EventTimestampNormalizer
    /// The CGEvents behind the processor's held events, same order (contract step 1). Copies, marked on replay.
    private var held: [(event: KeyEvent, cgEvent: CGEvent)] = []
    private var armedDeadline: UInt64?
    private var pollTicks = 0

    /// B4: the watchdog checks `tapIsEnabled` every this many 1 s polls (001 §7 B4: every 2 s).
    static let healthCheckEveryPolls = 2

    init(processor: KeyStreamProcessor, commit: HoldBackCommitLock, backend: KeyTapBackend,
         clock: any Clock = SystemClock(), timestamps: EventTimestampNormalizer = .system(),
         machNow: @escaping () -> UInt64 = { mach_absolute_time() },
         sendSignal: @escaping SignalSink, sendStatus: @escaping StatusSink) {
        self.processor = processor
        self.commit = commit
        self.backend = backend
        self.clock = clock
        self.timestamps = timestamps
        self.machNow = machNow
        self.sendSignal = sendSignal
        self.sendStatus = sendStatus
        held.reserveCapacity(HoldBackQueue.maxCapacity)
        backend.attachTimers(deadline: { [unowned self] in self.deadlineFired() },
                             poll: { [unowned self] in self.periodicCheck() })
    }

    var mode: TapMode { status.health.mode }
    var heldCGEventCount: Int { held.count }

    // MARK: - The tap callback

    /// True = let the event through; false = swallow it (only meaningful for an active tap).
    func handleTapEvent(type: CGEventType, event: CGEvent) -> Bool {
        if KeyEventTranslator.isTapDisabledNotice(type) {
            tapWasDisabled()
            return true
        }
        // Marker check first (design.md): our own posted text never reaches the buffer or the detector.
        let origin = KeyEventTranslator.origin(of: event)
        if origin == .ours { return true }
        guard let kind = KeyEventTranslator.kind(for: type) else { return true }
        #if DEBUG
        let started = clock.nowNanos
        #endif

        let nanos = timestamps.nanos(fromEventTimestamp: event.timestamp, machNow: machNow(),
                                     uptimeNanosNow: clock.nowNanos)
        let keyEvent = KeyEventTranslator.keyEvent(kind, from: event, origin: origin, timestampNanos: nanos)
        let (verdict, signal) = processor.handle(keyEvent)
        let pass: Bool
        switch verdict {
        case .pass:
            pass = true
        case .swallow:
            pass = false
        case .hold:
            // The system owns the original after we return nil, so keep a copy for the replay.
            held.append((keyEvent, event.copy() ?? event))
            pass = false
        }
        if let signal { emit(signal) }
        runFlushStep()

        #if DEBUG
        let before = status.health.overBudgetCallbacks
        status.health.recordCallback(durationNanos: clock.nowNanos &- started)
        if status.health.overBudgetCallbacks != before { publish() }
        #endif
        return pass
    }

    // MARK: - Hops from main / the worker (already on the tap thread)

    /// Main → tap (contract step 4): run the block on the processor, then the flush step.
    func perform(_ block: (inout KeyStreamProcessor) -> Void) {
        block(&processor)
        runFlushStep()
    }

    /// Reset with the current modifier flags (so a Shift held across it is remembered), then the flush step.
    func reset(_ reason: ResetReason) {
        let hadWord = !processor.buffer.isEmpty
        processor.reset(reason, deviceFlags: backend.currentDeviceFlags)
        if hadWord { sendSignal(.bufferInvalidated) }
        runFlushStep()
    }

    /// The worker is done (contract step 3): replay what the processor returns, *then* `commit.finish`, then the
    /// flush step. A stale generation replays nothing and leaves a newer generation's commit alone.
    func finishReplacement(gen: UInt64, newRendering: InputSourceID?, bufferAfter: [Stroke]?) {
        let events = processor.finishReplacement(gen: gen, newRendering: newRendering, bufferAfter: bufferAfter)
        replay(events)
        commit.finish(gen: gen)
        runFlushStep()
    }

    /// Install the tap for `requested` (or none for `.off`) and return the mode actually running.
    /// `userInitiated` (start/stop from main) clears the watchdog history; the watchdog's own downgrade doesn't.
    /// Never installs without the silent permission check, so it never causes a system prompt.
    @discardableResult
    func applyMode(_ requested: TapMode, userInitiated: Bool) -> TapMode {
        if userInitiated {
            policy.reset()
            status.degradedByWatchdog = false
            if requested == mode, requested != .off, backend.isEnabled {
                publish()
                return requested
            }
        }
        backend.uninstall()
        var achieved: TapMode = .off
        if requested != .off, backend.isGranted(requested),
           backend.install(mode: requested, handler: { [unowned self] type, event in
               self.handleTapEvent(type: type, event: event)
           }) {
            achieved = requested
        }
        timestamps.reset()
        let hadWord = !processor.buffer.isEmpty
        processor.setMode(achieved) // a change resets: the replacement aborts and held keys flush below
        if hadWord && processor.buffer.isEmpty { sendSignal(.bufferInvalidated) }
        runFlushStep()
        status.health.mode = achieved
        if achieved == .off {
            status.secureInputOn = false
        } else {
            checkSecureInput(publishing: false)
        }
        publish()
        return achieved
    }

    // MARK: - Timers (tap thread)

    /// The one-shot hold-back deadline timer fired.
    func deadlineFired() {
        // Spent: forget it, so the flush step re-arms even for the same time (a timer that fired a bit early).
        armedDeadline = nil
        backend.cancelDeadline()
        runFlushStep()
    }

    /// Every 1 s: Secure Input (001 §2.2, B9) and, every 2nd poll, the tap-health watchdog (B4).
    func periodicCheck() {
        guard mode != .off else { return }
        checkSecureInput(publishing: true)
        pollTicks &+= 1
        if pollTicks % Self.healthCheckEveryPolls == 0, !backend.isEnabled {
            tapWasDisabled()
        }
    }

    /// Also run on every app change (P2-20 calls it through KeyWatcher).
    func checkSecureInput(publishing: Bool) {
        let on = mode != .off && backend.isSecureInputEnabled
        guard on != status.secureInputOn else { return }
        status.secureInputOn = on
        // §6.2: the buffer and any replacement stop while another app protects typing. Double-Shift keeps working.
        if on { reset(.secureInputOn) }
        if publishing { publish() }
    }

    // MARK: - Watchdog (B4)

    func tapWasDisabled() {
        guard mode != .off else { return }
        switch policy.tapWasDisabled(atNanos: clock.nowNanos, mode: mode) {
        case .reEnable:
            backend.reEnable()
            status.health.reEnableCount += 1
            reset(.tapReEnabled) // events were missed
            publish()
        case .downgradeToListenOnly:
            replaceTapSoon(with: .listenOnly)
        case .turnOff:
            replaceTapSoon(with: .off)
        }
    }

    /// Replacing a tap from inside its own callback is unsafe, so it runs right after the callback returns.
    private func replaceTapSoon(with newMode: TapMode) {
        status.degradedByWatchdog = true
        backend.runSoon { [unowned self] in
            self.applyMode(newMode, userInitiated: false)
        }
    }

    // MARK: - Contract step 2

    /// `claimFlush` before `pollFlush`; re-post the flushed events marked `replay`; then `commit.finish`.
    func runFlushStep() {
        guard let gen = processor.activeGeneration else {
            disarmDeadline()
            return
        }
        var posting = false
        if let due = processor.nextDeadlineNanos, due <= clock.nowNanos {
            posting = !commit.claimFlush(gen: gen)
        }
        if let events = processor.pollFlush(postingStarted: posting) {
            replay(events)
            commit.finish(gen: gen)
        }
        rearmDeadline()
    }

    // MARK: - Private

    /// Contract step 1: a signal that starts a replacement arms the commit before anyone can see it.
    private func emit(_ signal: KeySignal) {
        switch signal {
        case let .doubleShift(_, gen), let .wordEnded(_, gen):
            if processor.isReplacing, processor.activeGeneration == gen { commit.arm(gen: gen) }
        case .wordBoundary, .bufferInvalidated, .undoCandidate:
            break
        }
        sendSignal(signal)
    }

    /// Re-posts the CGEvents behind `events`, in order, marked `replay`. The processor may leave some held events
    /// out (an auto-fix trigger the worker posted itself, K3), so match them as an in-order subsequence.
    private func replay(_ events: [HeldEvent]) {
        var i = 0
        for h in events {
            while i < held.count, held[i].event != h.event { i += 1 }
            guard i < held.count else { break }
            let e = held[i].cgEvent
            e.setIntegerValueField(.eventSourceUserData, value: EventOrigin.replayMarker)
            backend.post(e)
            i += 1
        }
        // Every drain empties the processor's queue; a stale finish drains nothing and keeps a newer hold.
        if processor.heldCount == 0 { held.removeAll(keepingCapacity: true) }
    }

    private func rearmDeadline() {
        guard let due = processor.nextDeadlineNanos else {
            disarmDeadline()
            return
        }
        guard armedDeadline != due else { return }
        armedDeadline = due
        backend.armDeadline(atUptimeNanos: due)
    }

    private func disarmDeadline() {
        guard armedDeadline != nil else { return }
        armedDeadline = nil
        backend.cancelDeadline()
    }

    private func publish() {
        sendStatus(status)
    }
}
