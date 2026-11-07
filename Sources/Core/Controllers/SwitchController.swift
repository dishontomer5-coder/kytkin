// P2-20: Per-app switching and learning (001 §3 flows (a) and (b)), plus the menu's Pin / Forget / Pause.
// Owns the RuleLearner; AppController forwards every event here. Main actor, unit-tested with fakes.
//
// (a) Context change → learner `contextChanged` → unless paused, disabled, or the app is disabled in `apps`:
//     RuleEngine.resolve → `select(target, .rule)` when there is a target that isn't current (keepCurrent → nothing).
//     A successful select of ours → `conflicts.noteOurSwitch()`. An external change within 300 ms of that select,
//     to another source, in the same context → re-assert once (design.md: "re-assert at most once"), never again.
//     P3-9 (D5): a Context that differs from the last one only in `pageState` reaches the learner but re-applies
//     nothing. Pin uses `RuleEngine.pinScope` (a private window pins the site too, owner Q1); Forget on a site acts
//     only on a site or siteHost rule (D6).
// (b) `.external` change → `conflicts.noteExternalSwitch()` and, unless Kytkin's own window is active, paused or
//     the app disabled, learner `externalSwitch`; `.ours` → learner `ourSwitch`. Word boundaries and dwell ticks feed
//     the learner too; a `.learn` outcome is written through `RuleWriter` (001 §12 S3).
// Learning flag (P2-19/P2-38): `learningEnabled = learnFromManualSwitches && enabled && !paused &&
//     !conflicts.pausesLearning`. Session state only: never written to the preferences.
// Kytkin's own window (P2-39, 001 §12 W2): ContextMonitor ignores Kytkin, so `context.current` stays the previous
//     app. While Kytkin is active the candidate is cancelled and external switches don't reach the learner; on
//     resign the settle restarts, and the previous app's rule is re-applied if that app is frontmost again.
// P2-55: only a *real* activation counts. Opening the status-bar menu can post NSApplication didBecomeActive while
//     the other app stays frontmost (WindowServer only makes Kytkin the "key thief"), and the matching resign may never
//     come. That left the gate stuck on: every later manual switch and word was dropped, so nothing was ever learned. The
//     root now passes `isFrontmost`; a not-frontmost activation and an unpaired resign change nothing (no cancel), and
//     any new Context clears the flag (another app is frontmost, so Kytkin can't be).
// Pause (001 §5.1): session state, not persisted. Stops switching and learning; AppController also turns the tap
//     off. Resuming re-applies the current app's rule.
// Kytkin on/off (`general.enabled`, Settings → General, P2-23): turning it off drops any candidate like Pause; P2-52
//     item 3: turning it back on re-applies the current app's rule, like resuming. While Settings is in front that
//     waits for the resign (Kytkin's own window is not a context), exactly as for Pause.
// P2-52 item 1: at resign the frontmost app may still read as Kytkin (or unknown). AppController then asks again a
//     moment later and calls `recheckAfterResign(frontmostPID:)`.
// P2-41: when the current app has quit (`context.currentAppIsGone`), external switches don't reach the learner
//     ("app quit") and its rule isn't re-applied; Pin/Forget still act on its rules.

import Foundation

@MainActor final class SwitchController {
    /// An external change this soon after our rule switch is a fight (another switcher or per-document input).
    static let reassertWindowNanos: UInt64 = 300_000_000

    struct CurrentRule: Equatable {
        let context: Context
        let resolution: Resolution
        /// The scope a Pin would write (the most specific one for this context). P3-9: `RuleEngine.pinScope`, so a
        /// private window pins the site too (owner Q1).
        let pinScope: RuleScope

        /// P3-9 (001 §14.9): the menu speaks about the site: a watched browser showing a known site (kept or read).
        var isSite: Bool {
            context.pageState != nil && HostNormalizer.normalized(context.siteDomain) != nil
        }

        /// The scope the menu's Forget removes; nil = nothing to forget. P3-9 (D6): on a site only a matched site or
        /// siteHost rule; the browser's own rule is forgotten in Settings or from the menu on a non-web page.
        var forgetScope: RuleScope? {
            guard let matched = resolution.matched else { return nil }
            guard isSite else { return matched.scope }
            switch matched.scope {
            case .site, .siteHost: return matched.scope
            case .app, .chat: return nil
            }
        }
    }

    private let switcher: any InputSourceSwitching
    private let context: any ContextMonitoring
    private let store: PreferencesStore
    private let conflicts: any ConflictDetecting
    private let clock: any Clock
    private let now: () -> Date

    private(set) var learner: RuleLearner
    private(set) var engine: RuleEngine
    private(set) var paused = false
    private(set) var isOwnAppActive = false
    /// Our last rule switch, for the one re-assert.
    private var lastRuleSelect: (target: InputSourceID, atNanos: UInt64, generation: UInt64)?
    private var reassertedGeneration: UInt64?
    private var keyboardTapAvailable = false
    /// `general.enabled` as last seen, so `preferencesDidChange` can tell an off → on change (P2-52 item 3).
    private var wasEnabled: Bool
    /// P2-55: the learner's last decision or the last switch the gates dropped, for the DEBUG menu (IDs only).
    private var lastLearnerNote: String?
    /// P3-9 (D5): the last Context delivered to `contextDidChange`, to spot a page-state-only change.
    private var lastDelivered: Context?

    init(switcher: any InputSourceSwitching, context: any ContextMonitoring, store: PreferencesStore,
         conflicts: any ConflictDetecting, clock: any Clock, now: @escaping () -> Date = Date.init) {
        self.switcher = switcher
        self.context = context
        self.store = store
        self.conflicts = conflicts
        self.clock = clock
        self.now = now
        let engine = Self.makeEngine(store.prefs)
        self.engine = engine
        wasEnabled = store.prefs.general.enabled
        learner = RuleLearner(engine: engine, learningEnabled: false, keyboardTapAvailable: false,
                              currentSource: switcher.current)
        refreshLearning()
    }

    // MARK: - Flow (a)

    func contextDidChange(_ c: Context) {
        isOwnAppActive = false   // P2-55: another app is frontmost, so Kytkin's own window can't be
        let pageStateOnly = lastDelivered.map { Self.differsOnlyInPageState($0, c) } ?? false
        lastDelivered = c
        handle(learner.handle(.contextChanged(c, atNanos: clock.nowNanos)))
        // P3-9 (D5, 001 §14.6): a change of page state alone (e.g. a click into the address bar and back) cancels a
        // candidate and restarts the settle, like a window focus change, but doesn't re-apply the rule: that would
        // undo the user's manual switch.
        guard !pageStateOnly else { return }
        applyRule(for: c)
    }

    /// P3-9: same app, pid, site, host, private flag and chat; only `pageState` (and the generation) differs.
    static func differsOnlyInPageState(_ a: Context, _ b: Context) -> Bool {
        a.pageState != b.pageState && a.bundleID == b.bundleID && a.pid == b.pid && a.host == b.host
            && a.siteDomain == b.siteDomain && a.isPrivateWindow == b.isPrivateWindow && a.chatKey == b.chatKey
    }

    private func applyRule(for c: Context) {
        guard !paused, store.prefs.general.enabled, !isDisabled(c.bundleID) else { return }
        // P2-41: the app quit (resign re-apply, resume, Kytkin on again): nothing to switch for. A new Context
        // clears the flag first, so a real app change always applies.
        guard !(context.currentAppIsGone && context.current?.pid == c.pid) else { return }
        guard let target = engine.resolve(c).target, target != switcher.current else { return }
        guard switcher.select(target, reason: .rule) else { return }
        conflicts.noteOurSwitch()
        lastRuleSelect = (target, clock.nowNanos, c.generation)
    }

    // MARK: - Flow (b)

    func inputSourceDidChange(_ change: InputSourceChange) {
        switch change {
        case .ours(let id):
            handle(learner.handle(.ourSwitch(id)))
        case .external(let id, let t):
            conflicts.noteExternalSwitch()
            if reassertIfFighting(id, at: t) { return note("switch to \(id.rawValue) re-asserted (fight)") }
            if let reason = ignoreReason() { return note("switch to \(id.rawValue) ignored (\(reason))") }
            handle(learner.handle(.externalSwitch(id, atNanos: t)))
        }
    }

    /// P2-55: why an external switch doesn't reach the learner (nil = it does).
    private func ignoreReason() -> String? {
        if isOwnAppActive { return "Kytkin active" }
        if paused { return "paused" }
        guard let c = context.current else { return "no app" }
        if context.currentAppIsGone { return "app quit" }   // P2-41: nothing is learned for a dead pid
        if isDisabled(c.bundleID) { return "app disabled" }
        return nil
    }

    /// True when it re-asserted (the external change is then not a user preference to learn).
    private func reassertIfFighting(_ id: InputSourceID, at t: UInt64) -> Bool {
        guard let last = lastRuleSelect, !paused, let c = context.current, c.generation == last.generation,
              reassertedGeneration != c.generation, id != last.target,
              t >= last.atNanos, t - last.atNanos < Self.reassertWindowNanos else { return false }
        reassertedGeneration = c.generation
        lastRuleSelect = nil
        if switcher.select(last.target, reason: .rule) { conflicts.noteOurSwitch() }
        return true
    }

    func wordBoundary() {
        guard !isOwnAppActive, !dropCandidateIfAppQuit() else { return }
        handle(learner.handle(.wordBoundary(atNanos: clock.nowNanos)))
    }

    /// The dwell clock (no word buffer). AppController ticks only while `wantsTicks`.
    func tick() {
        guard !isOwnAppActive, !dropCandidateIfAppQuit() else { return }
        handle(learner.handle(.tick(atNanos: clock.nowNanos)))
    }

    /// P2-41 (P3-5 QA): a candidate made before the current app quit must not be confirmed by words typed (or time
    /// spent) after it, e.g. in the next app before its Context arrives. Words and ticks are the only ways a
    /// candidate commits, so it is dropped on the first one after the quit. True = a candidate was dropped.
    private func dropCandidateIfAppQuit() -> Bool {
        guard context.currentAppIsGone, learner.pending != nil, let c = context.current else { return false }
        _ = learner.handle(.contextChanged(c, atNanos: clock.nowNanos))
        note("discarded (app quit)")
        return true
    }

    var wantsTicks: Bool { learner.pending != nil && !learner.keyboardTapAvailable }

    private func handle(_ outcome: LearnOutcome?) {
        guard let outcome else { return }
        switch outcome {
        case .discard(let reason):
            return note("discarded (\(reason))")
        case .learn(let scope, let source):
            note("learned \(Self.describe(scope))→\(source.rawValue)")
        }
        let date = now()
        store.update { $0.rules = RuleWriter.learn(outcome, into: $0.rules, now: date) }
        preferencesDidChange()
    }

    // MARK: - DEBUG diagnostics (P2-55)

    /// One line for the DEBUG menu: the gate state, the pending candidate and the last decision. Bundle and
    /// input-source IDs and reasons only; never typed text, and no site domain or chat key.
    var learnerDebug: String {
        let state: String
        if isOwnAppActive {
            state = "off while Kytkin is active"
        } else if !learner.learningEnabled {
            let g = store.prefs.general
            let why = !g.learnFromManualSwitches ? "setting off" : !g.enabled ? "Kytkin off"
                : paused ? "paused" : conflicts.conflicts.pausesLearning ? "per-document input" : "?"
            state = "off (\(why))"
        } else if let p = learner.pending {
            let progress = learner.keyboardTapAvailable
                ? "\(learner.pendingWords ?? 0)/\(learner.config.confirmWords) words" : "waiting for the dwell"
            state = "candidate \(Self.describe(p.scope))→\(p.source.rawValue), \(progress)"
        } else {
            state = learner.keyboardTapAvailable ? "idle (words)" : "idle (dwell)"
        }
        return "Learner: \(state)" + (lastLearnerNote.map { "; last: \($0)" } ?? "")
    }

    private func note(_ s: String) {
        lastLearnerNote = s
    }

    private static func describe(_ scope: RuleScope) -> String {
        switch scope {
        case .app(let bundleID): return bundleID
        case .site: return "site"
        case .siteHost: return "site host"
        case .chat(let bundleID, _): return "chat in \(bundleID)"
        }
    }

    // MARK: - Settings, conflicts, availability

    /// Rules or settings changed (any writer, including ours).
    func preferencesDidChange() {
        engine = Self.makeEngine(store.prefs)
        learner.engine = engine
        refreshLearning()
        enabledMayHaveChanged()
    }

    /// P2-52 item 3: Kytkin turned off → drop any candidate; turned back on → also re-apply the current app's rule
    /// (unless Kytkin's own window is in front: then the resign does it).
    private func enabledMayHaveChanged() {
        let enabled = store.prefs.general.enabled
        guard enabled != wasEnabled else { return }
        wasEnabled = enabled
        guard let c = context.current else { return }
        handle(learner.handle(.contextChanged(c, atNanos: clock.nowNanos)))
        if enabled, !paused, !isOwnAppActive { applyRule(for: c) }
    }

    /// FeatureAvailability changed: `learningWithWords` decides words vs dwell (001 §6.2).
    func setKeyboardTapAvailable(_ available: Bool) {
        keyboardTapAvailable = available
        refreshLearning()
    }

    /// Conflicts changed (per-document input pauses learning, P2-38) or Pause toggled.
    func refreshLearning() {
        let g = store.prefs.general
        learner.learningEnabled = g.learnFromManualSwitches && g.enabled && !paused
            && !conflicts.conflicts.pausesLearning
        learner.keyboardTapAvailable = keyboardTapAvailable
    }

    // MARK: - Kytkin's own window (P2-39)

    /// `isFrontmost`: Kytkin really is the frontmost app (P2-55: false when only the status-bar menu opened).
    /// True when it was taken as Kytkin's own window coming to the front.
    @discardableResult func kytkinDidBecomeActive(isFrontmost: Bool = true) -> Bool {
        guard isFrontmost else { return false }
        isOwnAppActive = true
        if let c = context.current { handle(learner.handle(.contextChanged(c, atNanos: clock.nowNanos))) }
        return true
    }

    /// `frontmostPID`: the app in front now (nil = unknown). True when it ended Kytkin's own-window state; an unpaired
    /// resign (P2-55: the status-bar menu closed) changes nothing, so it can't cancel a candidate.
    @discardableResult func kytkinDidResignActive(frontmostPID: Int32?) -> Bool {
        guard isOwnAppActive else { return false }
        isOwnAppActive = false
        guard let c = context.current else { return true }
        handle(learner.handle(.contextChanged(c, atNanos: clock.nowNanos)))
        if frontmostPID == c.pid { applyRule(for: c) }
        return true
    }

    /// P2-55 QA: AppController saw another app frontmost while the flag was on (the resign was never posted). Ends the
    /// flag only: the settle already counts from the activation, and the event about to arrive is the user's own.
    func ownWindowFlagWasStale() {
        guard isOwnAppActive else { return }
        isOwnAppActive = false
        note("Kytkin-active flag was stale, cleared")
    }

    /// P2-52 item 1: the second look after a resign whose frontmost app was still Kytkin or unknown. Same rule as
    /// the resign: re-apply only if the app in front is the one Kytkin was acting for (another app gets its own
    /// context change from ContextMonitor).
    func recheckAfterResign(frontmostPID: Int32) {
        guard !isOwnAppActive, let c = context.current, frontmostPID == c.pid else { return }
        applyRule(for: c)
    }

    // MARK: - Menu actions

    func setPaused(_ on: Bool) {
        guard on != paused else { return }
        paused = on
        refreshLearning()
        if let c = context.current {
            handle(learner.handle(.contextChanged(c, atNanos: clock.nowNanos)))   // drop any candidate
            if !on, !isOwnAppActive { applyRule(for: c) }
        }
    }

    var currentRule: CurrentRule? {
        guard let c = context.current else { return nil }
        return CurrentRule(context: c, resolution: engine.resolve(c), pinScope: engine.pinScope(for: c))
    }

    /// Pins the current input source for the current (non-Kytkin) app's most specific scope. nil = no context.
    @discardableResult func pinCurrent() -> Rule? {
        guard let info = currentRule else { return nil }
        let source = switcher.current
        guard !source.rawValue.isEmpty else { return nil }
        let date = now()
        store.update { $0.rules = RuleWriter.pin(info.pinScope, to: source, in: $0.rules, now: date) }
        preferencesDidChange()
        return engine.rule(for: info.pinScope)
    }

    /// Removes the rule that applies to the current app (the one `resolve` matched). False = there was none.
    /// P3-9 (D6): on a site, only a matched site or siteHost rule; a matched browser rule is left alone (false).
    @discardableResult func forgetCurrent() -> Bool {
        guard let scope = currentRule?.forgetScope else { return false }
        store.update { $0.rules = RuleWriter.forget(scope, in: $0.rules) }
        preferencesDidChange()
        return true
    }

    /// DEBUG "Switch to" and later menu picks: our switch, so the fight counter hears about it.
    @discardableResult func selectFromMenu(_ id: InputSourceID) -> Bool {
        let wasCurrent = switcher.current == id
        guard switcher.select(id, reason: .menu) else { return false }
        if !wasCurrent { conflicts.noteOurSwitch() }
        return true
    }

    /// P2-21: the switch after a double-Shift convert or toggle (flow (c) step 8). Our switch: the expected-switch
    /// token keeps it out of the learner, and the fight counter hears about it. False = paused/off or select failed.
    @discardableResult func selectAfterConvert(_ id: InputSourceID) -> Bool {
        guard !paused, store.prefs.general.enabled else { return false }
        let wasCurrent = switcher.current == id
        guard switcher.select(id, reason: .afterConvert) else { return false }
        if !wasCurrent { conflicts.noteOurSwitch() }
        return true
    }

    // MARK: - Helpers

    private func isDisabled(_ bundleID: String) -> Bool {
        store.prefs.apps[bundleID]?.disabled == true
    }

    private static func makeEngine(_ p: Preferences) -> RuleEngine {
        RuleEngine(rules: p.rules, defaultBehavior: p.general.defaultBehavior,
                   ignorePrivateWindowsCompletely: p.browsers.ignorePrivateWindowsCompletely)
    }
}
