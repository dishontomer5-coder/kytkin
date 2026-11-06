// P2-15: `ContextMonitoring`, tier 0 (001 §2.2, §3 flow (a)). Feeds an `AppActivationSource` into the
// pure `ContextAssembler` and calls `onChange` once per new Context. When the assembler holds a change
// (debounce), a one-shot main-run-loop timer calls `flushIfDue()` at the deadline.
// Tier 1 (AX window/browser/chat observers on their own thread) plugs in here in Phase 3/4.
// Never logs (titles and URLs never reach this type in tier 0; bundle IDs only).

import Foundation

@MainActor final class ContextMonitor: ContextMonitoring {
    var onChange: (@MainActor (Context) -> Void)?
    var current: Context? { assembler.current }

    private let source: AppActivationSource
    private let clock: any Clock
    private var assembler: ContextAssembler
    private var flushTimer: Timer?

    init(source: AppActivationSource,
         clock: any Clock = SystemClock(),
         ownPID: Int32 = ProcessInfo.processInfo.processIdentifier,
         ownBundleID: String? = Bundle.main.bundleIdentifier,
         debounceNanos: UInt64 = ContextAssembler.defaultDebounceNanos) {
        self.source = source
        self.clock = clock
        assembler = ContextAssembler(clock: clock, ownPID: ownPID, ownBundleID: ownBundleID,
                                     debounceNanos: debounceNanos)
    }

    func start() {
        source.onActivate = { [weak self] bundleID, pid in
            guard let self else { return }
            self.deliver(self.assembler.appActivated(bundleID: bundleID, pid: pid))
        }
        source.onTerminate = { [weak self] pid in
            guard let self else { return }
            self.assembler.appTerminated(pid: pid)
            self.armFlushTimer()
        }
        source.start()
    }

    func stop() {
        source.stop()
        source.onActivate = nil
        source.onTerminate = nil
        flushTimer?.invalidate()
        flushTimer = nil
        // A held change would otherwise be emitted by the first event after a later start(), even when
        // that event is Kytkin itself being frontmost. start() re-reads the frontmost app anyway.
        assembler.discardPending()
    }

    // MARK: - Private

    private func deliver(_ context: Context?) {
        if let context { onChange?(context) }
        armFlushTimer()
    }

    /// Keeps one timer aimed at the assembler's current deadline (or none).
    private func armFlushTimer() {
        flushTimer?.invalidate()
        flushTimer = nil
        guard let deadline = assembler.pendingDeadlineNanos else { return }
        let now = clock.nowNanos
        let delay = deadline > now ? TimeInterval(deadline - now) / 1_000_000_000 : 0
        let timer = Timer(timeInterval: delay, repeats: false) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.flushTimer = nil
                self.deliver(self.assembler.flushIfDue())
            }
        }
        // .common: keep firing while a menu (ours included) is tracking.
        RunLoop.main.add(timer, forMode: .common)
        flushTimer = timer
    }
}
