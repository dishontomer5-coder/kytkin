// P2-12: Why the processor was told to forget its state (001 §2.2). Every reason clears the word buffer,
// resets double-Shift, and flushes any held events unchanged.

import Foundation

enum ResetReason: Sendable, Equatable {
    case contextChange
    case secureInputOn
    case tapReEnabled
    case modeChange
    /// An input-source change that wasn't our own after-convert switch.
    case inputSourceChanged
}
