// P3-10: The AX thread's one read timer (001 §14.3.4). It lives on the run loop of the thread that first schedules
// it (the AX thread) and exists only while a deadline is set: `schedule(atNanos: nil)` invalidates and drops it, so
// with no browser in front there is no timer at all (B15). Deadlines are the `Clock`'s monotonic nanos; the fire
// date is "now + what's left", recomputed on every schedule. After sleep the watcher's `wake()` re-reads anyway.

import Foundation

final class RunLoopDeadlineTimer: DeadlineTimer {
    var onFire: (() -> Void)?

    private let clock: any Clock
    private var timer: CFRunLoopTimer?

    init(clock: any Clock) {
        self.clock = clock
    }

    deinit {
        if let timer { CFRunLoopTimerInvalidate(timer) }
    }

    func schedule(atNanos nanos: UInt64?) {
        guard let nanos else {
            if let timer { CFRunLoopTimerInvalidate(timer) }
            timer = nil
            return
        }
        let now = clock.nowNanos
        let left = nanos > now ? Double(nanos - now) / 1e9 : 0
        let fireDate = CFAbsoluteTimeGetCurrent() + left
        if let timer {
            CFRunLoopTimerSetNextFireDate(timer, fireDate)
            return
        }
        // Repeating with a huge interval, so it survives firing and is re-aimed with SetNextFireDate.
        let t = CFRunLoopTimerCreateWithHandler(nil, fireDate, 1e9, 0, 0) { [weak self] _ in self?.onFire?() }
        CFRunLoopAddTimer(CFRunLoopGetCurrent(), t, .commonModes)
        timer = t
    }
}
