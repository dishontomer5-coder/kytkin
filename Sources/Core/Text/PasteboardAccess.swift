// P3-37 (owner 2026-11-11, plan.md P3-37 (2)): the pasteboard seam for the clipboard convert in apps whose text box
// Kytkin can't read (Slack, VS Code, Chrome web fields…; never terminals). The live adapter is
// `System/Text/SystemPasteboard` (NSPasteboard.general), which is never compiled into the tests: tests use a fake, so no
// test ever touches the real clipboard (CLAUDE.md live-machine rule).
//
// Privacy: a snapshot holds the user's clipboard in memory only, for one convert, until it is written back; the copied
// box text lives only inside that convert (P3-40: nothing is kept for an undo any more). Nothing here is ever logged
// or stored (B12).

import Foundation

@TextActor protocol PasteboardAccess: AnyObject {
    /// Increments on every change of the pasteboard's owner or contents (`NSPasteboard.changeCount`).
    var changeCount: Int { get }

    /// Every item and type, with its data. nil when the pasteboard can't be copied exactly: a type whose data can't be
    /// read, or more than `maxBytes` in all. The clipboard convert then isn't used (it could not restore exactly).
    func snapshot(maxBytes: Int) -> PasteboardSnapshot?

    /// Puts `snapshot` back exactly (clear, then write every item with every type). False if the write failed.
    @discardableResult func restore(_ snapshot: PasteboardSnapshot) -> Bool

    /// The plain text of the pasteboard (what ⌘C put there), or nil.
    func string() -> String?

    /// Clears the pasteboard and writes `text` as plain text, marked `org.nspasteboard.TransientType` and
    /// `org.nspasteboard.ConcealedType` (nspasteboard.org) so clipboard managers skip it. False if the write failed.
    func writeTransient(_ text: String) -> Bool

    /// How many times another app has asked for the text `writeTransient` put there (the live adapter writes it
    /// lazily, through a data provider). Grows when the target app reads it for the paste, so the original can be put
    /// back right after. An adapter that can't tell keeps it at 0 (the restore then waits its full bound).
    var transientReads: Int { get }
}
