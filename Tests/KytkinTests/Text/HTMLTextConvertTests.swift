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

    func testPageCategory() {
        // P3-50: the convert's own page check (the address is reduced to a category and dropped).
        XCTAssertEqual(PageCategory.of(url: "https://mail.google.com/mail/u/0/#inbox?compose=new"), .webmail,
                       "P3-53 QA: an ordinary page that is webmail")
        XCTAssertEqual(PageCategory.of(url: "https://outlook.office.com/mail/"), .wholeDocument,
                       "office.com is a whole-document host already (blocked outright)")
        XCTAssertEqual(PageCategory.of(url: "https://outlook.live.com/mail/0/"), .webmail)
        XCTAssertEqual(PageCategory.of(url: "https://mail.example.com/"), .ordinary)
        XCTAssertTrue(PageCategory.webmail.isOrdinary)
        XCTAssertFalse(PageCategory.isWebmail(host: nil))
        XCTAssertFalse(PageCategory.isWebmail(host: "notmail.google.com.evil.com"))
        XCTAssertEqual(PageCategory.of(url: "https://docs.google.com/document/d/x/edit"), .wholeDocument)
        XCTAssertEqual(PageCategory.of(url: "https://x.sharepoint.com/sites/y"), .wholeDocument)
        XCTAssertEqual(PageCategory.of(url: "http://example.com"), .ordinary)
        XCTAssertEqual(PageCategory.of(url: "about:blank"), .unknown)
        XCTAssertEqual(PageCategory.of(url: "file:///tmp/x.html"), .unknown)
        XCTAssertEqual(PageCategory.of(url: ""), .unknown)
    }


    func testPageCategoryOfTheWebAreaChain() {
        // P3-50 QA: innermost first.
        let gmail = "https://mail.google.com/mail/u/0/"
        let docs = "https://docs.google.com/document/d/x/edit"
        XCTAssertEqual(PageCategory.of(webAreaURLs: [gmail], reachedTop: true), .webmail)
        XCTAssertEqual(PageCategory.of(webAreaURLs: ["about:blank", gmail], reachedTop: true), .webmail,
                       "an about:blank editor iframe inside an ordinary page")
        XCTAssertEqual(PageCategory.of(webAreaURLs: [gmail, "chrome://browser/content/browser.xhtml"], reachedTop: true),
                       .webmail, "a browser's own UI web area says nothing")
        XCTAssertEqual(PageCategory.of(webAreaURLs: ["https://example.com/a"], reachedTop: true), .ordinary)
        XCTAssertEqual(PageCategory.of(webAreaURLs: [docs, "https://example.com/blog"], reachedTop: true),
                       .wholeDocument, "Docs in an iframe of an ordinary page")
        XCTAssertEqual(PageCategory.of(webAreaURLs: ["https://example.com", docs], reachedTop: true), .wholeDocument)
        XCTAssertEqual(PageCategory.of(webAreaURLs: [nil, gmail], reachedTop: true), .unknown, "an unreadable area")
        XCTAssertEqual(PageCategory.of(webAreaURLs: [gmail], reachedTop: false), .unknown, "the top wasn't reached")
        XCTAssertEqual(PageCategory.of(webAreaURLs: [docs], reachedTop: false), .wholeDocument)
        XCTAssertEqual(PageCategory.of(webAreaURLs: [], reachedTop: true), .unknown)
        XCTAssertEqual(PageCategory.of(webAreaURLs: ["about:blank"], reachedTop: true), .unknown)
    }

    // MARK: - P3-48: Gmail quoted thread and signature

    private func box(_ html: String, _ plain: String) -> Swift.Result<HTMLTextConvert.Output, HTMLTextConvert.Refusal> {
        HTMLTextConvert.convert(html: html, plain: plain, skipQuotes: true, planner: planner)
    }

    static let reply = """
        <div dir="ltr">akuo vh</div><br><div class="gmail_quote gmail_quote_container"><div dir="ltr" \
        class="gmail_attr">On Mon, Nov 16, 2026 at 10:00 AM X &lt;x@y.com&gt; wrote:<br></div><blockquote \
        class="gmail_quote" style="margin:0px 0px 0px 0.8ex;border-left:1px solid rgb(204,204,204);padding-left:1ex">\
        <div dir="ltr">nv nmc</div></blockquote></div>
        """
    static let replyPlain = "akuo vh\n\nOn Mon, Nov 16, 2026 at 10:00 AM X <x@y.com> wrote:\n\nnv nmc"

    func testAGmailReplyConvertsOnlyWhatTheUserWrote() {
        let r = box(Self.reply, Self.replyPlain)
        XCTAssertEqual(r, .success(.init(
            html: Self.reply.replacingOccurrences(of: ">akuo vh<", with: ">שלום הי<"),
            plain: "שלום הי\n\nOn Mon, Nov 16, 2026 at 10:00 AM X <x@y.com> wrote:\n\nnv nmc")),
            "the quote is byte for byte, its English never converted and never deciding the direction")
    }

    func testTheQuoteNeverDecidesTheDirection() {
        // The box ends in the quote's English letters; without skipping them they would decide English → Hebrew and
        // convert the quote. Skipped, the user's own Hebrew word decides.
        let html = "<div dir=\"rtl\">שלום</div><blockquote>nv nmc</blockquote>"
        XCTAssertEqual(box(html, "שלום\nnv nmc"),
                       .success(.init(html: "<div dir=\"rtl\">akuo</div><blockquote>nv nmc</blockquote>",
                                      plain: "akuo\nnv nmc")))
    }

    func testAGmailSignatureIsLeftAlone() {
        let html = """
            <div dir="ltr">akuo<br clear="all"><br><span class="gmail_signature_prefix">-- </span><br>\
            <div dir="ltr" class="gmail_signature" data-smartmail="gmail_signature">Tomer Dishon<img src="x.png"></div></div>
            """
        let r = box(html, "akuo\n\n-- \nTomer Dishon")
        XCTAssertEqual(r, .success(.init(html: html.replacingOccurrences(of: ">akuo<", with: ">שלום<"),
                                         plain: "שלום\n\n-- \nTomer Dishon")))
    }

    func testASelectionInsideTheQuoteStillConverts() {
        // skipQuotes is only for the whole box.
        let html = "<blockquote class=\"gmail_quote\"><div dir=\"ltr\">nv nmc</div></blockquote>"
        XCTAssertEqual(convert(html, "nv nmc"),
                       .success(.init(html: html.replacingOccurrences(of: "nv nmc", with: "מה מצב"), plain: "מה מצב")))
    }

    func testActiveContentInsideAQuoteIsStillRefused() {
        XCTAssertEqual(box("<div>akuo</div><div class=\"gmail_quote\"><script>x</script></div>", "akuo\nx"),
                       .failure(.unsupportedTag))
        XCTAssertEqual(box("<div>akuo</div><div class=\"gmail_quote\"><div>x</div>", "akuo\nx"), .failure(.parse),
                       "an unclosed quote")
    }

    func testQuotedReplyBoundaries() {
        func b(_ s: String) -> Int? { QuotedReply.boundary(in: s) }
        XCTAssertEqual(b("akuo\n\nOn Mon, Nov 16 at 10:00 X <x@y.com> wrote:\n> nv"), 6)
        XCTAssertEqual(b("akuo\nOn Mon, Nov 16, 2026 at 10:00 AM Very Long Name <x@y.com>\nwrote:\nnv"), 5, "wrapped")
        XCTAssertEqual(b("akuo\n\u{200F}בתאריך יום ב׳, 16 בנוב׳ 2026 ב-10:00 מאת X <x@y.com>\u{200F} כתב/ה:\nnv"), 5)
        XCTAssertEqual(b("akuo\n\n---------- Forwarded message ---------\nFrom: X"), 6)
        XCTAssertEqual(b("akuo\n> nv"), 5)
        XCTAssertEqual(b("akuo\n-- \nTomer"), 5, "the signature delimiter")
        XCTAssertNil(b("akuo vh\nnv nmc"))
        XCTAssertNil(b("on the way, I wrote: x"), "an ordinary sentence")
    }

    // MARK: - P3-48 QA

    func testAQuoteTextNeverProtectsTheSameWordsInTheUsersPart() {
        // The quote's text node "vh" also occurs in what the user wrote. As an atom it would keep the user's "vh" from
        // converting (atoms protect every occurrence): it is not one, and the quote's own "vh" changing refuses the paste.
        XCTAssertEqual(box("<div>akuo vh</div><blockquote>vh</blockquote>", "akuo vh\nvh"), .failure(.quoteChanged))
        // A quote text found only in the quote stays an atom: the user's words convert, the quote is untouched.
        XCTAssertEqual(box("<div>akuo vh</div><blockquote>nv nmc</blockquote>", "akuo vh\nnv nmc"),
                       .success(.init(html: "<div>שלום הי</div><blockquote>nv nmc</blockquote>",
                                      plain: "שלום הי\nnv nmc")))
    }

    func testInsideAQuoteEventHandlersAndScriptAddressesAreRefused() {
        XCTAssertEqual(box("<div>akuo</div><blockquote><div onclick=\"x()\">nv</div></blockquote>", "akuo\nnv"),
                       .failure(.unsafeAttribute))
        XCTAssertEqual(box("<div>akuo</div><blockquote><a href=\" javascript:x()\">nv</a></blockquote>", "akuo\nnv"),
                       .failure(.unsafeAttribute))
        XCTAssertEqual(box("<div>akuo</div><blockquote><base href=\"https://x\">nv</blockquote>", "akuo\nnv"),
                       .failure(.unsupportedTag))
        XCTAssertEqual(box("<div>akuo</div><blockquote><a href=\"mailto:x@y.com\">nv nmc</a></blockquote>",
                           "akuo\nnv nmc"),
                       .success(.init(html: "<div>שלום</div><blockquote><a href=\"mailto:x@y.com\">nv nmc</a></blockquote>",
                                      plain: "שלום\nnv nmc")), "a mail link in a signature stays")
    }

    func testAtomRolesAreCountedPerRole() {
        XCTAssertEqual(ConvertTrace.roleCounts([]), "-")
        XCTAssertEqual(ConvertTrace.roleCounts(["AXStaticText", "AXQuoteText", "AXQuoteText", "AXLink", "AXQuoteText"]),
                       "AXStaticText:1,AXQuoteText:3,AXLink:1")
    }

    // MARK: - P3-54: Gecko's copy of a Gmail reply keeps no class and no blockquote

    static let geckoReply = """
        <div dir="ltr">akuo vh</div><br><div><div dir="ltr">On Mon, Nov 16, 2026 at 10:00 AM X &lt;x@y.com&gt; \
        wrote:<br></div><div><div dir="ltr">nv nmc</div><div dir="ltr">nv nmc</div></div></div>
        """
    static let geckoReplyPlain = "akuo vh\n\nOn Mon, Nov 16, 2026 at 10:00 AM X <x@y.com> wrote:\nnv nmc\nnv nmc"

    func testAGeckoReplyWithoutClassesStopsAtTheQuoteHeader() {
        var stats = HTMLTextConvert.Stats()
        let r = HTMLTextConvert.convert(html: Self.geckoReply, plain: Self.geckoReplyPlain, skipQuotes: true,
                                        planner: planner, stats: &stats)
        XCTAssertEqual(r, .success(.init(
            html: Self.geckoReply.replacingOccurrences(of: ">akuo vh<", with: ">שלום הי<"),
            plain: "שלום הי\n\nOn Mon, Nov 16, 2026 at 10:00 AM X <x@y.com> wrote:\nnv nmc\nnv nmc")),
            "the quote after the header is kept byte for byte")
        XCTAssertEqual(stats, .init(blockquoteTags: 0, classAttrs: 0, gmailClassHits: 0, skippedRegions: 0,
                                    htmlBoundary: true, plainBoundary: true))
        XCTAssertEqual("\(stats)", "blockquoteTags=0 classAttrs=0 gmailClassHits=0 skippedRegions=0 quoteBoundary=html/plain")
    }

    func testAHebrewGmailHeaderWithoutWroteIsABoundary() {
        let header = "\u{202B}בתאריך יום ב׳, 16 בנוב׳ 2026 ב-10:00 מאת \u{202A}X\u{202C}\u{200F} <x@y.com>:\u{202C}"
        XCTAssertEqual(QuotedReply.boundary(in: "שלום\n\n\(header)\nakuo"), 6)
        XCTAssertNil(QuotedReply.boundary(in: "בתאריך מחר נדבר"), "an ordinary sentence")
    }

    func testABoundaryInOnlyOneTextIsRefused() {
        var stats = HTMLTextConvert.Stats()
        let r = HTMLTextConvert.convert(html: "<div>akuo</div><div>On Mon X wrote:</div>", plain: "akuo On Mon X wrote:",
                                        skipQuotes: true, planner: planner, stats: &stats)
        XCTAssertEqual(r, .failure(.quoteBoundaryMismatch))
    }
}
