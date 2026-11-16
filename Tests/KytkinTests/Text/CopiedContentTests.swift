// P3-44: `CopiedContent.isRich`, the "never paste plain text over rich content" decision, over hand-written pasteboard
// data shaped like what Chromium / Slack / Gmail / Cocoa put there (written for the tests; nothing read from a real
// clipboard).

import XCTest

final class CopiedContentTests: XCTestCase {
    private let plain = PasteboardEntry(type: "public.utf8-plain-text", data: Data("x".utf8))

    private func rich(_ html: String) -> Bool {
        CopiedContent.isRich([[plain, .html(html)]])
    }

    func testPlainTextOnlyIsNotRich() {
        XCTAssertFalse(CopiedContent.isRich([[plain]]))
        XCTAssertFalse(CopiedContent.isRich([]))
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
        XCTAssertTrue(CopiedContent.isRich([[plain, PasteboardEntry(type: "public.png", data: Data([1]))]]))
        XCTAssertTrue(CopiedContent.isRich([[plain], [plain]]), "two items")
        XCTAssertTrue(CopiedContent.isRich([[plain, PasteboardEntry(type: "public.html", data: Data([0xFF, 0xFE]))]]),
                      "HTML that isn't UTF-8")
    }

    func testRTF() {
        func rtf(_ s: String) -> Bool {
            CopiedContent.isRich([[plain, PasteboardEntry(type: "public.rtf", data: Data(s.utf8))]])
        }
        XCTAssertFalse(rtf("{\\rtf1\\ansi\\ansicpg1252\\cocoartf2761 {\\fonttbl\\f0\\fswiss Helvetica;}"
                           + "\\pard\\pardirnatural\\partightenfactor0 \\f0\\fs24 \\cf0 akuo vh}"))
        XCTAssertTrue(rtf("{\\rtf1 \\b akuo\\b0 vh}"))
        XCTAssertFalse(rtf("{\\rtf1 \\b0 akuo}"), "bold off only")
        XCTAssertTrue(rtf("{\\rtf1 {\\field{\\*\\fldinst HYPERLINK \"x\"}}}"))
        XCTAssertTrue(rtf("{\\rtf1 \\ul x\\ulnone}"))
    }
}
