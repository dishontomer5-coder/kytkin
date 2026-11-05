// P2-5: One key press as the user made it: the key code plus the layer from the real modifier flags.
// The word buffer holds strokes, never the text they typed (design.md privacy invariants).

import Foundation

struct Stroke: Sendable, Equatable {
    let keyCode: UInt16
    let layer: KeyLayer
}
