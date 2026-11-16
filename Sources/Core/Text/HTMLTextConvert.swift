// P3-47 (owner 2026-11-16, Gmail compose in Zen: with a bold word anywhere in the box or the selection, double-Shift only
// switched, because P3-44 never pastes over rich content): a *formatting-preserving* paste. When the HTML a browser copied
// holds only formatting, its text nodes are converted with the same rule as the plain text, every tag and attribute is
// kept byte for byte, and the converted HTML is pasted (with the converted plain text next to it).
//
// Pure, bounded, conservative. Any doubt → a `Refusal` (the caller keeps the P3-44 behaviour: the typed run by keys, or
// just switch):
//   1. Tokenize: comments, `<!DOCTYPE>` / `<?…?>`, tags (quoted attribute values honoured), text. A `<` that starts
//      none of them, an unterminated tag or comment → `.parse`.
//   2. Tags: only formatting (`allowedTags`: b strong i em u s strike del ins sub sup small big mark span font div p br
//      blockquote ul ol li h1–h6 a, plus the html head body meta wrappers browsers add). Embeds / form controls / script
//      / style / anything else → `.unsupportedTag`. Attributes: `style` (text formatting), `class` / `id` (unless they
//      name a mention, emoji, pill…), `dir` `lang` `align` `color` `face` `size` `start` `type` `value` `charset`
//      `content` `http-equiv` `name` `title` `target` `rel`, `href` on `a`, `contenteditable` unless `false`. `data-*`,
//      `aria-*`, `contenteditable="false"`, a rich-content word in a class / id → `.marker`; any other attribute →
//      `.unsafeAttribute`.
//   3. Text: entities decoded (`&amp; &lt; &gt; &quot; &apos; &nbsp; &#N; &#xH;`; another named entity → `.parse`; a
//      bare `&` before a space or the end is a literal `&`). The text of the whole HTML, `T`, is the text nodes in order
//      with a line break for every block boundary (`div p br li …`), so words in two blocks never join. Text inside
//      `<a>` is atomic (a link's text is never converted).
//   4. `T` must have the same visible characters as the copied plain text (`.textMismatch`: hidden text, a signature
//      only in one of them…). The caller's planner converts `T` and the plain text with the same atoms; every change in
//      `T` must be exactly one grapheme of one text node (`.splitGrapheme`); the converted `T` must have the same visible
//      characters as the converted plain text (`.resultMismatch`).
//   5. Output: each text node rebuilt grapheme by grapheme: unchanged graphemes keep their raw bytes (entities as they
//      were), changed ones are written escaped (`&` `<` `>` and NBSP as entities), so converted text can never form
//      markup. Tags, comments and attributes are copied unchanged.
//
// P3-48 (Coordinator 2026-11-16): a whole-box convert of a Gmail reply / forward never touches the quoted thread or the
// signature. With `skipQuotes` (the box, never a selection: a selection inside the quote is the user's choice), an
// element whose class names `gmail_quote`, `gmail_signature` or `gmail_extra`, and any `<blockquote>`, opens a *skipped*
// region up to its matching end tag: its text nodes are copied byte for byte, are passed to the planner as atoms (one per
// text node, trimmed, ≥ 2 characters; so they never convert and never decide the direction, in the HTML's text and in
// the plain text alike), and a change landing in one anyway refuses the paste (`.quoteChanged`). Inside such a region
// any tag and attribute is kept as it was (signature images, `data-*`, mail links), except active or embedded content
// (`forbiddenInSkipped`: script, style, iframe, object, embed, svg, media, form controls) → `.unsupportedTag`.
//
// Privacy: the HTML, its text and the converted output live only for this one convert; nothing is logged (B12).

import Foundation

enum HTMLTextConvert {
    enum Refusal: String, Error, Sendable, Equatable {
        case tooBig, parse, unsupportedTag, unsafeAttribute, marker, textMismatch, nothingToConvert, splitGrapheme,
             resultMismatch, notEligible
        /// P3-49: a control character (other than tab / line breaks) in the HTML's text: it would bound what converts
        /// (a `BoxConversion` hard stop) where the plain text has none, so the two conversions could differ.
        case controlCharacter
        /// P3-48: a change would land in a quoted thread or a signature.
        case quoteChanged
    }

    struct Output: Sendable, Equatable {
        let html: String
        let plain: String
    }

    /// Converts `text` keeping each of `atoms` whole; per-grapheme changes in UTF-16 offsets of `text` (sorted), `[]` =
    /// nothing changes, nil = can't convert it.
    typealias Planner = (_ text: String, _ atoms: [String]) -> [TextChange]?

    static let maxBytes = CopiedContent.maxAnalyzedBytes

    static let allowedTags: Set<String> = [
        "html", "head", "body", "meta", "b", "strong", "i", "em", "u", "s", "strike", "del", "ins", "sub", "sup",
        "small", "big", "mark", "span", "font", "div", "p", "br", "blockquote", "ul", "ol", "li",
        "h1", "h2", "h3", "h4", "h5", "h6", "a",
    ]
    /// Tags whose boundaries separate words (a line break in `T`).
    static let blockTags: Set<String> = ["div", "p", "br", "blockquote", "ul", "ol", "li", "h1", "h2", "h3", "h4", "h5",
                                         "h6", "body", "html", "head"]
    /// P3-48: classes that open a skipped region (Gmail's quoted thread, signature, trimmed extra).
    static let skippedClassWords = ["gmail_quote", "gmail_signature", "gmail_extra"]
    /// P3-48: never allowed, even inside a skipped region.
    static let forbiddenInSkipped: Set<String> = ["script", "style", "iframe", "frame", "object", "embed", "svg", "video",
                                                  "audio", "canvas", "input", "button", "textarea", "select", "form",
                                                  // P3-48 QA: page-level and inert-script containers too
                                                  "base", "link", "template", "noscript", "math", "applet", "frameset"]
    /// P3-48: elements with no end tag (they never open a region or nest).
    static let voidTags: Set<String> = ["area", "base", "br", "col", "embed", "hr", "img", "input", "link", "meta",
                                        "param", "source", "track", "wbr"]

    static let plainAttributes: Set<String> = [
        "style", "dir", "lang", "align", "color", "face", "size", "start", "type", "value", "charset", "content",
        "http-equiv", "name", "title", "target", "rel",
        "clear",   // P3-48: Gmail's `<br clear="all">` before a signature
    ]

    // MARK: - Tokens

    private struct TextNode {
        /// The node's decoded graphemes: the raw source of each, its decoded text, its UTF-16 offset in `T`.
        var graphemes: [(raw: String, text: String, offset: Int)]
        let inLink: Bool
        /// P3-48: inside a quoted thread / signature (never changed).
        var skipped = false
    }

    private enum Part {
        case markup(String)
        case text(Int)   // index into `nodes`
    }

    private struct Parsed {
        var parts: [Part] = []
        var nodes: [TextNode] = []
        var t = ""
        var tUnits = 0
        var linkTexts: [String] = []
        /// P3-48: the trimmed text of every skipped text node (atoms for the planner).
        var skippedTexts: [String] = []
    }

    // MARK: - Entry

    /// Converts the copied `html` whose plain text is `plain` with `planner` (the same rule for both, link texts kept
    /// whole). The output's plain text is the planner's conversion of `plain` (checked against the HTML's).
    /// P3-48: `skipQuotes`: a whole-box convert (quoted thread and signature left alone).
    static func convert(html: String, plain: String, skipQuotes: Bool = false,
                        planner: Planner) -> Swift.Result<Output, Refusal> {
        guard html.utf8.count <= maxBytes else { return .failure(.tooBig) }
        let parsed: Parsed
        switch parse(html, skipQuotes: skipQuotes) {
        case .failure(let r): return .failure(r)
        case .success(let p): parsed = p
        }
        guard ConvertController.sameVisibleText(parsed.t, plain) else { return .failure(.textMismatch) }
        // P3-48 QA: atoms protect every occurrence of their text, so a quote text that also occurs in the user's own part
        // (outside every skipped region) would keep the user's words from converting. Such a text is not an atom; a
        // change landing in the quote's copy of it then refuses the paste (`.quoteChanged`), never converts it.
        var skippedUnit = [Bool](repeating: false, count: parsed.tUnits)
        for node in parsed.nodes where node.skipped {
            for g in node.graphemes { for k in g.offset..<min(g.offset + g.text.utf16.count, skippedUnit.count) { skippedUnit[k] = true } }
        }
        let tNS = parsed.t as NSString
        func onlyInSkipped(_ atom: String) -> Bool {
            var from = 0
            while from < tNS.length {   // bounded: each match moves `from` forward
                let r = tNS.range(of: atom, options: [.literal], range: NSRange(location: from, length: tNS.length - from))
                guard r.location != NSNotFound, r.length > 0 else { return true }
                if (r.location..<(r.location + r.length)).contains(where: { $0 >= skippedUnit.count || !skippedUnit[$0] }) {
                    return false
                }
                from = r.location + r.length
            }
            return true
        }
        let atoms = (parsed.linkTexts + parsed.skippedTexts.filter(onlyInSkipped)).filter { $0.count >= 2 }
        // P3-49: the plain text first, so a planner that fixes the direction on its first call uses the plain text's.
        guard let pChanges = planner(plain, atoms), let tChanges = planner(parsed.t, atoms) else {
            return .failure(.nothingToConvert)
        }
        guard !tChanges.isEmpty, !pChanges.isEmpty else { return .failure(.nothingToConvert) }
        guard let newPlain = apply(pChanges, to: plain), let newT = apply(tChanges, to: parsed.t) else {
            return .failure(.splitGrapheme)
        }
        guard ConvertController.sameVisibleText(newT, newPlain) else { return .failure(.resultMismatch) }

        // Map every change onto one grapheme of one text node.
        var byOffset: [Int: (node: Int, grapheme: Int)] = [:]
        for (n, node) in parsed.nodes.enumerated() {
            for (g, x) in node.graphemes.enumerated() { byOffset[x.offset] = (n, g) }
        }
        var replaced: [Int: [Int: String]] = [:]
        for c in tChanges {
            guard let at = byOffset[c.offset] else { return .failure(.splitGrapheme) }
            let g = parsed.nodes[at.node].graphemes[at.grapheme]
            guard !parsed.nodes[at.node].skipped else { return .failure(.quoteChanged) }   // P3-48
            guard g.text.utf16.count == c.length, !parsed.nodes[at.node].inLink else { return .failure(.splitGrapheme) }
            replaced[at.node, default: [:]][at.grapheme] = c.text
        }
        var out = ""
        for part in parsed.parts {
            switch part {
            case .markup(let m): out += m
            case .text(let n):
                let node = parsed.nodes[n]
                let changes = replaced[n] ?? [:]
                for (g, x) in node.graphemes.enumerated() {
                    out += changes[g].map(escape) ?? x.raw
                }
            }
        }
        return .success(Output(html: out, plain: newPlain))
    }

    /// The text of the whole HTML (`T`) and the link texts, for tests and the eligibility check.
    static func text(of html: String) -> String? {
        if case .success(let p) = parse(html, skipQuotes: false) { return p.t }
        return nil
    }

    // MARK: - Parse

    private static func parse(_ html: String, skipQuotes: Bool) -> Swift.Result<Parsed, Refusal> {
        let u = Array(html.utf8)
        var p = Parsed()
        var linkDepth = 0
        /// P3-48: the open elements of a skipped region (its first entry opened it); empty = not skipping.
        var skipStack: [String] = []
        var linkText = ""
        var textStart: Int?
        var i = 0

        func addBreak() {
            p.t += "\n"
            p.tUnits += 1
        }
        func flushText(upTo end: Int) -> Refusal? {
            guard let s = textStart, s < end else { textStart = nil; return nil }
            textStart = nil
            let raw = String(decoding: u[s..<end], as: UTF8.self)
            guard let decoded = decode(raw) else { return .parse }
            if decoded.text.unicodeScalars.contains(where: { u in
                u.properties.generalCategory == .control && !ReplacementPlanner.isLineBreak(u) && u != "\t"
            }) { return .controlCharacter }
            // Graphemes of the decoded node, each with its raw source.
            var graphemes: [(raw: String, text: String, offset: Int)] = []
            var scalarIndex = 0
            let scalars = decoded.scalars
            for ch in decoded.text {
                let n = ch.unicodeScalars.count
                guard scalarIndex + n <= scalars.count else { return .parse }
                let rawPiece = scalars[scalarIndex..<(scalarIndex + n)].map(\.raw).joined()
                scalarIndex += n
                graphemes.append((rawPiece, String(ch), p.tUnits))
                p.tUnits += ch.utf16.count
            }
            p.t += decoded.text
            if !skipStack.isEmpty {
                // P3-48: a skipped text node: kept as it was, an atom for the planner.
                let trimmed = decoded.text.trimmingCharacters(in: .whitespacesAndNewlines)
                if trimmed.count >= 2 { p.skippedTexts.append(trimmed) }
                p.nodes.append(TextNode(graphemes: graphemes, inLink: false, skipped: true))
                p.parts.append(.text(p.nodes.count - 1))
                return nil
            }
            if linkDepth > 0 { linkText += decoded.text }
            p.nodes.append(TextNode(graphemes: graphemes, inLink: linkDepth > 0))
            p.parts.append(.text(p.nodes.count - 1))
            return nil
        }

        while i < u.count {   // bounded: every pass moves `i` forward
            guard u[i] == UInt8(ascii: "<") else {
                if textStart == nil { textStart = i }
                i += 1
                continue
            }
            if let r = flushText(upTo: i) { return .failure(r) }
            if hasPrefix(u, i, "<!--") {
                guard let end = find(u, "-->", from: i + 4) else { return .failure(.parse) }
                p.parts.append(.markup(String(decoding: u[i..<(end + 3)], as: UTF8.self)))
                i = end + 3
                continue
            }
            guard i + 1 < u.count else { return .failure(.parse) }
            let next = u[i + 1]
            let isLetter = (next >= 0x41 && next <= 0x5A) || (next >= 0x61 && next <= 0x7A)
            guard isLetter || next == UInt8(ascii: "/") || next == UInt8(ascii: "!") || next == UInt8(ascii: "?") else {
                return .failure(.parse)
            }
            guard let close = tagEnd(u, from: i + 1) else { return .failure(.parse) }
            let rawTag = String(decoding: u[i...close], as: UTF8.self)
            let inner = String(decoding: u[(i + 1)..<close], as: UTF8.self)
            i = close + 1
            p.parts.append(.markup(rawTag))
            if next == UInt8(ascii: "!") || next == UInt8(ascii: "?") { continue }   // <!DOCTYPE …>, <?xml …?>
            var body = Substring(inner)
            let closing = body.hasPrefix("/")
            if closing { body = body.dropFirst() }
            let name = body.prefix { $0.isLetter || $0.isNumber }.lowercased()
            let selfClosing = body.hasSuffix("/") || voidTags.contains(name)
            // P3-48: inside a skipped region: anything but active / embedded content, nested exactly.
            if !skipStack.isEmpty {
                guard !forbiddenInSkipped.contains(name) else { return .failure(.unsupportedTag) }
                // P3-48 QA: no event handlers or script addresses, even in the user's own quoted bytes.
                if !closing, !attributesAreInert(String(body.dropFirst(name.count))) {
                    return .failure(.unsafeAttribute)
                }
                if closing {
                    guard let at = skipStack.lastIndex(of: name) else {
                        if voidTags.contains(name) { continue }   // a stray </br>
                        return .failure(.parse)
                    }
                    skipStack.removeSubrange(at...)
                } else if !selfClosing {
                    skipStack.append(name)
                }
                if blockTags.contains(name) { addBreak() }
                continue
            }
            if skipQuotes, !closing, !selfClosing, opensSkippedRegion(name, String(body.dropFirst(name.count))) {
                skipStack.append(name)
                addBreak()
                continue
            }
            guard allowedTags.contains(name) else { return .failure(.unsupportedTag) }
            if !closing, let r = checkAttributes(String(body.dropFirst(name.count)), tag: name) { return .failure(r) }
            if blockTags.contains(name) { addBreak() }
            if name == "a" {
                if closing {
                    guard linkDepth > 0 else { return .failure(.parse) }
                    linkDepth -= 1
                    if linkDepth == 0 { p.linkTexts.append(linkText); linkText = "" }
                } else if !body.hasSuffix("/") {
                    linkDepth += 1
                }
            }
        }
        if let r = flushText(upTo: u.count) { return .failure(r) }
        guard linkDepth == 0, skipStack.isEmpty else { return .failure(.parse) }
        return .success(p)
    }

    /// P3-48 QA: no `on…` event handler, and no `javascript:` / `vbscript:` / `data:text/html` address.
    private static func attributesAreInert(_ attributeText: String) -> Bool {
        attributes(attributeText).allSatisfy { name, value in
            let n = name.lowercased()
            let v = value.lowercased().filter { !$0.isWhitespace }
            return !n.hasPrefix("on") && !v.hasPrefix("javascript:") && !v.hasPrefix("vbscript:")
                && !v.hasPrefix("data:text/html")
        }
    }

    /// P3-48: a `<blockquote>`, or an element whose class names Gmail's quote / signature / extra.
    private static func opensSkippedRegion(_ tag: String, _ attributeText: String) -> Bool {
        if tag == "blockquote" { return true }
        return attributes(attributeText).contains { name, value in
            name.lowercased() == "class" && skippedClassWords.contains { value.lowercased().contains($0) }
        }
    }

    private static func checkAttributes(_ s: String, tag: String) -> Refusal? {
        for (name, value) in attributes(s) {
            let n = name.lowercased()
            let v = value.lowercased()
            if n.hasPrefix("data-") || n.hasPrefix("aria-") { return .marker }
            if n == "contenteditable" {
                if v.trimmingCharacters(in: .whitespaces) == "false" { return .marker }
                continue
            }
            if n == "class" || n == "id" {
                if CopiedContent.richWords.contains(where: { w in w != "link" && w != "list" && w != "bold"
                    && w != "italic" && w != "underline" && w != "strike" && w != "quote" && v.contains(w) }) {
                    return .marker
                }
                continue
            }
            if n == "href" {
                if tag == "a" { continue }
                return .unsafeAttribute
            }
            if !plainAttributes.contains(n) { return .unsafeAttribute }
        }
        return nil
    }

    // MARK: - Text

    private struct Decoded {
        let text: String
        /// Each decoded scalar with the raw source it came from.
        let scalars: [(raw: String, scalar: Unicode.Scalar)]
    }

    private static let named: [String: Unicode.Scalar] = [
        "amp": "&", "lt": "<", "gt": ">", "quot": "\"", "apos": "'", "nbsp": "\u{00A0}",
    ]

    private static func decode(_ raw: String) -> Decoded? {
        let s = Array(raw.unicodeScalars)
        var out: [(raw: String, scalar: Unicode.Scalar)] = []
        var i = 0
        while i < s.count {   // bounded: every pass moves `i` forward
            guard s[i] == "&" else {
                out.append((String(s[i]), s[i]))
                i += 1
                continue
            }
            if i + 1 >= s.count || s[i + 1].properties.isWhitespace {
                out.append(("&", "&"))   // a bare ampersand
                i += 1
                continue
            }
            guard let semi = s[(i + 1)...].prefix(12).firstIndex(of: ";") else { return nil }
            let body = String(String.UnicodeScalarView(s[(i + 1)..<semi]))
            let scalar: Unicode.Scalar?
            if body.hasPrefix("#x") || body.hasPrefix("#X") {
                scalar = UInt32(body.dropFirst(2), radix: 16).flatMap(Unicode.Scalar.init)
            } else if body.hasPrefix("#") {
                scalar = UInt32(body.dropFirst()).flatMap(Unicode.Scalar.init)
            } else {
                scalar = named[body]
            }
            guard let scalar else { return nil }
            out.append((String(String.UnicodeScalarView(s[i...semi])), scalar))
            i = semi + 1
        }
        var text = String.UnicodeScalarView()
        text.append(contentsOf: out.map(\.scalar))
        return Decoded(text: String(text), scalars: out)
    }

    /// Converted text written into HTML: never markup.
    static func escape(_ s: String) -> String {
        var out = ""
        for u in s.unicodeScalars {
            switch u {
            case "&": out += "&amp;"
            case "<": out += "&lt;"
            case ">": out += "&gt;"
            case "\u{00A0}": out += "&nbsp;"
            default: out.unicodeScalars.append(u)
            }
        }
        return out
    }

    /// `changes` (sorted, not overlapping) applied to `text`; nil when one doesn't fit.
    private static func apply(_ changes: [TextChange], to text: String) -> String? {
        var units = Array(text.utf16)
        for c in changes.sorted(by: { $0.offset > $1.offset }) {
            guard c.offset >= 0, c.end <= units.count else { return nil }
            units.replaceSubrange(c.offset..<c.end, with: Array(c.text.utf16))
        }
        return String(decoding: units, as: UTF16.self)
    }

    // MARK: - Bytes

    private static func attributes(_ s: String) -> [(String, String)] {
        var out: [(String, String)] = []
        let c = Array(s)
        var i = 0
        while true {   // bounded: each pass consumes ≥ 1 character or stops
            while i < c.count, c[i].isWhitespace || c[i] == "/" { i += 1 }
            guard i < c.count else { break }
            let start = i
            while i < c.count, !c[i].isWhitespace, c[i] != "=", c[i] != "/" { i += 1 }
            let name = String(c[start..<i])
            if name.isEmpty { i += 1; continue }
            while i < c.count, c[i].isWhitespace { i += 1 }
            var value = ""
            if i < c.count, c[i] == "=" {
                i += 1
                while i < c.count, c[i].isWhitespace { i += 1 }
                if i < c.count, c[i] == "\"" || c[i] == "'" {
                    let q = c[i]
                    i += 1
                    let vs = i
                    while i < c.count, c[i] != q { i += 1 }
                    value = String(c[vs..<min(i, c.count)])
                    i += 1
                } else {
                    let vs = i
                    while i < c.count, !c[i].isWhitespace { i += 1 }
                    value = String(c[vs..<i])
                }
            }
            out.append((name, value))
        }
        return out
    }

    private static func tagEnd(_ u: [UInt8], from: Int) -> Int? {
        var quote: UInt8?
        var i = from
        while i < u.count {
            let b = u[i]
            if let q = quote {
                if b == q { quote = nil }
            } else if b == UInt8(ascii: "\"") || b == UInt8(ascii: "'") {
                quote = b
            } else if b == UInt8(ascii: ">") {
                return i
            } else if b == UInt8(ascii: "<") {
                return nil   // a tag inside a tag: doubt
            }
            i += 1
        }
        return nil
    }

    private static func hasPrefix(_ u: [UInt8], _ i: Int, _ p: String) -> Bool {
        let b = Array(p.utf8)
        return i + b.count <= u.count && Array(u[i..<(i + b.count)]) == b
    }

    private static func find(_ u: [UInt8], _ p: String, from: Int) -> Int? {
        var i = from
        while i < u.count {
            if hasPrefix(u, i, p) { return i }
            i += 1
        }
        return nil
    }
}
