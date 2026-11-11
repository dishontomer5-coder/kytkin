// P3-42: a fake Chromium/Electron web text box for `ChromiumAXConvert`, built from the P3-37 probe facts and the research
// (docs/research/p3-37-electron-chromium-ax.md §2): `AXValue` and the caret read fine; an `AXSelectedText` write is a
// silent no-op (recorded, never applied); `AXSelectedTextRange` writes move the real selection; typed Unicode key events
// (read from a `RecordingPoster`, the way the app would get them) replace the selection after `keyLagNanos` on the fake
// clock. Options mimic Slack: a character hidden from `AXValue` (the emoji), offsets that drift after it when the range
// is set, `AXStringForRange` failing for a range that reaches the end, `AXSelectedText` dropping line breaks. Each unit
// carries a "bold" flag, so tests can see that formatting around the typed-over letters survives. Nothing here touches
// AX, CGEvent or a real app.

import Foundation

final class FakeChromiumField: AXTextElement {
    /// The page's own text (DOM), in UTF-16 units, and a per-unit formatting flag.
    private(set) var doc: [UInt16]
    private(set) var bold: [Bool]
    /// The DOM selection.
    private(set) var domSelection: Range<Int>
    /// Units of `doc` that `AXValue` (and every AX offset) leaves out: Slack's emoji.
    var hidden: Range<Int>?
    /// Setting `AXSelectedTextRange` takes the AX offsets as DOM offsets (they drift after `hidden`).
    var setRangeDrifts = false
    /// Lists the DOM attributes (web content). False: a native field (the omnibox).
    var webContent = true
    var role = "AXTextArea"
    /// P3-40: `AXSelectedText` leaves out the line breaks.
    var selectedTextDropsLineBreaks = false
    /// Slack: `AXStringForRange` fails (-25212) for a range that reaches the end of the value.
    var stringForRangeFailsAtEnd = false
    /// `AXStringForRange` answers this instead (an app whose offsets disagree with `AXValue`).
    var stringForRangeOverride: String?
    /// `AXNumberOfCharacters` answers this instead of the value's length.
    var numberOfCharactersOverride: Int?
    /// `AXValue` read fails.
    var valueFails = false
    /// Typed keys reach the page this long after they were posted. nil = never (a page that ignores them).
    var keyLagNanos: UInt64? = 0
    /// Chromium applies a range write in the renderer: this many reads of the selected range after a write still
    /// report the old selection.
    var staleRangeReadsAfterSet = 0
    private var staleLeft = 0
    private var previousSelection: Range<Int> = 0..<0
    /// Runs after every `AXSelectedTextRange` write (to move the clock, change focus…).
    var onSetRange: ((TextRange) -> Void)?

    private let poster: RecordingPoster
    private let clock: FakeClock
    private var seen = 0
    private var pending: [(due: UInt64, event: SyntheticKeyEvent)] = []

    private(set) var selectedTextWrites = 0
    private(set) var valueWrites = 0
    private(set) var rangeWrites: [TextRange] = []
    /// Every `AXValue` read (the verify polls).
    private(set) var valueReads = 0

    var processID: Int32? = 4242
    func isSameElement(as other: any FocusedElementIdentity) -> Bool { other === self }

    init(_ text: String, caret: Int? = nil, selection: Range<Int>? = nil, poster: RecordingPoster, clock: FakeClock,
         boldUnits: Range<Int>? = nil) {
        doc = Array(text.utf16)
        bold = Array(repeating: false, count: doc.count)
        if let b = boldUnits { for i in b { bold[i] = true } }
        let c = caret ?? doc.count
        domSelection = selection ?? c..<c
        self.poster = poster
        self.clock = clock
    }

    /// The page's text as the user sees it.
    var text: String { String(decoding: doc, as: UTF16.self) }
    /// The bold flag per grapheme of `text`.
    var boldText: String {
        var out = ""
        var i = 0
        for ch in text {
            let n = ch.utf16.count
            if bold[i] { out.append(ch) }
            i += n
        }
        return out
    }

    // MARK: - The page taking key events

    private func sync() {
        let events = poster.events
        while seen < events.count {
            pending.append((clock.nowNanos &+ (keyLagNanos ?? 0), events[seen]))
            seen += 1
        }
        guard keyLagNanos != nil else { return }
        while let first = pending.first, first.due <= clock.nowNanos {
            pending.removeFirst()
            apply(first.event)
        }
    }

    private func apply(_ e: SyntheticKeyEvent) {
        guard e.isKeyDown, e.modifierFlags == 0 else { return }
        if e.keyCode == KeyCode.delete, e.unicode.isEmpty {
            if domSelection.isEmpty, domSelection.lowerBound > 0 {
                let at = domSelection.lowerBound - 1
                doc.remove(at: at)
                bold.remove(at: at)
                domSelection = at..<at
            } else {
                replaceSelection(with: [])
            }
            return
        }
        guard e.keyCode == SyntheticKeyEvent.unicodeKeyCode, !e.unicode.isEmpty else { return }
        replaceSelection(with: e.unicode)
    }

    /// Typed text takes the formatting of the first selected unit (or of the unit before the caret).
    private func replaceSelection(with units: [UInt16]) {
        let lo = domSelection.lowerBound
        let style = domSelection.isEmpty ? (lo > 0 ? bold[lo - 1] : false) : bold[lo]
        let delta = units.count - domSelection.count
        doc.replaceSubrange(domSelection, with: units)
        bold.replaceSubrange(domSelection, with: Array(repeating: style, count: units.count))
        domSelection = (lo + units.count)..<(lo + units.count)
        // The hidden emoji moves with a length change before it.
        if let h = hidden, lo < h.lowerBound { hidden = (h.lowerBound + delta)..<(h.upperBound + delta) }
    }

    // MARK: - AX offsets

    private var axUnits: [UInt16] {
        guard let h = hidden else { return doc }
        var u = doc
        u.removeSubrange(h)
        return u
    }

    private func toAX(_ dom: Int) -> Int {
        guard let h = hidden else { return dom }
        if dom >= h.upperBound { return dom - h.count }
        return min(dom, h.lowerBound)
    }

    private func toDOM(_ ax: Int, isEnd: Bool) -> Int {
        guard let h = hidden, !setRangeDrifts else { return ax }
        if ax > h.lowerBound || (ax == h.lowerBound && !isEnd) { return ax + h.count }
        return ax
    }

    // MARK: - AXTextElement

    func attributeNames() -> Result<[String], AXAccessError> {
        .success(webContent ? ["AXRole", "AXValue", "AXSelectedTextRange", "AXDOMClassList", "AXDOMIdentifier",
                               "ChromeAXNodeId"]
                            : ["AXRole", "AXValue", "AXSelectedTextRange"])
    }

    func string(_ a: AXTextAttribute) -> Result<String, AXAccessError> {
        sync()
        switch a {
        case .role: return .success(role)
        case .value:
            valueReads += 1
            return valueFails ? .failure(.failed) : .success(String(decoding: axUnits, as: UTF16.self))
        case .selectedText:
            var u = Array(doc[domSelection])
            if let h = hidden {
                let overlap = h.clamped(to: domSelection)
                if !overlap.isEmpty { u.removeSubrange((overlap.lowerBound - domSelection.lowerBound)..<(overlap.upperBound - domSelection.lowerBound)) }
            }
            let s = String(decoding: u, as: UTF16.self)
            return .success(selectedTextDropsLineBreaks ? s.filter { !$0.isNewline } : s)
        default: return .failure(.noValue)
        }
    }

    func integer(_ a: AXTextAttribute) -> Result<Int, AXAccessError> {
        sync()
        guard a == .numberOfCharacters else { return .failure(.unsupported) }
        return .success(numberOfCharactersOverride ?? axUnits.count)
    }

    func range(_ a: AXTextAttribute) -> Result<TextRange, AXAccessError> {
        sync()
        switch a {
        case .selectedTextRange:
            var sel = domSelection
            if staleLeft > 0 {
                staleLeft -= 1
                sel = previousSelection
            }
            let lo = toAX(sel.lowerBound), hi = toAX(sel.upperBound)
            return .success(TextRange(location: lo, length: hi - lo))
        case .markedTextRange: return .failure(.noValue)
        default: return .failure(.unsupported)
        }
    }

    func isSettable(_ a: AXTextAttribute) -> Result<Bool, AXAccessError> {
        .success(a == .selectedText || a == .selectedTextRange || a == .value)
    }

    func string(in r: TextRange) -> Result<String, AXAccessError> {
        sync()
        let u = axUnits
        guard r.location >= 0, r.length >= 0, r.end <= u.count else { return .failure(.failed) }
        if stringForRangeFailsAtEnd, r.end == u.count { return .failure(.failed) }
        if let stringForRangeOverride { return .success(stringForRangeOverride) }
        return .success(String(decoding: u[r.location..<r.end], as: UTF16.self))
    }

    func supportsStringForRange() -> Result<Bool, AXAccessError> { .success(true) }

    func setString(_ value: String, for a: AXTextAttribute) -> Result<Void, AXAccessError> {
        // Chromium web content: `kReplaceSelectedText` is not handled, the call still succeeds (research §2).
        if a == .selectedText { selectedTextWrites += 1 }
        if a == .value { valueWrites += 1 }
        return .success(())
    }

    func setRange(_ value: TextRange, for a: AXTextAttribute) -> Result<Void, AXAccessError> {
        sync()
        guard a == .selectedTextRange, value.location >= 0, value.length >= 0 else { return .failure(.failed) }
        let lo = toDOM(value.location, isEnd: false)
        let hi = value.isCaret ? lo : toDOM(value.end, isEnd: true)
        guard lo <= hi, hi <= doc.count else { return .failure(.failed) }
        rangeWrites.append(value)
        previousSelection = domSelection
        staleLeft = staleRangeReadsAfterSet
        domSelection = lo..<hi
        onSetRange?(value)
        return .success(())
    }
}

/// A focus provider whose answer a test can switch (focus moving to another field between pieces).
final class SwitchableFocusProvider: FocusedElementProviding {
    var focused: any AXTextElement
    private(set) var reads = 0
    init(_ focused: any AXTextElement) { self.focused = focused }
    func focusedTextElement(timeout: Double) -> Result<any AXTextElement, AXAccessError> {
        reads += 1
        return .success(focused)
    }
}
