// P2-19: The contract the composition root (P2-20) and the menu (P2-22) use (001 §2.2 ConflictDetector).
// System/Platform/ConflictDetector implements it; controller tests use a fake.
//
// How P2-20 uses it (owner decision P2-38, 001 §12 R2):
//   - Build the learner's flag from BOTH the user setting and this pause, every time either changes:
//       learner.learningEnabled = store.prefs.general.learnFromManualSwitches && !detector.conflicts.pausesLearning
//     (set it once after `start()`, then in `onChange` and when the setting changes). Never write the
//     preference itself: the pause is session state, the user's setting stays as they chose it.
//   - Setting `learningEnabled = false` is enough: RuleLearner discards new external switches with
//     `.learningDisabled` and a candidate already pending is discarded at commit. Rules still apply.
//   - Feed fights: `noteOurSwitch()` after each successful select of ours, `noteExternalSwitch()` for each
//     change SwitchAttributor classifies as external.
// The menu (P2-22) shows `conflicts.runningSwitchers` and, when `perDocumentInputEnabled`, the warning that
// also says learning is paused. It can call `refresh()` from `menuNeedsUpdate` so the warning is fresh.

import Foundation

@MainActor protocol ConflictDetecting: AnyObject {
    var conflicts: Conflicts { get }
    /// External switches landing < 300 ms after ours, this session.
    var repeatedFights: Int { get }
    /// Called on the main actor whenever `conflicts` changes (not for fights).
    var onChange: (@MainActor (Conflicts) -> Void)? { get set }
    func start()
    func stop()
    /// Re-reads the preference and rescans running apps now.
    func refresh()
    func noteOurSwitch()
    func noteExternalSwitch()
}
