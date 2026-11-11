// P3-42 (001 §12.3 X15): ConvertController with the Chromium/Electron AX convert: which apps and requests use it, that it
// runs before the clipboard, that anything it can't vouch for before typing falls back to the P3-37 / P3-40 path exactly
// as before, the kill switch, and the buffer / switch / beep handling. Fakes only: a scripted replacer for the focus
// facts, a fake Chromium box, a fake pasteboard + app, the fake clock. No AX, no events, no real clipboard.

import XCTest

final class ConvertControllerChromiumTests: XCTestCase {
    private let slack = "com.tinyspeck.slackmacgap"
    private let chrome = "com.google.Chrome"
    private let vscode = "com.microsoft.VSCode"
    private let textEdit = "com.apple.TextEdit"
    private let layouts = ConvertFixtures.layouts

    private var log: ConvertLog!
    private var watcher: ConvertKeyWatcher!
    private var switches: SwitchRecorder!
    private var clock: FakeClock!

    override func setUp() { reset() }

    private func reset() {
        log = ConvertLog()
        watcher = ConvertKeyWatcher(log: log)
        switches = SwitchRecorder(log: log)
        clock = FakeClock(nowNanos: 1_000_000_000)
    }

    private struct Rig {
        let sut: ConvertController
        let replacer: ScriptedReplacer
        let field: FakeChromiumField
        let pasteboard: FakePasteboard
        let poster: RecordingPoster
    }

    @TextActor private func rig(_ text: String, caret: Int? = nil, selection: Range<Int>? = nil,
                                caps: ReplacementCapabilities = .init(), enabled: Bool = true,
                                role: String = "AXTextArea") -> Rig {
        let poster = RecordingPoster()
        let field = FakeChromiumField(text, caret: caret, selection: selection, poster: poster, clock: clock)
        let r = ScriptedReplacer(log: log)
        let selText = selection.map { s in String(decoding: Array(text.utf16)[s], as: UTF16.self) }
        r.focus = FocusInfo(role: role, isSecure: false, hasMarkedText: false, selTextSettable: true,
                            selRangeSettable: true, selection: selText)
        r.element = field
        let pb = FakePasteboard(poster: poster, clock: clock, box: text)
        let clock = self.clock!
        let log = self.log!
        let clipboard = ClipboardConvert(pasteboard: pb, poster: poster, clock: clock,
                                         sleep: { nanos in clock.advance(byNanos: nanos) })
        let ax = ChromiumAXConvert(focusProvider: SwitchableFocusProvider(field), poster: poster, clock: clock,
                                   sleep: { nanos in clock.advance(byNanos: nanos) })
        let sut = ConvertController(keyWatcher: watcher, clock: clock, capabilities: caps, beep: { log.add(.beep) },
                                    makeReplacer: { r }, switchLanguage: switches.hook,
                                    makeClipboard: { @TextActor @Sendable () -> ClipboardConvert? in clipboard },
                                    makeChromiumAX: { @TextActor @Sendable () -> ChromiumAXConvert? in ax },
                                    chromiumAXEnabled: enabled)
        return Rig(sut: sut, replacer: r, field: field, pasteboard: pb, poster: poster)
    }

    private func empty() -> WordSnapshot {
        WordSnapshot(strokes: [], previousWords: [], renderedIn: IDs.abc, isValid: false)
    }

    private func buffer(_ current: String) -> WordSnapshot {
        WordSnapshot(strokes: ConvertFixtures.strokes(current), previousWords: [], renderedIn: IDs.abc, isValid: true)
    }

    private func request(_ snapshot: WordSnapshot, gen: UInt64, app: String? = nil, useClipboard: Bool = true,
                         allows: Bool = true, inAddressBar: Bool = false,
                         current: InputSourceID = IDs.abc) -> ConvertRequest {
        ConvertRequest(snapshot: snapshot, gen: gen, bundleID: app ?? slack, mode: .convert, pair: ConvertFixtures.pair,
                       currentSource: current, switchAfterConvert: true, useClipboard: useClipboard,
                       inAddressBar: inAddressBar, allowsChromiumAX: allows)
    }

    private func clipboardKeys(_ poster: RecordingPoster) -> Int {
        poster.events.filter { $0.modifierFlags != 0 }.count
    }

    // MARK: - The path

    @TextActor func testSlackBoxConvertsThroughAXPiecesNotTheClipboard() async {
        let rig = rig("שלום akuo\nnv nmc")
        let out = await rig.sut.handle(request(empty(), gen: 1), layouts: layouts)
        XCTAssertEqual(out, .converted(to: IDs.hebrew, by: .axSelectAndType, switched: true))
        XCTAssertEqual(rig.field.text, "שלום שלום\nמה מצב")
        XCTAssertEqual(clipboardKeys(rig.poster), 0, "no ⌘A / ⌘C / ⌘V")
        XCTAssertEqual(rig.pasteboard.restores, 0, "the clipboard is never touched")
        XCTAssertEqual(rig.field.selectedTextWrites, 0)
        XCTAssertEqual(log.claims, [1])
        XCTAssertEqual(log.finishes, [.finish(gen: 1, newRendering: nil, bufferAfter: [])])
        XCTAssertEqual(log.switches, [.switchTo(IDs.hebrew, keepsBuffer: true)])
        XCTAssertEqual(log.beeps, 0)
    }

    @TextActor func testEveryChromiumBrowserAndChatAppGetsIt() async {
        for app in ["com.google.Chrome", "com.microsoft.edgemac", "com.brave.Browser", "company.thebrowser.Browser",
                    "com.vivaldi.Vivaldi", "com.operasoftware.Opera", "com.hnc.Discord", "com.microsoft.teams2"] {
            reset()
            let rig = rig("akuo")
            let out = await rig.sut.handle(request(empty(), gen: 1, app: app), layouts: layouts)
            XCTAssertEqual(out, .converted(to: IDs.hebrew, by: .axSelectAndType, switched: true), app)
        }
    }

    @TextActor func testDoubleShiftAgainConvertsAgain() async {
        let rig = rig("akuo")
        _ = await rig.sut.handle(request(empty(), gen: 1), layouts: layouts)
        XCTAssertEqual(rig.field.text, "שלום")
        let second = await rig.sut.handle(request(empty(), gen: 2, current: IDs.hebrew), layouts: layouts)
        XCTAssertEqual(second, .converted(to: IDs.abc, by: .axSelectAndType, switched: true))
        XCTAssertEqual(rig.field.text, "akuo")
    }

    @TextActor func testSelectionConvertsThroughAXPiecesAndKeepsItsLineBreak() async {
        let rig = rig("ok akuo\nakuo ok", selection: 3..<12)
        rig.field.selectedTextDropsLineBreaks = true   // Chromium (P3-40)
        let out = await rig.sut.handle(request(empty(), gen: 1), layouts: layouts)
        XCTAssertEqual(out, .converted(to: IDs.hebrew, by: .axSelectAndType, switched: true))
        XCTAssertEqual(rig.field.text, "ok שלום\nשלום ok")
        XCTAssertEqual(clipboardKeys(rig.poster), 0, "not the P3-40 ⌘C path")
        XCTAssertEqual(log.switches, [.switchTo(IDs.hebrew, keepsBuffer: false)], "a selection keeps P2-21's switch")
    }

    @TextActor func testWorksWithTheClipboardSwitchOff() async {
        let rig = rig("akuo")
        let out = await rig.sut.handle(request(empty(), gen: 1, useClipboard: false), layouts: layouts)
        XCTAssertEqual(out, .converted(to: IDs.hebrew, by: .axSelectAndType, switched: true))
    }

    // MARK: - Fallbacks (nothing typed)

    @TextActor func testSlackEmojiDriftFallsBackToTheClipboard() async {
        let rig = rig("akuo 😀 akuo")
        rig.field.hidden = 5..<7
        rig.field.setRangeDrifts = true
        let out = await rig.sut.handle(request(empty(), gen: 1), layouts: layouts)
        XCTAssertEqual(out, .converted(to: IDs.hebrew, by: .pasteboard, switched: true), "the P3-37 clipboard path")
        XCTAssertEqual(rig.field.text, "akuo 😀 akuo", "nothing typed into the box through AX")
        XCTAssertEqual(rig.pasteboard.box, "שלום 😀 שלום")
        XCTAssertEqual(log.claims, [1], "one claim shared by both paths")
        XCTAssertEqual(log.beeps, 0)
    }

    @TextActor func testNotWebContentFallsBack() async {
        let rig = rig("akuo")
        rig.field.webContent = false
        let out = await rig.sut.handle(request(empty(), gen: 1, app: chrome), layouts: layouts)
        XCTAssertEqual(out, .converted(to: IDs.hebrew, by: .pasteboard, switched: true))
        XCTAssertTrue(rig.field.rangeWrites.isEmpty)
    }

    @TextActor func testFallbackWithTheClipboardOffUsesTheRememberedBuffer() async {
        let rig = rig("akuo")
        rig.field.numberOfCharactersOverride = 9   // an inconsistent read
        let out = await rig.sut.handle(request(buffer("akuo"), gen: 1, useClipboard: false), layouts: layouts)
        XCTAssertEqual(out, .converted(to: IDs.hebrew, by: .backspaceAndType(count: 4), switched: true))
        XCTAssertEqual(clipboardKeys(rig.poster), 0)
    }

    // MARK: - Where it is never used

    @TextActor func testNotUsedWhereItMustNotRun() async {
        var userKeysOnly = ReplacementCapabilities()
        userKeysOnly.setOverride(.keysOnly, for: chrome)
        let cases: [(String, ConvertRequest, ReplacementCapabilities, Bool)] = [
            ("VS Code", request(empty(), gen: 1, app: vscode), .init(), true),
            ("an unseeded app", request(empty(), gen: 1, app: "com.example.app"), .init(), true),
            ("the user's Keys only", request(empty(), gen: 1, app: chrome), userKeysOnly, true),
            ("a whole-document site", request(empty(), gen: 1, app: chrome, allows: false), .init(), true),
            ("the address bar", request(empty(), gen: 1, app: chrome, inAddressBar: true), .init(), true),
            ("the kill switch", request(empty(), gen: 1, app: chrome), .init(), false),
        ]
        for (name, req, caps, enabled) in cases {
            reset()
            let rig = rig("akuo", caps: caps, enabled: enabled)
            _ = await rig.sut.handle(req, layouts: layouts)
            XCTAssertTrue(rig.field.rangeWrites.isEmpty, name)
            XCTAssertEqual(rig.field.text, "akuo", name)
        }
    }

    @TextActor func testKillSwitchLeavesTheClipboardPathAsBefore() async {
        let rig = rig("akuo", enabled: false)
        let out = await rig.sut.handle(request(empty(), gen: 1), layouts: layouts)
        XCTAssertEqual(out, .converted(to: IDs.hebrew, by: .pasteboard, switched: true))
    }

    @TextActor func testAReadableCocoaAppKeepsItsAXPath() async {
        let rig = rig("akuo")
        _ = await rig.sut.handle(request(empty(), gen: 1, app: textEdit), layouts: layouts)
        XCTAssertTrue(rig.field.rangeWrites.isEmpty)
    }

    @TextActor func testASecureOrComposingFocusNeverUsesIt() async {
        for (secure, composing) in [(true, false), (false, true)] {
            reset()
            let rig = rig("akuo")
            rig.replacer.focus = FocusInfo(role: "AXTextArea", isSecure: secure, hasMarkedText: composing,
                                           selTextSettable: true, selRangeSettable: true, selection: nil)
            _ = await rig.sut.handle(request(empty(), gen: 1), layouts: layouts)
            XCTAssertTrue(rig.field.rangeWrites.isEmpty)
        }
    }

    // MARK: - Stops after typing

    @TextActor func testAPartialConvertBeepsAndForgetsTheBuffer() async {
        let rig = rig("akuo akuo")
        let clock = self.clock!
        rig.field.onSetRange = { r in if !r.isCaret { clock.advance(byMilliseconds: 450) } }
        let out = await rig.sut.handle(request(buffer("akuo akuo"), gen: 1), layouts: layouts)
        XCTAssertEqual(out, .noop(.replacement(.halted(after: .axSelectAndType))))
        XCTAssertEqual(rig.field.text, "akuo שלום")
        XCTAssertEqual(log.beeps, 1)
        XCTAssertEqual(log.finishes, [.finish(gen: 1, newRendering: nil, bufferAfter: [])])
        XCTAssertEqual(clipboardKeys(rig.poster), 0, "never a second path after typing")
    }

    @TextActor func testNothingToConvertJustSwitches() async {
        let rig = rig("123 456")
        rig.replacer.focus = FocusInfo(role: "AXTextArea", isSecure: false, hasMarkedText: false,
                                       selTextSettable: true, selRangeSettable: true, selection: nil)
        let out = await rig.sut.handle(request(empty(), gen: 1, current: IDs.hebrew), layouts: layouts)
        XCTAssertEqual(out, .toggledOnly(to: IDs.abc, because: .nothingToConvert))
    }

    @TextActor func testTheControllerKeepsNoText() async {
        let rig = rig("Akuo")
        _ = await rig.sut.handle(request(empty(), gen: 1), layouts: layouts)
        XCTAssertFalse(ConvertControllerTests.containsString(Mirror(reflecting: rig.sut)), "no text anywhere inside")
    }

    // MARK: - The family hint

    func testFamilyHint() {
        var caps = ReplacementCapabilities()
        XCTAssertEqual(caps.family(for: slack), .chromiumAX)
        XCTAssertEqual(caps.family(for: "COM.GOOGLE.CHROME"), .chromiumAX)
        XCTAssertNil(caps.family(for: vscode))
        XCTAssertNil(caps.family(for: "com.apple.Terminal"))
        XCTAssertNil(caps.family(for: textEdit))
        caps.setOverride(.auto, for: slack)
        XCTAssertNil(caps.family(for: slack), "the user's own method wins")
    }
}
