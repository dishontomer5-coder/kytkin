// P2-18: Maps AX error codes onto Core's `AXAccessError`. Translation only.

import ApplicationServices

extension AXAccessError {
    init(_ error: AXError) {
        switch error {
        case .cannotComplete: self = .timeout   // what a messaging timeout (or a hung app) returns
        case .noValue: self = .noValue
        case .attributeUnsupported, .parameterizedAttributeUnsupported, .actionUnsupported: self = .unsupported
        case .apiDisabled: self = .notTrusted
        case .invalidUIElement: self = .invalidElement
        default: self = .failed
        }
    }
}
