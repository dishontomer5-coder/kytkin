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
        /// P2-49: the app hangs: writes the text, then the call times out (the state is unknown to the caller).
        case writesThenTimesOut
        /// P2-49: the app hangs: the call times out and nothing is written.
        case timesOut
        /// P3-33: WebKit's contenteditable rebalances whitespace: every no-break space written lands as a plain space.
        case noBreakSpacesBecomeSpaces
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
    /// QA P2-49: the selected-range read fails with this error (the selection itself is unchanged).
    var selectedRangeError: AXAccessError?
    /// Reads of these attributes time out.
    var timeouts: Set<AXTextAttribute> = []
    /// P2-49 item 6: the subrole read answers this instead (e.g. `.failure(.failed)`: an error or a wrong type).
    var subroleResult: Result<String, AXAccessError>?
    /// P2-49 item 5: true once any call answered `.timeout`; every AX call after that is counted here.
    private(set) var hasTimedOut = false
    private(set) var callsAfterTimeout = 0
    /// P2-59: setting a caret (an empty range) fails, so a selection can't be collapsed.
    var rejectsCaretRanges = false
    /// P2-59: `AXStringForRange` answers this instead of the real text (an app returning the wrong length).
    var stringForRangeOverride: String?
    /// P3-33: reads longer than this come back one unit short (an app counting far text, e.g. an attachment or a
    /// block break, differently from the range it was given).
    var stringForRangeExactUpTo: Int?
    /// P3-35: `AXNumberOfCharacters` answers this error instead (an app that won't say how long the field is).
    var numberOfCharactersError: AXAccessError?
    /// P3-40: Chromium-like: `AXSelectedText` leaves out the line breaks inside the selection (Slack's contenteditable
    /// joins paragraphs in it). `AXStringForRange` and the field itself keep them.
    var selectedTextDropsLineBreaks = false
    /// P6-0j QA: an inline-completion field (Spotlight): after each successful `AXSelectedText` write, this text is
    /// inserted after the caret and selected (the app completes again).
    var recompletes: String?
    /// P2-59: every range `AXStringForRange` was asked for.
    private(set) var stringRangesRead: [TextRange] = []

    private(set) var reads: [AXTextAttribute] = []
    private(set) var writes: [AXTextAttribute] = []

    /// P2-59c: the owning process, and the identity same-element checks compare (the same object = the same element).
    var processID: Int32? = 4242
    /// P2-49: the AX element this fake stands for. Two fakes with the same id are two copies of one element (live:
    /// `CFEqual` on two `AXUIElement`s); a new fake is a different element.
    lazy var elementID = ObjectIdentifier(self)
    func isSameElement(as other: any FocusedElementIdentity) -> Bool {
        (other as? FakeTextField)?.elementID == elementID
    }

    /// P4-5b: what `AXFocused` answers (and how many times it was asked).
    var focusedAnswer: Result<Bool, AXAccessError> = .failure(.unsupported)
    private(set) var focusedReads = 0
    func isFocused() -> Result<Bool, AXAccessError> {
        focusedReads += 1
        return focusedAnswer
    }

    init(_ text: String, selection: TextRange? = nil) {
        units = Array(text.utf16)
        self.selection = selection ?? TextRange(location: units.count, length: 0)
    }

    var text: String { String(decoding: units, as: UTF16.self) }

    /// Counts every call made after the app first timed out (P2-49 item 5: there should be none).
    private func call() { if hasTimedOut { callsAfterTimeout += 1 } }
    private func timedOut<T>() -> Result<T, AXAccessError> { hasTimedOut = true; return .failure(.timeout) }

    private func read<T>(_ a: AXTextAttribute, _ value: () -> T?) -> Result<T, AXAccessError> {
        call()
        reads.append(a)
        if timeouts.contains(a) { return timedOut() }
        guard let v = value() else { return .failure(.noValue) }
        return .success(v)
    }

    func string(_ a: AXTextAttribute) -> Result<String, AXAccessError> {
        switch a {
        case .role: return read(a) { role }
        case .subrole:
            if let subroleResult { call(); reads.append(a); return subroleResult }
            return read(a) { subrole }
        case .value: return read(a) { text }
        case .selectedText:
            return read(a) {
                let s = String(decoding: units[selection.location..<selection.end], as: UTF16.self)
                return selectedTextDropsLineBreaks ? s.filter { !$0.isNewline } : s   // P3-40
            }
        case .webKitMarkedText:
            call()
            reads.append(a)
            return timeouts.contains(a) ? timedOut() : webKitMarked
        default: call(); reads.append(a); return .failure(.failed)
        }
    }

    func integer(_ a: AXTextAttribute) -> Result<Int, AXAccessError> {
        if a != .numberOfCharacters { call(); return .failure(.unsupported) }
        if let numberOfCharactersError { call(); reads.append(a); return .failure(numberOfCharactersError) }
        return read(a) { units.count }
    }

    func range(_ a: AXTextAttribute) -> Result<TextRange, AXAccessError> {
        switch a {
        case .selectedTextRange:
            if let selectedRangeError { call(); reads.append(a); return .failure(selectedRangeError) }
            return read(a) { reportedRange ?? selection }
        case .markedTextRange: return read(a) { markedRange }
        default: call(); return .failure(.unsupported)
        }
    }

    func isSettable(_ a: AXTextAttribute) -> Result<Bool, AXAccessError> {
        call()
        if timeouts.contains(a) { return timedOut() }
        switch a {
        case .selectedText: return .success(selTextSettable)
        case .selectedTextRange: return .success(selRangeSettable)
        default: return .success(false)
        }
    }

    func string(in r: TextRange) -> Result<String, AXAccessError> {
        call()
        guard supportsStringForRangeValue else { return .failure(.unsupported) }
        stringRangesRead.append(r)
        if let stringForRangeOverride { return .success(stringForRangeOverride) }
        guard r.location >= 0, r.end <= units.count else { return .failure(.failed) }
        if let limit = stringForRangeExactUpTo, r.length > limit {
            return .success(String(decoding: units[(r.location + 1)..<r.end], as: UTF16.self))
        }
        return .success(String(decoding: units[r.location..<r.end], as: UTF16.self))
    }

    func supportsStringForRange() -> Result<Bool, AXAccessError> { call(); return .success(supportsStringForRangeValue) }

    func setString(_ value: String, for a: AXTextAttribute) -> Result<Void, AXAccessError> {
        call()
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
        case .writesThenTimesOut: replaceSelection(with: value); return timedOut()
        case .timesOut: return timedOut()
        case .noBreakSpacesBecomeSpaces:
            replaceSelection(with: String(decoding: value.utf16.map { $0 == 0xA0 ? 0x20 : $0 }, as: UTF16.self))
        }
        if let recompletes, writeBehavior == .normal {
            let at = selection.location
            units.insert(contentsOf: Array(recompletes.utf16), at: at)
            selection = TextRange(location: at, length: recompletes.utf16.count)
        }
        return .success(())
    }

    func setRange(_ value: TextRange, for a: AXTextAttribute) -> Result<Void, AXAccessError> {
        call()
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
