// P2-6: Where LayoutMaps come from at runtime (001 §2.2). The system adapter is
// `UCKeyTranslateLayoutMapProvider` (System/Input); tests use the checked-in fixtures instead.

import Foundation

@MainActor protocol LayoutMapProviding {
    /// Keyboard layouts the picker can offer. `includeDisabled` also lists installed-but-not-enabled ones.
    func convertibleLayouts(includeDisabled: Bool) -> [InputSourceInfo]
    /// The map for `id`, cached. `nil` = can't convert (not installed, or an input method with no layout data).
    func map(for id: InputSourceID) -> LayoutMap?
}
