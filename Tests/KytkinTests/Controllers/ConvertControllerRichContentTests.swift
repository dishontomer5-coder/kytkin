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
    }

    @TextActor private func rig(_ text: String, bold: Range<Int>? = nil, selection: Range<Int>? = nil,
                                chromium: Bool = true) -> Rig {
        let poster = RecordingPoster()
        let field = FakeChromiumField(text, selection: selection, poster: poster, clock: clock, boldUnits: bold)
        let r = ScriptedReplacer(log: log)
        let selText = selection.map { s in String(decoding: Array(text.utf16)[s], as: UTF16.self) }
        r.focus = FocusInfo(role: "AXTextArea", isSecure: false, hasMarkedText: false, selTextSettable: true,
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
        return Rig(sut: sut, field: field, pasteboard: pb, poster: poster)
    }

    private func empty() -> WordSnapshot {
        WordSnapshot(strokes: [], previousWords: [], renderedIn: IDs.abc, isValid: false)
    }

    private func buffer(_ current: String) -> WordSnapshot {
        WordSnapshot(strokes: ConvertFixtures.strokes(current), previousWords: [], renderedIn: IDs.abc, isValid: true)
    }

    private func request(_ snapshot: WordSnapshot, gen: UInt64 = 1, app: String? = nil) -> ConvertRequest {
        ConvertRequest(snapshot: snapshot, gen: gen, bundleID: app ?? slack, mode: .convert, pair: ConvertFixtures.pair,
                       currentSource: IDs.abc, switchAfterConvert: true, useClipboard: true, allowsChromiumAX: true)
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

    @TextActor func testGmailBoldCopyIsNotPastedTheTypedRunConvertsByKeys() async {
        let rig = rig("שלום akuo vh", bold: 0..<4)
        axNeverSelects(rig)
        rig.pasteboard.copiedExtras = [.html("<div dir=\"ltr\"><b>שלום</b> akuo vh</div>")]
        let out = await rig.sut.handle(request(buffer("vh"), app: chrome), layouts: layouts)
        XCTAssertEqual(out, .converted(to: IDs.hebrew, by: .backspaceAndType(count: 2), switched: true),
                       "only the remembered run, by keys")
        XCTAssertEqual(pastes(rig.poster), 0, "no plain-text paste over the bold")
        XCTAssertEqual(rig.pasteboard.box, "שלום akuo vh", "the app's box was never replaced by a paste")
        XCTAssertTrue(rig.pasteboard.holdsUserClipboard, "the user's clipboard is back")
        XCTAssertEqual(log.claims, [1])
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
        rig.pasteboard.copiedExtras = [.html("<b>שלום</b> akuo")]
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
        rig.pasteboard.copiedExtras = [.html("vh <b>שלום</b>")]
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
        rig.pasteboard.copiedExtras = [.html("<b>שלום</b> akuo vh")]
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
}
