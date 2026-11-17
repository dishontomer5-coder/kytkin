// P6-0c (flows §5.4, copy review §4.1): the setup window's practice box. Kytkin ignores its own windows as a context
// (P2-39), so a double-Shift there never reaches ConvertController: the setup model converts its own text box's
// string in process with the same Core conversion (`BoxConversion`, the pair's `LayoutSnapshot`). No Accessibility
// read, no clipboard, no posted keys. The practice text lives only in the window's memory and is cleared when the
// user leaves the screen (it is typed text).

import Foundation

enum PracticeConvert {
    struct Result: Equatable, Sendable {
        let text: String
        /// The language the text is in now (the after-convert switch goes there).
        let target: InputSourceID
    }

    /// Converts the text before the cursor (P3-62), as a double-Shift would; the cursor is at the end of the practice
    /// box. nil = nothing to convert (empty, or already in the other language with no letter to decide).
    static func convert(_ text: String, layouts: LayoutSnapshot) -> Result? {
        let n = text.utf16.count
        guard n > 0 else { return nil }
        let window = FieldWindow(text: text, location: 0, caret: n, reachesFieldStart: true, reachesFieldEnd: true)
        let result = BoxConversion.plan(window, classify: layouts.runClass, convert: { side, g in
            layouts.converter(from: layouts.source(of: side))?.convert(g).text ?? g
        })
        guard case .convert(let plan) = result else { return nil }
        let units = Array(text.utf16)
        let start = max(0, min(plan.edit.offset, n))
        let end = max(start, min(plan.edit.offset + plan.edit.length, n))
        let out = String(decoding: units[..<start], as: UTF16.self) + plan.text
            + String(decoding: units[end...], as: UTF16.self)
        return Result(text: out, target: layouts.source(of: plan.side.other))
    }

    /// The hint under the box (copy review §4.1): a real example for the user's pair when one side is Hebrew, else a
    /// generic line. `name`: a language's display name.
    static func hint(layouts: LayoutSnapshot?, name: (InputSourceID) -> String) -> String {
        guard let layouts else { return genericHint }
        for side in [PairSide.a, .b] {
            let hebrew = layouts.source(of: side)
            guard hebrew.rawValue.localizedCaseInsensitiveContains("hebrew"),
                  let back = layouts.converter(from: hebrew) else { continue }
            let other = layouts.source(of: side.other)
            let typed = sampleWord.map { back.convert(String($0)).text }.joined()
            guard !typed.isEmpty, typed != sampleWord else { continue }
            return "With the \(name(other)) keyboard on, type \(typed) and press Shift twice. "
                + "It becomes \u{2068}\(sampleWord)\u{2069}."
        }
        return genericHint
    }

    static let sampleWord = "שלום"
    static let genericHint = "Type a word in the wrong language, then press Shift twice."
}

/// P6-0c (flows §1.1 step 6, M2): a Kytkin running from the disk image or a quarantined copy (App Translocation)
/// loses its permissions and its login item when the copy goes away. The setup then asks to move it first.
enum InstallLocation {
    static func needsMove(bundlePath: String) -> Bool {
        bundlePath.hasPrefix("/Volumes/") || bundlePath.contains("/AppTranslocation/")
    }
}
