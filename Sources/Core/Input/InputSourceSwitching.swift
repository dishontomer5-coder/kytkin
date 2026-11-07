// P2-14: The Core-facing input-source switcher (001 §2.2). Implemented by `InputSourceSwitcher` over a
// `TISBackend`; the real backend is `TISInputSourceBackend` (System/Input). Controllers (P2-20) and the
// menu talk only to this protocol, so they can be tested with a fake.

import Foundation

@MainActor protocol InputSourceSwitching: AnyObject {
    /// The selected keyboard input source.
    var current: InputSourceID { get }
    /// P2-43: the current source with its name and language code, for the menu-bar label (nil if TIS reports none).
    var currentInfo: InputSourceInfo? { get }
    /// Keyboard input sources the user can select. `includeDisabled` also lists installed-but-disabled ones.
    func sources(includeDisabled: Bool) -> [InputSourceInfo]
    /// No-op (returns true) if `id` is already current. False = the select failed (unknown, disabled or TIS error).
    @discardableResult func select(_ id: InputSourceID, reason: SwitchReason) -> Bool
    /// Every real change of the selected source, told apart into ours/external by `SwitchAttributor`.
    /// P2-43 (001 §12 W3): ONE owner, the composition root (`AppEnvironment`), which fans it out.
    var onChange: (@MainActor (InputSourceChange) -> Void)? { get set }
    /// The user added, removed, enabled or disabled an input source (kTISNotifyEnabledKeyboardInputSourcesChanged).
    var onSourcesListChanged: (@MainActor () -> Void)? { get set }
}
