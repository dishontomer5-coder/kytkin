// P2-10: Learns per-app/site/chat rules from the user's manual switches (001 §2.2, §3 flow (b), R1 §3).
//
// Inputs come from the composition root: context changes (ContextMonitor), `.external` changes from
// SwitchAttributor (our own switches never arrive as `externalSwitch`, the token check runs first),
// word boundaries (KeyWatcher), and periodic ticks (for the dwell timer).
//
// Flow:
//   1. `externalSwitch(id, t)` within `settleAfterContextChange` (500 ms) of the last context change is
//      discarded: that's the OS restoring a per-document source or another switcher (R1 §3, §4).
//   2. Otherwise it becomes a candidate `(engine.learnableScope(context), id)`, unless a guard below says no.
//   3. The candidate commits after `confirmWords` (2) word boundaries, or, when no keyboard tap is
//      available, after `confirmDwellWithoutTap` (4 s) of dwell (seen on a `tick`).
//   4. A context change, our own switch, or a switch back to the previous source cancels it.
//      Another external switch replaces it with a new candidate.
//
// Guards (checked when the candidate is made and again at commit, because rules and settings can change
// in between):
//   - learning is off (Settings → General "Learn from manual switches") → nothing.
//   - the bundle ID is empty → nothing (todo P2-10).
//   - `isPrivateWindow == true` → nothing, not even app-level (plan.md Decision, P2-9 QA: stricter than
//     001 §3 (b) step 4). nil (unknown) counts as not private until P1-20.
//   - P3-9: `pageState == .editingAddress` (P3-31: or `.editingBrowserField`, the Find box) → nothing (D2); `.unknown`, or `.page` without a site → nothing (D3).
//     P3-14 (P3-20 decision): a Context whose site was read only from the Gecko address bar → nothing (applied, never
//     learned).
//     Only the candidate's own scope is checked for a pin, so a site is learned in a browser pinned to another
//     language (site beats the app pin, 001 §14.6).
//   - a **pinned** rule exists for the scope → nothing; pins stay fixed (plan.md Decision, 001 §11 Q2).
//   - a learned rule already says the same source → nothing to change.
//
// The learner only decides. `RuleLearner.upsert` turns a `.learn` outcome into the new rules array,
// which PreferencesStore (P2-8) then saves.

import Foundation

enum LearnerInput: Sendable, Equatable {
    case contextChanged(Context, atNanos: UInt64)
    /// An `.external` change from SwitchAttributor.
    case externalSwitch(InputSourceID, atNanos: UInt64)
    case wordBoundary(atNanos: UInt64)
    case tick(atNanos: UInt64)
    /// Kytkin switched (an `.ours` change) to this source. P2-10 QA: it carries the id (001 §2.2 has none) so a
    /// user's switch away and back to Kytkin's choice still counts as a switch back.
    case ourSwitch(InputSourceID)
}

struct LearnerConfig: Sendable, Equatable {
    /// An external change this soon after a context change came from the OS or another tool.
    var settleAfterContextChange: UInt64 = 500_000_000
    var confirmWords = 2
    var confirmDwellWithoutTap: UInt64 = 4_000_000_000
}

enum LearnOutcome: Sendable, Equatable {
    case learn(RuleScope, InputSourceID)
    case discard(DiscardReason)

    enum DiscardReason: Sendable, Equatable {
        case learningDisabled
        case noContext
        case emptyBundleID
        case privateWindow
        /// P3-9: a text field outside the page has focus (address bar, find bar): D2.
        case editingAddress
        /// P3-9: the browser's page couldn't be read (`.unknown`), or a `.page` came without a site: D3.
        case siteUnknown
        /// P3-14 (P3-20 decision): the site came only from the Gecko address bar, which can hold half-typed text.
        case siteFromAddressBar
        /// Within `settleAfterContextChange` of a context change.
        case tooSoonAfterContextChange
        case pinned
        case alreadyLearned
        /// A pending candidate was cancelled by these:
        case contextChanged
        case switchedBack
        case ourSwitch
    }
}

struct RuleLearner {
    let config: LearnerConfig
    /// Rebuilt by the composition root whenever the rules change.
    var engine: RuleEngine
    /// Settings → General "Learn from manual switches".
    var learningEnabled: Bool
    /// True when KeyWatcher runs (listen-only or active), so word boundaries arrive. False → dwell confirms (001 §6.2).
    var keyboardTapAvailable: Bool

    private struct Candidate {
        let scope: RuleScope
        let source: InputSourceID
        /// The source before this switch (nil = unknown). Switching back to it cancels.
        let previous: InputSourceID?
        let startedAt: UInt64
        var words = 0
    }

    private var context: Context?
    private var contextChangedAt: UInt64?
    /// The current source as last reported (the user's or Kytkin's). nil = unknown.
    private var currentSource: InputSourceID?
    private var candidate: Candidate?

    init(engine: RuleEngine, config: LearnerConfig = LearnerConfig(), learningEnabled: Bool = true,
         keyboardTapAvailable: Bool = true, currentSource: InputSourceID? = nil) {
        self.engine = engine
        self.config = config
        self.learningEnabled = learningEnabled
        self.keyboardTapAvailable = keyboardTapAvailable
        self.currentSource = currentSource
    }

    /// The scope and source waiting for confirmation, if any.
    var pending: (scope: RuleScope, source: InputSourceID)? {
        candidate.map { ($0.scope, $0.source) }
    }

    /// P2-55: word boundaries the pending candidate has seen (nil = no candidate). For the DEBUG menu line.
    var pendingWords: Int? { candidate?.words }

    /// nil = nothing decided yet (no candidate, or a candidate still waiting for confirmation).
    mutating func handle(_ input: LearnerInput) -> LearnOutcome? {
        switch input {
        case .contextChanged(let c, let t):
            context = c
            contextChangedAt = t
            return cancel(.contextChanged)

        case .ourSwitch(let id):
            currentSource = id
            return cancel(.ourSwitch)

        case .externalSwitch(let id, let t):
            let previous = currentSource
            currentSource = id
            return externalSwitch(to: id, previous: previous, at: t)

        case .wordBoundary:
            guard keyboardTapAvailable, var cand = candidate else { return nil }
            cand.words += 1
            candidate = cand
            return cand.words >= config.confirmWords ? commit() : nil

        case .tick(let t):
            guard !keyboardTapAvailable, let cand = candidate,
                  elapsed(from: cand.startedAt, to: t) >= config.confirmDwellWithoutTap else { return nil }
            return commit()
        }
    }

    // MARK: - Steps

    private mutating func externalSwitch(to id: InputSourceID, previous: InputSourceID?, at t: UInt64) -> LearnOutcome? {
        if let cand = candidate {
            candidate = nil
            // P2-10: H → A → H inside one context is a change of mind, not a preference (R1 §3 flip-flop).
            if cand.previous == id { return .discard(.switchedBack) }
        }
        guard let context else { return .discard(.noContext) }
        if let reason = guardReason(context) { return .discard(reason) }
        if let changedAt = contextChangedAt, elapsed(from: changedAt, to: t) < config.settleAfterContextChange {
            return .discard(.tooSoonAfterContextChange)
        }
        let scope = engine.learnableScope(for: context)
        if let reason = ruleReason(scope, id) { return .discard(reason) }
        candidate = Candidate(scope: scope, source: id, previous: previous, startedAt: t)
        return nil
    }

    private mutating func commit() -> LearnOutcome? {
        guard let cand = candidate else { return nil }
        candidate = nil
        guard let context else { return .discard(.noContext) }
        if let reason = guardReason(context) ?? ruleReason(cand.scope, cand.source) { return .discard(reason) }
        return .learn(cand.scope, cand.source)
    }

    private mutating func cancel(_ reason: LearnOutcome.DiscardReason) -> LearnOutcome? {
        guard candidate != nil else { return nil }
        candidate = nil
        return .discard(reason)
    }

    // MARK: - Guards

    private func guardReason(_ c: Context) -> LearnOutcome.DiscardReason? {
        if !learningEnabled { return .learningDisabled }
        if c.bundleID.isEmpty { return .emptyBundleID }
        if c.isPrivateWindow == true { return .privateWindow }   // P2-10: plan.md Decision, learn nothing
        // P3-9 (001 §14.6, D2, D3): in a watched browser, a site is learned only on a page whose site is known.
        // Typing in the address bar is no preference for the page underneath, and a switch on a page Kytkin couldn't
        // read must not become the browser's app rule. `.notWebPage` (new tab, settings) learns at app level.
        switch c.pageState {
        // P3-31: the Find box or another toolbar field is no preference for the page either (owner: nothing is learned
        // from any browser-chrome field), so it shares the address bar's reason.
        case .editingAddress?, .editingBrowserField?: return .editingAddress
        case .unknown?: return .siteUnknown
        case .page?:
            if HostNormalizer.normalized(c.siteDomain) == nil { return .siteUnknown }
        case .notWebPage?, nil:
            break
        }
        // P3-14 (P3-20 decision): an answer read only from the Gecko address bar is applied, never learned. Firefox can
        // keep half-typed text in an unfocused bar (`ynet.co`), and nothing tells it apart from the real address.
        return c.readFromAddressBar ? .siteFromAddressBar : nil
    }

    private func ruleReason(_ scope: RuleScope, _ id: InputSourceID) -> LearnOutcome.DiscardReason? {
        guard let existing = engine.rule(for: scope) else { return nil }
        if existing.origin == .pinned { return .pinned }          // P2-10: pins stay fixed
        if existing.inputSource == id { return .alreadyLearned }
        return nil
    }

    /// Monotonic, but an out-of-order timestamp must not trap: treat it as 0 elapsed.
    private func elapsed(from start: UInt64, to now: UInt64) -> UInt64 {
        now >= start ? now - start : 0
    }

    // MARK: - Applying an outcome

    /// Applies a `.learn` to `rules`: updates the learned rule for that scope (same id, new source and
    /// date) or appends a new learned rule. A pinned rule for the scope is never changed; then `rules`
    /// comes back as is. Other outcomes return `rules` unchanged.
    static func upsert(_ outcome: LearnOutcome, into rules: [Rule], now: Date, newID: UUID = UUID()) -> [Rule] {
        guard case .learn(let scope, let source) = outcome else { return rules }
        // P2-10: same normalization and duplicate tie-break as resolution (pinned wins), via RuleEngine.
        let existing = RuleEngine(rules: rules).rule(for: scope)
        if let existing {
            guard existing.origin == .learned,
                  let index = rules.firstIndex(where: { $0.id == existing.id }) else { return rules }
            var updated = rules
            updated[index].inputSource = source
            updated[index].updatedAt = now
            return updated
        }
        return rules + [Rule(id: newID, scope: scope, inputSource: source, origin: .learned, updatedAt: now)]
    }
}
