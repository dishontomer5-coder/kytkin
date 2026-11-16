// P3-47: `HTMLTextConvert`, the formatting-preserving paste: only text nodes convert (same box rule as the plain text,
// link texts kept), every tag / attribute / entity is kept byte for byte, and anything it can't vouch for is refused.
// Hand-written HTML shaped like Gmail's (Chromium) and Firefox / Zen's copies; nothing read from a real clipboard.

import XCTest

final class HTMLTextConvertTests: XCTestCase {
    private let layouts = ConvertFixtures.layouts

    /// The controller's box planner (direction from the last letter).
    private func planner(_ text: String, _ atoms: [String]) -> [TextChange]? {
        let w = FieldWindow(text: text, location: 0, caret: text.utf16.count, reachesFieldStart: true,
                            reachesFieldEnd: true)
        switch BoxConversion.plan(w, classify: layouts.runClass, atomicTexts: atoms, convert: { side, g in
            self.layouts.converter(from: self.layouts.source(of: side))?.convert(g).text ?? g
        }) {
        case .nothing: return []
        case .tooLong: return nil
        case .convert(let p): return p.changes
        }
    }

    private func convert(_ html: String, _ plain: String) -> Swift.Result<HTMLTextConvert.Output, HTMLTextConvert.Refusal> {
        HTMLTextConvert.convert(html: html, plain: plain, planner: planner)
    }

    private func html(_ html: String, _ plain: String) -> String? {
        if case .success(let o) = convert(html, plain) { return o.html }
        return nil
    }

    func testGmailBoldKeepsEveryTag() {
        let r = convert("<div dir=\"ltr\"><b>שלום</b> akuo vh</div>", "שלום akuo vh")
        XCTAssertEqual(r, .success(.init(html: "<div dir=\"ltr\"><b>שלום</b> שלום הי</div>", plain: "שלום שלום הי")))
    }

    func testFirefoxCopyWithWrappers() {
        let source = """
            <html><head><meta http-equiv="content-type" content="text/html; charset=utf-8"></head><body>
            <!--StartFragment--><div style="font-family: Arial"><b>שלום</b> akuo</div><!--EndFragment-->
            </body>
            </html>
            """
        XCTAssertEqual(html(source, "שלום akuo"), source.replacingOccurrences(of: "</b> akuo", with: "</b> שלום"))
    }

    func testEntitiesStayAsTheyWere() {
        XCTAssertEqual(html("<div>akuo &amp; vh&nbsp;x</div>", "akuo & vh\u{00A0}x"),
                       "<div>שלום &amp; הי&nbsp;ס</div>")
        XCTAssertEqual(html("<p>&#97;kuo</p>", "akuo"), "<p>שלום</p>",
                       "a numeric entity that converts is written as text")
        XCTAssertEqual(HTMLTextConvert.escape("<a&b>\u{00A0}"), "&lt;a&amp;b&gt;&nbsp;", "never markup")
    }

    func testLinkTextIsNeverConverted() {
        let r = convert("<div>akuo <a href=\"https://x.example\">vh</a></div>", "akuo vh")
        XCTAssertEqual(r, .success(.init(html: "<div>שלום <a href=\"https://x.example\">vh</a></div>",
                                         plain: "שלום vh")))
    }

    func testListsAndNestedFormatting() {
        XCTAssertEqual(html("<ul><li>akuo</li><li><b><i>a</i>kuo</b></li></ul>", "akuo\nakuo"),
                       "<ul><li>שלום</li><li><b><i>ש</i>לום</b></li></ul>")
        XCTAssertEqual(html("<h2>akuo</h2><blockquote>vh</blockquote>", "akuo\nvh"),
                       "<h2>שלום</h2><blockquote>הי</blockquote>", "blocks never join words")
    }

    func testPillsEmbedsAndUnknownMarkupAreRefused() {
        XCTAssertEqual(convert("<span data-mention=\"1\">@x</span> akuo", "@x akuo"), .failure(.marker))
        XCTAssertEqual(convert("<span contenteditable=\"false\">x</span> akuo", "x akuo"), .failure(.marker))
        XCTAssertEqual(convert("<span class=\"emoji\">x</span> akuo", "x akuo"), .failure(.marker))
        XCTAssertEqual(convert("<img src=\"x.png\"> akuo", " akuo"), .failure(.unsupportedTag))
        XCTAssertEqual(convert("<script>x</script>akuo", "akuo"), .failure(.unsupportedTag))
        XCTAssertEqual(convert("<code>akuo</code>", "akuo"), .failure(.unsupportedTag))
        XCTAssertEqual(convert("<span onclick=\"x\">akuo</span>", "akuo"), .failure(.unsafeAttribute))
        XCTAssertEqual(convert("<b href=\"x\">akuo</b>", "akuo"), .failure(.unsafeAttribute))
    }

    func testParseDoubtIsRefused() {
        XCTAssertEqual(convert("<div>a < b akuo</div>", "a < b akuo"), .failure(.parse))
        XCTAssertEqual(convert("<div>&foo; akuo</div>", "&foo; akuo"), .failure(.parse))
        XCTAssertEqual(convert("<!-- x <div>akuo</div>", "akuo"), .failure(.parse))
        XCTAssertEqual(convert("<div class=\"x>akuo</div>", "akuo"), .failure(.parse))
        XCTAssertEqual(convert("<a href=\"x\">akuo", "akuo"), .failure(.parse), "an unclosed link")
    }

    func testTextThatIsNotThePlainTextIsRefused() {
        XCTAssertEqual(convert("<div>akuo</div><div>signature</div>", "akuo"), .failure(.textMismatch))
        XCTAssertEqual(convert("<div>123</div>", "123"), .failure(.nothingToConvert), "no letters")
    }

    func testABareAmpersandIsText() {
        XCTAssertEqual(html("<div>akuo & vh</div>", "akuo & vh"), "<div>שלום & הי</div>")
    }

    func testControlCharactersInTheHTMLTextAreRefusedAndGeckosNULIsTrimmed() {
        XCTAssertEqual(convert("<div>akuo\u{0}</div>", "akuo"), .failure(.controlCharacter))
        let item = [PasteboardEntry(type: "public.utf8-plain-text", data: Data("akuo".utf8)),
                    PasteboardEntry(type: "public.html", data: Data("<div>akuo</div>".utf8) + Data([0, 0]))]
        XCTAssertEqual(CopiedContent.htmlForFormattingPaste([item]), "<div>akuo</div>")
    }
}
