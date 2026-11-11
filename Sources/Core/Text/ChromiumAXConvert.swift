// P3-42 (001 §12.3 X15; research p3-37 §5; probe docs/research/r3b/p3-37-results/): the Chromium/Electron AX convert, for
// apps seeded keys-only whose web text boxes AX can read (`FieldFamily.chromiumAX`: Chrome, Edge, Brave, Arc, Vivaldi,
// Opera, Slack, Discord, Teams). Probe facts (owner's Mac, macOS 26.6.2): Slack, Google Translate and Gmail compose expose
// an `AXTextArea` in the web area with no AX flag set; `AXValue` length == `AXNumberOfCharacters`; the caret range is
// consistent; `AXStringForRange` before the caret matches `AXValue`; line breaks are LF. Slack quirks: an emoji is missing
// from `AXValue` (one unit short) and `AXStringForRange` of the whole box fails (-25212). Research: an `AXSelectedText`
// write is a silent no-op in web content and an `AXValue` write breaks the page's editor, so neither is ever written here;
// an `AXSelectedTextRange` write moves the real selection.
//
// The flow, on @TextActor, every loop bounded:
//   1. The focused element must still be the one the convert started on. Read it: its attribute names must include a
//      DOM attribute (web content, never the omnibox or another native field), `AXValue` (≤ 16,384 UTF-16 units, the
//      P3-35 cap), `AXNumberOfCharacters` == that length, the selected range inside it (a caret for a box convert, a
//      selection for a selection convert), `AXSelectedText` == the value there (for a selection, Chromium may drop the
//      line breaks from it: the visible characters must then agree, P3-40), and `AXStringForRange` up to the caret /
//      selection end, when the app answers it, must agree too. Anything else → `.unavailable` (the caller uses the
//      clipboard path, P3-37, as before).
//   2. The caller converts (the P3-35 `BoxConversion` of the whole box, or the selection on its own) into per-grapheme
//      changes. Neighbouring changes become one piece; a piece never crosses the caret, never holds a line break or
//      any other control character (it would be typed), and never includes unchanged text: so Slack bold, links and
//      mentions around the changed letters stay as they are. More than `maxPieces` pieces: pieces separated only by
//      spaces are joined (still never across a line break or the caret); still too many → `.unavailable`.
//   3. The B3 claim. Then for each piece, **last to first** (earlier offsets stay valid): check the budget (400 ms, B5;
//      never stopped half way through a piece), check the focus (P2-49 item 3), set `AXSelectedTextRange` to the
//      piece (P3-42 QA: when the piece's text occurs more than once in the box, first a window around it whose text
//      is unique, read back the same way: a drift onto another occurrence of the same text can't pass), wait (≤ 100
//      ms, polled) until the app reports that range selected (Chromium updates it asynchronously),
//      read `AXSelectedText` back and require exactly the original piece (this catches Slack's
//      emoji offset shift and any drift), then post the replacement as Unicode key events (no control characters, no
//      modifiers, never Return; `KeyStrokeComposer` chunks long text) and wait (≤ 150 ms, polled) until `AXValue`
//      reads as the box with this piece replaced and the caret sits after it. Only then the next piece: an AX
//      selection set before the app took the typed keys would make them land on the wrong text.
//   4. The caret goes back to its logical place (moved by any length change before it; after a selection: the end of
//      the converted selection), and `AXValue` is read once more to verify the whole result.
//   A read-back mismatch, a budget or focus stop before anything was typed → the selection / caret is put back and
//   `.unavailable` (fall back). After at least one verified piece → `.partial` (each written piece was verified; the
//   caller beeps). Typed keys that never showed, or a post that failed part way → `.failed` (state unknown, beep).
//
// Privacy: the box text, the pieces and the converted text live only in `run` for this one convert, never logged or
// stored (B12, CLAUDE.md). `AXValue` is read to convert and to verify Kytkin's own write, piece by piece.

import Foundation

@TextActor final class ChromiumAXConvert {
    /// P3-42: the hidden kill switch (code). The composition root also honours the `KytkinDisableChromiumAX` user
    /// default (`defaults write <bundle id> KytkinDisableChromiumAX -bool YES`), so the path can be turned off without a
    /// rebuild; off = these apps use the P3-37 clipboard path as before.
    nonisolated static let isEnabled = true
    nonisolated static let killSwitchDefaultsKey = "KytkinDisableChromiumAX"

    /// The most pieces one convert types (each piece is a few AX calls plus a wait for the app to take the keys).
    nonisolated static let maxPieces = 24
    /// A focused element listing any of these attributes is a web-content node (Chromium `BrowserAccessibilityCocoa`;
    /// both are listed for Slack's composer, Translate's textarea and Gmail's compose in the probe). Native fields (the
    /// omnibox, the Find bar) have no DOM.
    nonisolated static let webContentAttributes: Set<String> = ["AXDOMIdentifier", "AXDOMClassList"]

    struct Timing: Sendable, Equatable {
        /// Poll interval while waiting for the app to take a piece's keys.
        var pollNanos: UInt64 = 5_000_000
        /// The longest wait for one piece (the KeyStreamProcessor's 1 s hard cap bounds the whole convert anyway).
        var settleNanos: UInt64 = 150_000_000
        /// The longest wait for a range write to show as the selection (research §5 step 3: ≤ 100 ms).
        var selectSettleNanos: UInt64 = 100_000_000
        /// 001 §7 B5: no new piece starts later than this after the flow started.
        var budgetNanos: UInt64 = ReplacementChain.defaultBudgetNanos

        init() {}
    }

    enum Source: Sendable, Equatable {
        /// Nothing selected: the whole box (P3-35).
        case box
        /// The user's selection (P3-40 (b): its line breaks stay, they are never part of a piece).
        case selection
    }

    /// What step 1 read. `text` is `AXValue`; `selection` is the AX selected range (a caret for `.box`).
    struct Read: Sendable, Equatable {
        let text: String
        let selection: TextRange
    }

    /// The caller's conversion of a `Read`.
    enum Planned: Sendable, Equatable {
        /// Per-grapheme changes, offsets relative to `Read.text` (sorted, not overlapping).
        case changes([TextChange])
        case nothing
        case tooLong
        /// The caller can't convert this read safely (e.g. its per-grapheme result disagrees with the whole one).
        case unavailable
    }

    /// One run of changed graphemes, typed over as one selection.
    struct Piece: Sendable, Equatable {
        let location: Int
        let original: String
        let replacement: String

        var range: TextRange { TextRange(location: location, length: original.utf16.count) }
        var end: Int { location + original.utf16.count }
        var delta: Int { replacement.utf16.count - original.utf16.count }
    }

    enum Stop: Error, Sendable, Equatable {
        /// The focused element is not the one the convert started on.
        case focusChanged
        /// No DOM attribute: not web content (the omnibox, a native field).
        case notWebContent
        /// An AX read failed or timed out.
        case readFailed
        /// The box is empty or bigger than the cap.
        case boxSize
        /// Length, range or text checks disagree (step 1), or a piece isn't typeable.
        case inconsistent
        case tooManyPieces
        /// Setting the selection failed, or the read-back is not the expected piece (Slack's emoji shift).
        case selectionMismatch
        /// The budget ran out before a piece.
        case timedOut
        /// A key event couldn't be posted.
        case postFailed
        /// The typed keys didn't show in `AXValue` (or the caret isn't after them) in time.
        case notSettled
        /// The final `AXValue` is not what was planned.
        case verifyFailed
    }

    enum Result: Sendable, Equatable {
        /// Every piece written and verified.
        case converted(pieces: Int)
        case nothingToConvert
        /// `BoxConversion` found a word bigger than the window (beeps).
        case tooLong
        /// The B3 claim was refused. Nothing written.
        case abandoned
        /// Nothing written; the selection / caret put back. The caller may use the clipboard path.
        case unavailable(Stop)
        /// `written` pieces were written and verified, then the flow stopped (caret put back). The caller beeps.
        case partial(written: Int, Stop)
        /// The field's state is unknown (typed keys didn't show, a post failed part way). The caller beeps.
        case failed(written: Int, Stop)
    }

    private let focusProvider: any FocusedElementProviding
    private let poster: any KeyEventPosting
    private let clock: any Clock
    private let sleep: @Sendable (UInt64) async -> Void
    let timing: Timing
    /// An AX call of this convert timed out: no more calls to the app (P2-49 item 5).
    private var timedOut = false

    init(focusProvider: any FocusedElementProviding, poster: any KeyEventPosting, clock: any Clock,
         timing: Timing = Timing(), sleep: @escaping @Sendable (UInt64) async -> Void) {
        self.focusProvider = focusProvider
        self.poster = poster
        self.clock = clock
        self.timing = timing
        self.sleep = sleep
    }

    /// Steps 1–4. `expected`: the element the convert started on. `plan`: the caller's conversion. `mayWrite`: the B3
    /// claim, asked once before the first write (the first selection set).
    func run(_ source: Source, expected: any FocusedElementIdentity, plan: (Read) -> Planned,
             mayWrite: () -> Bool) async -> Result {
        timedOut = false
        let start = clock.nowNanos
        guard let el = focusedElement(), el.isSameElement(as: expected) else { return .unavailable(.focusChanged) }
        let read: Read
        switch readBox(el, source) {
        case .failure(let stop): return .unavailable(stop)
        case .success(let r): read = r
        }
        let changes: [TextChange]
        switch plan(read) {
        case .nothing: return .nothingToConvert
        case .tooLong: return .tooLong
        case .unavailable: return .unavailable(.inconsistent)
        case .changes(let c): changes = c
        }
        // The caret (or the selection's end) never falls inside a piece, so its new place is known exactly.
        let anchor = source == .box ? read.selection.location : read.selection.end
        var pieces = Self.pieces(changes, in: read.text, splittingAt: anchor)
        if pieces.count > Self.maxPieces { pieces = Self.joinedAcrossSpaces(pieces, in: read.text, splittingAt: anchor) }
        guard !pieces.isEmpty else { return .nothingToConvert }
        guard pieces.count <= Self.maxPieces else { return .unavailable(.tooManyPieces) }
        guard Self.isValid(pieces, in: read.text, source: source, selection: read.selection) else {
            return .unavailable(.inconsistent)
        }
        guard mayWrite() else { return .abandoned }

        var current = Array(read.text.utf16)
        var written: [Piece] = []
        /// Put the caret back (moved by the written pieces before it) and say how the flow ended.
        func stop(_ why: Stop) -> Result {
            if written.isEmpty {
                if !timedOut { _ = el.setRange(read.selection, for: .selectedTextRange) }
                return .unavailable(why)
            }
            if !timedOut { placeCaret(el, at: Self.caret(after: written, anchor: anchor)) }
            return .partial(written: written.count, why)
        }

        for piece in pieces.reversed() {   // bounded: ≤ maxPieces
            if clock.nowNanos &- start > timing.budgetNanos { return stop(.timedOut) }
            guard let now = focusedElement(), now.isSameElement(as: el) else { return stop(.focusChanged) }
            // P3-42 QA: the read-back of the piece alone can't tell a drifted selection that lands on *another
            // occurrence* of the same text (Slack's emoji shift over "a a a", or the same word twice at the drift's
            // distance): the range reads back as set and the text agrees, so the wrong word would be typed over. So
            // when the piece's text is not unique in the box, first select a window around it whose text *is* unique
            // and require that read back: an agreeing unique text can only sit at its own place, so the offsets map
            // exactly there. No unique window (the box repeats itself) → nothing more is typed.
            guard let window = Self.anchorWindow(for: piece.range, in: current) else { return stop(.selectionMismatch) }
            if window != piece.range {
                let windowText = String(decoding: current[window.location..<window.end], as: UTF16.self)
                guard case .success = track(el.setRange(window, for: .selectedTextRange)),
                      await selects(el, window, windowText) else { return stop(.selectionMismatch) }
                if clock.nowNanos &- start > timing.budgetNanos { return stop(.timedOut) }
            }
            // Select the piece and check that the app selected exactly the expected text (offset drift, Slack emoji).
            guard case .success = track(el.setRange(piece.range, for: .selectedTextRange)),
                  await selects(el, piece.range, piece.original) else { return stop(.selectionMismatch) }
            // P3-42 QA: the waits above can use up the budget; keys are posted only inside it, so they are in the event
            // stream before the hold-back flush (deadline + hard cap) can replay the user's held keys onto a selection.
            if clock.nowNanos &- start > timing.budgetNanos { return stop(.timedOut) }
            guard let events = KeyStrokeComposer.typing(piece.replacement), events.allSatisfy(\.isSafeToPost) else {
                return stop(.inconsistent)   // can't happen: `isValid` checked it
            }
            for (i, e) in events.enumerated() where !poster.post(e) {
                if i == 0 { return stop(.postFailed) }
                return .failed(written: written.count, .postFailed)
            }
            current.replaceSubrange(piece.location..<piece.end, with: Array(piece.replacement.utf16))
            let caretAfterPiece = piece.location + piece.replacement.utf16.count
            guard await settled(el, expected: current, caret: caretAfterPiece) else {
                // The keys may still land later: move nothing (a caret set now could put them elsewhere).
                return .failed(written: written.count, .notSettled)
            }
            written.append(piece)
        }

        // Step 4: the caret to its logical place, then the whole box once more.
        placeCaret(el, at: Self.caret(after: written, anchor: anchor))
        guard !timedOut, case .success(let final) = track(el.string(.value)),
              ReplacementExecutor.readsBackAs(final, String(decoding: current, as: UTF16.self)) else {
            return .failed(written: written.count, .verifyFailed)
        }
        return .converted(pieces: written.count)
    }

    // MARK: - Step 1

    private func readBox(_ el: any AXTextElement, _ source: Source) -> Swift.Result<Read, Stop> {
        guard case .success(let names) = track(el.attributeNames()),
              names.contains(where: Self.webContentAttributes.contains) else {
            return .failure(timedOut ? .readFailed : .notWebContent)
        }
        guard case .success(let value) = track(el.string(.value)) else { return .failure(.readFailed) }
        let units = Array(value.utf16)
        let n = units.count
        guard n > 0, n <= ReplacementPlanner.maxFieldReadChars else { return .failure(.boxSize) }
        guard case .success(n) = track(el.integer(.numberOfCharacters)) else {
            return .failure(timedOut ? .readFailed : .inconsistent)
        }
        guard case .success(let sel) = track(el.range(.selectedTextRange)) else { return .failure(.readFailed) }
        guard sel.location >= 0, sel.length >= 0, sel.end <= n,
              source == .box ? sel.isCaret : !sel.isCaret else { return .failure(.inconsistent) }
        guard case .success(let selected) = track(el.string(.selectedText)) else { return .failure(.readFailed) }
        let slice = Array(units[sel.location..<sel.end])
        let sliceText = String(decoding: slice, as: UTF16.self)
        // Scalar boundaries: a range splitting a surrogate pair decodes to U+FFFD.
        guard Array(sliceText.utf16) == slice else { return .failure(.inconsistent) }
        if source == .box {
            guard selected.isEmpty else { return .failure(.inconsistent) }
        } else if !selected.unicodeScalars.elementsEqual(sliceText.unicodeScalars) {
            // P3-40: Chromium's AXSelectedText can drop the line breaks between paragraphs. Then the visible characters
            // must agree and the value's text (which keeps its LF) is used; every piece is checked again below.
            guard sliceText.contains(where: \.isNewline), ConvertController.sameVisibleText(selected, sliceText) else {
                return .failure(.inconsistent)
            }
        }
        // The text up to the caret (or the selection's end), where the app answers it (Slack fails it for the whole box,
        // -25212, but answers before the caret). An answer that disagrees means the offsets can't be trusted.
        if sel.end > 0 {
            switch track(el.string(in: TextRange(location: 0, length: sel.end))) {
            case .success(let prefix):
                let expected = String(decoding: units[..<sel.end], as: UTF16.self)
                if !prefix.isEmpty, !ReplacementExecutor.readsBackAs(prefix, expected) { return .failure(.inconsistent) }
            case .failure:
                if timedOut { return .failure(.readFailed) }
            }
        }
        return .success(Read(text: value, selection: sel))
    }

    // MARK: - Step 3 helpers

    /// After the range write: polls (bounded) until the app reports `range` selected (Chromium applies a selection in
    /// the renderer and updates the AX tree asynchronously, research §5 step 3), then requires `AXSelectedText` to be
    /// exactly `original` (P3-42 QA: or, for a window holding a line break, the same visible text: P3-40, Chromium can
    /// drop line breaks from it). The right range with other text = offset drift: false at once. The first check is
    /// immediate.
    private func selects(_ el: any AXTextElement, _ range: TextRange, _ original: String) async -> Bool {
        let polls = max(1, Int(timing.selectSettleNanos / max(timing.pollNanos, 1)))
        for i in 0...polls {
            if case .success(range) = track(el.range(.selectedTextRange)) {
                guard case .success(let selected) = track(el.string(.selectedText)) else { return false }
                if selected.unicodeScalars.elementsEqual(original.unicodeScalars) { return true }
                return original.contains(where: \.isNewline) && ConvertController.sameVisibleText(selected, original)
            }
            if timedOut { return false }
            if i < polls { await sleep(timing.pollNanos) }
        }
        return false
    }

    /// Polls (bounded) until `AXValue` reads as `expected` and the caret is at `caret`. The first check is immediate.
    private func settled(_ el: any AXTextElement, expected: [UInt16], caret: Int) async -> Bool {
        let want = String(decoding: expected, as: UTF16.self)
        let polls = max(1, Int(timing.settleNanos / max(timing.pollNanos, 1)))
        for i in 0...polls {
            if case .success(let v) = track(el.string(.value)), ReplacementExecutor.readsBackAs(v, want),
               case .success(let r) = track(el.range(.selectedTextRange)), r == TextRange(location: caret, length: 0) {
                return true
            }
            if timedOut { return false }
            if i < polls { await sleep(timing.pollNanos) }
        }
        return false
    }

    /// Best effort: the text is verified separately, so a caret the app won't move doesn't fail the convert.
    private func placeCaret(_ el: any AXTextElement, at location: Int) {
        guard !timedOut else { return }
        _ = track(el.setRange(TextRange(location: location, length: 0), for: .selectedTextRange))
    }

    private func focusedElement() -> (any AXTextElement)? {
        guard !timedOut else { return nil }
        switch focusProvider.focusedTextElement(timeout: ReplacementExecutor.axTimeout) {
        case .success(let el): return el
        case .failure(let e):
            if e == .timeout { timedOut = true }
            return nil
        }
    }

    /// Notes a timeout (P2-49 item 5: after one, nothing more is asked of the app).
    private func track<T>(_ r: Swift.Result<T, AXAccessError>) -> Swift.Result<T, AXAccessError> {
        if case .failure(.timeout) = r { timedOut = true }
        return r
    }

    // MARK: - Pure

    /// Neighbouring changes joined into pieces, never across `anchor` (the caret or the selection's end).
    nonisolated static func pieces(_ changes: [TextChange], in text: String, splittingAt anchor: Int) -> [Piece] {
        let units = Array(text.utf16)
        var out: [Piece] = []
        var start: Int?
        var end = 0
        var replacement = ""
        func flush() {
            if let s = start {
                out.append(Piece(location: s, original: String(decoding: units[s..<end], as: UTF16.self),
                                 replacement: replacement))
            }
            start = nil
            replacement = ""
        }
        for c in changes {
            // Sorted and not overlapping, or nothing (the caller then falls back).
            guard c.offset >= end, c.length > 0, c.end <= units.count, !c.text.isEmpty else { return [] }
            if start != nil, c.offset != end || c.offset == anchor { flush() }
            if start == nil { start = c.offset }
            end = c.end
            replacement += c.text
        }
        flush()
        return out
    }

    /// Pieces separated only by spaces (U+0020 / U+00A0) joined, the spaces typed again as they were. Never across a
    /// line break (not a space) or `anchor`.
    nonisolated static func joinedAcrossSpaces(_ pieces: [Piece], in text: String, splittingAt anchor: Int) -> [Piece] {
        let units = Array(text.utf16)
        var out: [Piece] = []
        for p in pieces {
            if let last = out.last, last.end <= p.location {
                let gap = units[last.end..<p.location]
                // The anchor may sit at either end of the joined piece, never inside it.
                let crossesAnchor = anchor > last.location && anchor < p.end
                if !crossesAnchor, gap.allSatisfy({ $0 == 0x20 || $0 == 0xA0 }) {
                    let gapText = String(decoding: gap, as: UTF16.self)
                    out[out.count - 1] = Piece(
                        location: last.location,
                        original: String(decoding: units[last.location..<p.end], as: UTF16.self),
                        replacement: last.replacement + gapText + p.replacement)
                    continue
                }
            }
            out.append(p)
        }
        return out
    }

    /// Every piece is inside the text (inside the selection for `.selection`), sorted, not overlapping, its original is
    /// the text there, and neither side holds a line break or another control character (they would be typed).
    nonisolated static func isValid(_ pieces: [Piece], in text: String, source: Source, selection: TextRange) -> Bool {
        let units = Array(text.utf16)
        var previousEnd = 0
        for p in pieces {
            guard p.location >= previousEnd, !p.original.isEmpty, !p.replacement.isEmpty, p.end <= units.count,
                  Array(units[p.location..<p.end]) == Array(p.original.utf16),
                  !ReplacementPlanner.containsUnsafeCharacter(p.original),
                  KeyStrokeComposer.typing(p.replacement) != nil else { return false }
            if source == .selection, p.location < selection.location || p.end > selection.end { return false }
            previousEnd = p.end
        }
        return true
    }

    /// P3-42 QA: the smallest window (on grapheme boundaries) around `range` whose text occurs exactly once in `units`:
    /// `range` itself when its text is already unique, growing on both sides (2, 4, … 256 units, then the whole box,
    /// which is always unique). nil only for an empty box or a bad range. Searches are bounded: ≤ 9 windows, each
    /// stopping at the second match.
    nonisolated static func anchorWindow(for range: TextRange, in units: [UInt16]) -> TextRange? {
        let n = units.count
        guard range.location >= 0, range.length > 0, range.end <= n else { return nil }
        if occursOnce(units[range.location..<range.end], in: units) { return range }
        let ns = String(decoding: units, as: UTF16.self) as NSString
        var grow = 2
        while grow <= 256 {
            var lo = max(0, range.location - grow), hi = min(n, range.end + grow)
            if lo > 0 { lo = ns.rangeOfComposedCharacterSequence(at: lo).location }
            if hi < n {
                let r = ns.rangeOfComposedCharacterSequence(at: hi)
                if r.location < hi { hi = r.location + r.length }
            }
            if lo == 0, hi == n { break }
            if occursOnce(units[lo..<hi], in: units) { return TextRange(location: lo, length: hi - lo) }
            grow *= 2
        }
        return TextRange(location: 0, length: n)
    }

    /// Whether `needle` occurs exactly once in `hay` (naive search, stops at the second match).
    nonisolated static func occursOnce(_ needle: ArraySlice<UInt16>, in hay: [UInt16]) -> Bool {
        let m = needle.count
        guard m > 0, m <= hay.count else { return false }
        let first = needle.first!
        var found = 0
        var i = 0
        while i + m <= hay.count {
            if hay[i] == first, hay[i..<(i + m)].elementsEqual(needle) {
                found += 1
                if found > 1 { return false }
            }
            i += 1
        }
        return found == 1
    }

    /// The caret after `written`: `anchor` moved by the length change of every written piece that ends at or before it.
    nonisolated static func caret(after written: [Piece], anchor: Int) -> Int {
        anchor + written.filter { $0.end <= anchor }.reduce(0) { $0 + $1.delta }
    }
}
