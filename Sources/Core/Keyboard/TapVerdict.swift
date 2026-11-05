// P2-12: What the tap does with an event (001 §2.2).

import Foundation

enum TapVerdict: Sendable, Equatable {
    case pass
    case swallow
    /// Swallow into the hold-back FIFO; it is replayed (marked `replay`) when the replacement finishes or flushes.
    case hold
}
