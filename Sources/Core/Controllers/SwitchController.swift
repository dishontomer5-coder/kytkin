// P2-20: Per-app switching and learning (001 §3 flows (a) and (b)), plus the menu's Pin / Forget / Pause.
// Owns the RuleLearner; AppController forwards every event here. Main actor, unit-tested with fakes.
//
// (a) Context change → learner `contextChanged` → unless paused, disabled, or the app is disabled in `apps`:
//     RuleEngine.resolve → `select(target, .rule)` when there is a target that isn't current (keepCurrent → nothing).
//     A successful select of ours → `conflicts.noteOurSwitch()`. An external change within 300 ms of that select,
//     to another source, in the same context → re-assert once (design.md: "re-assert at most once"), never again.
// (b) `.external` change → `conflicts.noteExternalSwitch()` and, unless Kytkin's own window is active, paused or
//     the app disabled, learner `externalSwitch`; `.ours` → learner `ourSwitch`. Word boundaries and dwell ticks feed
//     the learner too; a `.learn` outcome is written through `RuleWriter` (001 §12 S3).
// Learning flag (P2-19/P2-38): `learningEnabled = learnFromManualSwitches && enabled && !paused &&
//     !conflicts.pausesLearning`. Session state only: never written to the preferences.
// Kytkin's own window (P2-39, 001 §12 W2): ContextMonitor ignores Kytkin, so `context.current` stays the previous
//     app. While Kytkin is active the candidate is cancelled and external switches don't reach the learner; on
//     resign the settle restarts, and the previous app's rule is re-applied if that app is frontmost again.
// Pause (001 §5.1): session state, not persisted. Stops switching and learning; AppController also turns the tap
//     off. Resuming re-applies the current app's rule.

import Foundation

@MainActor final class SwitchController {
    /// An external change this soon after our rule switch is a fight (another switcher or per-document input).
    static let reassertWindowNanos: UInt64 = 300_000_000

    struct CurrentRule: Equatable {
        let context: Context
        let resolution: Resolution
        /// The scope a Pin would write (the most specific one for this context).
        let pinScope: RuleScope
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
        learner = RuleLearner(engine: engine, learningEnabled: false, keyboardTapAvailable: false,
                              currentSource: switcher.current)
        refreshLearning()
    }

    // MARK: - Flow (a)

    func contextDidChange(_ c: Context) {
        handle(learner.handle(.contextChanged(c, atNanos: clock.nowNanos)))
        applyRule(for: c)
    }

    private func applyRule(for c: Context) {
        guard !paused, store.prefs.general.enabled, !isDisabled(c.bundleID) else { return }
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
            if reassertIfFighting(id, at: t) { return }
            guard !isOwnAppActive, !paused, let c = context.current, !isDisabled(c.bundleID) else { return }
            handle(learner.handle(.externalSwitch(id, atNanos: t)))
        }
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
        guard !isOwnAppActive else { return }
        handle(learner.handle(.wordBoundary(atNanos: clock.nowNanos)))
    }

    /// The dwell clock (no word buffer). AppController ticks only while `wantsTicks`.
    func tick() {
        guard !isOwnAppActive else { return }
        handle(learner.handle(.tick(atNanos: clock.nowNanos)))
    }

    var wantsTicks: Bool { learner.pending != nil && !learner.keyboardTapAvailable }

    private func handle(_ outcome: LearnOutcome?) {
        guard let outcome, case .learn = outcome else { return }
        let date = now()
        store.update { $0.rules = RuleWriter.learn(outcome, into: $0.rules, now: date) }
        preferencesDidChange()
    }

    // MARK: - Settings, conflicts, availability

    /// Rules or settings changed (any writer, including ours).
    func preferencesDidChange() {
        engine = Self.makeEngine(store.prefs)
        learner.engine = engine
        refreshLearning()
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

    func kytkinDidBecomeActive() {
        isOwnAppActive = true
        if let c = context.current { handle(learner.handle(.contextChanged(c, atNanos: clock.nowNanos))) }
    }

    /// `frontmostPID`: the app in front now (nil = unknown).
    func kytkinDidResignActive(frontmostPID: Int32?) {
        isOwnAppActive = false
        guard let c = context.current else { return }
        handle(learner.handle(.contextChanged(c, atNanos: clock.nowNanos)))
        if frontmostPID == c.pid { applyRule(for: c) }
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
        return CurrentRule(context: c, resolution: engine.resolve(c), pinScope: engine.learnableScope(for: c))
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
    @discardableResult func forgetCurrent() -> Bool {
        guard let matched = currentRule?.resolution.matched else { return false }
        store.update { $0.rules = RuleWriter.forget(matched.scope, in: $0.rules) }
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
