// P3-37: a fake pasteboard that also plays the app on the other side of ⌘A / ⌘C / ⌘V / Right arrow, so the clipboard
// convert runs end to end without the real clipboard (CLAUDE.md: agents never touch it). The "app" reads the events
// the convert posted (`RecordingPoster`) each time the pasteboard is asked anything, and answers on the fake clock:
// ⌘C copies its box after `copyDelayNanos` (nil = never), ⌘V pastes the pasteboard's text over the ⌘A selection (or at
// the end) and counts a read of a transient write.
// P3-40: `userSelection`, a part of the box the user selected: ⌘C without ⌘A copies it, ⌘V replaces it.

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
    /// P3-47: the HTML written with a formatting-preserving paste (nil entries = plain-only writes).
    private(set) var transientHTMLWrites: [String?] = []
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
    /// P3-44: what else ⌘C puts in the copied item next to the plain text (e.g. `public.html` from Slack / Chrome).
    /// P3-46: by default a plain HTML flavour (positive evidence the copy is plain, which chat apps now need); `[]` =
    /// a copy with plain text only.
    var copiedExtras: [PasteboardEntry] = [.html("<span style=\"font-weight: 400\">copied</span>")]
    /// P3-62: ⇧⌘↑ selected from the cursor (`caret`) to the box's start.
    private(set) var selectedToStart = false
    /// P3-62: the cursor, UTF-16 offset in `box` (nil = the end).
    var caret: Int?
    private var caretUnits: Int { min(caret ?? box.utf16.count, box.utf16.count) }
    private var beforeCaret: String { String(decoding: Array(box.utf16)[..<caretUnits], as: UTF16.self) }
    /// P3-40: the user's selection in the box (its text, found in `box`), nil = a caret.
    var userSelection: String?
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

    /// P3-55 QA: runs on every restore (to move the clock).
    var onRestore: (() -> Void)?

    func restore(_ snapshot: PasteboardSnapshot) -> Bool {
        onRestore?()
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
        transientHTMLWrites.append(nil)
        return true
    }

    func writeTransient(_ text: String, html: String) -> Bool {
        sync()
        guard !writeFails else { return false }
        items = [[PasteboardEntry(type: Self.plain, data: Data(text.utf8)),
                  PasteboardEntry(type: "public.html", data: Data(html.utf8)),
                  PasteboardEntry(type: Self.transient, data: Data()),
                  PasteboardEntry(type: Self.concealed, data: Data())]]
        count += 1
        transientWrites.append(text)
        transientHTMLWrites.append(html)
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
            if e.modifierFlags == SyntheticKeyEvent.commandFlag | SyntheticKeyEvent.shiftFlag,
               e.keyCode == KeyCode.upArrow {
                selectedToStart = true   // P3-62: ⇧⌘↑
            } else if e.modifierFlags == SyntheticKeyEvent.commandFlag {
                switch e.keyCode {
                case ClipboardShortcut.copy.keyCode:
                    if selectedToStart || userSelection != nil, let d = copyDelayNanos { copyDue = clock.nowNanos + d }
                case ClipboardShortcut.paste.keyCode:
                    if let d = pasteDelayNanos { pasteDue = clock.nowNanos + d }
                default: break
                }
            } else if e.keyCode == KeyCode.rightArrow {
                selectedToStart = false
                userSelection = nil
            }
        }
        let now = clock.nowNanos
        if let due = copyDue, now >= due {
            copyDue = nil
            let copied = copiesInstead ?? (selectedToStart ? beforeCaret : userSelection ?? box)
            items = [[PasteboardEntry(type: Self.plain, data: Data(copied.utf8))] + copiedExtras]
            count += 1
        }
        if let due = pasteDue, now >= due {
            pasteDue = nil
            let pasted = text(of: items) ?? ""
            if items.first?.contains(where: { $0.type == Self.transient }) == true { reads += 1 }
            if selectedToStart {
                // P3-62: the paste replaces the text before the cursor; the cursor ends after it.
                let after = String(decoding: Array(box.utf16)[caretUnits...], as: UTF16.self)
                box = pasted + after
                caret = caret == nil ? nil : pasted.utf16.count
            } else if let sel = userSelection, let r = box.range(of: sel) {
                box.replaceSubrange(r, with: pasted)   // P3-40: the paste replaces the selection
            } else {
                box += pasted
            }
            selectedToStart = false
            userSelection = nil
            pastes += 1
        }
    }
}

extension PasteboardEntry {
    /// P3-44: an HTML entry, as Chromium writes it for a contenteditable copy.
    static func html(_ s: String) -> PasteboardEntry {
        PasteboardEntry(type: "public.html", data: Data(("<meta charset='utf-8'>" + s).utf8))
    }
}

/// P3-37: a focused-element identity for tests (identity = the object).
final class FakeElement: FocusedElementIdentity {
    let processID: Int32?
    init(pid: Int32? = 4242) { processID = pid }
    func isSameElement(as other: any FocusedElementIdentity) -> Bool { other === self }
}
