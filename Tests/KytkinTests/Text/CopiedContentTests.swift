// P3-44: `CopiedContent.isRich`, the "never paste plain text over rich content" decision, over hand-written pasteboard
// data shaped like what Chromium / Slack / Gmail / Cocoa put there (written for the tests; nothing read from a real
// clipboard).

import XCTest

final class CopiedContentTests: XCTestCase {
    /// P3-53: the verdict for a non-chat app with token-free text (the old `isRich` is gone).
    private func isRich(_ items: [[PasteboardEntry]]) -> Bool {
        CopiedContent.verdict(items, text: "x", app: .other).isRich
    }

    private let plain = PasteboardEntry(type: "public.utf8-plain-text", data: Data("x".utf8))

    private func rich(_ html: String) -> Bool {
        isRich([[plain, .html(html)]])
    }

    func testPlainTextOnlyIsNotRich() {
        XCTAssertFalse(isRich([[plain]]))
        XCTAssertFalse(isRich([]))
    }

    func testChromiumPlainContentEditableCopyIsNotRich() {
        // Chromium's inline computed styles on a plain run: font-weight 400, font-style normal, text-decoration-* initial.
        XCTAssertFalse(rich("""
            <span style="color: rgb(29, 28, 29); font-family: Slack-Lato, sans-serif; font-size: 15px; \
            font-style: normal; font-weight: 400; text-decoration-thickness: initial; text-decoration-style: initial; \
            text-decoration-color: initial; background-color: rgb(255, 255, 255);">akuo vh</span>
            """))
        XCTAssertFalse(rich("<!--StartFragment--><div dir=\"rtl\">שלום</div><div><br></div><p>vh</p><!--EndFragment-->"))
        XCTAssertFalse(rich("<html><head></head><body><span class=\"c-texty_input\" data-qa=\"message_input\">x</span></body></html>"))
    }

    func testOwnersSlackBoxIsRich() {
        // Bold, a mention pill and an emoji image: each alone makes it rich.
        XCTAssertTrue(rich("<b data-stringify-type=\"bold\">שלום</b> akuo"))
        XCTAssertTrue(rich("<span data-stringify-type=\"mention\" data-user-id=\"U1\">@Hillel Banai</span>"))
        XCTAssertTrue(rich("<img data-stringify-type=\"emoji\" data-stringify-emoji=\":joy:\" alt=\":joy:\" src=\"x.png\">"))
        XCTAssertTrue(rich("<span class=\"c-member_slug c-member_slug--link\">@Hillel</span>"))
    }

    func testGmailBoldIsRich() {
        // P3-44 (owner, checklist §P3-42 step 2/4): Gmail compose with one bold word.
        XCTAssertTrue(rich("<div dir=\"ltr\"><b>שלום</b> akuo vh</div>"))
        XCTAssertTrue(rich("<span style=\"font-weight:700\">שלום</span> akuo"))
        XCTAssertTrue(rich("<span style=\"font-weight: bold\">x</span>"))
    }

    func testOtherFormattingIsRich() {
        XCTAssertTrue(rich("<a href=\"https://example.com\">link</a>"))
        XCTAssertTrue(rich("<code>x</code>"))
        XCTAssertTrue(rich("<ul><li>x</li></ul>"))
        XCTAssertTrue(rich("<i>x</i>"))
        XCTAssertTrue(rich("<span style=\"font-style: italic\">x</span>"))
        XCTAssertTrue(rich("<span style=\"text-decoration: line-through\">x</span>"))
        XCTAssertTrue(rich("<span style=\"font-family: Menlo, monospace\">x</span>"))
        XCTAssertTrue(rich("<span title=\"x\">x</span>"), "an unknown attribute")
        XCTAssertFalse(rich("<span>x"), "an unclosed element's body is just text")
        XCTAssertTrue(rich("<span style=\"x\""), "an unterminated tag")
        XCTAssertTrue(rich("<!-- unterminated comment"))
    }

    func testRichTypesAndItems() {
        XCTAssertTrue(isRich([[plain, PasteboardEntry(type: "public.png", data: Data([1]))]]))
        XCTAssertTrue(isRich([[plain], [plain]]), "two items")
        XCTAssertTrue(isRich([[plain, PasteboardEntry(type: "public.html", data: Data([0xFF, 0xFE]))]]),
                      "HTML that isn't UTF-8")
    }

    func testRTF() {
        func rtf(_ s: String) -> Bool {
            isRich([[plain, PasteboardEntry(type: "public.rtf", data: Data(s.utf8))]])
        }
        XCTAssertFalse(rtf("{\\rtf1\\ansi\\ansicpg1252\\cocoartf2761 {\\fonttbl\\f0\\fswiss Helvetica;}"
                           + "\\pard\\pardirnatural\\partightenfactor0 \\f0\\fs24 \\cf0 akuo vh}"))
        XCTAssertTrue(rtf("{\\rtf1 \\b akuo\\b0 vh}"))
        XCTAssertFalse(rtf("{\\rtf1 \\b0 akuo}"), "bold off only")
        XCTAssertTrue(rtf("{\\rtf1 {\\field{\\*\\fldinst HYPERLINK \"x\"}}}"))
        XCTAssertTrue(rtf("{\\rtf1 \\ul x\\ulnone}"))
    }

    func testTypedRunAtEndOfTheCopiedBox() {
        // P3-44 QA: the typed run converts by Backspace at the end of the box only when the copy ends with it.
        XCTAssertTrue(ClipboardConvert.typedRunIsAtEnd(of: "שלום @Hillel Banai :joy:\nakuo vh", typedTail: "akuo vh"))
        XCTAssertTrue(ClipboardConvert.typedRunIsAtEnd(of: "vh akuo vh", typedTail: "vh"), "an earlier copy doesn't matter")
        XCTAssertFalse(ClipboardConvert.typedRunIsAtEnd(of: "akuo vh\n", typedTail: "akuo vh"), "a trailing line break")
        XCTAssertFalse(ClipboardConvert.typedRunIsAtEnd(of: "akuo vh ", typedTail: "akuo vh"), "a trailing space")
        XCTAssertFalse(ClipboardConvert.typedRunIsAtEnd(of: "vh", typedTail: "akuo vh"), "longer than the box")
        XCTAssertFalse(ClipboardConvert.typedRunIsAtEnd(of: "vh", typedTail: ""))
        XCTAssertFalse(ClipboardConvert.typedRunIsAtEnd(of: "vh", typedTail: nil))
        // Slack turned the typed `:joy:` into one emoji, but the plain copy still reads `:joy:`: 5 Backspaces would
        // delete the emoji and four characters before it.
        XCTAssertFalse(ClipboardConvert.typedRunIsAtEnd(of: "akuo :joy:", typedTail: ":joy:"))
        XCTAssertFalse(ClipboardConvert.typedRunIsAtEnd(of: "akuo vh :)", typedTail: "vh :)"))
    }

    // MARK: - P3-46: the strict verdict

    private func entry(_ type: String, _ s: String = "x") -> PasteboardEntry {
        PasteboardEntry(type: type, data: Data(s.utf8))
    }

    func testSlackPlainOnlyCopyIsRich() {
        // P3-46 owner retest: Slack's copy of 😂 + pill + bold carried no HTML Kytkin can vouch for.
        let v = CopiedContent.verdict([[plain]], text: "@Tomer Dishon :joy: תומר\nakuo vh", app: .chat)
        XCTAssertEqual(v, .init(isRich: true, reason: .noHTMLInChatApp))
        XCTAssertEqual(CopiedContent.verdict([[plain]], text: "akuo vh", app: .chat).reason, .noHTMLInChatApp,
                       "no HTML in a chat app is never proof of plain text")
    }

    func testPrivateAndCustomTypesAreRich() {
        XCTAssertEqual(CopiedContent.verdict([[plain, entry("org.chromium.web-custom-data")]], text: "akuo",
                                             app: .other).reason, .unknownType)
        XCTAssertEqual(CopiedContent.verdict([[plain, entry("com.tinyspeck.slack.texty")]], text: "akuo",
                                             app: .other).reason, .unknownType)
        XCTAssertEqual(CopiedContent.verdict([[plain, .html("<span>akuo</span>"), entry("org.chromium.source-url")]],
                                             text: "akuo", app: .chat), .init(isRich: false, reason: .plainHTML),
                       "Chromium's copy metadata is not content")
    }

    func testTokensInTheCopiedTextAreRich() {
        let html = PasteboardEntry.html("<span>x</span>")
        for text in ["@Tomer Dishon akuo", "akuo #general", "akuo :joy:", "see https://example.com", "www.example.com"] {
            XCTAssertEqual(CopiedContent.verdict([[plain, html]], text: text, app: .chat).reason, .tokenInText, text)
            XCTAssertEqual(CopiedContent.verdict([[plain]], text: text, app: .other).reason, .tokenInText, text)
        }
        for text in ["akuo vh", "a@b.com", "# heading", "12:30", ":: x", "@ x"] {
            XCTAssertFalse(CopiedContent.verdict([[plain]], text: text, app: .other).isRich, text)
        }
        XCTAssertEqual(CopiedContent.verdict([[plain, html]], text: "akuo vh", app: .chat),
                       .init(isRich: false, reason: .plainHTML), "proven plain in a chat app")
    }

    func testAppKindAndTypeCounts() {
        XCTAssertEqual(CopiedContent.appKind(bundleID: "com.tinyspeck.slackmacgap"), .chat)
        XCTAssertEqual(CopiedContent.appKind(bundleID: "com.hnc.Discord"), .chat)
        XCTAssertEqual(CopiedContent.appKind(bundleID: "com.google.Chrome"), .other)
        let c = CopiedContent.typeCounts([[plain, .html("x"), entry("public.rtf"), entry("org.chromium.web-custom-data"),
                                           entry("org.chromium.source-url"), entry("com.tinyspeck.private"),
                                           entry("public.png"), entry("public.utf16-plain-text")]])
        XCTAssertEqual("\(c)", "items=1 html=1 rtf=1 plain=2 chromiumCustom=1 chromiumMeta=1 private=1 image=1 other=0")
    }
}
