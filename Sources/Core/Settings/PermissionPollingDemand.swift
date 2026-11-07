// P2-26: Two screens want the 1 s permission poll (001 §2.2: "onboarding or Permissions screen visible"): the
// Settings → Permissions tab and the welcome window. `PermissionsProviding.setInteractive` is a single switch, so
// this keeps one flag per screen and turns the fast poll on while any of them is visible, off when none is. It calls
// `setInteractive` only when the answer changes (each call to `true` also does a fresh read).

import Foundation

@MainActor final class PermissionPollingDemand {
    enum Screen: Hashable, Sendable {
        case permissionsTab
        case onboarding
    }

    private let permissions: any PermissionsProviding
    private var visible: Set<Screen> = []

    init(permissions: any PermissionsProviding) {
        self.permissions = permissions
    }

    var isInteractive: Bool { !visible.isEmpty }

    func set(_ screen: Screen, visible on: Bool) {
        let before = isInteractive
        if on { visible.insert(screen) } else { visible.remove(screen) }
        if isInteractive != before { permissions.setInteractive(isInteractive) }
    }
}
