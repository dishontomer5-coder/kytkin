// P2-15: Turns raw context observations into one debounced, deduplicated `Context` (001 §2.2
// "ContextMonitor, plus ContextAssembler", §3 flows (a) and (e)). Pure: time comes from the injected `Clock`.
//
// Observations, applied in arrival order:
//   - `appActivated` (tier 0, NSWorkspace): a new frontmost app. Site and chat fields reset to nil.
//   - `appTerminated` (tier 0): drops a not-yet-emitted activation of an app that already quit.
//   - `browserURLChanged` / `chatChanged` (tier 1+, Phase 3/4): partial updates for the newest app's pid.
//     A result for any other pid is stale (the user moved on) and is dropped.
//
// Ignored completely (they never change state or timing):
//   - Kytkin itself: its own pid, its own bundle ID, or any `io.github.kytkin.` bundle ID. Opening Settings
//     activates Kytkin, and that must not look like an app change (context-monitoring.md §1, 001 §3 (a)).
//   - an empty (or blank) bundle ID, or a pid ≤ 0: nothing a rule can key on.
//
// Dedupe: a Context is emitted only when its content (bundle ID, pid, host, domain, private flag, chat key)
// differs from the last emitted one. Every emission bumps `generation` by one.
//
// Debounce (leading edge + trailing edge): the first change after a quiet period of `debounceNanos` is
// emitted at once, so app activation → switch stays within the 50 ms budget (001 §7 B7). A change that
// arrives less than `debounceNanos` after the previous change is held instead, and the deadline moves to
// `now + debounceNanos` on every further change. `flushIfDue()` emits the newest state once the deadline
// passes, or nothing if the burst ended where it started. So a fast swipe through several Spaces, or
// launch-time activation bounces, produce one Context, not one per hop. The caller (ContextMonitor) arms
// a timer for `pendingDeadlineNanos`.

import Foundation

struct ContextAssembler {
    /// 001 §2.2 tier 1: debounce 120 ms (browsers use 150 ms on the AX thread before they get here).
    static let defaultDebounceNanos: UInt64 = 120_000_000

    let ownPID: Int32
    let ownBundleID: String?
    let debounceNanos: UInt64
    /// Hosts that have their own (siteHost) rule. A host change inside the same registrable domain is a
    /// change only when the old or new host is in here (001 §3 (e) step 4). Lowercased, no trailing dot.
    /// Phase 3 keeps it in sync with the rules; empty in the MVP.
    var hostsWithOverrides: Set<String> = []

    /// The last emitted Context. nil until the first app other than Kytkin is seen.
    private(set) var current: Context?
    /// When set, a held change is waiting; call `flushIfDue()` at or after this time.
    private(set) var pendingDeadlineNanos: UInt64?

    private let clock: any Clock
    /// The newest observed state, emitted or not.
    private var latest: Facts?
    /// Time of the last observation that changed `latest` (starts the quiet period).
    private var lastChangeAtNanos: UInt64?
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
    /// change anything, or is held by the debounce (then see `pendingDeadlineNanos`).
    /// P2-15: 001 §2.2 lists `-> Context`; it is optional here because own-app, empty and duplicate
    /// activations must produce nothing (reported to the Architect).
    mutating func appActivated(bundleID: String, pid: Int32) -> Context? {
        guard !isIgnored(bundleID: bundleID, pid: pid) else { return nil }
        if let latest, latest.bundleID == bundleID, latest.pid == pid {
            // Same app again (e.g. a Space change re-read, or back from Kytkin's own window): keep site/chat.
            return nil
        }
        return apply(Facts(bundleID: bundleID, pid: pid))
    }

    /// An app quit. If its activation is still held (not emitted yet), drop it and go back to the
    /// last emitted state; NSWorkspace activates and reports the next app by itself.
    mutating func appTerminated(pid: Int32) {
        guard pendingDeadlineNanos != nil, let latest, latest.pid == pid else { return }
        discardPending()
    }

    /// Drops a held (not yet emitted) change and goes back to the last emitted state. ContextMonitor
    /// calls it on `stop()`, so a change held before a stop is never emitted after a later `start()`
    /// (the frontmost app is re-read on start instead).
    mutating func discardPending() {
        latest = current.map(Facts.init)
        pendingDeadlineNanos = nil
    }

    /// Phase 3: the active browser tab of `pid` changed. A change counts only when the registrable domain,
    /// the private flag, or a host with its own rule changed. nil = no change, stale pid, or held.
    mutating func browserURLChanged(host: String?, domain: String?, isPrivate: Bool?, pid: Int32) -> Context? {
        guard var next = latest, next.pid == pid else { return nil }
        let oldHost = Self.normalizedHost(next.host), newHost = Self.normalizedHost(host)
        let hostMatters = oldHost != newHost
            && [oldHost, newHost].contains { $0.map(hostsWithOverrides.contains) ?? false }
        guard next.siteDomain != domain || next.isPrivateWindow != isPrivate || hostMatters else { return nil }
        next.host = host
        next.siteDomain = domain
        next.isPrivateWindow = isPrivate
        return apply(next)
    }

    /// Phase 4: the open conversation in chat app `pid` changed. nil = no change, stale pid, or held.
    mutating func chatChanged(_ key: ChatKey?, pid: Int32) -> Context? {
        guard var next = latest, next.pid == pid, next.chatKey != key else { return nil }
        next.chatKey = key
        return apply(next)
    }

    /// The debounce step. Emits the held state once `pendingDeadlineNanos` has passed; nil before that,
    /// when nothing is held, or when the burst ended on the state already emitted.
    mutating func flushIfDue() -> Context? {
        guard let deadline = pendingDeadlineNanos, clock.nowNanos >= deadline else { return nil }
        pendingDeadlineNanos = nil
        return emitIfChanged()
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
        }
    }

    private func isIgnored(bundleID: String, pid: Int32) -> Bool {
        if pid <= 0 || pid == ownPID { return true }
        if bundleID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { return true }
        if let ownBundleID, bundleID == ownBundleID { return true }
        return bundleID.lowercased().hasPrefix(KnownSwitchers.ownBundleIDPrefix)
    }

    private mutating func apply(_ next: Facts) -> Context? {
        let now = clock.nowNanos
        let inBurst = pendingDeadlineNanos != nil
            || lastChangeAtNanos.map { now >= $0 && now - $0 < debounceNanos } ?? false
        latest = next
        lastChangeAtNanos = now
        if inBurst {
            // Hold it; a burst that returns to the emitted state leaves nothing to flush.
            pendingDeadlineNanos = next == current.map(Facts.init) ? nil : now + debounceNanos
            return nil
        }
        return emitIfChanged()
    }

    private mutating func emitIfChanged() -> Context? {
        guard let latest, latest != current.map(Facts.init) else { return nil }
        generation += 1
        let context = Context(bundleID: latest.bundleID, pid: latest.pid, host: latest.host,
                              siteDomain: latest.siteDomain, isPrivateWindow: latest.isPrivateWindow,
                              chatKey: latest.chatKey, generation: generation)
        current = context
        return context
    }

    private static func normalizedHost(_ s: String?) -> String? {
        guard var h = s?.lowercased() else { return nil }
        if h.hasSuffix(".") { h.removeLast() }
        return h
    }
}
