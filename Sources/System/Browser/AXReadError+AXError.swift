// P3-10: Maps AX error codes onto Core's `AXReadError` (001 §14.3.2). Translation only, no AX calls, so it is
// compiled into the tests. `kAXErrorCannotComplete` is what a messaging timeout (or a hung or busy browser)
// returns, so it becomes `.timedOut`: the read's latch trips on it and the read stops at once (B13).

import ApplicationServices

extension AXReadError {
    init(_ error: AXError) {
        switch error {
        case .cannotComplete: self = .timedOut
        case .invalidUIElement: self = .invalidElement
        case .apiDisabled: self = .apiDisabled
        default: self = .other
        }
    }
}
