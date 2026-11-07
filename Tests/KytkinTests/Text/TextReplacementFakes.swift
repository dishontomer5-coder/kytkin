// P2-18: Fakes for the TextReplacer seams. Nothing here touches AX, CGEvent or any real app.

import Foundation

/// A text field simulated in UTF-16 units, the way AX reports it.
final class FakeTextField: AXTextElement {
    enum WriteBehavior {
        /// Replaces the selection and leaves the caret after the new text (NSTextView, R5).
        case normal
        /// Replaces the selection and leaves the new text selected (some apps do, R5 read-back accepts it).
        case normalKeepsSelection
        /// Returns success and changes nothing (NSTextField not editing, WebKit, R5).
        case silentNoop
        /// Returns success but writes something else.
        case garble
        /// Returns an error and changes nothing.
        case fails
    }

    var role: String? = "AXTextArea"
    var subrole: String?
    var units: [UInt16]
    var selection: TextRange
    var selTextSettable = true
    var selRangeSettable = true
    var markedRange: TextRange?
    var webKitMarked: Result<String, AXAccessError> = .failure(.unsupported)
    var supportsStringForRangeValue = true
    var writeBehavior = WriteBehavior.normal
    /// Reported instead of the real selection (R5: WebKit's garbage range).
    var reportedRange: TextRange?
    /// Reads of these attributes time out.
    var timeouts: Set<AXTextAttribute> = []
    /// P2-59: setting a caret (an empty range) fails, so a selection can't be collapsed.
    var rejectsCaretRanges = false
    /// P2-59: `AXStringForRange` answers this instead of the real text (an app returning the wrong length).
    var stringForRangeOverride: String?
    /// P2-59: every range `AXStringForRange` was asked for.
    private(set) var stringRangesRead: [TextRange] = []

    private(set) var reads: [AXTextAttribute] = []
    private(set) var writes: [AXTextAttribute] = []

    init(_ text: String, selection: TextRange? = nil) {
        units = Array(text.utf16)
        self.selection = selection ?? TextRange(location: units.count, length: 0)
    }

    var text: String { String(decoding: units, as: UTF16.self) }

    private func read<T>(_ a: AXTextAttribute, _ value: () -> T?) -> Result<T, AXAccessError> {
        reads.append(a)
        if timeouts.contains(a) { return .failure(.timeout) }
        guard let v = value() else { return .failure(.noValue) }
        return .success(v)
    }

    func string(_ a: AXTextAttribute) -> Result<String, AXAccessError> {
        switch a {
        case .role: return read(a) { role }
        case .subrole: return read(a) { subrole }
        case .value: return read(a) { text }
        case .selectedText: return read(a) { String(decoding: units[selection.location..<selection.end], as: UTF16.self) }
        case .webKitMarkedText:
            reads.append(a)
            return timeouts.contains(a) ? .failure(.timeout) : webKitMarked
        default: reads.append(a); return .failure(.failed)
        }
    }

    func integer(_ a: AXTextAttribute) -> Result<Int, AXAccessError> {
        a == .numberOfCharacters ? read(a) { units.count } : .failure(.unsupported)
    }

    func range(_ a: AXTextAttribute) -> Result<TextRange, AXAccessError> {
        switch a {
        case .selectedTextRange: return read(a) { reportedRange ?? selection }
        case .markedTextRange: return read(a) { markedRange }
        default: return .failure(.unsupported)
        }
    }

    func isSettable(_ a: AXTextAttribute) -> Result<Bool, AXAccessError> {
        switch a {
        case .selectedText: return .success(selTextSettable)
        case .selectedTextRange: return .success(selRangeSettable)
        default: return .success(false)
        }
    }

    func string(in r: TextRange) -> Result<String, AXAccessError> {
        guard supportsStringForRangeValue else { return .failure(.unsupported) }
        stringRangesRead.append(r)
        if let stringForRangeOverride { return .success(stringForRangeOverride) }
        guard r.location >= 0, r.end <= units.count else { return .failure(.failed) }
        return .success(String(decoding: units[r.location..<r.end], as: UTF16.self))
    }

    func supportsStringForRange() -> Result<Bool, AXAccessError> { .success(supportsStringForRangeValue) }

    func setString(_ value: String, for a: AXTextAttribute) -> Result<Void, AXAccessError> {
        writes.append(a)
        guard a == .selectedText, selTextSettable else { return .failure(.failed) }
        switch writeBehavior {
        case .normal: replaceSelection(with: value)
        case .normalKeepsSelection:
            let start = selection.location
            replaceSelection(with: value)
            selection = TextRange(location: start, length: value.utf16.count)
        case .silentNoop: break
        case .garble: replaceSelection(with: "?")
        case .fails: return .failure(.failed)
        }
        return .success(())
    }

    func setRange(_ value: TextRange, for a: AXTextAttribute) -> Result<Void, AXAccessError> {
        writes.append(a)
        guard a == .selectedTextRange, selRangeSettable, value.end <= units.count,
              !(rejectsCaretRanges && value.isCaret) else { return .failure(.failed) }
        selection = value
        return .success(())
    }

    private func replaceSelection(with value: String) {
        let new = Array(value.utf16)
        units.replaceSubrange(selection.location..<selection.end, with: new)
        selection = TextRange(location: selection.location + new.count, length: 0)
    }
}

final class FakeFocusProvider: FocusedElementProviding {
    var result: Result<any AXTextElement, AXAccessError>
    private(set) var timeouts: [Double] = []

    init(_ field: FakeTextField) { result = .success(field) }
    init(error: AXAccessError) { result = .failure(error) }

    func focusedTextElement(timeout: Double) -> Result<any AXTextElement, AXAccessError> {
        timeouts.append(timeout)
        return result
    }
}

final class RecordingPoster: KeyEventPosting {
    private(set) var events: [SyntheticKeyEvent] = []
    /// Refuse every post from this index on.
    var failFrom: Int?

    func post(_ event: SyntheticKeyEvent) -> Bool {
        if let f = failFrom, events.count >= f { return false }
        events.append(event)
        return true
    }

    var backspaceCount: Int { events.filter { $0.keyCode == KeyCode.delete && $0.isKeyDown }.count }
    /// The text typed, from keyDown events only.
    var typed: String {
        String(decoding: events.filter { $0.isKeyDown }.flatMap(\.unicode), as: UTF16.self)
    }
}
