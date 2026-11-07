// P2-15: `ContextMonitoring`, tier 0 (001 §2.2, §3 flow (a)). Feeds an `AppActivationSource` into the
// pure `ContextAssembler` and calls `onChange` once per new Context. When the assembler holds a change
// (debounce), a one-shot main-run-loop timer calls `flushIfDue()` at the deadline.
// P3-5: `setHostsWithOverrides` and `currentAppIsGone` pass through to the assembler. P2-41: an isolated deinit stops
// the source and the flush timer, so a monitor released without `stop()` leaves no observer or timer behind.
//
// P3-14: tier 1, the browser watcher (001 §14.1, §14.5). The monitor keeps the raw frontmost app (Kytkin included)
// and the `SitePolicy` AppController pushes. On every activation, even one the assembler ignores (Kytkin itself, a
// duplicate): a watch request for that app → `browsers.attach` and the activation waits for its first read (the site
// grace, D4); no request (not a browser, Kytkin, site rules off, no Accessibility, PSL missing) → `browsers.detach`.
//   - A policy change re-runs that for the app in front. A browser that stops being watched while in front (Pause,
//     Kytkin off, Accessibility revoked, site rules turned off for it) drops its site fields, so its app rule applies.
//   - Observations: a stale attachID is dropped; the rest go to the assembler and `browserSupport`.
//   - Session resign (fast user switching away) → detach. Wake / session back → the source re-reports the frontmost
//     app (re-attach or re-read), then `browsers.wake()`.
//   - stop() and the isolated deinit detach.
//   - QA (P3-14): a policy change that starts watching the browser in front (Resume, turned on, a grant) holds it for
//     its first read like an activation (`isAwaitingSite`); the watched browser quitting or crashing detaches at once.
// Never logs (titles and URLs never reach this type: an observation carries a reduced site only; bundle IDs only).

import Foundation

@MainActor final class ContextMonitor: ContextMonitoring {
    var onChange: (@MainActor (Context) -> Void)?
    var current: Context? { assembler.current }
    var currentAppIsGone: Bool { assembler.currentAppIsGone }
    /// P3-14: session only (D15), for Settings → Browsers & Sites.
    private(set) var browserSupport = BrowserSupportTracker()

    private let source: AppActivationSource
    private let browsers: (any BrowserWatching)?
    private let clock: any Clock
    private let ownPID: Int32
    private let ownBundleID: String?
    private var assembler: ContextAssembler
    private var flushTimer: Timer?

    /// P3-14: the policy AppController pushed (nil = none yet: nothing is watched).
    private(set) var sitePolicy: SitePolicy?
    /// P3-14: the raw frontmost app as last reported, Kytkin included.
    private var frontmost: (bundleID: String, pid: Int32)?
    /// P3-14: the browser being watched now and the attach its results must carry.
    private struct Watch: Equatable {
        let pid: Int32
        let bundleID: String
        let request: BrowserWatchRequest
        let attachID: UInt64
    }
    private var watch: Watch?
    /// P3-14: false between a session resign and the next wake / activation.
    private var sessionActive = true
    /// P3-14: DEBUG only (counts and states, never a host).
    private var observationCount = 0
    private var lastObservation: BrowserObservation?

    init(source: AppActivationSource,
         browsers: (any BrowserWatching)? = nil,
         clock: any Clock = SystemClock(),
         ownPID: Int32 = ProcessInfo.processInfo.processIdentifier,
         ownBundleID: String? = Bundle.main.bundleIdentifier,
         debounceNanos: UInt64 = ContextAssembler.defaultDebounceNanos) {
        self.source = source
        self.browsers = browsers
        self.clock = clock
        self.ownPID = ownPID
        self.ownBundleID = ownBundleID
        assembler = ContextAssembler(clock: clock, ownPID: ownPID, ownBundleID: ownBundleID,
                                     debounceNanos: debounceNanos)
    }

    func start() {
        browsers?.onObservation = { [weak self] pid, attachID, observation, sawWindow in
            self?.observed(observation, pid: pid, attachID: attachID, sawWindow: sawWindow)
        }
        source.onActivate = { [weak self] bundleID, pid in
            self?.activated(bundleID: bundleID, pid: pid)
        }
        source.onTerminate = { [weak self] pid in
            guard let self else { return }
            // QA (P3-14): the watched browser quit or crashed: stop now (no observer or poll left on a dead pid until
            // the next activation; a read still in flight is dropped as stale).
            if self.watch?.pid == pid { self.stopWatching() }
            if self.frontmost?.pid == pid { self.frontmost = nil }
            self.assembler.appTerminated(pid: pid)
            self.armFlushTimer()
        }
        source.onWake = { [weak self] in
            guard let self else { return }
            self.sessionActive = true
            if self.watch != nil { self.browsers?.wake() }
        }
        source.onSessionResign = { [weak self] in
            guard let self else { return }
            self.sessionActive = false
            self.stopWatching()
        }
        source.start()
    }

    /// P2-41: the same cleanup as `stop()`, without touching the assembler (it goes away with us).
    /// P3-14: the browser watcher is detached too (no observer, no timer, no AX calls left behind).
    isolated deinit {
        source.stop()
        source.onActivate = nil
        source.onTerminate = nil
        source.onWake = nil
        source.onSessionResign = nil
        flushTimer?.invalidate()
        if watch != nil { browsers?.detach() }
        browsers?.onObservation = nil
    }

    func stop() {
        source.stop()
        source.onActivate = nil
        source.onTerminate = nil
        source.onWake = nil
        source.onSessionResign = nil
        flushTimer?.invalidate()
        flushTimer = nil
        stopWatching()
        browsers?.onObservation = nil
        frontmost = nil
        // A held change would otherwise be emitted by the first event after a later start(), even when
        // that event is Kytkin itself being frontmost. start() re-reads the frontmost app anyway.
        assembler.discardPending()
    }

    func setHostsWithOverrides(_ hosts: Set<String>) {
        deliver(assembler.setHostsWithOverrides(hosts))
    }

    /// P3-14: re-attaches (a new request), detaches (none any more) or leaves the watch alone (the same request).
    func setSitePolicy(_ policy: SitePolicy) {
        guard policy != sitePolicy else { return }
        sitePolicy = policy
        // While another user's session is in front nothing is watched; the next activation or wake applies it.
        guard sessionActive, let frontmost else { return }
        let wasWatching = watch?.pid == frontmost.pid
        if updateWatch(bundleID: frontmost.bundleID, pid: frontmost.pid, rereadIfSame: false) {
            // QA (P3-14): newly watched while in front (Resume, turned on, a grant): hold for the first read, like
            // an activation (D4), so the rule applies once with the site.
            if !wasWatching {
                assembler.awaitSite(pid: frontmost.pid)
                armFlushTimer()
            }
        } else {
            deliver(assembler.browserUnwatched(pid: frontmost.pid))
        }
    }

    var isAwaitingSite: Bool { assembler.isAwaitingSite }

    var siteDebug: String {
        guard let watch else { return "Sites: not watching" }
        var line = "Sites: \(watch.request.engine.rawValue) attach #\(watch.attachID), \(observationCount) updates"
        if let o = lastObservation {
            line += "; last: \(o.pageState) via \(o.via)" + (o.isPrivate == true ? ", private" : "")
        }
        return line
    }

    // MARK: - Private

    private func activated(bundleID: String, pid: Int32) {
        sessionActive = true   // an activation means this session is in front
        frontmost = (bundleID, pid)
        let watching = updateWatch(bundleID: bundleID, pid: pid, rereadIfSame: true)
        deliver(assembler.appActivated(bundleID: bundleID, pid: pid, awaitsSite: watching))
        // Back in a browser that is no longer watched (its site rules were turned off while Settings was in front):
        // the same app gives no new Context, so drop its stale site fields here.
        if !watching { deliver(assembler.browserUnwatched(pid: pid)) }
    }

    /// Attaches to the app in front if the policy has a request for it, else detaches. True = watching `pid` now.
    /// `rereadIfSame`: an activation of the watched browser re-reads it (the watcher does that for the same request);
    /// a policy change that leaves the request alone doesn't.
    @discardableResult
    private func updateWatch(bundleID: String, pid: Int32, rereadIfSame: Bool) -> Bool {
        guard let browsers, sessionActive, !isOwnApp(bundleID: bundleID, pid: pid),
              let request = sitePolicy?.request(for: bundleID) else {
            stopWatching()
            return false
        }
        if !rereadIfSame, let watch, watch.pid == pid, watch.request == request { return true }
        let id = browsers.attach(pid: pid, bundleID: bundleID, request: request)
        let next = Watch(pid: pid, bundleID: bundleID, request: request, attachID: id)
        if next != watch { lastObservation = nil }
        watch = next
        return true
    }

    private func stopWatching() {
        guard watch != nil else { return }
        watch = nil
        lastObservation = nil
        browsers?.detach()
    }

    private func isOwnApp(bundleID: String, pid: Int32) -> Bool {
        pid == ownPID || (ownBundleID.map { $0 == bundleID } ?? false)
    }

    private func observed(_ o: BrowserObservation, pid: Int32, attachID: UInt64, sawWindow: Bool) {
        guard let watch, watch.pid == pid, watch.attachID == attachID else { return }   // stale: dropped (§14.1)
        browserSupport.record(bundleID: watch.bundleID, o, sawWindow: sawWindow)
        observationCount += 1
        lastObservation = o
        deliver(assembler.browserObserved(o, pid: pid))
    }

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
