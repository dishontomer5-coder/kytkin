// P3-6: When the AX thread reads the frontmost browser (001 §14.3.4, §14.3.5, B14, B15). Pure: time comes in as
// `now` (monotonic nanos), so tests drive it with a FakeClock. The AX thread keeps one timer aimed at
// `nextDeadlineNanos`; when it fires (or right after a trigger) it asks `takeDue(now:)`, reads if that says so,
// and reports back with `readFinished`. Reads are synchronous on the AX thread, so there is never a read in flight
// while the scheduler is asked something.
//
//   attached / wake       → read at once (no debounce), and restart the readiness retries.
//   any other trigger     → read 150 ms after the last trigger of a burst, never later than 500 ms after its first.
//   focus change          → P3-29: also read at once (leading edge), at most one such read per 50 ms; the burst's
//                           150 ms trailing read still follows. ⌘L or a click into the address bar must switch to
//                           the browser's language before the first key, and a 150 ms debounce alone was too slow.
//   readiness retries     → after the attach read, while reads see no window or give `.unknown`: re-read at
//                           attach + 250 ms, + 500 ms, + 1 s, + 2 s (cold Gecko, a launching browser), then stop.
//                           Any read that saw a window and gave something other than `.unknown` ends them.
//   safety poll           → 2 s after the last read while attached (a read for any reason resets it).
//   detached              → no deadline at all: no timer, no AX calls (B15).
//   Apple Event retry     → P3-7: a read wanted an Apple Event but the 1 s rate limit held it back: read again at
//                           the time the limit allows (`readAgain(at:)`).
// Several due reasons coalesce into one read, and a read covers every trigger before it.

struct BrowserReadScheduler: Sendable {
    static let debounceNanos: UInt64 = 150_000_000
    static let maxWaitNanos: UInt64 = 500_000_000
    static let pollNanos: UInt64 = 2_000_000_000
    static let readinessRetryNanos: [UInt64] = [250_000_000, 500_000_000, 1_000_000_000, 2_000_000_000]
    /// P3-29: a focus change reads at once unless a read ran less than this long ago (then at this gap after it).
    /// Caps a storm of focus notifications at ~20 cached reads per second.
    static let focusReadGapNanos: UInt64 = 50_000_000

    private(set) var isAttached = false
    private var immediateAt: UInt64?      // a read at once was asked for at this time
    private var burstFirstAt: UInt64?
    private var burstDeadline: UInt64?
    private var retryBase: UInt64?        // the attach read's time; nil = no retries pending
    private var retryIndex = 0
    private var pollAt: UInt64?
    private var againAt: UInt64?          // P3-7: an Apple Event held back by the rate limit
    private var focusAt: UInt64?          // P3-29: the leading-edge read for a focus change
    private var lastReadAt: UInt64?       // P3-29: for the focus read gap

    init() {}

    /// P3-7: read again at `at` (the time the Apple Event rate limit allows the next send). The earliest one wins.
    mutating func readAgain(at: UInt64) {
        guard isAttached else { return }
        againAt = min(againAt ?? at, at)
    }

    /// The browser became frontmost (or its request changed): read at once.
    mutating func attached(now: UInt64) {
        isAttached = true
        immediateAt = now
        burstFirstAt = nil
        burstDeadline = nil
        retryBase = now
        retryIndex = 0
        pollAt = now + Self.pollNanos
    }

    /// Another app became frontmost, or the request went nil: nothing is due any more.
    mutating func detached() {
        self = BrowserReadScheduler()
    }

    mutating func trigger(_ t: BrowserTrigger, now: UInt64) {
        guard isAttached else { return }
        switch t {
        case .attached, .wake:
            attached(now: now)
        case .focusedWindowChanged, .mainWindowChanged, .focusedElementChanged, .titleChanged, .loadComplete,
             .addressValueChanged:
            if t == .focusedElementChanged {
                // P3-29: leading edge. The trailing burst read below still follows (a focus move can settle late).
                let at = max(now, lastReadAt.map { $0 + Self.focusReadGapNanos } ?? now)
                focusAt = min(focusAt ?? at, at)
            }
            let first = burstFirstAt ?? now
            burstFirstAt = first
            burstDeadline = min(now + Self.debounceNanos, first + Self.maxWaitNanos)
        }
    }

    /// After every read. `sawWindow == false` or an `.unknown` page keeps the readiness retries going.
    mutating func readFinished(_ o: BrowserObservation, sawWindow: Bool, now: UInt64) {
        guard isAttached else { return }
        pollAt = now + Self.pollNanos
        guard let base = retryBase else { return }
        if sawWindow && o.pageState != .unknown {
            retryBase = nil
            return
        }
        while retryIndex < Self.readinessRetryNanos.count, base + Self.readinessRetryNanos[retryIndex] <= now {
            retryIndex += 1
        }
        if retryIndex >= Self.readinessRetryNanos.count { retryBase = nil }
    }

    /// The earliest time a read is due; nil while detached.
    var nextDeadlineNanos: UInt64? {
        guard isAttached else { return nil }
        var deadline = pollAt
        if let i = immediateAt { deadline = min(deadline ?? i, i) }
        if let b = burstDeadline { deadline = min(deadline ?? b, b) }
        if let r = retryDeadline { deadline = min(deadline ?? r, r) }
        if let a = againAt { deadline = min(deadline ?? a, a) }
        if let f = focusAt { deadline = min(deadline ?? f, f) }
        return deadline
    }

    /// true = read now. Consumes every reason that is due (they coalesce into this one read).
    mutating func takeDue(now: UInt64) -> Bool {
        guard isAttached, let deadline = nextDeadlineNanos, deadline <= now else { return false }
        // P3-29: a read that only the focus leading edge made due keeps the burst's trailing read.
        let focusOnly = (focusAt.map { $0 <= now } ?? false) && !(immediateAt.map { $0 <= now } ?? false)
            && !(burstDeadline.map { $0 <= now } ?? false) && !(retryDeadline.map { $0 <= now } ?? false)
            && !(againAt.map { $0 <= now } ?? false) && !(pollAt.map { $0 <= now } ?? false)
        immediateAt = nil
        focusAt = nil
        lastReadAt = now
        if !focusOnly {
            // A read now covers every trigger so far, even a burst whose debounce hasn't run out.
            burstDeadline = nil
            burstFirstAt = nil
        }
        if let r = retryDeadline, r <= now { retryIndex += 1 }
        if let a = againAt, a <= now { againAt = nil }
        pollAt = now + Self.pollNanos   // readFinished re-arms it from the read's end
        return true
    }

    private var retryDeadline: UInt64? {
        guard let base = retryBase, retryIndex < Self.readinessRetryNanos.count else { return nil }
        return base + Self.readinessRetryNanos[retryIndex]
    }
}
