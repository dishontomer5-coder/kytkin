// P2-5: What one key types on each layer. `nil` means the layer types nothing (left out of the JSON).

import Foundation

struct KeyCell: Codable, Sendable, Equatable {
    var plain, shift, capsLock, option, shiftOption: String?

    init(plain: String? = nil, shift: String? = nil, capsLock: String? = nil,
         option: String? = nil, shiftOption: String? = nil) {
        self.plain = plain
        self.shift = shift
        self.capsLock = capsLock
        self.option = option
        self.shiftOption = shiftOption
    }

    subscript(layer: KeyLayer) -> String? {
        get {
            switch layer {
            case .plain: plain
            case .shift: shift
            case .capsLock: capsLock
            case .option: option
            case .shiftOption: shiftOption
            }
        }
        set {
            switch layer {
            case .plain: plain = newValue
            case .shift: shift = newValue
            case .capsLock: capsLock = newValue
            case .option: option = newValue
            case .shiftOption: shiftOption = newValue
            }
        }
    }

    /// The layers that type something, in `KeyLayer.allCases` order.
    var definedLayers: [KeyLayer] { KeyLayer.allCases.filter { self[$0] != nil } }
}
