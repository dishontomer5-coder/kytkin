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
    /// P3-46: a mention pill (units of `doc`) that every AX *offset* (selected range reads and writes, `AXStringForRange`)
    /// counts as one unit, while `AXValue` holds its whole text (Chromium's hypertext: an embedded object). Not combined
    /// with `hidden` in one test.
    var pill: Range<Int>?
    /// P3-46: `AXStringForRange` gives U+FFFC for the pill instead of its text.
    var pillAsObjectCharacter = false
    /// P3-51 (owner Slack traces `ax9/value9/common3`, `ax10/value10/common3`): an emoji (units of `doc`) that `AXValue`
    /// shows as one U+FFFC and the selected range reads and writes count as one unit, while `AXStringForRange` works in
    /// the page's own units (the emoji's two) and returns the emoji itself, as does `AXSelectedText`.
    var emojiObject: Range<Int>?
    /// Setting `AXSelectedTextRange` takes the AX offsets as DOM offsets (they drift after `hidden`).
    var setRangeDrifts = false
    /// P3-42 QA: after a range write, `AXSelectedTextRange` reads back exactly the range written (until typing moves the
    /// selection), however the page mapped it: a drifted write then "agrees", only the selected text can tell.
    var rangeReadEchoesWrite = false
    private var echoedRange: TextRange?
    /// Lists the DOM attributes (web content). False: a native field (the omnibox).
    var webContent = true
    var role = "AXTextArea"
    /// P3-40: `AXSelectedText` leaves out the line breaks.
    var selectedTextDropsLineBreaks = false
    /// Slack: `AXStringForRange` fails (-25212) for a range that reaches the end of the value.
    var stringForRangeFailsAtEnd = false
    /// P3-46 QA: `AXStringForRange` fails for every range (Slack's -25212, here also for the range up to the caret).
    var stringForRangeFails = false
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
    /// P3-44 QA: a stale range read comes from the old AX tree, so `AXSelectedText` read right after it is stale too
    /// (Chromium updates the whole tree asynchronously).
    var staleSelectedTextToo = false
    private var lastRangeReadStale = false
    private var previousSelection: Range<Int> = 0..<0
    /// P3-44: the texts the AX tree shows as inline elements (mention pills, links). nil = the call is unsupported.
    var inlineAtoms: [String]? = []
    /// P3-46: the role the fake reports for every inline atom.
    var inlineAtomRole = "AXStaticText"
    /// P3-44 (shape B): the selected range is read in page (DOM) units, as written, so a caret after a hidden emoji reads
    /// past the end of `AXValue`.
    var readsInPageUnits = false
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
        echoedRange = nil
        // The hidden emoji moves with a length change before it.
        if let h = hidden, lo < h.lowerBound { hidden = (h.lowerBound + delta)..<(h.upperBound + delta) }
        if let p = pill, lo < p.lowerBound { pill = (p.lowerBound + delta)..<(p.upperBound + delta) }
        if let e = emojiObject, lo < e.lowerBound { emojiObject = (e.lowerBound + delta)..<(e.upperBound + delta) }
    }

    // MARK: - AX offsets

    private var axUnits: [UInt16] {
        if let e = emojiObject {
            var u = doc
            u.replaceSubrange(e, with: [0xFFFC])
            return u
        }
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

    /// P3-46: a `doc` offset in pill-compressed units, and back.
    private func toObject(_ dom: Int) -> Int {
        guard let p = pill ?? emojiObject, dom > p.lowerBound else { return dom }
        return dom >= p.upperBound ? dom - p.count + 1 : p.lowerBound
    }

    private func fromObject(_ obj: Int) -> Int {
        guard let p = pill ?? emojiObject, obj > p.lowerBound else { return obj }
        return obj + p.count - 1
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
            let shown = staleSelectedTextToo && lastRangeReadStale ? previousSelection : domSelection
            var u = Array(doc[shown])
            if let h = hidden {
                let overlap = h.clamped(to: shown)
                if !overlap.isEmpty { u.removeSubrange((overlap.lowerBound - shown.lowerBound)..<(overlap.upperBound - shown.lowerBound)) }
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
            lastRangeReadStale = staleLeft > 0
            if staleLeft > 0 {
                staleLeft -= 1
                sel = previousSelection
            }
            if rangeReadEchoesWrite, let echoedRange { return .success(echoedRange) }
            if readsInPageUnits { return .success(TextRange(location: sel.lowerBound, length: sel.count)) }
            if pill != nil || emojiObject != nil {
                let lo = toObject(sel.lowerBound), hi = toObject(sel.upperBound)
                return .success(TextRange(location: lo, length: hi - lo))
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
        if stringForRangeFails { return .failure(.failed) }
        if stringForRangeFailsAtEnd, r.end == u.count { return .failure(.failed) }
        if let stringForRangeOverride { return .success(stringForRangeOverride) }
        if emojiObject != nil {   // P3-51: the page's own units
            guard r.end <= doc.count else { return .failure(.failed) }
            return .success(String(decoding: doc[r.location..<r.end], as: UTF16.self))
        }
        if let p = pill {
            let lo = fromObject(r.location), hi = fromObject(r.end)
            guard hi <= doc.count else { return .failure(.failed) }
            var out: [UInt16] = []
            var i = lo
            while i < hi {
                if pillAsObjectCharacter, i == p.lowerBound {
                    out.append(0xFFFC)
                    i = p.upperBound
                } else {
                    out.append(doc[i])
                    i += 1
                }
            }
            return .success(String(decoding: out, as: UTF16.self))
        }
        return .success(String(decoding: u[r.location..<r.end], as: UTF16.self))
    }

    func supportsStringForRange() -> Result<Bool, AXAccessError> { .success(true) }

    /// P3-53: the budget the last atom walk was given, and a hook (to move the fake clock: a slow walk).
    private(set) var atomBudgets: [UInt64] = []
    var onInlineAtoms: (() -> Void)?
    func inlineAtoms(maxNodes: Int, budgetNanos: UInt64) -> Result<[InlineAtom], AXAccessError> {
        atomBudgets.append(budgetNanos)
        onInlineAtoms?()
        return inlineAtoms.map { .success($0.prefix(maxNodes).map { InlineAtom(text: $0, role: inlineAtomRole) }) }
            ?? .failure(.unsupported)
    }

    func setString(_ value: String, for a: AXTextAttribute) -> Result<Void, AXAccessError> {
        // Chromium web content: `kReplaceSelectedText` is not handled, the call still succeeds (research §2).
        if a == .selectedText { selectedTextWrites += 1 }
        if a == .value { valueWrites += 1 }
        return .success(())
    }

    func setRange(_ value: TextRange, for a: AXTextAttribute) -> Result<Void, AXAccessError> {
        sync()
        guard a == .selectedTextRange, value.location >= 0, value.length >= 0 else { return .failure(.failed) }
        var lo = toDOM(value.location, isEnd: false)
        var hi = value.isCaret ? lo : toDOM(value.end, isEnd: true)
        if pill != nil || emojiObject != nil { lo = fromObject(value.location); hi = fromObject(value.end) }
        guard lo <= hi, hi <= doc.count else { return .failure(.failed) }
        rangeWrites.append(value)
        previousSelection = domSelection
        staleLeft = staleRangeReadsAfterSet
        domSelection = lo..<hi
        echoedRange = value
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
