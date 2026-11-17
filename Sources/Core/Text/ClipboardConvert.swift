// P3-37 (owner 2026-11-11, plan.md P3-37 (2); 001 §12.3 X12): the clipboard convert, for apps whose text box Kytkin
// can't read through Accessibility (Slack, Discord, Teams, VS Code, Chrome web fields…). Never in a terminal, never in
// a secure field or under Secure Input, never when the user chose "Keys only" for the app (ConvertController decides
// that; this type only runs the flow). Pure over seams (`PasteboardAccess`, `KeyEventPosting`, a clock and a sleep),
// so it is unit-tested with fakes only.
//
// The box flow, on @TextActor (off main), every wait bounded:
//   1. Snapshot the whole pasteboard (every item, every type). Can't (too big, unreadable type) → `.unavailable`,
//      nothing posted, the caller falls back to the remembered buffer.
//   2. Take the hold-back claim (B3), re-check the focus, post ⇧⌘↑ (P3-62: from the cursor to the box's start), ⌘C.
//   3. Wait for `changeCount` to move (≤ 250 ms, polled every 10 ms). It didn't, or the copy is empty → nothing before
//      the cursor, or the app can't copy: P3-62 QA: drop the selection (Right arrow) only when AX shows one (else the
//      arrow would move the cursor), `.boxEmpty` (the caller just switches), and watch
//      ≤ 750 ms after the finish for a late copy, which is then undone (the user's clipboard put back).
//   4. Convert the copied text (the caller's rule). Nothing changes / too long → restore the clipboard, Right arrow.
//   5. Within the 400 ms budget and with the focus unchanged: write the converted text as plain text marked transient
//      and concealed, post ⌘V (it replaces the ⇧⌘↑ selection; the caret ends after it, where the cursor was).
//   6. After the caller's finish (held keys replayed): wait until the app read the pasted text (≥ 100 ms, ≤ 500 ms), then
//      put the user's clipboard back, only if nobody wrote to it since (`changeCount` still ours).
// P3-40 (owner 2026-11-11): a selection AX reported in an app whose box AX can't read (Slack, Chrome…) is copied with
// ⌘C alone (no ⇧⌘↑: the selection is already there), because Chromium's `AXSelectedText` can drop the line breaks between
// paragraphs: typing over it, or pasting the AX text, joined the lines. The caller checks the copy against the AX text
// (`Conversion.mismatch`), converts it and the paste replaces the selection. Nothing copied → `.boxEmpty` (the selection
// is untouched, nothing was posted but ⌘C).
//
// P3-44 (owner tests 2026-11-16: Slack bold + @mention + emoji, Gmail bold, flattened to plain text): after the copy,
// what the app put on the pasteboard is checked (`CopiedContent.verdict`: HTML with formatting, mentions, emoji images,
// links, code, lists; RTF formatting; images, files). Rich → no plain-text paste (P3-47: a formatting-only HTML copy is
// pasted as converted HTML, below); otherwise nothing is pasted: the clipboard goes back at once, the ⇧⌘↑
// selection is dropped (Right arrow: the caret back where the cursor was), and `.richContent` tells the caller whether
// the copied text *ends with* the run the user typed (`typedTail`, the remembered buffer's text), i.e. whether the caret
// now sits right after it, so the caller may convert just that run by Backspace + typing; otherwise it only switches.
// The decision reads the copied data in memory, for this one convert; never logged.
//
// P3-47 (owner 2026-11-16, Gmail compose in Zen: a bold word anywhere meant no convert at all): a rich copy whose HTML
// holds only formatting (`CopiedContent.htmlForFormattingPaste`, then `HTMLTextConvert`) in an app that is not a chat app
// is converted *inside* the HTML (text nodes only, tags kept byte for byte) and pasted as HTML + plain text, so the bold,
// links and lists stay. The caller's `htmlPlanner` converts with the same rule as the plain text (links kept whole); the
// caller's `convert` still runs first on the plain text (size cap, P3-40 selection check, line-break rule). Any refusal →
// the P3-44 behaviour (`.richContent`). `lastCopy.htmlPaste` says which (enum names only).
//
// Privacy: the snapshot, the copied box and the converted text live only in this flow; P3-40: nothing is kept after
// it (no undo copy any more). Nothing here is logged or stored (B12).

import Foundation

@TextActor final class ClipboardConvert {
    struct Timing: Sendable, Equatable {
        /// Step 3: how long ⌘C may take to reach the pasteboard.
        var copyWaitNanos: UInt64 = 250_000_000
        /// Poll interval for every wait.
        var pollNanos: UInt64 = 10_000_000
        /// Step 6: the paste is given at least this long, and the restore waits at most `pasteReadWaitNanos` for the
        /// app to read the text (the live adapter can't tell when it did, so it always waits the whole bound).
        var pasteMinNanos: UInt64 = 100_000_000
        var pasteReadWaitNanos: UInt64 = 500_000_000
        /// After the app read it, before the restore.
        var pasteSettleNanos: UInt64 = 50_000_000
        /// Step 3: a copy that arrives after we gave up is undone within this window.
        var lateCopyWatchNanos: UInt64 = 750_000_000
        /// 001 §7 B5: ⌘V is never posted later than this after the flow started.
        var budgetNanos: UInt64 = ReplacementChain.defaultBudgetNanos
        /// P3-53: ⇧⌘↑ / ⌘C are posted only this soon after the convert started (`startedAt`), so the copy wait still
        /// fits before `budgetNanos`. Later → `.timedOut`, nothing posted.
        var copyStartBudgetNanos: UInt64 = 200_000_000

        init() {}
    }

    /// The most clipboard data Kytkin copies to put back (a large image or file list). Bigger → no clipboard convert.
    static let maxSnapshotBytes = 16 * 1024 * 1024
    /// P3-44: the most copied data read to decide whether it is rich (more → rich, nothing pasted).
    static let maxCopiedBytes = 4 * 1024 * 1024

    enum Source: Sendable, Equatable {
        /// ⇧⌘↑, ⌘C: the text box from its start up to the cursor (P3-62).
        case box
        /// P3-40: ⌘C alone (no ⇧⌘↑) copies the selection that is already there; its converted text is pasted over it.
        case copiedSelection
    }

    enum Conversion: Sendable, Equatable {
        case replace(String)
        case nothing
        case tooLong
        /// P3-37 QA: the text may not be pasted here (a line break in an app that might be a terminal). Beeps.
        case unsafe
        /// P3-40: the copied selection is not the selection AX reported (⌘C copied something else). Beeps.
        case mismatch
    }

    enum Result: Sendable, Equatable {
        /// ⌘V was posted. P3-40: no text comes back (the undo that kept the replaced text is gone; undo is ⌘Z).
        case pasted
        /// The box was copied but nothing in it converts (the clipboard is put back, the selection dropped).
        case nothingToConvert
        /// The box is longer than the convert cap (beeps).
        case tooLong
        /// P3-37 QA: the caller refused to paste this text (`Conversion.unsafe`); the clipboard put back (beeps).
        case unsafeText
        /// P3-40: the copy is not the selection AX reported (`Conversion.mismatch`); the clipboard put back (beeps).
        case selectionMismatch
        /// P3-44: the copy is rich (formatting, mentions, emoji images, links…): nothing pasted, the clipboard put back,
        /// a ⇧⌘↑ selection dropped (the caret back where the cursor was). `typedRunAtEnd`: the copied text ends with the
        /// caller's `typedTail` (so the caret is right after the typed run).
        case richContent(typedRunAtEnd: Bool)
        /// ⌘C changed nothing, or copied nothing: an empty box, or an app that can't copy. The caller falls back.
        /// P3-40: for `.copiedSelection` the selection is still there (no ⇧⌘↑, no Right arrow was posted).
        case boxEmpty
        /// Nothing was posted or written (no snapshot, the first event refused). The caller falls back.
        case unavailable
        /// The hold-back claim was refused (B3). Nothing posted.
        case abandoned
        /// The focus moved (before ⇧⌘↑, or before ⌘V): stopped, the clipboard put back.
        case focusChanged
        /// The budget ran out before ⌘V: stopped, the clipboard put back.
        case timedOut
        /// A post or a pasteboard write failed part way: the field may have the ⇧⌘↑ selection; the clipboard put back.
        case failed
    }

    /// What to do after the caller's finish (step 6, or step 3's late-copy watch). Holds the user's clipboard until then.
    struct PendingRestore: Sendable {
        enum Kind: Sendable, Equatable {
            /// Restore once the app read the pasted text; only while `changeCount == ours`.
            case afterPaste(ours: Int, readsBefore: Int)
            /// Restore if a late copy moves `changeCount` away from `baseline`.
            case lateCopy(baseline: Int)
        }
        let snapshot: PasteboardSnapshot
        let kind: Kind
    }

    private let pasteboard: any PasteboardAccess
    /// P3-46: what the last run's copy looked like, for the DEBUG trace: type categories as counts and the verdict's
    /// reason (nil = no copy, or it couldn't be read). Never any data.
    struct CopyDiagnostic: Sendable, Equatable {
        let types: CopiedContent.TypeCounts?
        let reason: CopiedContent.Reason?
        /// P3-47: the formatting-preserving paste: nil = not tried (plain copy, chat app, no planner).
        var htmlPaste: HTMLPaste?
    }

    /// P3-47: how the formatting-preserving paste went (for the DEBUG trace).
    enum HTMLPaste: Sendable, Equatable, CustomStringConvertible {
        case ok
        case refused(HTMLTextConvert.Refusal)
        var description: String {
            switch self {
            case .ok: "ok"
            case .refused(let r): "refused(\(r.rawValue))"
            }
        }
    }
    private(set) var lastCopy: CopyDiagnostic?
    /// P3-65 (audit H1): the last run stopped because the user's clipboard is Concealed / Transient (`.unavailable`).
    private(set) var refusedSecretClipboard = false
    /// P3-65 (audit L1): fill `lastCopy` only when someone reads it (the DEBUG trace). Release: off.
    var diagnostics = true
    private let poster: any KeyEventPosting
    private let clock: any Clock
    private let sleep: @Sendable (UInt64) async -> Void
    let timing: Timing

    init(pasteboard: any PasteboardAccess, poster: any KeyEventPosting, clock: any Clock,
         timing: Timing = Timing(), sleep: @escaping @Sendable (UInt64) async -> Void) {
        self.pasteboard = pasteboard
        self.poster = poster
        self.clock = clock
        self.timing = timing
        self.sleep = sleep
    }

    /// Runs steps 1–5. `focusIsSame`: the focused element is still the one the convert started on (P2-49 item 3: keys
    /// go to whatever has focus). `mayWrite`: the B3 claim, asked once before the first post.
    /// P3-44: `typedTail`, the text the user typed last (the remembered buffer), for `.richContent(typedRunAtEnd:)`.
    /// P3-46: `app`: how strict the rich check is (chat apps: rich unless proven plain).
    /// P3-47: `htmlPlanner`: converts a text with the box / selection rule keeping the given atoms whole (nil = no
    /// formatting-preserving paste).
    /// P3-53: `startedAt`: when the convert started (the controller's request start): the time spent on other paths
    /// and the page check counts against the same budget. nil = now.
    /// P3-58: `pasteRichAsPlain`: the rich verdict is not asked (chat apps: the owner accepted that bold / italic
    /// become plain; Slack's `:shortcode:` text turns back into emoji on paste).
    func run(_ source: Source, typedTail: String? = nil, app: CopiedContent.AppKind = .other, startedAt: UInt64? = nil,
             pasteRichAsPlain: Bool = false,
             convert: (String) -> Conversion, htmlPlanner: HTMLTextConvert.Planner? = nil,
             selectionShows: () -> Bool? = { nil },
             focusIsSame: () -> Bool, mayWrite: () -> Bool) async -> (Result, PendingRestore?) {
        lastCopy = nil
        refusedSecretClipboard = false
        let start = startedAt ?? clock.nowNanos
        // P3-53: too late to copy and still paste inside the budget: nothing is posted.
        if clock.nowNanos &- start > timing.copyStartBudgetNanos { return (.timedOut, nil) }
        guard let snapshot = pasteboard.snapshot(maxBytes: Self.maxSnapshotBytes) else { return (.unavailable, nil) }
        // P3-65 (audit H1): a password manager's concealed / transient item is never snapshotted, copied over or put
        // back (that would stop its auto-clear). Nothing is posted; the caller falls back (a chat app just switches).
        if snapshot.isConcealedOrTransient {
            refusedSecretClipboard = true
            return (.unavailable, nil)
        }
        let before = pasteboard.changeCount
        guard mayWrite() else { return (.abandoned, nil) }

        // P3-40: `.copiedSelection` has its selection already, so only ⌘C (⇧⌘↑ would widen it to the box's start). The P3-37
        // paste of AX's selected text without a copy is gone (AX's text is what lost the line breaks).
        let all = source == .box
        guard focusIsSame() else { return (.focusChanged, nil) }
        // P3-62: the box is the text from its start up to the cursor: ⇧⌘↑ selects it (the anchor stays at the cursor).
        let selectToStart: [SyntheticKeyEvent] = all ? [.selectToStart(keyDown: true), .selectToStart(keyDown: false)] : []
        switch post(selectToStart + [.shortcut(.copy, keyDown: true), .shortcut(.copy, keyDown: false)]) {
        case .none: return (.unavailable, nil)
        case .some(false):
            if all { collapse() }
            return (.failed, PendingRestore(snapshot: snapshot, kind: .lateCopy(baseline: before)))
        case .some(true): break
        }
        // Step 3: bounded wait for the copy (≤ copyWait / poll iterations).
        var polls = 0
        let maxPolls = max(1, Int(timing.copyWaitNanos / max(timing.pollNanos, 1)))
        while pasteboard.changeCount == before, polls < maxPolls {
            await sleep(timing.pollNanos)
            polls += 1
        }
        // P3-62 QA: nothing (or nothing but "") was copied: usually ⇧⌘↑ selected nothing (the cursor at the box's
        // start, an empty box, an app that ignores it), and a Right arrow would then move the cursor one character.
        // The selection is dropped only when the app (AX) shows one (a slow copy after ⇧⌘↑ did select).
        guard pasteboard.changeCount != before else {
            if all, selectionShows() == true { collapse() }
            return (.boxEmpty, PendingRestore(snapshot: snapshot, kind: .lateCopy(baseline: before)))
        }
        let text = pasteboard.string() ?? ""
        guard !text.isEmpty else {
            pasteboard.restore(snapshot)
            if all, selectionShows() == true { collapse() }
            return (.boxEmpty, nil)
        }

        /// Stops after the copy: the user's clipboard goes back now (only the app's own copy was there since); a ⇧⌘↑
        /// selection is dropped.
        func stop(_ result: Result, collapsing: Bool = true) -> (Result, PendingRestore?) {
            pasteboard.restore(snapshot)
            if collapsing && all { collapse() }
            return (result, nil)
        }

        // P3-44: never paste plain text over rich content (an unreadable copy counts as rich).
        // P3-46: the strict verdict (no HTML in a chat app, unknown types, mention / shortcode / URL tokens → rich).
        let copied = pasteboard.snapshot(maxBytes: Self.maxCopiedBytes)
        let verdict = copied.map { CopiedContent.verdict($0.items, text: text, app: app) }
        if diagnostics {   // P3-65 (audit L1)
            lastCopy = CopyDiagnostic(types: copied.map { CopiedContent.typeCounts($0.items) }, reason: verdict?.reason)
        }
        var htmlOut: HTMLTextConvert.Output?
        if !pasteRichAsPlain, verdict?.isRich ?? true {
            // P3-47: formatting only (not a chat app) → convert inside the HTML and paste it.
            if app == .other, let planner = htmlPlanner, let items = copied?.items {
                guard let html = CopiedContent.htmlForFormattingPaste(items) else {
                    lastCopy?.htmlPaste = .refused(.notEligible)
                    let atEnd = source == .box && Self.typedRunIsAtEnd(of: text, typedTail: typedTail)
                    return stop(.richContent(typedRunAtEnd: atEnd))
                }
                // The caller's own checks first (size cap, P3-40 selection check, line breaks), as for a plain paste.
                switch convert(text) {
                case .nothing: return stop(.nothingToConvert)
                case .tooLong: return stop(.tooLong)
                case .unsafe: return stop(.unsafeText)
                case .mismatch: return stop(.selectionMismatch)
                case .replace: break
                }
                switch HTMLTextConvert.convert(html: html, plain: text, planner: planner) {
                case .success(let out):
                    lastCopy?.htmlPaste = .ok
                    htmlOut = out
                case .failure(let r):
                    lastCopy?.htmlPaste = .refused(r)
                }
            }
            if htmlOut == nil {
                let atEnd = source == .box && Self.typedRunIsAtEnd(of: text, typedTail: typedTail)
                return stop(.richContent(typedRunAtEnd: atEnd))
            }
        }

        let new: String
        if let htmlOut {
            new = htmlOut.plain
        } else {
            switch convert(text) {
            case .nothing: return stop(.nothingToConvert)
            case .tooLong: return stop(.tooLong)
            case .unsafe: return stop(.unsafeText)
            case .mismatch: return stop(.selectionMismatch)
            case .replace(let s): new = s
            }
        }
        guard !new.isEmpty, !new.unicodeScalars.elementsEqual(text.unicodeScalars) else {
            return stop(.nothingToConvert)
        }
        if clock.nowNanos &- start > timing.budgetNanos { return stop(.timedOut) }
        // P2-49 item 3: ⌘V goes to whatever has focus; the selection would stay selected elsewhere anyway.
        guard focusIsSame() else { return stop(.focusChanged, collapsing: false) }
        let written = htmlOut.map { pasteboard.writeTransient(new, html: $0.html) } ?? pasteboard.writeTransient(new)
        guard written else {
            pasteboard.restore(snapshot)
            if all { collapse() }
            return (.failed, nil)
        }
        let ours = pasteboard.changeCount
        let reads = pasteboard.transientReads
        switch post([.shortcut(.paste, keyDown: true), .shortcut(.paste, keyDown: false)]) {
        case .some(true):
            return (.pasted,
                    PendingRestore(snapshot: snapshot, kind: .afterPaste(ours: ours, readsBefore: reads)))
        case .none, .some(false):
            pasteboard.restore(snapshot)
            if all { collapse() }
            return (.failed, nil)
        }
    }

    /// Step 6 (or the late-copy watch). Every wait bounded; the user's clipboard is put back at most once, and never over
    /// something another app or the user wrote after us.
    func finish(_ pending: PendingRestore) async {
        let poll = max(timing.pollNanos, 1)
        switch pending.kind {
        case let .afterPaste(ours, readsBefore):
            let minPolls = Int(timing.pasteMinNanos / poll)
            let maxPolls = max(minPolls, Int(timing.pasteReadWaitNanos / poll))
            var polls = 0
            while polls < maxPolls, pasteboard.changeCount == ours,
                  polls < minPolls || pasteboard.transientReads == readsBefore {
                await sleep(timing.pollNanos)
                polls += 1
            }
            if pasteboard.transientReads != readsBefore { await sleep(timing.pasteSettleNanos) }
            if pasteboard.changeCount == ours { pasteboard.restore(pending.snapshot) }
        case let .lateCopy(baseline):
            let maxPolls = Int(timing.lateCopyWatchNanos / poll)
            var polls = 0
            while polls < maxPolls, pasteboard.changeCount == baseline {
                await sleep(timing.pollNanos)
                polls += 1
            }
            // The app's copy landed after we gave up: undo it, so the user's clipboard is what it was.
            if pasteboard.changeCount != baseline { pasteboard.restore(pending.snapshot) }
        }
    }

    /// P3-44: the copied (plain) box text ends with the typed run, so the caret after ⇧⌘↑ + Right arrow is right after
    /// it. P3-44 QA: never for a run holding a colon: Slack turns a typed `:joy:` (or `:)`) into one emoji while the
    /// plain-text copy still reads `:joy:`, so the copy would "end with" the run and the Backspaces (one per typed
    /// character) would delete the emoji and the text before it.
    nonisolated static func typedRunIsAtEnd(of text: String, typedTail: String?) -> Bool {
        guard let tail = typedTail, !tail.isEmpty, !tail.contains(":") else { return false }
        return endsWith(text.unicodeScalars, tail.unicodeScalars)
    }

    /// P3-44: `a` ends with `b`, scalar by scalar (no canonical equivalence: the key path counts the buffer's own text).
    nonisolated static func endsWith(_ a: String.UnicodeScalarView, _ b: String.UnicodeScalarView) -> Bool {
        let x = Array(a), y = Array(b)
        return y.count <= x.count && Array(x[(x.count - y.count)...]) == y
    }

    /// Drops the ⇧⌘↑ selection: the caret goes to its end, where the cursor was (best effort; nothing else is posted).
    private func collapse() {
        _ = post([.rightArrow(keyDown: true), .rightArrow(keyDown: false)])
    }

    /// nil = nothing posted (refused before the first event); true = all posted; false = stopped part way.
    private func post(_ events: [SyntheticKeyEvent]) -> Bool? {
        guard events.allSatisfy(\.isSafeToPost) else { return nil }
        for (i, e) in events.enumerated() where !poster.post(e) {
            return i == 0 ? nil : false
        }
        return true
    }
}
