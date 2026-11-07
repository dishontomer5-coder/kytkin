// P2-26: Two screens want the 1 s permission poll (001 §2.2: "onboarding or Permissions screen visible"): the
// Settings → Permissions tab and the welcome window. `PermissionsProviding.setInteractive` is a single switch, so
// this keeps one flag per screen and turns the fast poll on while any of them is visible, off when none is. It calls
// `setInteractive` only when the answer changes (each call to `true` also does a fresh read).
//
// P3-12 (P2-63): "visible" also means actually on screen. A screen that is shown (its window open, its tab picked)
// but whose window is hidden (Kytkin hidden) or fully covered by other windows doesn't need the poll, so each screen
// also has a "covered" flag, fed from the window's occlusion state by the UI. The poll runs while some screen is
// shown and not covered, and comes back (with a fresh read) as soon as one is uncovered. The UI marks a window
// uncovered when it brings it to the front (it is on top then) and reports every occlusion change after that.

import Foundation

@MainActor final class PermissionPollingDemand {
    enum Screen: Hashable, Sendable {
        case permissionsTab
        case onboarding
    }

    private let permissions: any PermissionsProviding
    private var shown: Set<Screen> = []
    private var covered: Set<Screen> = []

    init(permissions: any PermissionsProviding) {
        self.permissions = permissions
    }

    var isInteractive: Bool { !shown.subtracting(covered).isEmpty }

    /// The screen is up (window open and, for a tab, selected) or not.
    func set(_ screen: Screen, visible on: Bool) {
        change { if on { shown.insert(screen) } else { shown.remove(screen) } }
    }

    /// P3-12: the screen's window is hidden or fully covered (`true`), or at least partly on screen (`false`).
    func set(_ screen: Screen, covered on: Bool) {
        change { if on { covered.insert(screen) } else { covered.remove(screen) } }
    }

    private func change(_ body: () -> Void) {
        let before = isInteractive
        body()
        if isInteractive != before { permissions.setInteractive(isInteractive) }
    }
}
