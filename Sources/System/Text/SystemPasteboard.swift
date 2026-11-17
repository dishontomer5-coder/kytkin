// P3-37: the live `PasteboardAccess` (NSPasteboard.general), for the clipboard convert in unreadable non-terminal apps
// (001 §12.3 X12). Translation only; every decision is in Core's `ClipboardConvert`. Not compiled into the test target
// (project.yml lists System files for tests one by one, and System/Text is not among them): no test ever touches the
// real clipboard (CLAUDE.md live-machine rule). Nothing here logs; the data lives only until it is written back.
//
// Why the converted text is written directly and not through a lazy `NSPasteboardItemDataProvider`: the provider's
// callback is serviced on a run loop, and @TextActor's serial queue has none, so the target app's paste could stall.
// `transientReads` therefore stays 0 and `ClipboardConvert` waits its whole (bounded) restore delay.

import AppKit

@TextActor final class SystemPasteboard: PasteboardAccess {
    /// nspasteboard.org markers: clipboard managers skip (Transient) and hide (Concealed) what Kytkin pastes.
    private static let transientType = NSPasteboard.PasteboardType("org.nspasteboard.TransientType")
    private static let concealedType = NSPasteboard.PasteboardType("org.nspasteboard.ConcealedType")

    private let pasteboard = NSPasteboard.general

    nonisolated init() {}

    var changeCount: Int { pasteboard.changeCount }

    var transientReads: Int { 0 }

    func currentTypes() -> [String]? {   // P3-65 QA: names only, no data read
        pasteboard.pasteboardItems.map { items in items.flatMap { $0.types.map(\.rawValue) } }
    }

    func snapshot(maxBytes: Int) -> PasteboardSnapshot? {
        var total = 0
        var items: [[PasteboardEntry]] = []
        for item in pasteboard.pasteboardItems ?? [] {
            var entries: [PasteboardEntry] = []
            for type in item.types {
                // A type whose data can't be read can't be put back exactly: no clipboard convert at all.
                guard let data = item.data(forType: type) else { return nil }
                total += data.count
                guard total <= maxBytes else { return nil }
                entries.append(PasteboardEntry(type: type.rawValue, data: data))
            }
            items.append(entries)
        }
        return PasteboardSnapshot(items: items)
    }

    @discardableResult func restore(_ snapshot: PasteboardSnapshot) -> Bool {
        pasteboard.clearContents()
        guard !snapshot.items.isEmpty else { return true }
        let items = snapshot.items.map { entries -> NSPasteboardItem in
            let item = NSPasteboardItem()
            for e in entries { item.setData(e.data, forType: NSPasteboard.PasteboardType(e.type)) }
            return item
        }
        return pasteboard.writeObjects(items)
    }

    func string() -> String? {
        pasteboard.string(forType: .string)
    }

    func writeTransient(_ text: String) -> Bool {
        write(text, html: nil)
    }

    /// P3-47: plain text and HTML in one item (the target app takes the HTML and keeps the formatting).
    func writeTransient(_ text: String, html: String) -> Bool {
        write(text, html: html)
    }

    private func write(_ text: String, html: String?) -> Bool {
        let item = NSPasteboardItem()
        // P3-47 QA: UTF-8 bytes, as the copy was read (`String(data:encoding: .utf8)`) and as browsers write it.
        if let html, !item.setData(Data(html.utf8), forType: .html) { return false }
        guard item.setString(text, forType: .string),
              item.setData(Data(), forType: Self.transientType),
              item.setData(Data(), forType: Self.concealedType) else { return false }
        pasteboard.clearContents()
        return pasteboard.writeObjects([item])
    }
}
