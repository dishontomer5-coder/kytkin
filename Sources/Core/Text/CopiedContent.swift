// P3-44 (owner tests 2026-11-16: Slack bold + @mention pill + emoji, and Gmail bold, were pasted back as plain text by the
// P3-37 clipboard convert, losing the bold, the mention and the emoji): is what ⌘A ⌘C just copied *rich*? Rich content is
// never replaced by a plain-text paste; the caller converts only the typed run (keys) or just switches the language.
// Pure and conservative: anything it can't vouch for as "plain text runs and line breaks" counts as rich.
//
//   - More than one pasteboard item, or an image / file / URL / RTFD / web-archive type → rich.
//   - HTML (`public.html`, as Chromium writes for a contenteditable copy): only `html head body meta span div p br` tags
//     (plus comments and `<!DOCTYPE>`), and on them only harmless attributes: `style` without bold (≥ 600) / italic /
//     underline / strike-through / monospace / sub- or superscript; `class`, `id`, `data-*` and `aria-*` without a
//     word that names rich content (mention, emoji, link, code, bold…); `dir`, `lang`, `charset`, `content`,
//     `http-equiv`, `name`, `translate`, `spellcheck`, `contenteditable`. Anything else (`b`, `strong`, `a`, `img`,
//     `code`, `ul`, `li`, `blockquote`, Slack's `data-stringify-type="mention"`…) → rich. Bigger than 2 MB or not UTF-8 → rich.
//   - No HTML but RTF: rich when it uses a formatting / object control word (`\b`, `\i`, `\ul`, `\strike`, `\field`,
//     `\pict`, `\super`, `\sub`, list words, `\NeXTGraphic`, `\attachment`; not their `0` "off" forms).
//   - Plain text only → not rich (the paste is what it was before P3-44).
//
// P3-46 (owner retest 2026-11-16: Slack box with 😂 + a mention pill `@Tomer Dishon` + bold was judged plain and pasted:
// the pill fell apart, `Dishon` converted, the emoji came back as another one). Slack's composer copy does not carry an
// HTML flavour Kytkin can vouch for (its rich data travels as its own web-custom data, or not at all), so "no HTML" can't
// mean "plain". `verdict(_:text:app:)` is stricter and explains itself (`Reason`, enum names only, for the DEBUG trace):
//   - any type that is not plain text, HTML, RTF or Chromium's copy metadata (`org.chromium.source-url`, the internal
//     source token) → rich (`unknownType`): `org.chromium.web-custom-data` (an app's own clipboard format), Slack's
//     private types, anything new;
//   - chat apps (Slack, Discord, Teams): plain only with positive evidence: an HTML flavour that passes the plain check
//     *and* a plain text with no mention-like `@word` / `#word`, `:shortcode:` or web address. No HTML → rich;
//   - other apps (browsers, unseeded apps): HTML / RTF as above; plain text only → rich when the text holds a mention-like
//     token, a shortcode or a web address (a pill or chip the copy flattened), else plain.

// Privacy: reads the copied data in memory for this one convert only; nothing is logged or kept (B12).

import Foundation

enum CopiedContent {
    static let maxAnalyzedBytes = 2 * 1024 * 1024

    static let htmlTypes: Set<String> = ["public.html", "Apple HTML pasteboard type"]
    static let rtfTypes: Set<String> = ["public.rtf", "NeXT Rich Text Format v1.0 pasteboard type"]
    /// Types that are rich by themselves (an image of an emoji, a file, a link, attachments).
    static let richTypes: Set<String> = [
        "public.png", "public.tiff", "public.jpeg", "public.heic", "com.compuserve.gif", "public.svg-image",
        "com.adobe.pdf", "public.file-url", "public.url", "public.url-name", "com.apple.flat-rtfd", "com.apple.rtfd",
        "NeXT RTFD pasteboard type", "com.apple.webarchive", "Apple Web Archive pasteboard type",
        "NSFilenamesPboardType", "Apple URL pasteboard type", "NeXT TIFF v4.0 pasteboard type",
    ]

    static let plainTags: Set<String> = ["html", "head", "body", "meta", "span", "div", "p", "br"]
    static let plainAttributes: Set<String> = ["dir", "lang", "charset", "content", "http-equiv", "name", "translate",
                                               "spellcheck", "contenteditable"]
    /// Words in a class, id, data-* or aria-* name or value that name rich content.
    static let richWords = ["mention", "emoji", "link", "code", "bold", "italic", "strike", "underline", "quote",
                            "list", "pill", "channel", "usergroup", "broadcast", "image", "img", "url", "emoticon"]

    /// P3-46: how strict the verdict is for the app the copy came from.
    enum AppKind: Sendable, Equatable {
        /// Slack, Discord, Teams: rich unless proven plain.
        case chat
        /// Everything else.
        case other
    }

    /// P3-46 / P3-60: the chat apps (`ReplacementCapabilities.chatAppBundleIDs`, the one list) are `.chat`.
    static func appKind(bundleID: String) -> AppKind {
        ReplacementCapabilities.isChatApp(bundleID) ? .chat : .other
    }

    /// P3-46: Chromium's copy metadata (where the copy came from), never content.
    static let chromiumMetaTypes: Set<String> = ["org.chromium.source-url", "org.chromium.internal.source-rfh-token",
                                                 "org.chromium.chromium-renderer-initiated-paste"]
    static let plainTypes: Set<String> = ["public.utf8-plain-text", "public.utf16-plain-text",
                                          "public.utf16-external-plain-text", "public.plain-text", "public.text",
                                          "NSStringPboardType"]
    /// P3-44 / P3-46: the transient / concealed markers (nspasteboard.org) are flags, not content.
    static let markerTypes: Set<String> = ["org.nspasteboard.TransientType", "org.nspasteboard.ConcealedType",
                                           "org.nspasteboard.AutoGeneratedType", "org.nspasteboard.source"]

    /// P3-46: why a copy is rich or plain (for the DEBUG trace; enum names only).
    enum Reason: String, Sendable, Equatable {
        case plainHTML, plainRTF, plainText
        case multipleItems, richType, unknownType, richHTML, richRTF, noHTMLInChatApp, tokenInText
    }

    struct Verdict: Sendable, Equatable {
        let isRich: Bool
        let reason: Reason
    }

    /// P3-46: the type categories of a copy, as counts (never names of private types, never data), for the DEBUG trace.
    struct TypeCounts: Sendable, Equatable, CustomStringConvertible {
        var html = 0, rtf = 0, plain = 0, chromiumCustom = 0, chromiumMeta = 0, privateType = 0, image = 0, other = 0
        var items = 0
        var description: String {
            "items=\(items) html=\(html) rtf=\(rtf) plain=\(plain) chromiumCustom=\(chromiumCustom) "
                + "chromiumMeta=\(chromiumMeta) private=\(privateType) image=\(image) other=\(other)"
        }
    }

    static func typeCounts(_ items: [[PasteboardEntry]]) -> TypeCounts {
        var c = TypeCounts()
        c.items = items.count
        for e in items.joined() {
            let t = e.type
            if htmlTypes.contains(t) { c.html += 1 }
            else if rtfTypes.contains(t) { c.rtf += 1 }
            else if plainTypes.contains(t) || markerTypes.contains(t) { c.plain += 1 }
            else if t == "org.chromium.web-custom-data" { c.chromiumCustom += 1 }
            else if chromiumMetaTypes.contains(t) { c.chromiumMeta += 1 }
            else if t.hasPrefix("public.image") || ["public.png", "public.tiff", "public.jpeg", "public.heic",
                                                    "com.compuserve.gif"].contains(t) { c.image += 1 }
            else if t.hasPrefix("public.") || t.hasPrefix("com.apple.") || t.hasPrefix("NS") || t.hasPrefix("Apple ")
                        || t.hasPrefix("NeXT ") { c.other += 1 }
            else { c.privateType += 1 }
        }
        return c
    }

    /// P3-46: the strict verdict (see the header). `text` is the copied plain text (memory only).
    static func verdict(_ items: [[PasteboardEntry]], text: String, app: AppKind) -> Verdict {
        guard items.count <= 1 else { return Verdict(isRich: true, reason: .multipleItems) }
        var html: Data?
        var rtf: Data?
        for e in items.first ?? [] {
            if richTypes.contains(e.type) || e.type.hasPrefix("public.image") {
                return Verdict(isRich: true, reason: .richType)
            }
            if htmlTypes.contains(e.type) {
                if html == nil { html = e.data }
            } else if rtfTypes.contains(e.type) {
                if rtf == nil { rtf = e.data }
            } else if !plainTypes.contains(e.type), !markerTypes.contains(e.type),
                      !chromiumMetaTypes.contains(e.type) {
                return Verdict(isRich: true, reason: .unknownType)
            }
        }
        if let html, htmlIsRich(html) { return Verdict(isRich: true, reason: .richHTML) }
        if html == nil, let rtf, rtfIsRich(rtf) { return Verdict(isRich: true, reason: .richRTF) }
        if app == .chat, html == nil { return Verdict(isRich: true, reason: .noHTMLInChatApp) }
        if textHasRichToken(text) { return Verdict(isRich: true, reason: .tokenInText) }
        return Verdict(isRich: false, reason: html != nil ? .plainHTML : rtf != nil ? .plainRTF : .plainText)
    }

    /// P3-46: the plain text holds something a copy may have flattened: a mention-like `@word` / `#word` (at a word's
    /// start, followed by a letter or digit), a `:shortcode:`, or a web address.
    static func textHasRichToken(_ text: String) -> Bool {
        let words = text.split(whereSeparator: { $0.isWhitespace || $0.isNewline })
        for w in words {
            if let f = w.first, f == "@" || f == "#", w.count > 1,
               let second = w.dropFirst().first, second.isLetter || second.isNumber { return true }
            if w.contains("://") || w.lowercased().hasPrefix("www.") { return true }
            // `:code:` inside the word: 1+ ASCII letters / digits / `_` `+` `-` between two colons.
            let c = Array(w)
            var a = 0
            while a < c.count {   // bounded: `a` only moves forward
                guard c[a] == ":" else { a += 1; continue }
                var b = a + 1
                while b < c.count, c[b].isASCII, c[b].isLetter || c[b].isNumber || "_+-".contains(c[b]) { b += 1 }
                if b < c.count, c[b] == ":", b > a + 1 { return true }
                a = max(b, a + 1)
            }
        }
        return false
    }

    /// P3-47: alternate representations a browser writes next to the HTML (the same content), allowed for a
    /// formatting-preserving paste: RTF, web archives, Chromium's copy metadata, Mozilla's own flavours except custom
    /// page data.
    static let alternateTypes: Set<String> = ["com.apple.webarchive", "Apple Web Archive pasteboard type"]

    /// P3-47: the copied HTML when the copy may get a formatting-preserving paste: one item, an HTML flavour (UTF-8, ≤
    /// the analysis cap), and besides it only plain text, markers, RTF, web archives, Chromium copy metadata or
    /// Mozilla flavours (not `org.mozilla.custom-clipdata`: a page's own data). nil = not eligible.
    static func htmlForFormattingPaste(_ items: [[PasteboardEntry]]) -> String? {
        guard items.count == 1, let item = items.first else { return nil }
        var html: String?
        for e in item {
            if htmlTypes.contains(e.type) {
                guard html == nil, e.data.count <= maxAnalyzedBytes, let s = String(data: e.data, encoding: .utf8) else {
                    return nil
                }
                // P3-49 (owner: Gmail in Zen, `htmlPaste=refused(nothingToConvert)`): Gecko writes its HTML flavour as a
                // C string, with a terminating NUL. In the HTML's text that NUL is a control character, which
                // `BoxConversion` treats as a hard stop: the segment holding the "caret" (the end) was empty, so
                // nothing converted. Trailing NULs are not content: dropped here.
                var trimmed = Substring(s)
                while trimmed.last == "\u{0}" { trimmed = trimmed.dropLast() }
                html = String(trimmed)
            } else if plainTypes.contains(e.type) || markerTypes.contains(e.type) || rtfTypes.contains(e.type)
                        || alternateTypes.contains(e.type) || chromiumMetaTypes.contains(e.type)
                        || (e.type.hasPrefix("org.mozilla.") && e.type != "org.mozilla.custom-clipdata") {
                continue
            } else {
                return nil
            }
        }
        return html
    }

    // MARK: - HTML

    static func htmlIsRich(_ data: Data) -> Bool {
        guard data.count <= maxAnalyzedBytes, let s = String(data: data, encoding: .utf8) else { return true }
        let u = Array(s.utf8)
        var i = 0
        while i < u.count {   // bounded: every pass moves `i` forward
            guard u[i] == UInt8(ascii: "<") else { i += 1; continue }
            if hasPrefix(u, at: i, "<!--") {
                guard let end = find(u, "-->", from: i + 4) else { return true }
                i = end + 3
                continue
            }
            guard let close = tagEnd(u, from: i + 1) else { return true }
            let inner = String(decoding: u[(i + 1)..<close], as: UTF8.self)
            i = close + 1
            if inner.hasPrefix("!") || inner.hasPrefix("?") { continue }   // <!DOCTYPE …>, <?xml …?>
            if !tagIsPlain(inner) { return true }
        }
        return false
    }

    /// One tag's inside (between `<` and `>`).
    private static func tagIsPlain(_ inner: String) -> Bool {
        var body = Substring(inner)
        let closing = body.hasPrefix("/")
        if closing { body = body.dropFirst() }
        let name = body.prefix { $0.isLetter || $0.isNumber }.lowercased()
        guard plainTags.contains(name) else { return false }
        if closing { return true }
        return attributes(String(body.dropFirst(name.count))).allSatisfy { attributeIsPlain(name: $0.0, value: $0.1) }
    }

    private static func attributeIsPlain(name: String, value: String) -> Bool {
        let n = name.lowercased()
        let v = value.lowercased()
        if n == "style" { return styleIsPlain(v) }
        if n == "class" || n == "id" || n.hasPrefix("data-") || n.hasPrefix("aria-") {
            return !richWords.contains { n.contains($0) || v.contains($0) }
        }
        return plainAttributes.contains(n)
    }

    /// A `style` value: rich when it makes text bold, italic, underlined, struck through, monospace or sub/superscript.
    static func styleIsPlain(_ style: String) -> Bool {
        for declaration in style.split(separator: ";") {
            let parts = declaration.split(separator: ":", maxSplits: 1)
            guard parts.count == 2 else { continue }
            let prop = parts[0].trimmingCharacters(in: .whitespaces).lowercased()
            let value = parts[1].trimmingCharacters(in: .whitespaces).lowercased()
            switch prop {
            case "font-weight":
                if value.hasPrefix("bold") || (Int(value) ?? 0) >= 600 { return false }
            case "font-style":
                if value.contains("italic") || value.contains("oblique") { return false }
            case "text-decoration", "text-decoration-line":
                if ["underline", "line-through", "overline"].contains(where: value.contains) { return false }
            case "font-family":
                if ["mono", "courier", "menlo", "consolas", "monaco"].contains(where: value.contains) { return false }
            case "vertical-align":
                if value.hasPrefix("sub") || value.hasPrefix("super") { return false }
            default:
                continue
            }
        }
        return true
    }

    /// `name`, `name=value`, `name="value"`, `name='value'` pairs (values unescaped only as far as needed here).
    private static func attributes(_ s: String) -> [(String, String)] {
        var out: [(String, String)] = []
        let c = Array(s)
        var i = 0
        func skipSpace() { while i < c.count, c[i].isWhitespace || c[i] == "/" { i += 1 } }
        while true {   // bounded: each pass consumes ≥ 1 character or stops
            skipSpace()
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

    /// The `>` closing a tag that starts at `from`, skipping quoted attribute values.
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
            }
            i += 1
        }
        return nil
    }

    private static func hasPrefix(_ u: [UInt8], at i: Int, _ p: String) -> Bool {
        let b = Array(p.utf8)
        return i + b.count <= u.count && Array(u[i..<(i + b.count)]) == b
    }

    private static func find(_ u: [UInt8], _ p: String, from: Int) -> Int? {
        var i = from
        while i < u.count {
            if hasPrefix(u, at: i, p) { return i }
            i += 1
        }
        return nil
    }

    // MARK: - RTF

    static let richRTFWords: Set<String> = ["b", "i", "ul", "uld", "uldb", "ulw", "ulth", "uldash", "ulwave", "strike",
                                            "striked", "field", "fldinst", "pict", "shppict", "object", "super", "sub",
                                            "listtext", "pntext", "ls", "NeXTGraphic", "attachment"]

    static func rtfIsRich(_ data: Data) -> Bool {
        guard data.count <= maxAnalyzedBytes else { return true }
        let u = Array(data)
        var i = 0
        while i < u.count {   // bounded: every pass moves `i` forward
            guard u[i] == UInt8(ascii: "\\") else { i += 1; continue }
            i += 1
            let start = i
            while i < u.count, (u[i] >= 0x41 && u[i] <= 0x5A) || (u[i] >= 0x61 && u[i] <= 0x7A) { i += 1 }
            guard i > start else { i += 1; continue }   // a control symbol such as \\ or \{
            let word = String(decoding: u[start..<i], as: UTF8.self)
            let pStart = i
            if i < u.count, u[i] == UInt8(ascii: "-") { i += 1 }
            while i < u.count, u[i] >= 0x30, u[i] <= 0x39 { i += 1 }
            let param = String(decoding: u[pStart..<i], as: UTF8.self)
            if richRTFWords.contains(word), param != "0" { return true }
        }
        return false
    }
}
