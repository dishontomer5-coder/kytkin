// P2-12: One user event held back during a replacement, returned in arrival order for replay.
// The adapter keeps its own copies of the CGEvents in the same order (one per `.hold` verdict) and re-posts
// them marked `replay`. Never logged.

import Foundation

struct HeldEvent: Sendable, Equatable {
    let event: KeyEvent
}
