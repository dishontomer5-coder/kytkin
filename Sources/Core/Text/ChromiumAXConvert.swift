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
// P3-44 (owner test 2026-11-16, Slack: bold Hebrew + an @mention pill + 😂, then a line typed on EN; the box was pasted
// as plain text by the clipboard path, so this path had stopped before typing). In the P3-42 fakes that is exactly the
// Slack emoji drift: `AXValue` (and the caret read) leave the emoji out while an `AXSelectedTextRange` write counts it,
// so every piece after the emoji selected text one emoji early, the read-back disagreed (`.selectionMismatch`) and
// nothing was typed. Which of two shapes Slack really has is not proven on the owner's Mac (the probe had no emoji), so
// both are handled and the DEBUG log (`ConvertTrace`, `Diagnostic`) says which one was seen:
//   (A) reads in `AXValue` units, writes in page units (the fake's `setRangeDrifts`);
//   (B) reads and writes in page units: the caret then reads *past* the end of `AXValue` (by the hidden units).
// Fix, without trusting any offset: each piece's unique window is tried at a shift of `d` hidden units (the last piece's
// shift first, then smaller ones, then larger ones up to `maxHiddenUnits`; pieces are written last to first, so an
// earlier piece never has more hidden units before it). A shift is taken only when the app shows the selection and
// `AXSelectedText` reads back exactly the unique window's text: a selection holding a hidden unit reads back shorter, and
// a unique text can only sit at its own place, so a wrong shift is never typed over. (B) also lets the box read go on
// with the caret past the end (taken as the end of `AXValue`). The caret goes back in the units the app takes: (B) the
// raw caret read moved by the length changes; (A) the logical caret plus the shift of the last written piece before it.
// Known limit (A): a hidden emoji *right* before the caret can't be seen, so the caret may land just before it.
// P3-44 also passes the texts of mention pills / links the AX tree shows as their own elements (`inlineAtomTexts`) to the
// plan, so `BoxConversion` keeps them whole, and records a `Diagnostic` (enums and counts, never text) for the DEBUG log.
//
// P3-46 (owner retest 2026-11-16, DEBUG trace `readCheck=prefix`: in a Slack box with a mention pill, `AXStringForRange`
// up to the caret disagreed with `AXValue`'s prefix, so the convert stopped before typing and the clipboard flattened the
// box). The pill is a separate inline element, and Chromium's range offsets (and the text it returns for them) need not
// count it the way `AXValue` does (an embedded-object character, the pill's name, or nothing). So a disagreeing prefix
// no longer stops the convert by itself: `valueOffset(matching:in:atoms:)` maps the returned text onto `AXValue`
// (equal characters; U+FFFC or an atom's text standing for a pill; an emoji `AXValue` leaves out; NBSP = space) and,
// when every character is accounted for, the caret is taken at that value offset, with the app's own caret kept as the
// raw one (so the shift at the caret may be *negative*: a pill counted as one unit). The piece search then tries
// shifts on both sides (nearest to the last one first, ≤ `maxShiftTries` per piece); every piece is still typed only
// after an exact read-back of its unique window, so a wrong caret or shift can't be typed over. No mapping → stop as
// before. The DEBUG trace gets counts only: the prefix mismatch (lengths, common prefix / suffix), whether the caret
// was mapped, and the atoms' AX role names.
//
// P3-51 (owner Slack traces: `vh 😄 vh vh` → `prefixMismatch=ax9/value9/common3` and `ax10/value10/common3`, a second
// line → `ax35/value35/common28`, a selection → `readCheck=selectionText`): equal lengths that part right at the emoji fit
// one shape only: `AXValue` holds the emoji as one U+FFFC, the caret and the selected range count it as one unit (so
// both agree with `AXValue`), while `AXStringForRange` takes its range in the page's own units and returns the emoji's
// two UTF-16 units, so its text for (0, caret) ends one unit *before* the caret. (With the emoji simply missing from
// `AXValue`, the P3-46 walk already mapped it; with U+FFFC in both, nothing would disagree.) So the walk now pairs
// U+FFFC with an emoji grapheme and skips an object on either side; the caret is the later of the walk's end and the
// app's caret (wider prefix text → the caret stays; a pill counted as one unit → the walk's end); a selection keeps its
// range when the prefix is the wider one; `AXSelectedText` and window read-backs may show the emoji where `AXValue` has
// U+FFFC (selection: the rest must agree; window: grapheme by grapheme, in place). Pieces never hold an object, and each
// is still typed only after an exact read-back. The trace adds `prefixObjects=` (U+FFFC / emoji counts per side).
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
    /// P3-44: the most units the page may count that `AXValue` leaves out (Slack emoji) before a piece or the caret.
    /// Bounds the shift search (≤ maxHiddenUnits + 1 tries per piece, each also inside the budget).
    nonisolated static let maxHiddenUnits = 16
    /// P3-46: the most units a shift may go below zero (pills counted as one unit by the app's offsets: one pill name,
    /// or a few), and the most shifts tried for one piece (each try waits for the app; the budget bounds them too).
    nonisolated static let maxNegativeShift = 64
    nonisolated static let maxShiftTries = 12
    /// P3-44: the most inline elements looked at for mention pills (`inlineAtomTexts`).
    nonisolated static let maxAtomNodes = 64

    struct Timing: Sendable, Equatable {
        /// Poll interval while waiting for the app to take a piece's keys.
        var pollNanos: UInt64 = 5_000_000
        /// The longest wait for one piece (the KeyStreamProcessor's 1 s hard cap bounds the whole convert anyway).
        var settleNanos: UInt64 = 150_000_000
        /// The longest wait for a range write to show as the selection (research §5 step 3: ≤ 100 ms).
        var selectSettleNanos: UInt64 = 100_000_000
        /// 001 §7 B5: no new piece starts later than this after the flow started.
        var budgetNanos: UInt64 = ReplacementChain.defaultBudgetNanos
        /// P3-53: step 1 (the box read and the atom walks) must end within this much of the double-Shift, so the
        /// first piece still has time inside `budgetNanos` (and the hold-back deadline, B5). Out of time → stop
        /// before anything is written (`.unavailable(.timedOut)`).
        var readBudgetNanos: UInt64 = 200_000_000

        init() {}
    }

    enum Source: Sendable, Equatable {
        /// Nothing selected: the whole box (P3-35).
        case box
        /// The user's selection (P3-40 (b): its line breaks stay, they are never part of a piece).
        case selection
    }

    /// What step 1 read. `text` is `AXValue`; `selection` is the AX selected range (a caret for `.box`), in `AXValue`
    /// units (P3-44: a caret read past the end is taken as the end).
    struct Read: Sendable, Equatable {
        let text: String
        let selection: TextRange
        /// P3-44: texts of inline elements that are mention pills or links (kept whole by the plan). Never logged.
        var atoms: [String] = []
        /// P3-44: the selected range exactly as the app reported it (put back when nothing was typed).
        var rawSelection: TextRange?
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
        /// Setting the selection failed, or the read-back is not the expected piece at any shift (Slack's emoji shift).
        case selectionMismatch
        /// P3-44: the app never showed the range set (within `selectSettleNanos`): nothing judged, nothing typed.
        case selectionNotShown
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

    /// P3-44: what the last `run` saw, for the DEBUG log (`ConvertTrace`). Enums and counts only, never text.
    struct Diagnostic: Sendable, Equatable {
        /// The step-1 check that failed, if one did.
        enum ReadCheck: String, Sendable, Equatable {
            case notWebContent, valueRead, boxSize, numberOfCharacters, rangeRead, rangeBounds, selectedTextRead,
                 scalarBoundary, caretSelectedText, selectionText, prefix, atomRead
        }
        /// Which unit space the app's reads turned out to use (header: A = value, B = page), once a shift showed it.
        enum ReadSpace: String, Sendable, Equatable { case unknown, value, page }
        var readCheck: ReadCheck?
        /// UTF-16 units the caret read past the end of `AXValue` (shape B), else 0.
        var caretPastValue = 0
        var pieces = 0
        var atoms = 0
        /// The largest shift a written piece was found at.
        var maxShift = 0
        /// Selection tries that showed another text (a wrong shift).
        var otherTextTries = 0
        var readSpace: ReadSpace = .unknown
        /// P3-46: the caret was mapped onto `AXValue` through a disagreeing `AXStringForRange` prefix.
        var caretMapped = false
        /// P3-46: counts describing a disagreeing prefix (nil = it agreed or wasn't read).
        var prefixMismatch: PrefixMismatch?
        /// P3-46: the AX role of each inline atom found (role names only, e.g. `AXStaticText`, `AXLink`).
        var atomRoles: [String] = []
        /// P3-51: U+FFFC / emoji counts in the disagreeing prefix, AX side and value side (counts only).
        var prefixObjects: String?
        /// P3-55: the prefix disagreed with no U+FFFC or emoji on either side (a shape not understood yet, e.g. a
        /// `:shortcode:`-entered Slack emoji): the caller must not fall back to keys in a chat app.
        var prefixUnexplained = false
        /// P3-57: the first ≤ 8 scalars of the prefix mismatch on each side: `L` letter, `N` digit, `Z` space, else
        /// `U+XXXX/<category>` (never a letter).
        var spanShape: String?
        /// P3-57: odd units in `AXValue` (Cf / Co / Cn / non-emoji So / variation selectors): count and the first 4
        /// distinct code points.
        var oddUnits: String?
        /// P3-57: odd-unit runs dropped from the reads (one per `AXImage`).
        var oddRunsStripped = 0
        /// P3-55: `AXValue`'s length (= `AXNumberOfCharacters`, checked), UTF-16 units (a count only).
        var valueUnits = 0
    }

    /// P3-46: how `AXStringForRange(0, caret)` differed from `AXValue`'s prefix (UTF-16 counts only).
    struct PrefixMismatch: Sendable, Equatable, CustomStringConvertible {
        let axUnits: Int
        let valueUnits: Int
        let commonPrefix: Int
        let commonSuffix: Int
        /// Units of each side outside the common prefix and suffix (the mismatch's span).
        var axSpan: Int { max(0, axUnits - commonPrefix - commonSuffix) }
        var valueSpan: Int { max(0, valueUnits - commonPrefix - commonSuffix) }
        var description: String {
            "ax\(axUnits)/value\(valueUnits)/common\(commonPrefix)+\(commonSuffix)/span\(axSpan)~\(valueSpan)"
        }
    }
    private(set) var lastDiagnostic = Diagnostic()
    /// P3-51 QA: `AXValue` holds an emoji as text (not only U+FFFC): window read-backs must then match exactly.
    private var valueHasLiteralObjects = false
    /// P3-57: this convert's `AXValue` holds one run of odd units (Cf / Co / Cn / non-emoji So / variation selectors) per
    /// `AXImage` in the box (Slack's image emoji), which the app's offsets don't count: every `AXValue` /
    /// `AXSelectedText` read drops them (`strippingOddUnits`), so value units = the app's units.
    private var stripOddUnits = false

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
    /// P3-53: `startedAt`: when the convert started (the controller's request start), so the time spent before this
    /// path (another path's reads, the page check) counts against the same budget. nil = now.
    func run(_ source: Source, expected: any FocusedElementIdentity, startedAt: UInt64? = nil,
             plan: (Read) -> Planned, mayWrite: () -> Bool) async -> Result {
        timedOut = false
        stripOddUnits = false   // P3-57
        lastDiagnostic = Diagnostic()
        let start = startedAt ?? clock.nowNanos
        // P3-53: already past the read budget (a slow earlier path): nothing is asked of the app.
        if clock.nowNanos &- start > timing.readBudgetNanos { return .unavailable(.timedOut) }
        guard let el = focusedElement(), el.isSameElement(as: expected) else { return .unavailable(.focusChanged) }
        let read: Read
        switch readBox(el, source, start: start) {
        case .failure(let stop): return .unavailable(stop)
        case .success(let r): read = r
        }
        // P3-53 QA: the prefix read after the atom walks can take one more AX timeout: the whole read must fit.
        if clock.nowNanos &- start > timing.readBudgetNanos {
            lastDiagnostic.readCheck = .atomRead
            return .unavailable(.timedOut)
        }
        lastDiagnostic.atoms = read.atoms.count
        valueHasLiteralObjects = read.text.contains { $0 != "\u{FFFC}" && Self.isObject($0) }
        let changes: [TextChange]
        switch plan(read) {
        case .nothing: return .nothingToConvert
        case .tooLong: return .tooLong
        case .unavailable: return .unavailable(.inconsistent)
        case .changes(let c): changes = c
        }
        // The caret (or the selection's end) never falls inside a piece, so its new place is known exactly.
        let anchor = source == .box ? read.selection.location : read.selection.end
        let raw = read.rawSelection ?? read.selection
        let rawAnchor = source == .box ? raw.location : raw.end
        var pieces = Self.pieces(changes, in: read.text, splittingAt: anchor)
        if pieces.count > Self.maxPieces { pieces = Self.joinedAcrossSpaces(pieces, in: read.text, splittingAt: anchor) }
        guard !pieces.isEmpty else { return .nothingToConvert }
        guard pieces.count <= Self.maxPieces else { return .unavailable(.tooManyPieces) }
        guard Self.isValid(pieces, in: read.text, source: source, selection: read.selection) else {
            return .unavailable(.inconsistent)
        }
        lastDiagnostic.pieces = pieces.count
        // P3-53 QA: never a claim after the budget (no write could follow it anyway).
        if clock.nowNanos &- start > timing.budgetNanos { return .unavailable(.timedOut) }
        guard mayWrite() else { return .abandoned }

        var current = Array(read.text.utf16)
        var written: [Piece] = []
        /// P3-44: the shift each written piece was found at (same order as `written`).
        var shifts: [Int] = []
        /// P3-44: the unit space the app reads in (header: A = value, B = page). A caret read past the end is B.
        var space: Diagnostic.ReadSpace = rawAnchor != anchor ? .page : .unknown
        /// Where the caret goes at the end (or after a stop), in the units the app takes for writes.
        func caretTarget() -> Int {
            let moved = Self.caret(after: written, anchor: anchor)
            if space == .value {
                // (A): page units = value units + the hidden units before; the last written piece before the caret
                // gives the best lower bound.
                let before = zip(written, shifts).filter { $0.0.end <= anchor }.map(\.1).max() ?? 0
                return moved + before
            }
            return moved + (rawAnchor - anchor)
        }
        /// Put the caret back (moved by the written pieces before it) and say how the flow ended.
        func stop(_ why: Stop) -> Result {
            lastDiagnostic.readSpace = space
            if written.isEmpty {
                if !timedOut { _ = el.setRange(raw, for: .selectedTextRange) }
                return .unavailable(why)
            }
            if !timedOut { placeCaret(el, at: caretTarget()) }
            return .partial(written: written.count, why)
        }

        // P3-44: the shift to try first (shape B: the caret's own excess). P3-46: it may be negative (a pill counted as
        // one unit, the caret mapped through the prefix), so shifts are tried on both sides of it.
        var hint = max(-Self.maxNegativeShift, min(rawAnchor - anchor, Self.maxHiddenUnits))
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
            let windowText = String(decoding: current[window.location..<window.end], as: UTF16.self)
            // P3-44: where the window and the piece sit in the page's units (bounded tries; see `locate`).
            let d: Int
            switch await locate(el, piece: piece, window: window, windowText: windowText, hint: hint,
                                allowNegative: rawAnchor < anchor, start: start) {
            case .found(let shift): d = shift
            case .stop(let why): return stop(why)
            }
            // P3-42 QA: the waits above can use up the budget; keys are posted only inside it, so they are in the event
            // stream before the hold-back flush (deadline + hard cap) can replay the user's held keys onto a selection.
            if clock.nowNanos &- start > timing.budgetNanos { return stop(.timedOut) }
            guard let events = KeyStrokeComposer.typing(piece.replacement), events.allSatisfy(\.isSafeToPost) else {
                return stop(.inconsistent)   // can't happen: `isValid` checked it
            }
            for (i, e) in events.enumerated() where !poster.post(e) {
                if i == 0 { return stop(.postFailed) }
                lastDiagnostic.readSpace = space
                return .failed(written: written.count, .postFailed)
            }
            current.replaceSubrange(piece.location..<piece.end, with: Array(piece.replacement.utf16))
            let caretAfterPiece = piece.location + piece.replacement.utf16.count
            guard let seen = await settled(el, expected: current, caret: caretAfterPiece, shift: d) else {
                // The keys may still land later: move nothing (a caret set now could put them elsewhere).
                lastDiagnostic.readSpace = space
                return .failed(written: written.count, .notSettled)
            }
            if d != 0, space == .unknown { space = seen }
            written.append(piece)
            shifts.append(d)
            if abs(d) > abs(lastDiagnostic.maxShift) { lastDiagnostic.maxShift = d }
            hint = d
        }

        // Step 4: the caret to its logical place, then the whole box once more.
        lastDiagnostic.readSpace = space
        placeCaret(el, at: caretTarget())
        guard !timedOut, case .success(let final) = track(el.string(.value)).map(stripIfNeeded),
              ReplacementExecutor.readsBackAs(final, String(decoding: current, as: UTF16.self)) else {
            return .failed(written: written.count, .verifyFailed)
        }
        return .converted(pieces: written.count)
    }

    /// P3-44: how `locate` ended.
    private enum Located {
        case found(Int)
        case stop(Stop)
    }

    /// P3-44: finds the page offset of `piece`, without trusting any offset. For each start shift `d` (`shiftCandidates`)
    /// the unique `window` is selected at `window.location + d`:
    ///   - its text reads back exactly → no hidden unit in it, the piece sits at the same shift (selected and read back
    ///     on its own when it is not the window);
    ///   - it reads back as a shorter *prefix* of the window's text → `k` hidden units inside it: the selection is
    ///     widened by `k` (still `d + k ≤ bound`) and must then read back exactly the window's text; the piece, whose
    ///     text must occur only once in the window, is then found inside that range (shift `d … d + k`) by an exact
    ///     read-back;
    ///   - anything else → the next `d`.
    /// An exact unique text can only sit at its own place, and a piece-length selection whose text is the piece's has
    /// no hidden unit in it, so a wrong place is never typed over. Every try is inside the budget.
    /// P3-46 QA: `allowNegative` only when the caret was mapped through the prefix (the app's caret reads below the
    /// value's): a negative shift is then proven to exist; otherwise an unchecked caret could reach a wrong word.
    private func locate(_ el: any AXTextElement, piece: Piece, window: TextRange, windowText: String, hint: Int,
                        allowNegative: Bool, start: UInt64) async -> Located {
        let windowUnits = Array(windowText.utf16)
        let bound = Self.maxHiddenUnits
        // P3-46: both sides of the hint, nearest first; never a range before the box's start.
        let lower = allowNegative ? max(-Self.maxNegativeShift, -window.location) : 0
        let candidates = Self.shiftCandidates(hint: hint, lower: lower,
                                              upper: bound).prefix(Self.maxShiftTries)
        for d in candidates {   // bounded: ≤ maxShiftTries
            if clock.nowNanos &- start > timing.budgetNanos { return .stop(.timedOut) }
            var k = 0
            var outcome = await select(el, window, shift: d, windowText, exactLength: window == piece.range)
            // Hidden units inside the window: widen it (bounded: k only grows, d + k ≤ bound).
            while case .otherText(let got) = outcome, d + k < bound {
                // `got` is the visible text of a selection `window.length + k` long: a proper prefix of the window's
                // text = the start is right and hidden units ate the rest; widen by the visible units still missing.
                // P3-54 (owner: Slack `vh 😄 vh vh` and "word 😄 word" failed, "word word 😄" worked): when `AXValue`
                // holds the emoji as U+FFFC but the app *writes* ranges in page units (the emoji's two), the window
                // around a repeated word holds that U+FFFC and its read-back shows the emoji itself, so the plain UTF-16
                // prefix test never matched and no window could be placed after an emoji. Compared with every emoji
                // grapheme read back as one U+FFFC (only when the window holds a U+FFFC), the prefix test sees the
                // missing units again; the widened window must still read back in place (`select`).
                let normalized = windowUnits.contains(0xFFFC) ? Self.objectsAsFFFC(got) : got
                let g = Array(normalized.utf16)
                guard !g.isEmpty, g.count < windowUnits.count, windowUnits.starts(with: g) else { break }
                let more = k + windowUnits.count - g.count
                guard d + more <= bound else { break }
                k = more
                if clock.nowNanos &- start > timing.budgetNanos { return .stop(.timedOut) }
                outcome = await select(el, TextRange(location: window.location, length: window.length + k), shift: d,
                                       windowText)
            }
            switch outcome {
            case .notShown: return .stop(timedOut ? .readFailed : .selectionNotShown)
            case .otherText:
                lastDiagnostic.otherTextTries += 1
                if timedOut { return .stop(.readFailed) }
                continue
            case .matched: break
            }
            if window == piece.range, k == 0 { return .found(d) }
            // The piece inside the window: at shift d (k == 0), or somewhere in d … d + k when hidden units are inside
            // (then its text must occur once in the window, so the exact read-back can only be that occurrence).
            let inner = k == 0 ? [d] : Array(d...(d + k))
            if k > 0 {
                let p = Array(piece.original.utf16)
                var hits = 0
                var i = 0
                while i + p.count <= windowUnits.count {   // bounded by the window's length
                    if windowUnits[i..<(i + p.count)].elementsEqual(p) { hits += 1 }
                    i += 1
                }
                // The piece's text more than once in the window: its place can't be told; try the next shift.
                guard hits == 1 else { continue }
            }
            for shift in inner {
                if clock.nowNanos &- start > timing.budgetNanos { return .stop(.timedOut) }
                switch await select(el, piece.range, shift: shift, piece.original, exactLength: true) {
                case .matched: return .found(shift)
                case .notShown: return .stop(timedOut ? .readFailed : .selectionNotShown)
                case .otherText:
                    lastDiagnostic.otherTextTries += 1
                    if timedOut { return .stop(.readFailed) }
                }
            }
            // Not found inside this window placement: the next shift.
        }
        return .stop(.selectionMismatch)
    }

    /// P3-44 / P3-46: the shifts to try for one piece: `hint` (clamped to `lower…upper`) first, then the others nearest
    /// to it first, the smaller one before the larger one at the same distance.
    nonisolated static func shiftCandidates(hint: Int, lower: Int = 0, upper: Int) -> [Int] {
        let lo = min(lower, upper), hi = upper
        let h = max(lo, min(hint, hi))
        var out = [h]
        var step = 1
        while h - step >= lo || h + step <= hi {   // bounded: ≤ hi − lo steps
            if h - step >= lo { out.append(h - step) }
            if h + step <= hi { out.append(h + step) }
            step += 1
        }
        return out
    }

    /// P3-46: where `prefix` (what the app returned for the range up to its caret) ends in `value`, in UTF-16 units of
    /// `value`, when every character of it is accounted for: equal characters (NBSP = space, any line break = any line
    /// break); U+FFFC or nothing standing for an atom's text in `value` (a pill); U+FFFC or an emoji (with its
    /// modifiers) that `value` leaves out. nil = something else differs (the offsets can't be trusted). Linear, bounded
    /// by the two lengths and the atoms.
    nonisolated static func valueOffset(matching prefix: String, in value: [UInt16], atoms: [String]) -> Int? {
        prefixAlignment(prefix, in: value, atoms: atoms)?.end
    }

    /// P3-51 QA: the walk of `valueOffset`, with how much the prefix text was *wider* (UTF-16 units it holds that
    /// `value` doesn't: an emoji's own units where `value` has one U+FFFC or nothing) and *narrower* (units of `value`
    /// it doesn't hold: a pill as one U+FFFC or nothing, a U+FFFC the prefix leaves out) than `value` along the way.
    nonisolated static func prefixAlignment(_ prefix: String, in value: [UInt16], atoms: [String])
        -> (end: Int, wider: Int, narrower: Int)? {
        // P3-51 (owner Slack traces `prefixMismatch=ax9/value9/common3`, `ax10/value10`): an emoji can be *nothing* in
        // one text and U+FFFC or its own scalars in the other, on either side. So the walk is per grapheme: equal
        // graphemes; an object on both sides (U+FFFC ↔ an emoji, two emoji images); an object on one side only
        // (skipped there); U+FFFC or nothing standing for an atom's text in `value`.
        let p = Array(prefix)
        let v = Array(String(decoding: value, as: UTF16.self))
        let atomChars = atoms.filter { $0.count >= 2 }.map(Array.init)
        func same(_ a: Character, _ b: Character) -> Bool {
            if a == b { return true }
            if (a == " " || a == "\u{00A0}"), (b == " " || b == "\u{00A0}") { return true }
            return a.isNewline && b.isNewline
        }
        func atomLength(at j: Int) -> Int? {
            atomChars.first { a in j + a.count <= v.count && Array(v[j..<(j + a.count)]) == a }?.count
        }
        var i = 0, j = 0
        var wider = 0, narrower = 0
        /// Moves past `a` prefix graphemes and `b` value graphemes, counting the unit difference.
        func step(_ a: Int, _ b: Int) {
            let pu = p[i..<(i + a)].reduce(0) { $0 + $1.utf16.count }
            let vu = v[j..<(j + b)].reduce(0) { $0 + $1.utf16.count }
            if pu > vu { wider += pu - vu } else { narrower += vu - pu }
            i += a
            j += b
        }
        while i < p.count {   // bounded: i or j moves forward every pass
            if j < v.count, same(p[i], v[j]) { step(1, 1); continue }
            if j < v.count, isObject(p[i]), isObject(v[j]) { step(1, 1); continue }             // ￼ ↔ emoji
            if p[i] == "\u{FFFC}", let n = atomLength(at: j) { step(1, n); continue }           // a pill as one object
            if isObject(p[i]) { step(1, 0); continue }                                          // an emoji AXValue drops
            if j < v.count, isObject(v[j]) { step(0, 1); continue }                             // one the AX text drops
            if let n = atomLength(at: j) { step(0, n); continue }                               // a pill left out
            return nil
        }
        return (String(v[..<j]).utf16.count, wider, narrower)
    }

    /// P3-51 QA: the caret in `AXValue` units from a disagreeing prefix read (`prefixUnits` long, asked for
    /// (0, `appCaret`)). Only *wider* (an emoji's units where the value and the caret count one U+FFFC or none): the
    /// app's caret already is in value units, and the walk must end exactly `wider` units before it → `appCaret`.
    /// Only *narrower* (a pill counted as one unit, P3-46) → the walk's end. Both at once → nil: the two effects can
    /// cancel or mix (a pill and emoji before the caret), so the caret can't be told and nothing is typed.
    nonisolated static func caret(fromPrefix a: (end: Int, wider: Int, narrower: Int), appCaret: Int) -> Int? {
        if a.wider > 0, a.narrower > 0 { return nil }
        if a.wider > 0 { return a.end + a.wider == appCaret ? appCaret : nil }
        return a.end >= appCaret ? a.end : nil
    }

    /// P3-51: an embedded object or an emoji grapheme (U+FFFC, an emoji, or a sequence with VS16 / ZWJ / keycap).
    nonisolated static func isObject(_ c: Character) -> Bool {
        if c == "\u{FFFC}" { return true }
        let scalars = c.unicodeScalars
        if scalars.contains(where: { $0.value == 0xFE0F || $0.value == 0x200D || $0.value == 0x20E3 }) { return true }
        guard let first = scalars.first else { return false }
        return first.properties.isEmojiPresentation || (first.value >= 0x2100 && first.properties.isEmoji)
    }

    /// P3-51: the same visible text once objects (U+FFFC, emoji) are left out on both sides (they may be nothing, one
    /// U+FFFC or the emoji's own units, depending on the read), spaces and line breaks too. Never true for two texts
    /// with no visible character left.
    nonisolated static func sameIgnoringObjects(_ a: String, _ b: String) -> Bool {
        func strip(_ s: String) -> String { String(s.filter { !isObject($0) }) }
        return ConvertController.sameVisibleText(strip(a), strip(b))
    }

    /// P3-51: equal grapheme by grapheme, where U+FFFC on one side may stand for an object (an emoji) on the other.
    /// Positional, so a window that reads back this way still sits at its own place.
    nonisolated static func sameWithObjectsInPlace(_ selected: String, _ original: String) -> Bool {
        let a = Array(selected), b = Array(original)
        guard a.count == b.count, b.contains(where: isObject) || a.contains(where: isObject) else { return false }
        for (x, y) in zip(a, b) where x != y {
            guard (x == "\u{FFFC}" && isObject(y)) || (y == "\u{FFFC}" && isObject(x)) else { return false }
        }
        return true
    }

    /// P3-54: every object grapheme (an emoji) written as one U+FFFC, as `AXValue` shows it in Slack's shape C.
    nonisolated static func objectsAsFFFC(_ s: String) -> String {
        String(s.map { isObject($0) ? "\u{FFFC}" : $0 })
    }

    /// P3-57: a scalar of the odd runs Slack leaves for an image emoji: a format character (ZWSP, ZWJ, BOM…), private
    /// use, unassigned, a non-emoji other symbol, or a variation selector. Never U+FFFC (P3-51 handles it as an object
    /// the app counts) nor an emoji.
    nonisolated static func isOddUnit(_ u: Unicode.Scalar) -> Bool {
        if u.value == 0xFFFC { return false }
        // P3-57 QA: never the marks people type: bidi marks / embeddings / isolates (Hebrew users type RLM / LRM),
        // ZWJ / ZWNJ (inside words of some scripts), the Arabic letter mark. Stripping one the app counts would shift
        // every offset after it (the exact read-backs would still refuse to type, but the convert would be lost).
        if userTypedMarks.contains(u.value) { return false }
        if (0xFE00...0xFE0F).contains(u.value) || (0xE0100...0xE01EF).contains(u.value) { return true }
        switch u.properties.generalCategory {
        case .format, .privateUse, .unassigned, .surrogate: return true
        case .otherSymbol: return !(u.properties.isEmojiPresentation || (u.value >= 0x2100 && u.properties.isEmoji))
        default: return false
        }
    }

    /// P3-57 QA: format characters a user's own text holds (never treated as an image's odd units).
    nonisolated static let userTypedMarks: Set<UInt32> = [0x200C, 0x200D, 0x200E, 0x200F, 0x061C, 0x202A, 0x202B, 0x202C,
                                                          0x202D, 0x202E, 0x2066, 0x2067, 0x2068, 0x2069]

    /// P3-57: the runs of consecutive odd scalars in `text` (UTF-16 ranges).
    nonisolated static func oddRuns(in text: String) -> [Range<Int>] {
        var runs: [Range<Int>] = []
        var at = 0
        var start: Int?
        for u in text.unicodeScalars {
            let n = String(u).utf16.count
            if isOddUnit(u) {
                if start == nil { start = at }
            } else if let s = start {
                runs.append(s..<at)
                start = nil
            }
            at += n
        }
        if let s = start { runs.append(s..<at) }
        return runs
    }

    /// P3-57: `text` without its odd scalars.
    nonisolated static func strippingOddUnits(_ text: String) -> String {
        var out = String.UnicodeScalarView()
        out.append(contentsOf: text.unicodeScalars.filter { !isOddUnit($0) })
        return String(out)
    }

    private func stripIfNeeded(_ s: String) -> String { stripOddUnits ? Self.strippingOddUnits(s) : s }

    /// P3-57: one scalar for the trace: `L` / `N` / `Z`, else its code point and category. Never a letter's identity.
    nonisolated static func shapeCode(_ u: Unicode.Scalar) -> String {
        let p = u.properties
        if p.isAlphabetic { return "L" }
        if p.numericType != nil { return "N" }
        if p.isWhitespace { return "Z" }
        let cat: String
        switch p.generalCategory {
        case .format: cat = "Cf"
        case .privateUse: cat = "Co"
        case .unassigned: cat = "Cn"
        case .otherSymbol: cat = "So"
        case .control: cat = "Cc"
        case .nonspacingMark: cat = "Mn"
        case .surrogate: cat = "Cs"
        case .mathSymbol, .currencySymbol, .modifierSymbol: cat = "S"
        default: cat = "P"
        }
        return String(format: "U+%04X/", u.value) + cat
    }

    /// P3-57: the shape of the first ≤ 8 scalars after the common prefix, on each side.
    nonisolated static func spanShape(ax: String, value: String) -> String {
        let a = Array(ax.unicodeScalars), b = Array(value.unicodeScalars)
        var k = 0
        while k < a.count, k < b.count, a[k] == b[k] { k += 1 }
        func shape(_ x: [Unicode.Scalar]) -> String {
            x[k..<min(x.count, k + 8)].map(shapeCode).joined(separator: ",")
        }
        return "ax[\(shape(a))] value[\(shape(b))]"
    }

    /// P3-57: odd units in a text: their count and the first 4 distinct code points.
    nonisolated static func oddUnitsSummary(_ text: String) -> String? {
        let odd = text.unicodeScalars.filter(isOddUnit)
        guard !odd.isEmpty else { return nil }
        var seen: [UInt32] = []
        for u in odd where !seen.contains(u.value) && seen.count < 4 { seen.append(u.value) }
        return "\(odd.count):" + seen.map { String(format: "U+%04X", $0) }.joined(separator: ",")
    }

    /// P3-51: U+FFFC and other object graphemes in a text (counts only, for the DEBUG trace).
    nonisolated static func objectCounts(_ s: String) -> (fffc: Int, emoji: Int) {
        var f = 0, e = 0
        for c in s where isObject(c) { if c == "\u{FFFC}" { f += 1 } else { e += 1 } }
        return (f, e)
    }

    // MARK: - Step 1

    private func readBox(_ el: any AXTextElement, _ source: Source, start: UInt64) -> Swift.Result<Read, Stop> {
        func fail(_ check: Diagnostic.ReadCheck, _ stop: Stop) -> Swift.Result<Read, Stop> {
            lastDiagnostic.readCheck = check
            return .failure(stop)
        }
        guard case .success(let names) = track(el.attributeNames()),
              names.contains(where: Self.webContentAttributes.contains) else {
            return fail(.notWebContent, timedOut ? .readFailed : .notWebContent)
        }
        guard case .success(var value) = track(el.string(.value)) else { return fail(.valueRead, .readFailed) }
        var units = Array(value.utf16)
        var n = units.count
        guard n > 0, n <= ReplacementPlanner.maxFieldReadChars else { return fail(.boxSize, .boxSize) }
        lastDiagnostic.valueUnits = n   // P3-55
        guard case .success(n) = track(el.integer(.numberOfCharacters)) else {
            return fail(.numberOfCharacters, timedOut ? .readFailed : .inconsistent)
        }
        // P3-57: the odd units (counts and code points only) for the trace, whatever happens next.
        let odd = Self.oddRuns(in: value)
        lastDiagnostic.oddUnits = Self.oddUnitsSummary(value)
        // P3-44: mention pills / links the AX tree shows as their own elements, for the plan to keep whole. Best
        // effort: an app that can't list them gives none (the `@word` rule still holds); a timeout stops the convert.
        // P3-46: read before the prefix check (it uses them, and the trace counts them even when the check fails).
        var atoms: [String] = []
        var images = 0
        // P3-53: the walks get what is left of the read budget; none left → stop before anything is written.
        let elapsed = clock.nowNanos &- start
        guard elapsed < timing.readBudgetNanos else { return fail(.atomRead, .timedOut) }
        switch track(el.inlineAtoms(maxNodes: Self.maxAtomNodes, budgetNanos: timing.readBudgetNanos - elapsed)) {
        case .success(let a):
            atoms = a.map(\.text).filter { !$0.isEmpty }   // P3-55: images come as empty atoms (trace count only)
            images = a.filter { $0.role == "AXImage" }.count   // P3-57
            lastDiagnostic.atomRoles = a.map { Self.roleName($0.role) }
        case .failure: if timedOut { return fail(.atomRead, .readFailed) }
        }
        // P3-53: a walk that came back late (one slow AX call) still ends the read: no piece after the budget.
        if clock.nowNanos &- start > timing.readBudgetNanos { return fail(.atomRead, .timedOut) }
        lastDiagnostic.atoms = atoms.count
        // P3-57 (owner Slack traces `vh 🔥 vh vh`: `valueUnits=11` for 9 visible units, `atomRoles=AXImage:1`, the
        // prefix read 9 long and parting right after `vh `): Slack's image emoji leaves a run of odd units in `AXValue`
        // that the app's caret, ranges and `AXStringForRange` don't count. When there is exactly one such run per
        // `AXImage`, they are dropped from every read of this convert, so `AXValue`'s units are the app's again and the
        // P3-42 … P3-51 checks (prefix, exact read-backs) run as usual. Counts that don't match → keep the raw value
        // (the prefix check then fails and a chat app just switches, P3-55).
        if images > 0, !odd.isEmpty, odd.count == images {
            stripOddUnits = true
            lastDiagnostic.oddRunsStripped = odd.count
            value = Self.strippingOddUnits(value)
            units = Array(value.utf16)
            n = units.count
            guard n > 0 else { return fail(.boxSize, .boxSize) }
        }
        guard case .success(let raw) = track(el.range(.selectedTextRange)) else { return fail(.rangeRead, .readFailed) }
        var sel = raw
        // P3-44 (shape B): a caret read past the end of `AXValue` by no more than `maxHiddenUnits` = the page counts
        // units the value leaves out (Slack's emoji); taken as the end of the value, and put back as read.
        if source == .box, raw.isCaret, raw.location > n, raw.location - n <= Self.maxHiddenUnits {
            sel = TextRange(location: n, length: 0)
            lastDiagnostic.caretPastValue = raw.location - n
        }
        guard sel.location >= 0, sel.length >= 0, sel.end <= n,
              source == .box ? sel.isCaret : !sel.isCaret else { return fail(.rangeBounds, .inconsistent) }
        guard case .success(let selected) = track(el.string(.selectedText)).map(stripIfNeeded) else {
            return fail(.selectedTextRead, .readFailed)
        }
        let slice = Array(units[sel.location..<sel.end])
        let sliceText = String(decoding: slice, as: UTF16.self)
        // Scalar boundaries: a range splitting a surrogate pair decodes to U+FFFD.
        guard Array(sliceText.utf16) == slice else { return fail(.scalarBoundary, .inconsistent) }
        if source == .box {
            guard selected.isEmpty else { return fail(.caretSelectedText, .inconsistent) }
        } else if !selected.unicodeScalars.elementsEqual(sliceText.unicodeScalars) {
            // P3-40: Chromium's AXSelectedText can drop the line breaks between paragraphs. Then the visible characters
            // must agree and the value's text (which keeps its LF) is used; every piece is checked again below.
            // P3-51 (owner: selecting text after an emoji in Slack only switched, `readCheck=selectionText`): the
            // selected text may show an emoji where `AXValue` has U+FFFC or nothing; the rest must agree.
            let lineBreaksOnly = sliceText.contains(where: \.isNewline)
                && ConvertController.sameVisibleText(selected, sliceText)
            guard lineBreaksOnly || Self.sameIgnoringObjects(selected, sliceText) else {
                return fail(.selectionText, .inconsistent)
            }
        }
        // The text up to the caret (or the selection's end), where the app answers it (Slack fails it for the whole box,
        // -25212, but answers before the caret). An answer that disagrees means the offsets can't be trusted.
        // P3-44: not with a caret read past the end (shape B: the app's range units are not the value's).
        // P3-46: a disagreeing answer for a caret (box convert) is mapped onto the value (`valueOffset`): the caret is
        // then taken there and the app's own caret kept as the raw one; a selection still stops.
        if sel.end > 0, sel == raw {
            switch track(el.string(in: TextRange(location: 0, length: sel.end))).map(stripIfNeeded) {
            case .success(let prefix):
                let expected = String(decoding: units[..<sel.end], as: UTF16.self)
                // P3-46 QA: an empty answer proves nothing when the box holds a pill (see `.failure` below).
                if prefix.isEmpty, source == .box, !atoms.isEmpty { return fail(.prefix, .inconsistent) }
                if !prefix.isEmpty, !ReplacementExecutor.readsBackAs(prefix, expected) {
                    lastDiagnostic.prefixMismatch = Self.mismatch(Array(prefix.utf16), Array(expected.utf16))
                    let ax = Self.objectCounts(prefix), val = Self.objectCounts(expected)
                    lastDiagnostic.prefixObjects = "ax\(ax.fffc)fffc+\(ax.emoji)emoji/value\(val.fffc)fffc+\(val.emoji)emoji"
                    lastDiagnostic.prefixUnexplained = ax.fffc + ax.emoji + val.fffc + val.emoji == 0
                    lastDiagnostic.spanShape = Self.spanShape(ax: prefix, value: expected)   // P3-57
                    guard let alignment = Self.prefixAlignment(prefix, in: units, atoms: atoms),
                          alignment.end <= n, let c = Self.caret(fromPrefix: alignment, appCaret: sel.end), c <= n
                    else { return fail(.prefix, .inconsistent) }
                    // P3-51: a selection keeps its reported range only when the prefix read is the wider one (its
                    // range then needs no mapping); a narrower one (pills counted as one unit) still stops it.
                    // P3-51 QA: wider only, and exactly accounted for (`caret(fromPrefix:)`).
                    if source == .selection {
                        guard alignment.narrower == 0, c == sel.end else { return fail(.prefix, .inconsistent) }
                        lastDiagnostic.caretMapped = true
                        return .success(Read(text: value, selection: sel, atoms: atoms, rawSelection: raw))
                    }
                    // P3-51: the app's text for the range up to its caret may be in other units than the caret: wider
                    // (an emoji's two units where `AXValue` and the caret count one U+FFFC, or none) → it ends *before*
                    // the caret, which stays; narrower (a pill counted as one unit, P3-46) → it ends after, and the caret
                    // is taken there. P3-46 QA: never both (`caret(fromPrefix:)`). Every piece is still read back.
                    let mapped = Array(String(decoding: units[..<c], as: UTF16.self).utf16)
                    guard mapped == Array(units[..<c]) else { return fail(.prefix, .inconsistent) }   // scalar boundary
                    sel = TextRange(location: c, length: 0)
                    lastDiagnostic.caretMapped = true
                }
            case .failure:
                if timedOut { return fail(.prefix, .readFailed) }
                // P3-46 QA: with a pill in the box the app's offsets may count it as one unit, so an unchecked caret
                // can sit lines early in `AXValue` (and the plan then picks the wrong direction: a bold Hebrew word was
                // retyped while the typed English line stayed). No prefix to map it through → stop (fall back).
                if source == .box, !atoms.isEmpty { return fail(.prefix, .inconsistent) }
            }
        }
        return .success(Read(text: value, selection: sel, atoms: atoms, rawSelection: raw))
    }

    /// P3-46: an AX role for the DEBUG trace: kept only when it looks like an AX role name (`AX` + letters, ≤ 40),
    /// else `other`. Never text.
    nonisolated static func roleName(_ role: String) -> String {
        guard role.hasPrefix("AX"), role.count <= 40, role.allSatisfy({ $0.isASCII && $0.isLetter }) else { return "other" }
        return role
    }

    /// P3-46: counts describing two disagreeing UTF-16 strings (never their text).
    nonisolated static func mismatch(_ ax: [UInt16], _ value: [UInt16]) -> PrefixMismatch {
        var cp = 0
        while cp < ax.count, cp < value.count, ax[cp] == value[cp] { cp += 1 }
        var cs = 0
        while cs < ax.count - cp, cs < value.count - cp, ax[ax.count - 1 - cs] == value[value.count - 1 - cs] { cs += 1 }
        return PrefixMismatch(axUnits: ax.count, valueUnits: value.count, commonPrefix: cp, commonSuffix: cs)
    }

    // MARK: - Step 3 helpers

    /// P3-44: what one selection try showed.
    enum SelectOutcome: Sendable, Equatable {
        /// The app showed the selection and `AXSelectedText` is exactly the expected text.
        case matched
        /// The app showed a selection whose text is something else (a wrong shift / drift; the text read back, for
        /// `locate` only, dropped at once).
        case otherText(String)
        /// The app never showed a new selection in time (or a read failed): nothing to judge.
        case notShown
    }

    /// Sets `range` moved by `shift` page units, then polls (bounded) until the app shows the selection (Chromium applies
    /// it in the renderer and updates the AX tree asynchronously, research §5 step 3) and judges `AXSelectedText`: it
    /// must be exactly `original` (P3-42 QA: or, for a window holding a line break, the same visible text: P3-40,
    /// Chromium can drop line breaks from it). P3-44: "shows" = any range that differs from the one read just before the
    /// write (shape A reports in value units); it is then judged by the text alone. P3-44 QA: when the selection
    /// before already reads like the target (or can't be read), it is first moved to a caret, so a stale read of the old
    /// AX tree can never pass for the new selection. The first check is immediate.
    /// P3-61: `exactLength` (a piece about to be typed over): the app must report a selection exactly as long as the
    /// piece. Chromium's `AXSelectedText` drops line breaks, so a selection that swallowed the paragraph break after the
    /// piece read back "right" and typing over it joined two lines (owner, Gmail reply in Chrome).
    private func select(_ el: any AXTextElement, _ range: TextRange, shift: Int, _ original: String,
                        exactLength: Bool = false) async -> SelectOutcome {
        let target = TextRange(location: range.location + shift, length: range.length)
        var before: TextRange? = if case .success(let r) = track(el.range(.selectedTextRange)) { r } else { nil }
        if timedOut { return .notShown }
        let polls = max(1, Int(timing.selectSettleNanos / max(timing.pollNanos, 1)))
        // P3-44 QA: a read of the old AX tree (Chromium applies a range write asynchronously; the range *and* the
        // selected text of the old tree) must never pass for the new selection. When the selection now reads as the
        // new one would (shape A reports a widened window holding hidden units as the bare piece range), or can't be
        // read, it is first moved to a caret at the target: a caret read is told apart from any (non-empty) target.
        if before == nil || before == target || before == range {
            let caret = TextRange(location: target.location, length: 0)
            guard case .success = track(el.setRange(caret, for: .selectedTextRange)) else {
                return timedOut ? .notShown : .otherText("")
            }
            before = nil
            for i in 0...polls {
                if case .success(let r) = track(el.range(.selectedTextRange)), r.isCaret { before = r; break }
                if timedOut { return .notShown }
                if i < polls { await sleep(timing.pollNanos) }
            }
            guard before != nil else { return .notShown }
        }
        guard case .success = track(el.setRange(target, for: .selectedTextRange)) else {
            return timedOut ? .notShown : .otherText("")   // e.g. a shifted range past the page's end
        }
        for i in 0...polls {
            // Shown = any range other than the one read just before the write (shape A reports the new selection in
            // value units, which may be neither `target` nor `range`); `before` is never a twin of the target here.
            if case .success(let r) = track(el.range(.selectedTextRange)), r != before {
                guard case .success(let selected) = track(el.string(.selectedText)).map(stripIfNeeded) else {
                    return .notShown
                }
                if exactLength, r.length != range.length { return .otherText(selected) }   // P3-61
                if selected.unicodeScalars.elementsEqual(original.unicodeScalars) { return .matched }
                if original.contains(where: \.isNewline), ConvertController.sameVisibleText(selected, original) {
                    return .matched
                }
                // P3-51: a window holding U+FFFC in `AXValue` reads back with the emoji there (same place, same count).
                // P3-51 QA: only when every object in `AXValue` is a U+FFFC: a literal emoji elsewhere in the value
                // (text, not an image) would read back the same as an image emoji and could pass for the window.
                if !valueHasLiteralObjects, Self.sameWithObjectsInPlace(selected, original) { return .matched }
                return .otherText(selected)
            }
            if timedOut { return .notShown }
            if i < polls { await sleep(timing.pollNanos) }
        }
        return .notShown
    }

    /// Polls (bounded) until `AXValue` reads as `expected` and the caret is after the piece: at `caret` (value units,
    /// shape A) or `caret + shift` (page units, shape B). Returns which one it saw, nil if it never settled. The first
    /// check is immediate.
    private func settled(_ el: any AXTextElement, expected: [UInt16], caret: Int, shift: Int) async
        -> Diagnostic.ReadSpace? {
        let want = String(decoding: expected, as: UTF16.self)
        let polls = max(1, Int(timing.settleNanos / max(timing.pollNanos, 1)))
        for i in 0...polls {
            if case .success(let v) = track(el.string(.value)).map(stripIfNeeded),
               ReplacementExecutor.readsBackAs(v, want),
               case .success(let r) = track(el.range(.selectedTextRange)), r.isCaret {
                if r.location == caret { return shift == 0 ? .unknown : .value }
                if r.location == caret + shift { return .page }
            }
            if timedOut { return nil }
            if i < polls { await sleep(timing.pollNanos) }
        }
        return nil
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
                  // P3-51 QA: never type over an embedded object or emoji (the relaxed read-backs accept one in place).
                  !p.original.contains(where: isObject),
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
