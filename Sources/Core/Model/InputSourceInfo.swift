// P2-6: What Kytkin knows about one installed input source (001 §2.2, Core/Model).
// Listed by LayoutMapProviding (and later InputSourceSwitching, P2-14) for the Settings language picker.

import Foundation

struct InputSourceInfo: Sendable, Equatable {
    let id: InputSourceID
    let name: String
    /// Element 0 of the source's languages list (R1), e.g. "he". Empty if the source lists none.
    let languageCode: String
    let isEnabled: Bool
    /// A keyboard layout with uchr data, so a LayoutMap can be built for it (R6 §3).
    let isConvertible: Bool
    /// CJK and other input methods: best effort, can't convert.
    let isInputMethod: Bool
}
