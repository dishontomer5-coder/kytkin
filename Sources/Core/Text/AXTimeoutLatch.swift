// P2-49 item 5: a hung app answers every AX call with a 0.25 s messaging timeout (001 §7 B5). A step that kept
// reading after the first timeout (write → intact check → collapse → read-back fallback) would chain several of
// them and blow the 400 ms convert budget. So the first timeout trips a latch, and from then on, for the rest of
// that replacement, every AX call (element reads and writes, and the focus re-check before a key step) fails at
// once with `.timeout` without asking the app. A failure is never "untouched" by accident: the executor's
// intact checks then read as unknown, so the chain halts, and the key steps refuse (their focus check fails).

import Foundation

/// One replacement's timeout state, shared by the executor and its `TimeoutLatchedElement`.
final class AXTimeoutLatch {
    private(set) var tripped = false

    func reset() { tripped = false }

    /// Runs `call` unless the latch has tripped; trips it when `call` times out.
    func guarded<T>(_ call: () -> Result<T, AXAccessError>) -> Result<T, AXAccessError> {
        if tripped { return .failure(.timeout) }
        let result = call()
        if case .failure(.timeout) = result { tripped = true }
        return result
    }
}

/// Wraps the focused element so every AX call goes through the latch. Identity is the wrapped element's.
final class TimeoutLatchedElement: AXTextElement {
    let inner: any AXTextElement
    private let latch: AXTimeoutLatch

    init(_ inner: any AXTextElement, latch: AXTimeoutLatch) {
        self.inner = inner
        self.latch = latch
    }

    func string(_ attribute: AXTextAttribute) -> Result<String, AXAccessError> {
        latch.guarded { inner.string(attribute) }
    }

    func integer(_ attribute: AXTextAttribute) -> Result<Int, AXAccessError> {
        latch.guarded { inner.integer(attribute) }
    }

    func range(_ attribute: AXTextAttribute) -> Result<TextRange, AXAccessError> {
        latch.guarded { inner.range(attribute) }
    }

    func isSettable(_ attribute: AXTextAttribute) -> Result<Bool, AXAccessError> {
        latch.guarded { inner.isSettable(attribute) }
    }

    func string(in range: TextRange) -> Result<String, AXAccessError> {
        latch.guarded { inner.string(in: range) }
    }

    func supportsStringForRange() -> Result<Bool, AXAccessError> {
        latch.guarded { inner.supportsStringForRange() }
    }

    func isFocused() -> Result<Bool, AXAccessError> {   // P4-5b
        latch.guarded { inner.isFocused() }
    }

    func setString(_ value: String, for attribute: AXTextAttribute) -> Result<Void, AXAccessError> {
        latch.guarded { inner.setString(value, for: attribute) }
    }

    func setRange(_ value: TextRange, for attribute: AXTextAttribute) -> Result<Void, AXAccessError> {
        latch.guarded { inner.setRange(value, for: attribute) }
    }

    var processID: Int32? { inner.processID }

    func isSameElement(as other: any FocusedElementIdentity) -> Bool {
        inner.isSameElement(as: (other as? TimeoutLatchedElement)?.inner ?? other)
    }
}
