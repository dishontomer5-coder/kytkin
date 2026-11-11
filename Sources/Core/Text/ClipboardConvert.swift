// P3-37 (owner 2026-11-11, plan.md P3-37 (2); 001 §12.3 X12): the clipboard convert, for apps whose text box Kytkin
// can't read through Accessibility (Slack, Discord, Teams, VS Code, Chrome web fields…). Never in a terminal, never in
// a secure field or under Secure Input, never when the user chose "Keys only" for the app (ConvertController decides
// that; this type only runs the flow). Pure over seams (`PasteboardAccess`, `KeyEventPosting`, a clock and a sleep),
// so it is unit-tested with fakes only.
//
// The box flow, on @TextActor (off main), every wait bounded:
//   1. Snapshot the whole pasteboard (every item, every type). Can't (too big, unreadable type) → `.unavailable`,
//      nothing posted, the caller falls back to the remembered buffer.
//   2. Take the hold-back claim (B3), re-check the focus, post ⌘A, ⌘C.
//   3. Wait for `changeCount` to move (≤ 250 ms, polled every 10 ms). It didn't, or the copy is empty → the box is
//      empty or the app can't copy: drop the ⌘A selection (Right arrow), `.boxEmpty` (the caller falls back), and watch
//      ≤ 750 ms after the finish for a late copy, which is then undone (the user's clipboard put back).
//   4. Convert the copied text (the caller's rule). Nothing changes / too long → restore the clipboard, Right arrow.
//   5. Within the 400 ms budget and with the focus unchanged: write the converted text as plain text marked transient
//      and concealed, post ⌘V (it replaces the ⌘A selection; the caret ends after it, at the end of the box).
//   6. After the caller's finish (held keys replayed): wait until the app read the pasted text (≥ 100 ms, ≤ 500 ms), then
//      put the user's clipboard back, only if nobody wrote to it since (`changeCount` still ours).
// A known selection (AX read it, but it holds a line break so it can't be typed over) skips 2–3: its converted text
// is pasted over it.
//
// Privacy: the snapshot, the copied box and the converted text live only in this flow (the caller keeps the replaced
// text for the undo until the next key, click or focus change). Nothing here is logged or stored (B12).

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

        init() {}
    }

    /// The most clipboard data Kytkin copies to put back (a large image or file list). Bigger → no clipboard convert.
    static let maxSnapshotBytes = 16 * 1024 * 1024

    enum Source: Sendable, Equatable {
        /// ⌘A, ⌘C: the whole text box.
        case box
        /// AX read the selection (it holds a line break, so it can't be typed over): paste over it.
        case selection(String)
    }

    enum Conversion: Sendable, Equatable {
        case replace(String)
        case nothing
        case tooLong
        /// P3-37 QA: the text may not be pasted here (a line break in an app that might be a terminal). Beeps.
        case unsafe
    }

    enum Result: Sendable, Equatable {
        /// ⌘V was posted. `original` = the text it replaced (for the undo), `written` = what was pasted.
        case pasted(original: String, written: String)
        /// The box was copied but nothing in it converts (the clipboard is put back, the selection dropped).
        case nothingToConvert
        /// The box is longer than the convert cap (beeps).
        case tooLong
        /// P3-37 QA: the caller refused to paste this text (`Conversion.unsafe`); the clipboard put back (beeps).
        case unsafeText
        /// ⌘C changed nothing, or copied nothing: an empty box, or an app that can't copy. The caller falls back.
        case boxEmpty
        /// Nothing was posted or written (no snapshot, the first event refused). The caller falls back.
        case unavailable
        /// The hold-back claim was refused (B3). Nothing posted.
        case abandoned
        /// The focus moved (before ⌘A, or before ⌘V): stopped, the clipboard put back.
        case focusChanged
        /// The budget ran out before ⌘V: stopped, the clipboard put back.
        case timedOut
        /// A post or a pasteboard write failed part way: the field may have the ⌘A selection; the clipboard put back.
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
    func run(_ source: Source, convert: (String) -> Conversion, focusIsSame: () -> Bool,
             mayWrite: () -> Bool) async -> (Result, PendingRestore?) {
        let start = clock.nowNanos
        guard let snapshot = pasteboard.snapshot(maxBytes: Self.maxSnapshotBytes) else { return (.unavailable, nil) }
        let before = pasteboard.changeCount
        guard mayWrite() else { return (.abandoned, nil) }

        let text: String
        let selectedAll: Bool
        switch source {
        case .selection(let s):
            text = s
            selectedAll = false
        case .box:
            guard focusIsSame() else { return (.focusChanged, nil) }
            switch post([.shortcut(.selectAll, keyDown: true), .shortcut(.selectAll, keyDown: false),
                         .shortcut(.copy, keyDown: true), .shortcut(.copy, keyDown: false)]) {
            case .none: return (.unavailable, nil)
            case .some(false):
                collapse()
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
            guard pasteboard.changeCount != before else {
                collapse()
                return (.boxEmpty, PendingRestore(snapshot: snapshot, kind: .lateCopy(baseline: before)))
            }
            let copied = pasteboard.string() ?? ""
            guard !copied.isEmpty else {
                pasteboard.restore(snapshot)
                collapse()
                return (.boxEmpty, nil)
            }
            text = copied
            selectedAll = true
        }

        /// Stops after the copy: the user's clipboard goes back now (only the app's own copy was there since).
        func stop(_ result: Result, collapsing: Bool = true) -> (Result, PendingRestore?) {
            if selectedAll { pasteboard.restore(snapshot) }
            if collapsing && selectedAll { collapse() }
            return (result, nil)
        }

        let new: String
        switch convert(text) {
        case .nothing: return stop(.nothingToConvert)
        case .tooLong: return stop(.tooLong)
        case .unsafe: return stop(.unsafeText)
        case .replace(let s): new = s
        }
        guard !new.isEmpty, !new.unicodeScalars.elementsEqual(text.unicodeScalars) else {
            return stop(.nothingToConvert)
        }
        if clock.nowNanos &- start > timing.budgetNanos { return stop(.timedOut) }
        // P2-49 item 3: ⌘V goes to whatever has focus; the selection would stay selected elsewhere anyway.
        guard focusIsSame() else { return stop(.focusChanged, collapsing: false) }
        guard pasteboard.writeTransient(new) else {
            pasteboard.restore(snapshot)
            if selectedAll { collapse() }
            return (.failed, nil)
        }
        let ours = pasteboard.changeCount
        let reads = pasteboard.transientReads
        switch post([.shortcut(.paste, keyDown: true), .shortcut(.paste, keyDown: false)]) {
        case .some(true):
            return (.pasted(original: text, written: new),
                    PendingRestore(snapshot: snapshot, kind: .afterPaste(ours: ours, readsBefore: reads)))
        case .none, .some(false):
            pasteboard.restore(snapshot)
            if selectedAll { collapse() }
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

    /// Drops the ⌘A selection, caret at the end (best effort; nothing else is posted).
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
