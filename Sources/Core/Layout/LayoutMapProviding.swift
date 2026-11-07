// P2-6: Where LayoutMaps come from at runtime (001 §2.2). The system adapter is
// `UCKeyTranslateLayoutMapProvider` (System/Input); tests use the checked-in fixtures instead.

import Foundation

@MainActor protocol LayoutMapProviding {
    /// Keyboard layouts the picker can offer. `includeDisabled` also lists installed-but-not-enabled ones.
    func convertibleLayouts(includeDisabled: Bool) -> [InputSourceInfo]
    /// The map for `id`, cached. `nil` = can't convert (not installed, or an input method with no layout data).
    func map(for id: InputSourceID) -> LayoutMap?
    /// P2-24: the input source Kytkin selects for the pair member `id`: `id` itself for an installed layout, the
    /// `base` for an imported map that types with an installed layout (001 §4.3), nil if there is none.
    func inputSource(for id: InputSourceID) -> InputSourceID?
}

extension LayoutMapProviding {
    /// A provider of system maps only: every map id is an input source.
    func inputSource(for id: InputSourceID) -> InputSourceID? { id }

    /// P2-24: the pair as input sources, for switching (each member resolved by `inputSource(for:)`; a member with
    /// none keeps its id, so a toggle to it fails visibly instead of switching to something else).
    func inputSources(for pair: LanguagePair) -> LanguagePair {
        LanguagePair(a: inputSource(for: pair.a) ?? pair.a, b: inputSource(for: pair.b) ?? pair.b)
    }
}
