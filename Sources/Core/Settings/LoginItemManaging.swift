// P2-23: The seam for launch at login (R8 §8). The live adapter is `SMAppServiceLoginItems` (System/Login) over
// `SMAppService.mainApp`; tests use a fake. Kytkin calls `register`/`unregister` ONLY from the user's click on the
// General tab switch, never at startup (design.md: never change system settings without the user).

import Foundation

@MainActor protocol LoginItemManaging: AnyObject {
    /// Read fresh every time (R8: don't cache it; the user can change it in System Settings).
    var status: LoginItemStatus { get }
    func register() throws
    func unregister() throws
    /// Opens System Settings → General → Login Items. User click only.
    func openSystemSettingsLoginItems()
}
