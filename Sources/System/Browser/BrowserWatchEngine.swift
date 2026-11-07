// P3-10: What runs on the AX thread for the frontmost browser (001 §14.1, §14.3.4, B13–B16). One engine for the
// process; at most one browser attached at a time. Per attach it holds the tree for that pid, one
// `BrowserAddressReader` (its per-window cache dies with the attach), one observer and the `BrowserReadScheduler`;
// one `DeadlineTimer` is aimed at the earliest of the scheduler's deadline and the observer's retry.
//
//   attach    → a fresh tree, reader and observer; register the notifications (R2 retry: 100 ms doubling to 1 s,
//               give up after 5 s; the poll still reads meanwhile); read at once.
//   reread    → the same pid and request were attached again (the browser came back to the front): read at once.
//   trigger   → from the observer. Gecko's `AXValueChanged` on the address bar is dropped while the bar has focus
//               (one per keystroke; its value is never fetched). A window or title change re-checks the private flag.
//   wake      → read at once (and re-try the observer if it gave up).
//   detach    → observer removed, timer removed, cache dropped: no AX calls and no timer until the next attach (B15).
//   post      → only when the facts (site, page state, private flag) changed since the last post, and always after an
//               attach, reread or wake, so main's site grace gets its first read (§14.5). Results go to main through
//               `deliver`, which never blocks (B16).
//
// Thread confinement: every method runs on the AX thread (the watcher hops there); in tests, on the test thread.
// Never logs (Browser/ folder, lint rule 2b); observations carry hosts only, never a URL (§14.3.6).

import Foundation

/// The type-erased face `BrowserWatcher` drives. AX thread only.
protocol BrowserWatchEngineDriving: AnyObject, Sendable {
    func attach(pid: Int32, request: BrowserWatchRequest, attachID: UInt64)
    func reread()
    func wake()
    func detach()
}

final class BrowserWatchEngine<Tree: AXNodeReading, Observer: BrowserNotificationObserving>: BrowserWatchEngineDriving,
    @unchecked Sendable where Observer.Node == Tree.Node { // @unchecked: confined to the AX thread (see above)
    typealias Deliver = @Sendable (_ pid: Int32, _ attachID: UInt64, BrowserObservation, _ sawWindow: Bool) -> Void

    /// R2: observer registration retry (§14.3.4).
    static var observerRetryFirstNanos: UInt64 { 100_000_000 }
    static var observerRetryMaxNanos: UInt64 { 1_000_000_000 }
    static var observerRetryGiveUpNanos: UInt64 { 5_000_000_000 }

    private let clock: any Clock
    private let makeTree: (Int32) -> Tree
    private let makeObserver: () -> Observer
    private let timer: any DeadlineTimer
    private let deliver: Deliver
    private let makeReader: (BrowserWatchRequest) -> BrowserAddressReader<Tree>
    /// P3-7: the Automation fallback (nil = none: tests that don't test it, or no live sender).
    private let appleEvents: AppleEventFallback?

    private struct Attached {
        let pid: Int32
        let attachID: UInt64
        let request: BrowserWatchRequest
        let tree: Tree
        var reader: BrowserAddressReader<Tree>
        let observer: Observer
        var observerReady = false
        var retry: ObserverRetry?
        var watchedBar: Tree.Node?
        var lastPosted: BrowserObservation?
    }

    private struct ObserverRetry {
        var at: UInt64
        var delay: UInt64
        let giveUpAt: UInt64
    }

    private var attached: Attached?
    private var scheduler = BrowserReadScheduler()

    /// Reads done since the engine was made (for tests and P3-14's DEBUG line).
    private(set) var readCount = 0

    init(clock: any Clock, siteReader: SiteReader, makeTree: @escaping (Int32) -> Tree,
         makeObserver: @escaping () -> Observer, timer: any DeadlineTimer, deliver: @escaping Deliver,
         makeReader: ((BrowserWatchRequest) -> BrowserAddressReader<Tree>)? = nil,
         appleEvents: AppleEventFallback? = nil) {
        self.clock = clock
        self.appleEvents = appleEvents
        self.makeTree = makeTree
        self.makeObserver = makeObserver
        self.timer = timer
        self.deliver = deliver
        // Tests pass a reader with a stand-in strategy; the app uses each engine's own (P3-11, P3-13).
        self.makeReader = makeReader ?? { BrowserAddressReader(request: $0, siteReader: siteReader) }
        timer.onFire = { [weak self] in self?.service() }
    }

    var isAttached: Bool { attached != nil }
    var attachedPid: Int32? { attached?.pid }
    var isObserverReady: Bool { attached?.observerReady ?? false }

    // MARK: - Driving

    func attach(pid: Int32, request: BrowserWatchRequest, attachID: UInt64) {
        detach()
        let now = clock.nowNanos
        var reader = makeReader(request)
        reader.deadlineClock = clock   // B13: a read stops after 0.5 s wall
        // P3-7 (§14.7): Apple Events only with a dialect in the request (opted in ∧ granted ∧ Kytkin on).
        if let dialect = request.appleScript, let appleEvents {
            appleEvents.attached(pid: pid)
            reader.appleEvents = AppleEventSession(pid: pid, dialect: dialect, fallback: appleEvents)
        }
        let observer = makeObserver()
        attached = Attached(pid: pid, attachID: attachID, request: request, tree: makeTree(pid), reader: reader,
                            observer: observer)
        observer.onTrigger = { [weak self] t in self?.trigger(t) }
        tryObserver(now: now, after: nil)
        attached?.reader.noteTrigger(.attached)
        scheduler.attached(now: now)
        service()
    }

    func reread() {
        guard attached != nil else { return }
        trigger(.attached)
    }

    func wake() {
        guard let a = attached else { return }
        if !a.observerReady && a.retry == nil { tryObserver(now: clock.nowNanos, after: nil) }
        trigger(.wake)
    }

    func detach() {
        guard let a = attached else { return }
        a.observer.onTrigger = nil
        a.observer.detach()
        attached = nil
        scheduler.detached()
        timer.schedule(atNanos: nil)
    }

    /// From the observer (AX thread).
    func trigger(_ t: BrowserTrigger) {
        guard let a = attached else { return }
        if t == .addressValueChanged {
            // Gecko posts one per keystroke while the bar has focus: drop it unless the bar is known to be unfocused.
            // Only AXFocused is asked; the value is never fetched here.
            guard let bar = a.watchedBar, (try? a.tree.isFocused(bar)) == .some(false) else { return }
        }
        attached?.reader.noteTrigger(t)
        if t == .attached || t == .wake { attached?.lastPosted = nil }
        scheduler.trigger(t, now: clock.nowNanos)
        service()
    }

    // MARK: - Timer

    /// Runs whatever is due, then re-aims the timer. Also the timer's handler.
    func service() {
        guard attached != nil else {
            timer.schedule(atNanos: nil)
            return
        }
        let now = clock.nowNanos
        if let r = attached?.retry, r.at <= now { tryObserver(now: now, after: r) }
        if scheduler.takeDue(now: now) { performRead() }
        guard let a = attached else { return }
        var next = scheduler.nextDeadlineNanos
        if let r = a.retry { next = min(next ?? r.at, r.at) }
        timer.schedule(atNanos: next)
    }

    // MARK: - Internals

    private func performRead() {
        guard var a = attached else { return }
        let start = clock.nowNanos
        let (observation, sawWindow) = a.reader.read(a.tree, now: start)
        readCount += 1
        scheduler.readFinished(observation, sawWindow: sawWindow, now: clock.nowNanos)
        if let at = a.reader.takeAppleEventRetry() { scheduler.readAgain(at: at) }   // P3-7: rate-limited send
        if a.request.engine == .gecko { updateBarWatch(&a) }
        let changed = a.lastPosted.map { !observation.hasSameFacts(as: $0) } ?? true
        if changed { a.lastPosted = observation }
        attached = a
        if changed { deliver(a.pid, a.attachID, observation, sawWindow) }
    }

    /// Gecko: keep `AXValueChanged` registered on the window's cached address bar (re-registered when it changes).
    private func updateBarWatch(_ a: inout Attached) {
        let bar = a.reader.windows.first?.addressBar
        switch (bar, a.watchedBar) {
        case (nil, nil): return
        case let (new?, old?) where a.tree.isSame(new, old): return
        default:
            a.watchedBar = bar
            if a.observerReady { a.observer.observeValueChanges(of: bar) }
        }
    }

    /// Registers the observer; on failure schedules the next try (100 ms, doubling to 1 s), until `giveUpAt`.
    private func tryObserver(now: UInt64, after previous: ObserverRetry?) {
        guard let a = attached else { return }
        if a.observer.attach(pid: a.pid) {
            attached?.observerReady = true
            attached?.retry = nil
            if let bar = a.watchedBar { a.observer.observeValueChanges(of: bar) }
            return
        }
        let delay = previous.map { min($0.delay * 2, Self.observerRetryMaxNanos) } ?? Self.observerRetryFirstNanos
        let giveUpAt = previous?.giveUpAt ?? now + Self.observerRetryGiveUpNanos
        // Past the give-up time the observer stays off; the 2 s poll keeps reading (§14.3.4).
        attached?.retry = now + delay <= giveUpAt ? ObserverRetry(at: now + delay, delay: delay, giveUpAt: giveUpAt) : nil
    }
}
