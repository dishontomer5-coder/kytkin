// P3-37: a fake pasteboard that also plays the app on the other side of ⌘A / ⌘C / ⌘V / Right arrow, so the clipboard
// convert runs end to end without the real clipboard (CLAUDE.md: agents never touch it). The "app" reads the events
// the convert posted (`RecordingPoster`) each time the pasteboard is asked anything, and answers on the fake clock:
// ⌘C copies its box after `copyDelayNanos` (nil = never), ⌘V pastes the pasteboard's text over the ⌘A selection (or at
// the end) and counts a read of a transient write.

import Foundation

@TextActor final class FakePasteboard: PasteboardAccess {
    static let plain = "public.utf8-plain-text"
    static let transient = "org.nspasteboard.TransientType"
    static let concealed = "org.nspasteboard.ConcealedType"

    private let poster: RecordingPoster
    private let clock: FakeClock
    private var seen = 0

    // The pasteboard.
    private(set) var items: [[PasteboardEntry]]
    private var count = 100
    private(set) var restores = 0
    private(set) var transientWrites: [String] = []
    var snapshotFails = false
    var writeFails = false
    private var reads = 0
    /// P3-37: logs each restore (to check it comes after the finish).
    var log: ConvertLog?

    // The app.
    /// The text box's content.
    var box: String
    /// ⌘C reaches the pasteboard this long after it was posted. nil = never (an app that can't copy).
    var copyDelayNanos: UInt64? = 20_000_000
    /// ⌘V reads the pasteboard this long after it was posted (and counts a read). nil = never reads.
    var pasteDelayNanos: UInt64? = 30_000_000
    /// ⌘C copies this instead of the box (e.g. "" for an app that copies nothing).
    var copiesInstead: String?
    private(set) var selectedAll = false
    private(set) var pastes = 0
    private var copyDue: UInt64?
    private var pasteDue: UInt64?

    init(poster: RecordingPoster, clock: FakeClock, box: String, clipboard: [[PasteboardEntry]] = FakePasteboard.user) {
        self.poster = poster
        self.clock = clock
        self.box = box
        items = clipboard
    }

    /// What the user had copied: two items, three types (text, RTF, a private type).
    static let user: [[PasteboardEntry]] = [
        [PasteboardEntry(type: plain, data: Data("my copied text".utf8)),
         PasteboardEntry(type: "public.rtf", data: Data("{\\rtf1 my copied text}".utf8))],
        [PasteboardEntry(type: "com.example.private", data: Data([0, 1, 2, 3]))],
    ]

    var holdsUserClipboard: Bool { items == Self.user }

    /// Someone else (the user, another app) copies now.
    func externalCopy(_ text: String) {
        items = [[PasteboardEntry(type: Self.plain, data: Data(text.utf8))]]
        count += 1
    }

    // MARK: - PasteboardAccess

    var changeCount: Int { sync(); return count }
    var transientReads: Int { sync(); return reads }

    func snapshot(maxBytes: Int) -> PasteboardSnapshot? {
        sync()
        let s = PasteboardSnapshot(items: items)
        return snapshotFails || s.byteCount > maxBytes ? nil : s
    }

    func restore(_ snapshot: PasteboardSnapshot) -> Bool {
        sync()
        items = snapshot.items
        count += 1
        restores += 1
        log?.add(.clipboardRestored)
        return true
    }

    func string() -> String? {
        sync()
        return text(of: items)
    }

    func writeTransient(_ text: String) -> Bool {
        sync()
        guard !writeFails else { return false }
        items = [[PasteboardEntry(type: Self.plain, data: Data(text.utf8)),
                  PasteboardEntry(type: Self.transient, data: Data()),
                  PasteboardEntry(type: Self.concealed, data: Data())]]
        count += 1
        transientWrites.append(text)
        return true
    }

    // MARK: - The app

    private func text(of items: [[PasteboardEntry]]) -> String? {
        items.first?.first { $0.type == Self.plain }.map { String(decoding: $0.data, as: UTF8.self) }
    }

    /// Plays every event posted since the last call, then whatever is due on the clock.
    func sync() {
        let events = poster.events
        while seen < events.count {
            let e = events[seen]
            seen += 1
            guard e.isKeyDown else { continue }
            if e.modifierFlags == SyntheticKeyEvent.commandFlag {
                switch e.keyCode {
                case ClipboardShortcut.selectAll.keyCode: selectedAll = true
                case ClipboardShortcut.copy.keyCode:
                    if selectedAll, let d = copyDelayNanos { copyDue = clock.nowNanos + d }
                case ClipboardShortcut.paste.keyCode:
                    if let d = pasteDelayNanos { pasteDue = clock.nowNanos + d }
                default: break
                }
            } else if e.keyCode == KeyCode.rightArrow {
                selectedAll = false
            }
        }
        let now = clock.nowNanos
        if let due = copyDue, now >= due {
            copyDue = nil
            let copied = copiesInstead ?? box
            items = [[PasteboardEntry(type: Self.plain, data: Data(copied.utf8))]]
            count += 1
        }
        if let due = pasteDue, now >= due {
            pasteDue = nil
            let pasted = text(of: items) ?? ""
            if items.first?.contains(where: { $0.type == Self.transient }) == true { reads += 1 }
            box = selectedAll ? pasted : box + pasted
            selectedAll = false
            pastes += 1
        }
    }
}

/// P3-37: a focused-element identity for tests (identity = the object).
final class FakeElement: FocusedElementIdentity {
    let processID: Int32?
    init(pid: Int32? = 4242) { processID = pid }
    func isSameElement(as other: any FocusedElementIdentity) -> Bool { other === self }
}
