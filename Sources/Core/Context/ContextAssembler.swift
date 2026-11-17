// P2-15: Turns raw context observations into one debounced, deduplicated `Context` (001 §2.2
// "ContextMonitor, plus ContextAssembler", §3 flows (a) and (e)). Pure: time comes from the injected `Clock`.
// P3-5: Phase 3 API and P2-41 hardening (001 §14.5): browser observations with a page state, the site grace,
// `hostsWithOverrides` re-evaluation, a 500 ms max hold, and the "current app has quit" flag.
//
// Observations, applied in arrival order:
//   - `appActivated` (tier 0, NSWorkspace): a new frontmost app. Site, chat and page-state fields reset to nil.
//   - `appTerminated` (tier 0): drops a not-yet-emitted activation of an app that already quit, and marks the
//     emitted app as gone when it is the one that quit (`currentAppIsGone`, cleared by the next emission).
//   - `browserObserved` / `chatChanged` (tier 1+, Phase 3/4): partial updates for the newest app's pid.
//     A result for any other pid is stale (the user moved on) and is dropped.
//
// Ignored completely (they never change state or timing):
//   - Kytkin itself: its own pid, its own bundle ID, or any `io.github.kytkin.` bundle ID. Opening Settings
//     activates Kytkin, and that must not look like an app change (context-monitoring.md §1, 001 §3 (a)).
//   - an empty (or blank) bundle ID, or a pid ≤ 0: nothing a rule can key on.
//
// Dedupe: a Context is emitted only when its content (bundle ID, pid, host, domain, private flag, chat key,
// page state) differs from the last emitted one. Every emission bumps `generation` by one.
//
// Debounce (leading edge + trailing edge): the first change after a quiet period of `debounceNanos` is
// emitted at once, so app activation → switch stays within the 50 ms budget (001 §7 B7). A change that
// arrives less than `debounceNanos` after the previous change is held instead, and the deadline moves to
// `now + debounceNanos` on every further change, but never past `maxHoldNanos` after the first held change
// of the burst (P2-41: browser triggers feed bursts, and an endless one must still emit). `flushIfDue()`
// emits the newest state once the deadline passes, or nothing if the burst ended where it started. So a fast
// swipe through several Spaces, or launch-time activation bounces, produce one Context, not one per hop.
// The caller (ContextMonitor) arms a timer for `pendingDeadlineNanos`.
//
// Site grace (P3-5, D4): `appActivated(…, awaitsSite: true)` (a browser Kytkin watches) is held until the first
// `browserObserved` for that pid, which releases it at once with app and site together, or until
// `siteGraceNanos` later, when it is emitted app-only with `pageState = .unknown`. So activating a browser on a
// site with its own rule gives one switch, not the browser's rule and then the site's a few ms later.

import Foundation

struct ContextAssembler {
    /// 001 §2.2 tier 1: debounce 120 ms (browsers use 150 ms on the AX thread before they get here).
    static let defaultDebounceNanos: UInt64 = 120_000_000
    /// P3-5 (D4): how long a browser activation waits for its first site read.
    static let siteGraceNanos: UInt64 = 150_000_000
    /// P2-41: a held change is emitted no later than this after the first held change of a burst.
    static let maxHoldNanos: UInt64 = 500_000_000

    let ownPID: Int32
    let ownBundleID: String?
    let debounceNanos: UInt64
    /// Hosts that have their own (siteHost) rule, HostNormalizer form. A host change inside the same
    /// registrable domain is a change only when the old or new host is in here (001 §3 (e) step 4).
    /// P3-5: set through `setHostsWithOverrides`, which re-evaluates the newest observed host.
    private(set) var hostsWithOverrides: Set<String> = []

    /// The last emitted Context. nil until the first app other than Kytkin is seen.
    private(set) var current: Context?
    /// P2-41: the emitted app quit (its pid is dead). Cleared by the next emission.
    private(set) var currentAppIsGone = false

    /// When set, a held change is waiting; call `flushIfDue()` at or after this time.
    var pendingDeadlineNanos: UInt64? {
        let grace = siteGrace?.deadlineNanos
        guard let burst = burstDeadlineNanos else { return grace }
        guard let grace else { return burst }
        // Both: wait for the later one, but the max hold still caps it.
        return min(max(burst, grace), (burstStartNanos ?? burst) + Self.maxHoldNanos)
    }

    private let clock: any Clock
    /// The newest observed state, emitted or not.
    private var latest: Facts?
    /// Time of the last observation that changed `latest` (starts the quiet period).
    private var lastChangeAtNanos: UInt64?
    /// The debounce deadline of a held burst (nil = no burst held).
    private var burstDeadlineNanos: UInt64?
    /// P2-41: when the first held change of the current burst arrived (for the max hold).
    private var burstStartNanos: UInt64?
    /// P3-5: a browser activation held for its first site read.
    private var siteGrace: (pid: Int32, deadlineNanos: UInt64)?
    /// P3-5: the newest host the browser reported for `latest.pid`, even when that host change didn't count
    /// (no override) and so isn't in `latest`. `setHostsWithOverrides` compares it with the emitted one.
    private var observedHost: String?
    private var generation: UInt64 = 0

    init(clock: any Clock, ownPID: Int32, ownBundleID: String?,
         debounceNanos: UInt64 = ContextAssembler.defaultDebounceNanos) {
        self.clock = clock
        self.ownPID = ownPID
        self.ownBundleID = ownBundleID
        self.debounceNanos = debounceNanos
    }

    // MARK: - Observations

    /// A new frontmost app. Returns the new Context if it is emitted now; nil if it was ignored, didn't
    /// change anything, or is held by the debounce or the site grace (then see `pendingDeadlineNanos`).
    /// `awaitsSite`: Kytkin watches this browser, so hold the activation for its first read (P3-5, D4).
    /// P2-15: 001 §2.2 lists `-> Context`; it is optional here because own-app, empty and duplicate
    /// activations must produce nothing (reported to the Architect).
    mutating func appActivated(bundleID: String, pid: Int32, awaitsSite: Bool = false) -> Context? {
        guard !isIgnored(bundleID: bundleID, pid: pid) else { return nil }
        if let latest, latest.bundleID == bundleID, latest.pid == pid {
            // Same app again (e.g. a Space change re-read, or back from Kytkin's own window): keep site/chat.
            return nil
        }
        observedHost = nil
        return apply(Facts(bundleID: bundleID, pid: pid), activation: (awaitsSite: awaitsSite, pid: pid))
    }

    /// An app quit. If its activation is still held (not emitted yet), drop it and go back to the
    /// last emitted state; NSWorkspace activates and reports the next app by itself.
    /// P2-41: if it is the emitted app, `currentAppIsGone` turns on until the next emission.
    mutating func appTerminated(pid: Int32) {
        if let current, current.pid == pid { currentAppIsGone = true }
        guard pendingDeadlineNanos != nil, let latest, latest.pid == pid else { return }
        discardPending()
    }

    /// Drops a held (not yet emitted) change and goes back to the last emitted state. ContextMonitor
    /// calls it on `stop()`, so a change held before a stop is never emitted after a later `start()`
    /// (the frontmost app is re-read on start instead).
    mutating func discardPending() {
        latest = current.map(Facts.init)
        observedHost = current?.host
        endHold()
    }

    /// P3-5: the browser `pid` reported what its frontmost window shows (001 §14.5). `site` is the reduced
    /// address (never a URL): `host = site.host`, `siteDomain = site.siteKey`. A change counts when the site
    /// key, the private flag, the page state, or a host that has an override changed. The first observation
    /// for a browser activation held by the site grace releases it at once, app and site together.
    /// nil = no change, stale pid, or held.
    /// P3-14: `siteNotLearnable` (the P3-20 decision) counts as a change too: it decides whether the site may be
    /// learned, so bar → `AXURL` on the same site must reach the learner.
    mutating func browserObserved(site: SiteAddress?, pageState: BrowserPageState, isPrivate: Bool?,
                                  siteNotLearnable: Bool = false, pid: Int32) -> Context? {
        guard var next = latest, next.pid == pid else { return nil }
        let host = site?.host, domain = site?.siteKey
        observedHost = host
        if let grace = siteGrace, grace.pid == pid {
            // The read the activation was waiting for: one Context with app and site together.
            siteGrace = nil
            next.host = host
            next.siteDomain = domain
            next.isPrivateWindow = isPrivate
            next.pageState = pageState
            next.siteNotLearnable = siteNotLearnable
            latest = next
            // Held only by the grace → emit now. Also part of a burst → the burst's deadline emits the merge.
            return burstDeadlineNanos == nil ? release() : nil
        }
        let oldHost = Self.normalizedHost(next.host), newHost = Self.normalizedHost(host)
        guard next.siteDomain != domain || next.isPrivateWindow != isPrivate || next.pageState != pageState
                || next.siteNotLearnable != siteNotLearnable || hostMatters(oldHost, newHost) else { return nil }
        next.host = host
        next.siteDomain = domain
        next.isPrivateWindow = isPrivate
        next.pageState = pageState
        next.siteNotLearnable = siteNotLearnable
        return apply(next)
    }

    /// 001 §14.2/§14.5 signature: one browser read (P3-6's `BrowserObservation`; `via` is for diagnostics only).
    mutating func browserObserved(_ o: BrowserObservation, pid: Int32) -> Context? {
        browserObserved(site: o.site, pageState: o.pageState, isPrivate: o.isPrivate,
                        siteNotLearnable: o.siteNotLearnable, pid: pid)
    }

    /// P3-14: Kytkin stopped watching browser `pid` while it is still in front (the site policy changed: Kytkin
    /// paused or off, Accessibility revoked, site rules turned off for it). Its site fields and page state go back to
    /// nil, so the browser's own app rule applies, as for any app. A grace still waiting for its first read ends now.
    /// nil = no change, stale pid, or held.
    mutating func browserUnwatched(pid: Int32) -> Context? {
        guard var next = latest, next.pid == pid else { return nil }
        if let grace = siteGrace, grace.pid == pid {
            siteGrace = nil
            return burstDeadlineNanos == nil ? release() : nil   // held only by the grace: emit the app now
        }
        guard next.pageState != nil || next.siteDomain != nil || next.host != nil else { return nil }
        observedHost = nil
        next.host = nil
        next.siteDomain = nil
        next.isPrivateWindow = nil
        next.pageState = nil
        next.siteNotLearnable = false
        return apply(next)
    }

    /// QA (P3-14): Kytkin started watching browser `pid` while it was already in front (Resume, turned back on,
    /// Accessibility granted, site rules turned on for it). Like an activation of a watched browser (D4), the next
    /// Context waits for the first read, or `siteGraceNanos` (then app-only with `pageState = .unknown`). Only for
    /// the newest app with no page state (an unwatched browser); a grace already running is kept.
    mutating func awaitSite(pid: Int32) {
        guard let latest, latest.pid == pid, latest.pageState == nil, siteGrace == nil else { return }
        siteGrace = (pid, clock.nowNanos + Self.siteGraceNanos)
    }

    /// QA (P3-14): a browser activation (or `awaitSite`) is waiting for its first read.
    var isAwaitingSite: Bool { siteGrace != nil }

    /// P3-5: the hosts of all siteHost rules changed (AppController, on every preferences change). If the newest
    /// observed host differs from the one in the newest state and either is now an override, the host change
    /// counts after all, so an override the user just added for the page they're on applies at once.
    mutating func setHostsWithOverrides(_ hosts: Set<String>) -> Context? {
        hostsWithOverrides = Set(hosts.compactMap(HostNormalizer.normalized))
        guard var next = latest, let observed = observedHost,
              hostMatters(Self.normalizedHost(next.host), Self.normalizedHost(observed)) else { return nil }
        next.host = observed
        return apply(next)
    }

    /// Phase 4: the open conversation in chat app `pid` changed. nil = no change, stale pid, or held.
    mutating func chatChanged(_ key: ChatKey?, pid: Int32) -> Context? {
        guard var next = latest, next.pid == pid, next.chatKey != key else { return nil }
        next.chatKey = key
        return apply(next)
    }

    /// The debounce step. Emits the held state once `pendingDeadlineNanos` has passed; nil before that,
    /// when nothing is held, or when the burst ended on the state already emitted. A browser activation whose
    /// site grace ran out is emitted app-only with `pageState = .unknown`.
    mutating func flushIfDue() -> Context? {
        guard let deadline = pendingDeadlineNanos, clock.nowNanos >= deadline else { return nil }
        return release()
    }

    // MARK: - Private

    /// Everything in a Context except the generation.
    private struct Facts: Equatable {
        var bundleID: String
        var pid: Int32
        var host: String?
        var siteDomain: String?
        var isPrivateWindow: Bool?
        var chatKey: ChatKey?
        var pageState: BrowserPageState?
        var siteNotLearnable = false

        init(bundleID: String, pid: Int32) {
            self.bundleID = bundleID
            self.pid = pid
        }

        init(_ c: Context) {
            bundleID = c.bundleID
            pid = c.pid
            host = c.host
            siteDomain = c.siteDomain
            isPrivateWindow = c.isPrivateWindow
            chatKey = c.chatKey
            pageState = c.pageState
            siteNotLearnable = c.siteNotLearnable
        }
    }

    private func isIgnored(bundleID: String, pid: Int32) -> Bool {
        if pid <= 0 || pid == ownPID { return true }
        if bundleID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { return true }
        if let ownBundleID, bundleID == ownBundleID { return true }
        return bundleID.lowercased().hasPrefix(KnownSwitchers.ownBundleIDPrefix)
    }

    /// A host change inside one registrable domain matters only when the old or the new host has an override
    /// (P3-19: the rule shared with SwitchController).
    private func hostMatters(_ oldHost: String?, _ newHost: String?) -> Bool {
        HostNormalizer.hostChangeMatters(oldHost, newHost, hasOverride: hostsWithOverrides.contains)
    }

    /// `activation`: a new app; its grace replaces any earlier one (after the burst check, which still sees it).
    private mutating func apply(_ next: Facts, activation: (awaitsSite: Bool, pid: Int32)? = nil) -> Context? {
        let now = clock.nowNanos
        let inBurst = pendingDeadlineNanos != nil
            || lastChangeAtNanos.map { now >= $0 && now - $0 < debounceNanos } ?? false
        if let activation {
            siteGrace = activation.awaitsSite ? (activation.pid, now + Self.siteGraceNanos) : nil
        }
        latest = next
        lastChangeAtNanos = now
        guard inBurst else {
            burstStartNanos = nil
            // A browser activation waits for its site (`pendingDeadlineNanos` = the grace deadline).
            return siteGrace == nil ? release() : nil
        }
        // Hold it; a burst that returns to the emitted state leaves nothing to flush (unless a grace still waits).
        let start = burstStartNanos ?? now
        burstStartNanos = start
        if next == current.map(Facts.init) {
            burstDeadlineNanos = nil
            return nil
        }
        burstDeadlineNanos = min(now + debounceNanos, start + Self.maxHoldNanos)
        // P2-41: the max hold already ran out (a burst that never paused): emit the newest state now.
        if let deadline = pendingDeadlineNanos, deadline <= now { return release() }
        return nil
    }

    /// Ends any hold and emits the newest state if it differs from the last emitted one.
    private mutating func release() -> Context? {
        if let grace = siteGrace, latest?.pid == grace.pid, latest?.pageState == nil {
            latest?.pageState = .unknown   // the grace ran out before the first read: app-only (§14.5)
        }
        endHold()
        return emitIfChanged()
    }

    private mutating func endHold() {
        burstDeadlineNanos = nil
        burstStartNanos = nil
        siteGrace = nil
    }

    private mutating func emitIfChanged() -> Context? {
        guard let latest, latest != current.map(Facts.init) else { return nil }
        generation += 1
        let context = Context(bundleID: latest.bundleID, pid: latest.pid, host: latest.host,
                              siteDomain: latest.siteDomain, isPrivateWindow: latest.isPrivateWindow,
                              chatKey: latest.chatKey, pageState: latest.pageState,
                              siteNotLearnable: latest.siteNotLearnable, generation: generation)
        current = context
        currentAppIsGone = false
        return context
    }

    /// P3-2: the shared HostNormalizer (also RuleEngine's), so `hostsWithOverrides` compares like the rules do.
    private static func normalizedHost(_ s: String?) -> String? {
        HostNormalizer.normalized(s)
    }
}
