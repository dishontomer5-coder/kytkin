// P2-18: Why an AX read or write didn't succeed, reduced to what the replacer decides on (001 §2.2, B5).

import Foundation

enum AXAccessError: Error, Sendable, Equatable {
    /// The app didn't answer within the messaging timeout (0.25 s), or the call couldn't complete.
    case timeout
    /// The attribute exists but has no value right now (e.g. no selection).
    case noValue
    /// The element doesn't support the attribute (or the parameterized attribute).
    case unsupported
    /// Accessibility isn't granted. Checked silently; Kytkin never prompts from here.
    case notTrusted
    /// The element went away (the field closed or the app quit).
    case invalidElement
    /// Any other AX error, or a value of an unexpected type.
    case failed

    /// Errors that mean "this element can't be trusted for anything right now", so a focus read gives up
    /// instead of guessing (001 §12 T4).
    var abortsFocusRead: Bool {
        switch self {
        case .timeout, .notTrusted, .invalidElement: return true
        case .noValue, .unsupported, .failed: return false
        }
    }
}
