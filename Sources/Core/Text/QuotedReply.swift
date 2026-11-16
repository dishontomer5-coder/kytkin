// P3-48 (Coordinator 2026-11-16): in a plain-text copy of a mail reply or forward (no HTML to tell the parts apart), a
// whole-box convert converts only what comes before the quoted thread or the signature. `boundary(in:)` finds the
// first line that starts one:
//   - a quote header: `On … wrote:` (also wrapped over two lines, the second ending in `wrote:`), or Gmail's Hebrew
//     `בתאריך … כתב:` / `כתבה:` / `כתב/ה:`;
//   - a forward header: `---------- Forwarded message ---------`, or the Hebrew `---------- הודעה שהועברה ----------`;
//   - a quoted line (`>` first, after spaces);
//   - the signature delimiter line `-- ` (or `--`).
// Bidi marks Gmail puts around Hebrew headers are ignored. Pure; the text is only looked at for this one convert.

import Foundation

enum QuotedReply {
    /// The UTF-16 offset where the quote / forward / signature starts (the start of its line), nil = none found.
    static func boundary(in text: String) -> Int? {
        let lines = text.components(separatedBy: "\n")
        var offset = 0
        for (k, raw) in lines.enumerated() {   // bounded by the number of lines
            let line = clean(raw)
            let next = k + 1 < lines.count ? clean(lines[k + 1]) : ""
            if startsQuote(line, next: next) { return offset }
            offset += raw.utf16.count + 1
        }
        return nil
    }

    private static func clean(_ s: String) -> String {
        let marks: Set<UInt32> = [0x200E, 0x200F, 0x202A, 0x202B, 0x202C, 0x202D, 0x202E, 0x2066, 0x2067, 0x2068, 0x2069]
        var out = String.UnicodeScalarView()
        out.append(contentsOf: s.unicodeScalars.filter { !marks.contains($0.value) && $0.value != 0x0D })
        return String(out).trimmingCharacters(in: .whitespaces)
    }

    private static func startsQuote(_ line: String, next: String) -> Bool {
        if line.hasPrefix(">") { return true }
        if line == "--" || line == "-- " { return true }
        let lower = line.lowercased()
        if lower.hasPrefix("on "), lower.hasSuffix("wrote:") || next.lowercased().hasSuffix("wrote:") { return true }
        if line.hasPrefix("בתאריך"),
           ["כתב:", "כתבה:", "כתב/ה:"].contains(where: { line.hasSuffix($0) || next.hasSuffix($0) }) { return true }
        if lower.contains("forwarded message"), line.hasPrefix("---") { return true }
        if line.contains("הודעה שהועברה"), line.hasPrefix("---") { return true }
        return false
    }
}
