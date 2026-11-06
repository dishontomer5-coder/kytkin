// P2-14: The thin seam between `InputSourceSwitcher` (Core, unit-tested) and the Text Input Sources API.
// The real implementation is `TISInputSourceBackend` (System/Input): pure translation, no decisions.
// Tests use a fake, so the switcher contract (001 §2.2) is tested without ever selecting a real source.

import Foundation

@MainActor protocol TISBackend: AnyObject {
    /// The selected keyboard input source (TISCopyCurrentKeyboardInputSource). nil if TIS reports none.
    var current: InputSourceInfo? { get }
    /// Selectable keyboard input sources, deduplicated by ID.
    func sources(includeDisabled: Bool) -> [InputSourceInfo]
    /// TISSelectInputSource on an enabled source. False if it isn't enabled or TIS returns an error.
    func select(_ id: InputSourceID) -> Bool
    /// Starts delivering the two distributed TIS notifications on the main actor. Called once, from init.
    func observe(selectedChanged: @escaping @MainActor () -> Void,
                 enabledChanged: @escaping @MainActor () -> Void)
}
