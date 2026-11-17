// P3-44 (owner tests 2026-11-16: Slack bold + @mention pill + 😂 + a typed line, and Gmail bold, were pasted back as
// plain text): ConvertController never pastes over rich content (the copied HTML decides; the typed run converts by
// keys when the box ends with it, else double-Shift just switches), the owner's Slack box converts through the Chromium
// AX path with the emoji drift and the mention pill, Gmail bold stays bold, and the DEBUG trace names the paths without
// any text. Fakes only: a scripted replacer, a fake Chromium box, a fake pasteboard + app, the fake clock.

import XCTest

/// Collects the DEBUG traces (called on @TextActor only).
final class TraceSink: @unchecked Sendable {
    var traces: [ConvertTrace] = []
}

final class ConvertControllerRichContentTests: XCTestCase {
    private let slack = "com.tinyspeck.slackmacgap"
    private let chrome = "com.google.Chrome"
    private let layouts = ConvertFixtures.layouts

    private var log: ConvertLog!
    private var watcher: ConvertKeyWatcher!
    private var switches: SwitchRecorder!
    private var clock: FakeClock!
    private var sink: TraceSink!

    override func setUp() {
        log = ConvertLog()
        watcher = ConvertKeyWatcher(log: log)
        switches = SwitchRecorder(log: log)
        clock = FakeClock(nowNanos: 1_000_000_000)
        sink = TraceSink()
    }

    private struct Rig {
        let sut: ConvertController
        let field: FakeChromiumField
        let pasteboard: FakePasteboard
        let poster: RecordingPoster
        var replacer: ScriptedReplacer? = nil
    }

    @TextActor private func rig(_ text: String, bold: Range<Int>? = nil, selection: Range<Int>? = nil,
                                chromium: Bool = true, axWritesSelection: Bool = true, caret: Int? = nil) -> Rig {
        let poster = RecordingPoster()
        let field = FakeChromiumField(text, caret: caret, selection: selection, poster: poster, clock: clock,
                                      boldUnits: bold)
        let r = ScriptedReplacer(log: log)
        let selText = selection.map { s in String(decoding: Array(text.utf16)[s], as: UTF16.self) }
        r.focus = FocusInfo(role: "AXTextArea", isSecure: false, hasMarkedText: false, selTextSettable: axWritesSelection,
                            selRangeSettable: true, selection: selText)
        r.element = field
        let pb = FakePasteboard(poster: poster, clock: clock, box: text)
        let clock = self.clock!
        let log = self.log!
        let sink = self.sink!
        let clipboard = ClipboardConvert(pasteboard: pb, poster: poster, clock: clock,
                                         sleep: { nanos in clock.advance(byNanos: nanos) })
        let ax = ChromiumAXConvert(focusProvider: SwitchableFocusProvider(field), poster: poster, clock: clock,
                                   sleep: { nanos in clock.advance(byNanos: nanos) })
        let sut = ConvertController(keyWatcher: watcher, clock: clock, beep: { log.add(.beep) },
                                    makeReplacer: { r }, switchLanguage: switches.hook,
                                    makeClipboard: { @TextActor @Sendable () -> ClipboardConvert? in clipboard },
                                    makeChromiumAX: { @TextActor @Sendable () -> ChromiumAXConvert? in ax },
                                    chromiumAXEnabled: chromium,
                                    diagnose: { trace in sink.traces.append(trace) })
        return Rig(sut: sut, field: field, pasteboard: pb, poster: poster, replacer: r)
    }

    private func empty() -> WordSnapshot {
        WordSnapshot(strokes: [], previousWords: [], renderedIn: IDs.abc, isValid: false)
    }

    private func buffer(_ current: String) -> WordSnapshot {
        WordSnapshot(strokes: ConvertFixtures.strokes(current), previousWords: [], renderedIn: IDs.abc, isValid: true)
    }

    private func request(_ snapshot: WordSnapshot, gen: UInt64 = 1, app: String? = nil,
                         siteUnknown: Bool = false) -> ConvertRequest {
        ConvertRequest(snapshot: snapshot, gen: gen, bundleID: app ?? slack, mode: .convert, pair: ConvertFixtures.pair,
                       currentSource: IDs.abc, switchAfterConvert: true, useClipboard: true, allowsChromiumAX: true,
                       browserSiteUnknown: siteUnknown)
    }

    private func pastes(_ poster: RecordingPoster) -> Int {
        poster.events.filter { $0.isKeyDown && $0.modifierFlags != 0 && $0.keyCode == ClipboardShortcut.paste.keyCode }
            .count
    }

    private func backspaces(_ poster: RecordingPoster) -> Int {
        poster.events.filter { $0.isKeyDown && $0.keyCode == KeyCode.delete }.count
    }

    /// Makes the AX path give up before typing (the app never shows a selection), so the clipboard path runs.
    private func axNeverSelects(_ rig: Rig) {
        rig.field.staleRangeReadsAfterSet = 1_000_000
    }

    // MARK: - The owner's boxes through AX

    @TextActor func testOwnersSlackBoxConvertsOnlyTheTypedLineThroughAX() async {
        let rig = rig("שלום @Hillel Banai 😂\nakuo vh", bold: 0..<4)
        rig.field.hidden = 19..<21
        rig.field.setRangeDrifts = true
        rig.field.inlineAtoms = ["@Hillel Banai"]
        let out = await rig.sut.handle(request(empty()), layouts: layouts)
        XCTAssertEqual(out, .converted(to: IDs.hebrew, by: .axSelectAndType, switched: true))
        XCTAssertEqual(rig.field.text, "שלום @Hillel Banai 😂\nשלום הי", "mention, emoji kept; line 2 converted")
        XCTAssertEqual(rig.field.boldText, "שלום", "the bold word was never retyped")
        XCTAssertEqual(pastes(rig.poster), 0)
        XCTAssertEqual(rig.pasteboard.restores, 0, "the clipboard is never touched")
    }

    @TextActor func testGmailBoldStaysBoldThroughAX() async {
        let rig = rig("שלום akuo vh", bold: 0..<4)
        let out = await rig.sut.handle(request(empty(), app: chrome), layouts: layouts)
        XCTAssertEqual(out, .converted(to: IDs.hebrew, by: .axSelectAndType, switched: true))
        XCTAssertEqual(rig.field.text, "שלום שלום הי")
        XCTAssertEqual(rig.field.boldText, "שלום")
        XCTAssertEqual(pastes(rig.poster), 0)
    }

    // MARK: - Item 1: never paste over rich content

    @TextActor func testGmailBoldCopyIsPastedAsConvertedHTML() async {
        // P3-47: formatting only (bold) in a browser: converted inside the HTML, pasted as HTML + plain text.
        let rig = rig("שלום akuo vh", bold: 0..<4)
        axNeverSelects(rig)
        rig.pasteboard.copiedExtras = [.html("<div dir=\"ltr\"><b>שלום</b> akuo vh</div>")]
        let out = await rig.sut.handle(request(buffer("vh"), app: chrome), layouts: layouts)
        XCTAssertEqual(out, .converted(to: IDs.hebrew, by: .pasteboard, switched: true))
        XCTAssertEqual(rig.pasteboard.transientHTMLWrites.last ?? nil,
                       "<meta charset='utf-8'><div dir=\"ltr\"><b>שלום</b> שלום הי</div>", "every tag kept")
        XCTAssertEqual(rig.pasteboard.transientWrites.last, "שלום שלום הי")
        XCTAssertTrue(rig.pasteboard.holdsUserClipboard, "the user's clipboard is back")
        XCTAssertEqual(sink.traces.first?.copy?.htmlPaste, .ok)
        XCTAssertTrue(sink.traces.first?.line.contains("htmlPaste=ok") == true)
        XCTAssertEqual(log.beeps, 0)
    }

    @TextActor func testRichCopyWithAnEmbedIsNotPastedTheTypedRunConvertsByKeys() async {
        // An image (an emoji, a chip) can't round-trip: P3-44 behaviour.
        let rig = rig("שלום akuo vh", bold: 0..<4)
        axNeverSelects(rig)
        rig.pasteboard.copiedExtras = [.html("<div><b>שלום</b> <img src=\"x.png\"> akuo vh</div>")]
        let out = await rig.sut.handle(request(buffer("vh"), app: chrome), layouts: layouts)
        XCTAssertEqual(out, .converted(to: IDs.hebrew, by: .backspaceAndType(count: 2), switched: true),
                       "only the remembered run, by keys")
        XCTAssertEqual(pastes(rig.poster), 0, "no paste over the image")
        XCTAssertTrue(rig.pasteboard.holdsUserClipboard, "the user's clipboard is back")
        XCTAssertEqual(sink.traces.first?.copy?.htmlPaste, .refused(.unsupportedTag))
        XCTAssertEqual(log.beeps, 0)
    }

    @TextActor func testOwnersSlackCopyIsNotPastedTheTypedRunConvertsByKeys() async {
        // The P3-44 report itself: the AX path gave up, the copy carries bold, a mention and an emoji image.
        let rig = rig("שלום @Hillel Banai :joy:\nakuo vh", bold: 0..<4)
        axNeverSelects(rig)
        rig.pasteboard.copiedExtras = [.html("""
            <b data-stringify-type="bold">שלום</b> <span data-stringify-type="mention">@Hillel Banai</span> \
            <img data-stringify-type="emoji" alt=":joy:" src="x.png"><br>akuo vh
            """)]
        let out = await rig.sut.handle(request(buffer("vh")), layouts: layouts)
        XCTAssertEqual(out, .converted(to: IDs.hebrew, by: .backspaceAndType(count: 2), switched: true))
        XCTAssertEqual(pastes(rig.poster), 0)
        XCTAssertTrue(rig.pasteboard.holdsUserClipboard)
    }

    @TextActor func testRichCopyWithNothingRememberedJustSwitches() async {
        let rig = rig("שלום akuo", bold: 0..<4)
        axNeverSelects(rig)
        rig.pasteboard.copiedExtras = [.html("<b>שלום</b> <img src=\"x\"> akuo")]
        let out = await rig.sut.handle(request(empty(), app: chrome), layouts: layouts)
        XCTAssertEqual(out, .toggledOnly(to: IDs.hebrew, because: .richContent))
        XCTAssertEqual(pastes(rig.poster), 0)
        XCTAssertEqual(backspaces(rig.poster), 0)
        XCTAssertTrue(rig.pasteboard.holdsUserClipboard)
        XCTAssertEqual(log.beeps, 0)
    }

    @TextActor func testRichCopyThatDoesNotEndWithTheTypedRunJustSwitchesAndForgetsIt() async {
        // The caret is at the end of the box after the ⌘A selection is dropped, not after the typed run: no keys.
        let rig = rig("vh שלום", bold: 3..<7)
        axNeverSelects(rig)
        rig.pasteboard.copiedExtras = [.html("vh <b>שלום</b><span data-chip=\"1\"></span>")]
        let out = await rig.sut.handle(request(buffer("vh"), app: chrome), layouts: layouts)
        XCTAssertEqual(out, .toggledOnly(to: IDs.hebrew, because: .richContent))
        XCTAssertEqual(backspaces(rig.poster), 0, "no Backspace at the wrong place")
        XCTAssertEqual(pastes(rig.poster), 0)
        XCTAssertEqual(log.finishes, [.finish(gen: 1, newRendering: nil, bufferAfter: [])], "buffer forgotten")
    }

    @TextActor func testPlainHTMLCopyIsPastedAsBefore() async {
        let rig = rig("akuo vh")
        axNeverSelects(rig)
        rig.pasteboard.copiedExtras = [.html("<span style=\"font-weight: 400; font-style: normal\">akuo vh</span>")]
        let out = await rig.sut.handle(request(buffer("vh"), app: chrome), layouts: layouts)
        XCTAssertEqual(out, .converted(to: IDs.hebrew, by: .pasteboard, switched: true))
        XCTAssertEqual(rig.pasteboard.box, "שלום הי")
        XCTAssertEqual(pastes(rig.poster), 1)
    }

    @TextActor func testARichSelectionIsNeverPastedOver() async {
        let rig = rig("ok akuo ok", selection: 3..<7, chromium: false)
        rig.pasteboard.userSelection = "akuo"
        rig.pasteboard.copiedExtras = [.html("<b>akuo</b>")]
        let out = await rig.sut.handle(request(empty()), layouts: layouts)
        XCTAssertEqual(out, .toggledOnly(to: IDs.hebrew, because: .richContent))
        XCTAssertEqual(pastes(rig.poster), 0)
        XCTAssertTrue(rig.pasteboard.holdsUserClipboard)
    }

    // MARK: - Item 4: the DEBUG trace

    @TextActor func testTheTraceNamesThePathsAndHoldsNoText() async {
        let rig = rig("שלום akuo vh", bold: 0..<4)
        axNeverSelects(rig)
        rig.pasteboard.copiedExtras = [.html("<b>שלום</b> <img src=\"x\"> akuo vh")]
        _ = await rig.sut.handle(request(buffer("vh"), app: chrome), layouts: layouts)
        XCTAssertEqual(sink.traces.count, 1, "one trace per double-Shift")
        guard let t = sink.traces.first else { return }
        XCTAssertEqual(t.bundleID, chrome)
        XCTAssertEqual(t.steps.map(\.path), [.chromiumAX, .clipboard, .keys])
        XCTAssertTrue(t.steps.first?.reason.hasSuffix("selectionNotShown)") == true, t.steps.first?.reason ?? "")
        XCTAssertEqual(t.richCopy, true)
        XCTAssertNil(t.chromiumSkipped)
        let line = t.line
        for text in ["שלום", "akuo", "vh", "הי", "<b>"] {
            XCTAssertFalse(line.contains(text), "no text in the log line: \(text)")
        }
        XCTAssertTrue(line.contains("chromium{readCheck=-"))
    }

    @TextActor func testTheTraceSaysWhyTheChromiumPathWasSkipped() async {
        let rig = rig("akuo", chromium: false)
        _ = await rig.sut.handle(request(empty(), app: chrome), layouts: layouts)
        XCTAssertEqual(sink.traces.first?.chromiumSkipped, "disabled")
        XCTAssertEqual(sink.traces.first?.steps.first?.path, .clipboard)
    }

    // MARK: - P3-46 (owner retest: Slack pill + emoji + bold pasted back as plain text)

    @TextActor func testSlackCopyWithoutHTMLIsNeverPasted() async {
        let rig = rig("@Tomer Dishon :joy: תומר\nakuo vh", bold: 20..<24)
        axNeverSelects(rig)
        rig.pasteboard.copiedExtras = []   // Slack: plain text only (its rich data is not HTML)
        let out = await rig.sut.handle(request(buffer("vh")), layouts: layouts)
        XCTAssertEqual(out, .converted(to: IDs.hebrew, by: .backspaceAndType(count: 2), switched: true),
                       "only the typed run, by keys")
        XCTAssertEqual(pastes(rig.poster), 0)
        XCTAssertTrue(rig.pasteboard.holdsUserClipboard)
        guard let t = sink.traces.first else { return XCTFail("no trace") }
        XCTAssertEqual(t.copy?.reason, .noHTMLInChatApp)
        XCTAssertEqual(t.copy?.types?.html, 0)
        XCTAssertTrue(t.line.contains("copyVerdict=noHTMLInChatApp"))
        XCTAssertTrue(t.line.contains("copiedTypes{items=1 html=0 rtf=0 plain=1"))
        for text in ["Tomer", "Dishon", "תומר", "akuo", "joy"] { XCTAssertFalse(t.line.contains(text), text) }
    }

    @TextActor func testSlackCustomDataCopyIsNeverPasted() async {
        let rig = rig("akuo vh")
        axNeverSelects(rig)
        rig.pasteboard.copiedExtras = [.html("<span>akuo vh</span>"),
                                       PasteboardEntry(type: "org.chromium.web-custom-data", data: Data([1, 2]))]
        let out = await rig.sut.handle(request(empty()), layouts: layouts)
        XCTAssertEqual(out, .toggledOnly(to: IDs.hebrew, because: .richContent))
        XCTAssertEqual(pastes(rig.poster), 0)
        XCTAssertEqual(sink.traces.first?.copy?.reason, .unknownType)
        XCTAssertEqual(sink.traces.first?.copy?.types?.chromiumCustom, 1)
    }

    @TextActor func testOwnersRetestBoxConvertsThroughAXWithThePillCountedAsOneUnit() async {
        let rig = rig("@Tomer Dishon תומר\nakuo vh", bold: 14..<18)
        rig.field.pill = 0..<13
        rig.field.pillAsObjectCharacter = true
        rig.field.inlineAtoms = ["@Tomer Dishon"]
        let out = await rig.sut.handle(request(empty()), layouts: layouts)
        XCTAssertEqual(out, .converted(to: IDs.hebrew, by: .axSelectAndType, switched: true))
        XCTAssertEqual(rig.field.text, "@Tomer Dishon תומר\nשלום הי")
        XCTAssertEqual(rig.field.boldText, "תומר")
        XCTAssertEqual(pastes(rig.poster), 0)
        let line = sink.traces.first?.line ?? ""
        XCTAssertTrue(line.contains("caretMapped=true"), line)
        XCTAssertTrue(line.contains("atomRoles=AXStaticText"), line)
        XCTAssertTrue(line.contains("prefixMismatch=ax"), line)
        XCTAssertFalse(line.contains("Tomer"))
    }

    @TextActor func testPlainTextOnlyCopyOutsideChatAppsIsStillPasted() async {
        // P3-46 QA: the fake now adds a plain HTML flavour by default; a plain-text-only copy in a browser (no token in
        // it) must still paste as before P3-46, and one with a private type must not.
        let rig = rig("akuo vh")
        axNeverSelects(rig)
        rig.pasteboard.copiedExtras = []
        let out = await rig.sut.handle(request(buffer("vh"), app: chrome), layouts: layouts)
        XCTAssertEqual(out, .converted(to: IDs.hebrew, by: .pasteboard, switched: true))
        XCTAssertEqual(rig.pasteboard.box, "שלום הי")
        XCTAssertEqual(sink.traces.first?.copy?.reason, .plainText)
    }

    @TextActor func testBrowserCopyWithAWebAddressIsNotPasted() async {
        let rig = rig("akuo https://example.com vh")
        axNeverSelects(rig)
        rig.pasteboard.copiedExtras = []
        let out = await rig.sut.handle(request(empty(), app: chrome), layouts: layouts)
        XCTAssertEqual(out, .toggledOnly(to: IDs.hebrew, because: .richContent))
        XCTAssertEqual(pastes(rig.poster), 0)
        XCTAssertTrue(rig.pasteboard.holdsUserClipboard)
    }

    // MARK: - P3-47: formatting-preserving paste

    @TextActor func testABoldSelectionInABrowserIsPastedAsConvertedHTML() async {
        let rig = rig("ok akuo ok", selection: 3..<7, chromium: false)
        rig.pasteboard.userSelection = "akuo"
        rig.pasteboard.copiedExtras = [.html("<b>akuo</b>")]
        let out = await rig.sut.handle(request(empty(), app: chrome), layouts: layouts)
        XCTAssertEqual(out, .converted(to: IDs.hebrew, by: .pasteboard, switched: true))
        XCTAssertEqual(rig.pasteboard.transientHTMLWrites.last ?? nil, "<meta charset='utf-8'><b>שלום</b>")
        XCTAssertEqual(rig.pasteboard.box, "ok שלום ok", "the paste replaced the selection only")
        XCTAssertEqual(clipboardKeysWithoutSelectAll(rig.poster), true, "⌘C and ⌘V, no ⌘A")
    }

    @TextActor func testZenGmailBoldBoxIsPastedAsConvertedHTML() async {
        // P3-47 owner case: Zen (Gecko) has no Chromium AX path; the clipboard path keeps the bold now.
        let rig = rig("שלום akuo vh", bold: 0..<4)
        rig.pasteboard.copiedExtras = [.html("""
            <html><body>
            <!--StartFragment--><div dir="ltr"><b>שלום</b>&nbsp;akuo vh</div><!--EndFragment-->
            </body>
            </html>
            """)]
        let out = await rig.sut.handle(request(empty(), app: "app.zen-browser.zen"), layouts: layouts)
        XCTAssertEqual(out, .converted(to: IDs.hebrew, by: .pasteboard, switched: true))
        XCTAssertTrue((rig.pasteboard.transientHTMLWrites.last ?? nil)?
            .contains("<div dir=\"ltr\"><b>שלום</b>&nbsp;שלום הי</div>") == true)
        XCTAssertTrue(rig.pasteboard.holdsUserClipboard)
    }

    @TextActor func testZenTwoLineGmailBoxIsPastedAsConvertedHTML() async {
        // P3-47: Zen is a seeded browser now, so a box with a line break may be pasted (P3-37 rules for known browsers).
        let rig = rig("שלום akuo\nnv vh", bold: 0..<4)
        rig.pasteboard.copiedExtras = [.html("<div dir=\"ltr\"><div><b>שלום</b> akuo</div><div>nv vh</div></div>")]
        let out = await rig.sut.handle(request(empty(), app: "app.zen-browser.zen"), layouts: layouts)
        XCTAssertEqual(out, .converted(to: IDs.hebrew, by: .pasteboard, switched: true))
        XCTAssertEqual(rig.pasteboard.transientHTMLWrites.last ?? nil,
                       "<meta charset='utf-8'><div dir=\"ltr\"><div><b>שלום</b> שלום</div><div>מה הי</div></div>")
        XCTAssertEqual(rig.pasteboard.transientWrites.last, "שלום שלום\nמה הי")
        XCTAssertEqual(log.beeps, 0, "no line-break refusal")
        XCTAssertTrue(rig.pasteboard.holdsUserClipboard)
    }

    @TextActor func testChatAppsNeverGetAnHTMLPaste() async {
        let rig = rig("שלום akuo vh", bold: 0..<4)
        axNeverSelects(rig)
        rig.pasteboard.copiedExtras = [.html("<b>שלום</b> akuo vh")]
        let out = await rig.sut.handle(request(empty()), layouts: layouts)   // Slack
        XCTAssertEqual(out, .toggledOnly(to: IDs.hebrew, because: .richContent))
        XCTAssertEqual(pastes(rig.poster), 0)
        XCTAssertNil(sink.traces.first?.copy?.htmlPaste, "not tried in a chat app")
    }

    @TextActor func testACustomPageFlavourIsNotEligible() async {
        let rig = rig("שלום akuo vh", bold: 0..<4)
        axNeverSelects(rig)
        rig.pasteboard.copiedExtras = [.html("<b>שלום</b> akuo vh"),
                                       PasteboardEntry(type: "org.chromium.web-custom-data", data: Data([1]))]
        let out = await rig.sut.handle(request(empty(), app: chrome), layouts: layouts)
        XCTAssertEqual(out, .toggledOnly(to: IDs.hebrew, because: .richContent))
        XCTAssertEqual(sink.traces.first?.copy?.htmlPaste, .refused(.notEligible))
        XCTAssertTrue(sink.traces.first?.line.contains("htmlPaste=refused(notEligible)") == true)
    }

    // MARK: - P3-47 QA: a browser page whose host is unknown (Google Docs can't be ruled out)

    @TextActor func testZenBoxIsNeverCopiedWhileTheSiteIsUnknown() async {
        let rig = rig("שלום akuo vh", bold: 0..<4)
        rig.pasteboard.copiedExtras = [.html("<div><b>שלום</b> akuo vh</div>")]
        let out = await rig.sut.handle(request(buffer("vh"), app: "app.zen-browser.zen", siteUnknown: true),
                                       layouts: layouts)
        XCTAssertEqual(pastes(rig.poster), 0, "no whole-box paste")
        XCTAssertFalse(rig.pasteboard.selectedAll, "no ⌘A")
        XCTAssertEqual(rig.pasteboard.transientWrites, [])
        XCTAssertNotEqual(out, .converted(to: IDs.hebrew, by: .pasteboard, switched: true))
    }

    @TextActor func testChromeBoxIsNeverCopiedWhileTheSiteIsUnknown() async {
        let rig = rig("akuo vh")
        axNeverSelects(rig)
        let out = await rig.sut.handle(request(buffer("vh"), app: chrome, siteUnknown: true), layouts: layouts)
        XCTAssertEqual(pastes(rig.poster), 0)
        XCTAssertFalse(rig.pasteboard.selectedAll)
        XCTAssertNotEqual(out, .converted(to: IDs.hebrew, by: .pasteboard, switched: true))
    }

    @TextActor func testAMultiLineSelectionIsPastedAsHTMLWhileTheSiteIsUnknown() async {
        // P3-49 (Coordinator decision 2026-11-16; replaces the P3-47 QA rule "no line breaks on an unknown site"): the
        // unknown-site gate stops the ⌘A whole-box copy only. A selection is the user's own and the paste replaces only
        // it, so a multi-line one goes through the formatting-preserving HTML path (line breaks kept as structure).
        let rig = rig("ok akuo\nvh ok", selection: 3..<10, chromium: false, axWritesSelection: false)
        rig.pasteboard.userSelection = "akuo\nvh"
        rig.pasteboard.copiedExtras = [.html("<div><b>akuo</b></div><div>vh</div>")]
        let out = await rig.sut.handle(request(empty(), app: "app.zen-browser.zen", siteUnknown: true), layouts: layouts)
        XCTAssertEqual(out, .converted(to: IDs.hebrew, by: .pasteboard, switched: true))
        XCTAssertEqual(rig.pasteboard.transientHTMLWrites.last ?? nil,
                       "<meta charset='utf-8'><div><b>שלום</b></div><div>הי</div>")
        XCTAssertEqual(rig.pasteboard.box, "ok שלום\nהי ok", "only the selection replaced")
        XCTAssertFalse(rig.pasteboard.selectedAll, "no ⌘A")
        XCTAssertTrue(rig.pasteboard.holdsUserClipboard)
    }

    @TextActor func testAMultiLinePlainSelectionIsPastedWhileTheSiteIsUnknown() async {
        // P3-49: the plain path too, the copy checked against the selection AX reported (P3-40).
        let rig = rig("ok akuo\nvh ok", selection: 3..<10, chromium: false, axWritesSelection: false)
        rig.pasteboard.userSelection = "akuo\nvh"
        rig.pasteboard.copiedExtras = []
        let out = await rig.sut.handle(request(empty(), app: "app.zen-browser.zen", siteUnknown: true), layouts: layouts)
        XCTAssertEqual(out, .converted(to: IDs.hebrew, by: .pasteboard, switched: true))
        XCTAssertEqual(rig.pasteboard.box, "ok שלום\nהי ok")
        XCTAssertFalse(rig.pasteboard.selectedAll)
    }

    @TextActor func testAMultiLineSelectionThatIsNotTheAXSelectionIsNeverPasted() async {
        // P3-49: the copy is not what AX reported selected (P3-40 mismatch): nothing pasted, unknown site or not.
        let rig = rig("ok akuo\nvh ok", selection: 3..<10, chromium: false, axWritesSelection: false)
        rig.pasteboard.userSelection = "akuo\nvh"
        rig.pasteboard.copiesInstead = "something\nelse"
        rig.pasteboard.copiedExtras = []
        _ = await rig.sut.handle(request(empty(), app: "app.zen-browser.zen", siteUnknown: true), layouts: layouts)
        XCTAssertEqual(pastes(rig.poster), 0)
        XCTAssertTrue(rig.pasteboard.holdsUserClipboard)
    }

    @TextActor func testAOneLineSelectionIsStillPastedWhileTheSiteIsUnknown() async {
        let rig = rig("ok akuo ok", selection: 3..<7, chromium: false, axWritesSelection: false)
        rig.pasteboard.userSelection = "akuo"
        rig.pasteboard.copiedExtras = [.html("<b>akuo</b>")]
        let out = await rig.sut.handle(request(empty(), app: "app.zen-browser.zen", siteUnknown: true), layouts: layouts)
        XCTAssertEqual(out, .converted(to: IDs.hebrew, by: .pasteboard, switched: true))
        XCTAssertEqual(rig.pasteboard.box, "ok שלום ok")
    }

    @TextActor func testZenWritesASelectionThroughAXFirst() async {
        // P3-47 QA: Gecko stays `.auto`: a selection AX can write is converted through AX, not the clipboard.
        let rig = rig("ok akuo ok", selection: 3..<7, chromium: false)
        rig.pasteboard.userSelection = "akuo"
        let out = await rig.sut.handle(request(empty(), app: "app.zen-browser.zen"), layouts: layouts)
        XCTAssertEqual(out, .converted(to: IDs.hebrew, by: .axWriteSelection(verify: true), switched: true))
        XCTAssertEqual(pastes(rig.poster), 0)
    }

    // MARK: - P3-53 QA (Coordinator 2026-11-16): a cut-short quote search blocks a webmail whole box only

    @TextActor func testAGmailWholeBoxWithACutShortQuoteSearchTypesNothing() async {
        let rig = rig("akuo vh")
        rig.field.quoteSearchCutShort = true
        var r = request(empty(), app: chrome)
        r.webmailPage = true
        _ = await rig.sut.handle(r, layouts: layouts)
        XCTAssertEqual(rig.field.text, "akuo vh", "the AX path never typed over the box (or a quote it couldn't see)")
        XCTAssertEqual(rig.field.quoteSearchMustCompleteAsks, [true])
        // It falls back as for any incomplete read: the clipboard path (its HTML paste skips Gmail's quote itself).
        XCTAssertEqual(sink.traces.first?.steps.first?.path, .chromiumAX)
        XCTAssertTrue(sink.traces.first?.steps.first?.reason.hasPrefix("unavailable") == true)
    }

    @TextActor func testAGmailSelectionDoesNotNeedTheQuoteSearch() async {
        let rig = rig("ok akuo ok", selection: 3..<7)
        rig.field.quoteSearchCutShort = true
        var r = request(empty(), app: chrome)
        r.webmailPage = true
        _ = await rig.sut.handle(r, layouts: layouts)
        XCTAssertEqual(rig.field.quoteSearchMustCompleteAsks.first, false, "a selection is the user's choice")
    }

    @TextActor func testSlackWithACutShortQuoteSearchStillConverts() async {
        let rig = rig("akuo vh")
        rig.field.quoteSearchCutShort = true
        let out = await rig.sut.handle(request(empty()), layouts: layouts)
        XCTAssertEqual(out, .converted(to: IDs.hebrew, by: .axSelectAndType, switched: true))
        XCTAssertEqual(rig.field.quoteSearchMustCompleteAsks, [false])
    }

    @TextActor func testAnUnknownSiteFoundToBeWebmailNeedsTheQuoteSearchToo() async {
        let rig = rig("akuo vh")
        rig.field.quoteSearchCutShort = true
        rig.replacer?.pageCategory = .webmail
        _ = await rig.sut.handle(request(empty(), app: chrome, siteUnknown: true), layouts: layouts)
        XCTAssertEqual(rig.field.text, "akuo vh")
        XCTAssertEqual(rig.field.quoteSearchMustCompleteAsks, [true])
    }

    @TextActor func testKeysAfterASlowChromiumTryAreNeverPostedPastTheBudget() async {
        // P3-53 QA: the AX path spends the budget (each selection try waits; the app never shows it), then falls back
        // to the remembered buffer's keys: those run inside what is left of the same 400 ms, so here not at all.
        let rig = rig("akuo vh")
        axNeverSelects(rig)
        let clock = self.clock!
        rig.field.onSetRange = { _ in clock.advance(byMilliseconds: 250) }
        let r = ConvertRequest(snapshot: buffer("vh"), gen: 1, bundleID: chrome, mode: .convert,
                               pair: ConvertFixtures.pair, currentSource: IDs.abc, switchAfterConvert: true,
                               useClipboard: false, allowsChromiumAX: true)
        let out = await rig.sut.handle(r, layouts: layouts)
        XCTAssertNotEqual(out, .converted(to: IDs.hebrew, by: .backspaceAndType(count: 2), switched: true))
        XCTAssertEqual(backspaces(rig.poster), 0, "no Backspace after the budget")
        XCTAssertTrue(rig.poster.events.allSatisfy { $0.keyCode != KeyCode.delete }, "no key after the budget")
    }

    // MARK: - P3-54 QA (Coordinator 2026-11-16): a webmail whole box where no quote was seen

    @TextActor func testAWebmailBoxWithNoQuoteSeenConvertsOnlyTheCaretsBlockThroughAX() async {
        // A reply whose header no pattern knows and whose AX tree shows no quote: the caret's paragraph block, up to the
        // caret, is all that converts; the unrecognised thread below it (and any text above the empty line) stays.
        let box = "nv nmc\n\nakuo vh\n\nIl Lun X ha scritto:\nnv nmc"
        let rig = rig(box, caret: 15)
        var r = request(empty(), app: chrome)
        r.webmailPage = true
        let out = await rig.sut.handle(r, layouts: layouts)
        XCTAssertEqual(out, .converted(to: IDs.hebrew, by: .axSelectAndType, switched: true))
        XCTAssertEqual(rig.field.text, "nv nmc\n\nשלום הי\n\nIl Lun X ha scritto:\nnv nmc")
    }

    @TextActor func testANonWebmailBoxStillConvertsWhole() async {
        let rig = rig("nv nmc\n\nakuo vh", caret: 15)
        let out = await rig.sut.handle(request(empty(), app: chrome), layouts: layouts)
        XCTAssertEqual(out, .converted(to: IDs.hebrew, by: .axSelectAndType, switched: true))
        XCTAssertEqual(rig.field.text, "מה מצב\n\nשלום הי")
    }

    @TextActor func testAFreshZenGmailComposeWithNoQuoteSignalIsPastedWhole() async {
        // Coordinator decision 2026-11-16 (keeps §P3-50 ✅): the clipboard path has no caret after ⌘A, and a fresh
        // compose has no quote at all: bold + two lines convert whole, as an HTML paste.
        let rig = rig("שלום akuo\nnv vh", bold: 0..<4)
        rig.pasteboard.copiedExtras = [.html("<div dir=\"ltr\"><div><b>שלום</b> akuo</div><div>nv vh</div></div>")]
        var r = request(empty(), app: "app.zen-browser.zen")
        r.webmailPage = true
        let out = await rig.sut.handle(r, layouts: layouts)
        XCTAssertEqual(out, .converted(to: IDs.hebrew, by: .pasteboard, switched: true))
        XCTAssertEqual(rig.pasteboard.transientHTMLWrites.last ?? nil,
                       "<meta charset='utf-8'><div dir=\"ltr\"><div><b>שלום</b> שלום</div><div>מה הי</div></div>")
        XCTAssertEqual(sink.traces.first?.copy?.htmlPaste, .ok)
    }

    @TextActor func testAWebmailReplyWithARecognisedHeaderStillCutsOnTheClipboardPath() async {
        // No Gmail class, no blockquote (as in Gecko's copy), but the English header: only the text above it converts.
        let html = "<div><b>akuo</b> vh</div><div>On Mon, Nov 16, 2026 at 10:00 AM X wrote:</div><div>nv nmc</div>"
        let rig = rig("akuo vh\nOn Mon, Nov 16, 2026 at 10:00 AM X wrote:\nnv nmc")
        rig.pasteboard.copiedExtras = [.html(html)]
        var r = request(empty(), app: "app.zen-browser.zen")
        r.webmailPage = true
        let out = await rig.sut.handle(r, layouts: layouts)
        XCTAssertEqual(out, .converted(to: IDs.hebrew, by: .pasteboard, switched: true))
        XCTAssertEqual(rig.pasteboard.transientHTMLWrites.last ?? nil,
                       "<meta charset='utf-8'>" + html.replacingOccurrences(of: "<b>akuo</b> vh", with: "<b>שלום</b> הי"))
        XCTAssertEqual(rig.pasteboard.transientWrites.last, "שלום הי\nOn Mon, Nov 16, 2026 at 10:00 AM X wrote:\nnv nmc")
    }

    func testTheCaretsBlockStartsAfterTheLastEmptyLine() {
        func b(_ s: String, _ caret: Int) -> Int { ConvertController.blockStart(before: caret, in: Array(s.utf16)) }
        XCTAssertEqual(b("akuo vh", 7), 0)
        XCTAssertEqual(b("a\n\nakuo", 7), 3)
        XCTAssertEqual(b("a\n \u{00A0}\nakuo\nvh", 12), 5, "a line of spaces / NBSP is empty")
        XCTAssertEqual(b("a\nb\nakuo", 8), 0, "no empty line: the whole text before the caret")
        XCTAssertEqual(b("a\n\n", 3), 3, "the caret on an empty line")
        XCTAssertEqual(b("", 0), 0)
    }

    private func clipboardKeysWithoutSelectAll(_ poster: RecordingPoster) -> Bool {
        let downs = poster.events.filter { $0.isKeyDown && $0.modifierFlags != 0 }.map(\.keyCode)
        return downs == [ClipboardShortcut.copy.keyCode, ClipboardShortcut.paste.keyCode]
    }

    // MARK: - P3-49 (owner retest in Zen: the unselected box only switched; a multi-line selection beeped)

    /// Gecko writes its HTML flavour as a C string: a NUL after `</html>`.
    private func geckoHTML(_ body: String) -> PasteboardEntry {
        PasteboardEntry(type: "public.html", data: Data("""
            <html><body>
            <!--StartFragment-->\(body)<!--EndFragment-->
            </body>
            </html>
            """.utf8) + Data([0]))
    }

    @TextActor func testZenBoxWithGeckosTrailingNULIsPastedAsConvertedHTML() async {
        // Root cause: the NUL was a control character in the HTML's text, a `BoxConversion` hard stop right at the
        // "caret" (the end), so the HTML planner found nothing (`htmlPaste=refused(nothingToConvert)`).
        let rig = rig("שלום akuo vh", bold: 0..<4)
        rig.pasteboard.copiedExtras = [geckoHTML("<div dir=\"ltr\"><b>שלום</b> akuo vh</div>")]
        let out = await rig.sut.handle(request(buffer("vh"), app: "app.zen-browser.zen"), layouts: layouts)
        XCTAssertEqual(out, .converted(to: IDs.hebrew, by: .pasteboard, switched: true))
        let html = rig.pasteboard.transientHTMLWrites.last ?? nil
        XCTAssertTrue(html?.contains("<div dir=\"ltr\"><b>שלום</b> שלום הי</div>") == true, html ?? "nil")
        XCTAssertFalse(html?.contains("\u{0}") == true, "the NUL is not written back")
        XCTAssertEqual(rig.pasteboard.transientWrites.last, "שלום שלום הי")
        XCTAssertEqual(sink.traces.first?.copy?.htmlPaste, .ok)
        XCTAssertTrue(sink.traces.first?.line.contains("siteKnown=true") == true)
    }

    @TextActor func testZenTwoLineBoxWithTrailingNULAndAnEmptyLine() async {
        let rig = rig("שלום akuo\nnv vh", bold: 0..<4)
        rig.pasteboard.copiedExtras = [
            geckoHTML("<div dir=\"ltr\"><div><b>שלום</b> akuo</div><div>nv vh</div><div><br></div></div>")]
        let out = await rig.sut.handle(request(empty(), app: "app.zen-browser.zen"), layouts: layouts)
        XCTAssertEqual(out, .converted(to: IDs.hebrew, by: .pasteboard, switched: true))
        XCTAssertEqual(rig.pasteboard.transientWrites.last, "שלום שלום\nמה הי")
    }

    @TextActor func testZenMultiLineSelectionWithTheSiteKnownIsPastedAsConvertedHTML() async {
        let rig = rig("ok akuo\nvh ok", selection: 3..<10, chromium: false, axWritesSelection: false)
        rig.pasteboard.userSelection = "akuo\nvh"
        rig.pasteboard.copiedExtras = [geckoHTML("<div><b>akuo</b></div><div>vh</div>")]
        let out = await rig.sut.handle(request(empty(), app: "app.zen-browser.zen"), layouts: layouts)
        XCTAssertEqual(out, .converted(to: IDs.hebrew, by: .pasteboard, switched: true))
        XCTAssertEqual(rig.pasteboard.box, "ok שלום\nהי ok", "line break kept")
        XCTAssertTrue((rig.pasteboard.transientHTMLWrites.last ?? nil)?.contains("<div><b>שלום</b></div><div>הי</div>")
                      == true)
        XCTAssertEqual(log.beeps, 0)
    }

    @TextActor func testTheTraceSaysWhetherTheSiteWasKnown() async {
        let rig = rig("ok akuo\nvh ok", selection: 3..<10, chromium: false, axWritesSelection: false)
        rig.pasteboard.userSelection = "akuo\nvh"
        var r = request(empty(), app: "app.zen-browser.zen", siteUnknown: true)
        r.pageState = .page
        _ = await rig.sut.handle(r, layouts: layouts)
        let line = sink.traces.first?.line ?? ""
        XCTAssertTrue(line.contains("siteKnown=false"), line)
        XCTAssertTrue(line.contains("pageState=page"), line)
        // P3-49 (Coordinator decision 2026-11-16): a multi-line selection is pasted on an unknown site too.
        XCTAssertTrue(line.contains("clipboard:pasted"), line)
        for text in ["akuo", "vh", "שלום", "הי"] { XCTAssertFalse(line.contains(text), text) }
    }

    // MARK: - P3-50 (owner: in Zen the box never converted; every trace `siteKnown=false pageState=none`)

    @TextActor func testUnknownSiteButAnOrdinaryFocusedPageAllowsTheWholeBox() async {
        let rig = rig("שלום akuo vh", bold: 0..<4)
        rig.replacer?.pageCategory = .ordinary
        rig.pasteboard.copiedExtras = [.html("<div dir=\"ltr\"><b>שלום</b> akuo vh</div>")]
        var r = request(buffer("vh"), app: "app.zen-browser.zen", siteUnknown: true)
        r.siteWatch = "websiteRulesOff"
        let out = await rig.sut.handle(r, layouts: layouts)
        XCTAssertEqual(out, .converted(to: IDs.hebrew, by: .pasteboard, switched: true))
        XCTAssertEqual(rig.pasteboard.transientWrites.last, "שלום שלום הי")
        let line = sink.traces.first?.line ?? ""
        XCTAssertTrue(line.contains("siteKnown=false"), line)
        XCTAssertTrue(line.contains("siteWatch=websiteRulesOff"), line)
        XCTAssertTrue(line.contains("pageCheck=ordinary"), line)
    }

    @TextActor func testUnknownSiteAndAWholeDocumentPageNeverCopiesAnything() async {
        let rig = rig("akuo\nvh", selection: 0..<7, chromium: false, axWritesSelection: false)
        rig.replacer?.pageCategory = .wholeDocument
        rig.pasteboard.userSelection = "akuo\nvh"
        let out = await rig.sut.handle(request(empty(), app: "app.zen-browser.zen", siteUnknown: true), layouts: layouts)
        XCTAssertEqual(pastes(rig.poster), 0)
        XCTAssertFalse(rig.poster.events.contains { $0.modifierFlags != 0 }, "no ⌘C either")
        XCTAssertNotEqual(out, .converted(to: IDs.hebrew, by: .pasteboard, switched: true))
        XCTAssertTrue(sink.traces.first?.line.contains("pageCheck=wholeDocument") == true)
    }

    @TextActor func testUnknownSiteAndAnUnreadablePageStillRefusesTheWholeBox() async {
        let rig = rig("שלום akuo vh", bold: 0..<4)
        rig.replacer?.pageCategory = .unknown
        let out = await rig.sut.handle(request(buffer("vh"), app: "app.zen-browser.zen", siteUnknown: true),
                                       layouts: layouts)
        XCTAssertFalse(rig.pasteboard.selectedAll, "no ⌘A")
        XCTAssertNotEqual(out, .converted(to: IDs.hebrew, by: .pasteboard, switched: true))
        XCTAssertTrue(sink.traces.first?.line.contains("pageCheck=unknown") == true)
    }

    @TextActor func testAKnownSiteNeverAsksThePage() async {
        let rig = rig("akuo vh")
        rig.replacer?.pageCategory = .wholeDocument   // would refuse if asked
        let out = await rig.sut.handle(request(buffer("vh"), app: "app.zen-browser.zen"), layouts: layouts)
        XCTAssertEqual(out, .converted(to: IDs.hebrew, by: .pasteboard, switched: true))
        XCTAssertEqual(rig.replacer?.pageChecks, 0)
    }

    // MARK: - P3-48: Gmail reply / forward: the quoted thread and the signature never convert

    @TextActor func testAPlainReplyCopyConvertsOnlyWhatComesBeforeTheQuote() async {
        let box = "akuo vh\n\nOn Mon, Nov 16, 2026 at 10:00 AM X <x@y.com> wrote:\n> nv nmc"
        let rig = rig(box)
        axNeverSelects(rig)
        rig.pasteboard.copiedExtras = []   // plain text only
        let out = await rig.sut.handle(request(empty(), app: chrome), layouts: layouts)
        XCTAssertEqual(out, .converted(to: IDs.hebrew, by: .pasteboard, switched: true))
        XCTAssertEqual(rig.pasteboard.transientWrites.last,
                       "שלום הי\n\nOn Mon, Nov 16, 2026 at 10:00 AM X <x@y.com> wrote:\n> nv nmc")
    }

    @TextActor func testAZenGmailReplyPastesTheQuoteBackUnchanged() async {
        let html = HTMLTextConvertTests.reply
        let rig = rig(HTMLTextConvertTests.replyPlain)
        rig.pasteboard.copiedExtras = [.html(html)]
        let out = await rig.sut.handle(request(empty(), app: "app.zen-browser.zen"), layouts: layouts)
        XCTAssertEqual(out, .converted(to: IDs.hebrew, by: .pasteboard, switched: true))
        XCTAssertEqual(rig.pasteboard.transientHTMLWrites.last ?? nil,
                       "<meta charset='utf-8'>" + html.replacingOccurrences(of: ">akuo vh<", with: ">שלום הי<"))
        XCTAssertEqual(sink.traces.first?.copy?.htmlPaste, .ok)
    }

    @TextActor func testAChromeGmailReplyThroughAXKeepsTheQuote() async {
        // The AX tree shows the quote's lines (`AXQuoteText` atoms from the live walk): never typed over.
        let rig = rig("akuo vh\nOn Mon X wrote:\nnv nmc")
        rig.field.inlineAtoms = ["On Mon X wrote:", "nv nmc"]
        rig.field.inlineAtomRole = "AXQuoteText"
        let out = await rig.sut.handle(request(empty(), app: chrome), layouts: layouts)
        XCTAssertEqual(out, .converted(to: IDs.hebrew, by: .axSelectAndType, switched: true))
        XCTAssertEqual(rig.field.text, "שלום הי\nOn Mon X wrote:\nnv nmc")
    }

    @TextActor func testASelectionInsideTheQuoteStillConverts() async {
        let rig = rig("ok\nnv nmc", selection: 3..<9, chromium: false, axWritesSelection: false)
        rig.pasteboard.userSelection = "nv nmc"
        rig.pasteboard.copiedExtras = [.html("<blockquote class=\"gmail_quote\"><div>nv nmc</div></blockquote>")]
        let out = await rig.sut.handle(request(empty(), app: "app.zen-browser.zen"), layouts: layouts)
        XCTAssertEqual(out, .converted(to: IDs.hebrew, by: .pasteboard, switched: true))
        XCTAssertEqual(rig.pasteboard.box, "ok\nמה מצב")
    }

    // MARK: - P3-53: the Chromium path on a browser page whose host is unknown (Google Docs right after load)

    @TextActor func testAWholeDocumentPageNeverGetsTheChromiumPath() async {
        let rig = rig("akuo vh")
        rig.replacer?.pageCategory = .wholeDocument
        let out = await rig.sut.handle(request(buffer("vh"), app: chrome, siteUnknown: true), layouts: layouts)
        XCTAssertTrue(rig.field.rangeWrites.isEmpty, "no AX selection in the document")
        XCTAssertEqual(pastes(rig.poster), 0)
        XCTAssertNotEqual(out, .converted(to: IDs.hebrew, by: .axSelectAndType, switched: true))
        XCTAssertEqual(sink.traces.first?.chromiumSkipped, "wholeDocumentPage")
        XCTAssertEqual(rig.replacer?.pageChecks, 1, "asked once per request")
    }

    @TextActor func testAnUnknownPageGetsTheChromiumPathForASelectionOnly() async {
        let box = rig("akuo vh")
        box.replacer?.pageCategory = .unknown
        _ = await box.sut.handle(request(buffer("vh"), app: chrome, siteUnknown: true), layouts: layouts)
        XCTAssertTrue(box.field.rangeWrites.isEmpty, "the whole box: never")
        XCTAssertEqual(sink.traces.first?.chromiumSkipped, "siteUnknownBox")

        sink = TraceSink()
        let sel = rig("ok akuo ok", selection: 3..<7)
        sel.replacer?.pageCategory = .unknown
        let out = await sel.sut.handle(request(empty(), app: chrome, siteUnknown: true), layouts: layouts)
        XCTAssertEqual(out, .converted(to: IDs.hebrew, by: .axSelectAndType, switched: true))
        XCTAssertEqual(sel.field.text, "ok שלום ok")
    }

    @TextActor func testAnOrdinaryPageGetsTheChromiumPathAndThePageIsAskedOnce() async {
        let rig = rig("akuo vh")
        rig.replacer?.pageCategory = .ordinary
        let out = await rig.sut.handle(request(buffer("vh"), app: chrome, siteUnknown: true), layouts: layouts)
        XCTAssertEqual(out, .converted(to: IDs.hebrew, by: .axSelectAndType, switched: true))
        XCTAssertEqual(rig.replacer?.pageChecks, 1)
        XCTAssertEqual(rig.replacer?.pageCheckBudgets, [ConvertController.pageCheckBudgetNanos])
    }

    // MARK: - P3-54: Gmail reply in Zen, Gecko's copy without classes

    @TextActor func testAZenGmailReplyWithoutClassesKeepsTheQuote() async {
        let rig = rig(HTMLTextConvertTests.geckoReplyPlain)
        // Bold in the user's part makes the copy rich (the owner's case: `copyVerdict=richHTML htmlPaste=ok`).
        let html = HTMLTextConvertTests.geckoReply.replacingOccurrences(of: ">akuo vh<", with: "><b>akuo</b> vh<")
        rig.pasteboard.copiedExtras = [.html(html)]
        let out = await rig.sut.handle(request(empty(), app: "app.zen-browser.zen"), layouts: layouts)
        XCTAssertTrue((rig.pasteboard.transientHTMLWrites.last ?? nil)?.contains("><b>שלום</b> הי<") == true)
        XCTAssertTrue((rig.pasteboard.transientHTMLWrites.last ?? nil)?.contains(">nv nmc</div><div dir=\"ltr\">nv nmc<")
                      == true, "the quote byte for byte")
        XCTAssertEqual(out, .converted(to: IDs.hebrew, by: .pasteboard, switched: true))
        XCTAssertEqual(rig.pasteboard.transientWrites.last,
                       "שלום הי\n\nOn Mon, Nov 16, 2026 at 10:00 AM X <x@y.com> wrote:\nnv nmc\nnv nmc")
        let line = sink.traces.first?.line ?? ""
        XCTAssertTrue(line.contains("html{blockquoteTags=0 classAttrs=0 gmailClassHits=0 skippedRegions=0 "
                                    + "quoteBoundary=html/plain}"), line)
        XCTAssertFalse(line.contains("akuo") || line.contains("wrote"), "no text in the trace")
    }

    // MARK: - P3-55: the Slack wrong-text write

    @TextActor func testOwnersSlackBoxRichCopyFallbackUsesBackspacesNeverTheStaleSelection() async {
        // `akuo 😄 akuo יקךךם`: the AX path gives up, the copy is Slack's own (unknownType) and ends with the typed run.
        // Then AX still shows the ⌘A selection (the Right arrow hadn't reached it): the old fallback typed the AX
        // selection's converted text (with U+FFFC) "over" it, and the keys were appended.
        let box = "akuo 😄 akuo יקךךם"
        let rig = rig(box)
        axNeverSelects(rig)
        rig.pasteboard.copiedExtras = [PasteboardEntry(type: "org.chromium.web-custom-data", data: Data([1]))]
        // Read 1: the double-Shift's focus read; read 2: the fallback after the AX path; read 3 on: after ⌘A.
        rig.replacer?.focusFromRead = (3, FocusInfo(role: "AXTextArea", isSecure: false, hasMarkedText: false,
                                                    selTextSettable: true, selRangeSettable: true,
                                                    selection: "akuo \u{FFFC} akuo יקךךם"))
        let snap = WordSnapshot(strokes: ConvertFixtures.strokes("hello"), previousWords: [], renderedIn: IDs.hebrew,
                                isValid: true)
        var r = request(snap)
        r = ConvertRequest(snapshot: snap, gen: 1, bundleID: slack, mode: .convert, pair: ConvertFixtures.pair,
                           currentSource: IDs.hebrew, switchAfterConvert: true, useClipboard: true,
                           allowsChromiumAX: true)
        let out = await rig.sut.handle(r, layouts: layouts)
        XCTAssertEqual(out, .converted(to: IDs.abc, by: .backspaceAndType(count: 5), switched: true))
        XCTAssertEqual(log.performs, [.backspaceAndType(count: 5)], "never typeOverSelection")
        XCTAssertEqual(rig.replacer?.typedTexts, ["hello"], "only the buffer's own re-rendering")
        XCTAssertFalse(rig.replacer?.typedTexts.contains { $0.contains("\u{FFFC}") } ?? true)
        XCTAssertEqual(pastes(rig.poster), 0)
    }

    @TextActor func testARichCopyRunHoldingAColonIsNeverTypedByKeys() async {
        let rig = rig("akuo vh:")
        axNeverSelects(rig)
        rig.pasteboard.copiedExtras = [PasteboardEntry(type: "org.chromium.web-custom-data", data: Data([1]))]
        let colon = ConvertFixtures.abc.keys.filter { $0.value.shift == ":" }.map(\.key).min()!
        let snap = WordSnapshot(strokes: ConvertFixtures.strokes("vh") + [Stroke(keyCode: colon, layer: .shift)],
                                previousWords: [], renderedIn: IDs.abc, isValid: true)
        rig.pasteboard.box = "akuo vh:"
        let out = await rig.sut.handle(request(snap), layouts: layouts)
        XCTAssertEqual(out, .toggledOnly(to: IDs.hebrew, because: .richContent))
        XCTAssertTrue(log.performs.isEmpty)
    }

    @TextActor func testAnUnexplainedPrefixMismatchInAChatAppJustSwitches() async {
        // The `:shortcode:` emoji shape: the prefix disagrees with no U+FFFC / emoji on either side.
        let rig = rig("akuo akuo vh")
        rig.field.stringForRangeOverride = "akuo xxxx vh"
        rig.pasteboard.copiedExtras = [PasteboardEntry(type: "org.chromium.web-custom-data", data: Data([1]))]
        let out = await rig.sut.handle(request(buffer("vh")), layouts: layouts)
        XCTAssertEqual(out, .toggledOnly(to: IDs.hebrew, because: .fieldUnreadable))
        XCTAssertTrue(log.performs.isEmpty, "no keys")
        XCTAssertFalse(rig.poster.events.contains { $0.modifierFlags != 0 }, "no ⌘A / ⌘C")
        XCTAssertTrue(sink.traces.first?.line.contains("prefixUnexplained=true") == true)
        XCTAssertTrue(sink.traces.first?.line.contains("valueUnits=12") == true)
    }

    // MARK: - P3-55 QA: nothing acts on a selection AX may still report after Kytkin's own select-all / arrows

    @TextActor func testAnEmptyBoxCopyWithNothingRememberedNeverFallsBackToTheStaleSelection() async {
        // Select-all + copy copied nothing (and the Right arrow was posted); AX still reports the select-all
        // selection. The old fallback read it and typed the box over it. Now: just switch.
        let box = "akuo \u{FFFC} akuo"
        let rig = rig(box)
        axNeverSelects(rig)
        rig.pasteboard.copiesInstead = ""
        // Read 1: the double-Shift; read 2: the fallback after the AX path (no selection yet); read 3 on: stale.
        rig.replacer?.focusFromRead = (3, FocusInfo(role: "AXTextArea", isSecure: false, hasMarkedText: false,
                                                    selTextSettable: true, selRangeSettable: true, selection: box))
        let out = await rig.sut.handle(request(empty()), layouts: layouts)
        XCTAssertEqual(out, .toggledOnly(to: IDs.hebrew, because: .nothingToConvert))
        XCTAssertTrue(rig.pasteboard.selectedAll, "the box path ran (select-all posted)")
        XCTAssertTrue(log.performs.isEmpty, "nothing typed over a selection")
        XCTAssertEqual(rig.replacer?.typedTexts ?? [], [])
    }

    @TextActor func testRichCopyKeysAreNeverPostedPastTheBudget() async {
        // The copy wait (and the restore) used the budget up: the typed run is not typed, the language just switches.
        let rig = rig("akuo vh", chromium: false)
        rig.pasteboard.copiedExtras = [PasteboardEntry(type: "org.chromium.web-custom-data", data: Data([1]))]
        let clock = self.clock!
        rig.pasteboard.onRestore = { clock.advance(byMilliseconds: 450) }
        let out = await rig.sut.handle(request(buffer("vh"), app: chrome), layouts: layouts)
        XCTAssertEqual(out, .toggledOnly(to: IDs.hebrew, because: .richContent))
        XCTAssertTrue(log.performs.isEmpty, "no Backspace after the budget")
    }

    // MARK: - P3-57: Slack's image emoji (odd units in AXValue, an AXImage child)

    @TextActor func testOwnersSlackImageEmojiBoxConvertsThroughAX() async {
        // `akuo :smile: akuo hello` → page text `akuo  akuo hello`, AXValue 2 units longer at the image.
        let rig = rig("akuo  akuo hello")
        rig.field.oddValueUnits = (5, [0xE000, 0xE001])
        rig.field.imageCount = 1
        let out = await rig.sut.handle(request(empty()), layouts: layouts)
        XCTAssertEqual(out, .converted(to: IDs.hebrew, by: .axSelectAndType, switched: true))
        XCTAssertEqual(rig.field.text, "שלום  שלום יקךךם")
        XCTAssertEqual(pastes(rig.poster), 0)
        let line = sink.traces.first?.line ?? ""
        XCTAssertTrue(line.contains("oddUnits=2:U+E000,U+E001") && line.contains("oddRunsStripped=1"), line)
        XCTAssertFalse(line.contains("akuo") || line.contains("hello"), "no text in the trace")
    }
}
