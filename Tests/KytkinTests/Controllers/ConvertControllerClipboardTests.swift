// P3-37 (owner 2026-11-11, plan.md P3-37; 001 §12.3 X12): ConvertController in apps whose text box can't be read:
// (a) nothing remembered → at least switch the language, (c) the clipboard convert (Slack multi-line box, direction,
// undo, every reason it is not used, fallback to the buffer, a known multi-line selection), with fakes only: a scripted
// replacer, a fake pasteboard + app, the fake clock. No real clipboard, no real events.

import XCTest

final class ConvertControllerClipboardTests: XCTestCase {
    private let slack = "com.tinyspeck.slackmacgap"
    private let chrome = "com.google.Chrome"
    private let vscode = "com.microsoft.VSCode"
    private let terminal = "com.apple.Terminal"
    private let textEdit = "com.apple.TextEdit"
    private let layouts = ConvertFixtures.layouts

    private var log: ConvertLog!
    private var watcher: ConvertKeyWatcher!
    private var switches: SwitchRecorder!
    private var clock: FakeClock!

    override func setUp() {
        log = ConvertLog()
        watcher = ConvertKeyWatcher(log: log)
        switches = SwitchRecorder(log: log)
        clock = FakeClock(nowNanos: 1_000_000_000)
    }

    private struct Rig {
        let sut: ConvertController
        let replacer: ScriptedReplacer
        let pasteboard: FakePasteboard
        let poster: RecordingPoster
        let element: FakeElement
    }

    @TextActor private func rig(box: String, focus: FocusInfo? = nil, caps: ReplacementCapabilities = .init(),
                                clipboardSeams: Bool = true) -> Rig {
        let r = ScriptedReplacer(log: log)
        r.focus = focus ?? FocusInfo(role: "AXTextArea", isSecure: false, hasMarkedText: false,
                                     selTextSettable: false, selRangeSettable: false, selection: nil)
        let element = FakeElement()
        r.element = element
        let poster = RecordingPoster()
        let pb = FakePasteboard(poster: poster, clock: clock, box: box)
        let clock = self.clock!
        let log = self.log!
        let clipboard = ClipboardConvert(pasteboard: pb, poster: poster, clock: clock,
                                         sleep: { nanos in clock.advance(byNanos: nanos) })
        var seams: (@TextActor @Sendable () -> ClipboardConvert?)?
        if clipboardSeams { seams = { @TextActor @Sendable () -> ClipboardConvert? in clipboard } }
        let sut = ConvertController(keyWatcher: watcher, clock: clock, capabilities: caps, beep: { log.add(.beep) },
                                    makeReplacer: { r }, switchLanguage: switches.hook, makeClipboard: seams)
        return Rig(sut: sut, replacer: r, pasteboard: pb, poster: poster, element: element)
    }

    private func empty(untouched: UInt64? = nil) -> WordSnapshot {
        WordSnapshot(strokes: [], previousWords: [], renderedIn: IDs.abc, isValid: false,
                     untouchedSinceConvert: untouched)
    }

    private func buffer(_ current: String, in source: InputSourceID = IDs.abc) -> WordSnapshot {
        WordSnapshot(strokes: ConvertFixtures.strokes(current), previousWords: [], renderedIn: source, isValid: true)
    }

    private func request(_ snapshot: WordSnapshot, gen: UInt64, app: String? = nil, useClipboard: Bool = true,
                         current: InputSourceID = IDs.abc) -> ConvertRequest {
        ConvertRequest(snapshot: snapshot, gen: gen, bundleID: app ?? slack, mode: .convert, pair: ConvertFixtures.pair,
                       currentSource: current, switchAfterConvert: true, useClipboard: useClipboard)
    }

    private func pastes(_ poster: RecordingPoster) -> Int {
        poster.events.filter { $0.isKeyDown && $0.modifierFlags != 0 && $0.keyCode == ClipboardShortcut.paste.keyCode }
            .count
    }

    private func clipboardKeys(_ poster: RecordingPoster) -> Int {
        poster.events.filter { $0.modifierFlags != 0 }.count
    }

    // MARK: - The Slack multi-line box

    @TextActor func testAMultiLineSlackBoxConvertsEveryLineThroughTheClipboard() async {
        let rig = rig(box: "akuo\nnv nmc")
        let out = await rig.sut.handle(request(empty(), gen: 1), layouts: layouts)
        XCTAssertEqual(out, .converted(to: IDs.hebrew, by: .pasteboard, switched: true))
        XCTAssertEqual(rig.pasteboard.box, "שלום\nמה מצב", "both lines")
        XCTAssertTrue(rig.pasteboard.holdsUserClipboard, "the user's clipboard is back after the finish")
        XCTAssertEqual(log.claims, [1])
        XCTAssertEqual(log.finishes, [.finish(gen: 1, newRendering: nil, bufferAfter: [])])
        XCTAssertEqual(log.switches, [.switchTo(IDs.hebrew, keepsBuffer: true)])
        XCTAssertEqual(log.beeps, 0)
        XCTAssertTrue(log.performs.isEmpty, "no key steps")
    }

    @TextActor func testTheFinishComesBeforeTheClipboardRestore() async {
        let rig = rig(box: "akuo")
        rig.pasteboard.log = log
        _ = await rig.sut.handle(request(empty(), gen: 1), layouts: layouts)
        let finish = log.entries.firstIndex { if case .finish = $0 { true } else { false } }
        let restore = log.entries.firstIndex(of: .clipboardRestored)
        XCTAssertNotNil(finish)
        XCTAssertNotNil(restore)
        XCTAssertLessThan(finish ?? .max, restore ?? .min, "held keys replay before the restore wait")
        XCTAssertTrue(rig.pasteboard.holdsUserClipboard)
    }

    @TextActor func testTheDirectionIsTheRememberedBuffersLanguage() async {
        // The box ends in Hebrew, but the user just typed English letters meaning Hebrew (the buffer).
        let rig = rig(box: "akuo שלום")
        let out = await rig.sut.handle(request(buffer("akuo"), gen: 1), layouts: layouts)
        XCTAssertEqual(out, .converted(to: IDs.hebrew, by: .pasteboard, switched: true))
        XCTAssertEqual(rig.pasteboard.box, "שלום שלום")
    }

    @TextActor func testWithNothingRememberedTheBoxsLastLetterDecides() async {
        let rig = rig(box: "akuo שלום")
        let out = await rig.sut.handle(request(empty(), gen: 1), layouts: layouts)
        XCTAssertEqual(out, .converted(to: IDs.abc, by: .pasteboard, switched: true))
        XCTAssertEqual(rig.pasteboard.box, "akuo akuo")
    }

    @TextActor func testDoubleShiftAgainRightAwayPastesTheOriginalBack() async {
        let rig = rig(box: "Akuo\nvh")
        _ = await rig.sut.handle(request(empty(), gen: 1), layouts: layouts)
        XCTAssertEqual(rig.pasteboard.box, "שלום\nהי")
        XCTAssertNotNil(rig.sut.lastClip)
        let back = await rig.sut.handle(request(empty(untouched: 1), gen: 2), layouts: layouts)
        XCTAssertEqual(back, .converted(to: IDs.abc, by: .pasteboard, switched: true))
        XCTAssertEqual(rig.pasteboard.box, "Akuo\nvh", "exactly, capital A too")
        XCTAssertNil(rig.sut.lastClip, "an undo keeps no record")
        XCTAssertTrue(rig.pasteboard.holdsUserClipboard)
        _ = await rig.sut.handle(request(empty(untouched: 2), gen: 3), layouts: layouts)
        XCTAssertEqual(rig.pasteboard.box, "שלום\nהי", "a third double-Shift converts again")
    }

    @TextActor func testTheUndoNeedsNothingTouchedSince() async {
        let rig = rig(box: "Akuo")
        _ = await rig.sut.handle(request(empty(), gen: 1), layouts: layouts)
        _ = await rig.sut.handle(request(empty(untouched: nil), gen: 2), layouts: layouts)   // a key since
        XCTAssertEqual(rig.pasteboard.box, "akuo", "a normal convert back, not the exact original")
    }

    @TextActor func testTheUndoRecordIsDroppedOnTheNextKeyClickOrFocusChange() async {
        let rig = rig(box: "akuo")
        _ = await rig.sut.handle(request(empty(), gen: 1), layouts: layouts)
        XCTAssertNotNil(rig.sut.lastClip)
        rig.sut.forgetUndoRecord()
        XCTAssertNil(rig.sut.lastClip)
    }

    @TextActor func testTheUndoRecordHoldsOnlyTheReplacedText() async {
        let rig = rig(box: "akuo")
        _ = await rig.sut.handle(request(empty(), gen: 1), layouts: layouts)
        let fields = Mirror(reflecting: rig.sut.lastClip!).children.compactMap(\.label)
        XCTAssertEqual(fields, ["gen", "bundleID", "processID", "fingerprint", "original", "from", "to"])
    }

    // MARK: - Fallbacks

    // P3-37 QA: after ⌘A and the Right arrow the caret is at the end of the box (or one character further), not where
    // the buffer ends: typing the buffer by keys then would backspace over the wrong text.
    @TextActor func testNoCopyAfterSelectAllWithABufferBeepsAndTypesNothing() async {
        for copies in ["", nil] as [String?] {
            log = ConvertLog()
            watcher = ConvertKeyWatcher(log: log)
            switches = SwitchRecorder(log: log)
            let rig = rig(box: "akuo")
            if let copies { rig.pasteboard.copiesInstead = copies } else { rig.pasteboard.copyDelayNanos = nil }
            let out = await rig.sut.handle(request(buffer("akuo"), gen: 1), layouts: layouts)
            XCTAssertEqual(out, .noop(.replacement(.exhausted)))
            XCTAssertEqual(log.beeps, 1)
            XCTAssertTrue(log.performs.isEmpty, "no key steps")
            XCTAssertFalse(rig.poster.events.contains { $0.keyCode == KeyCode.delete }, "no Backspace posted")
            XCTAssertEqual(log.finishes, [.finish(gen: 1, newRendering: nil, bufferAfter: [])], "buffer forgotten")
            XCTAssertEqual(rig.pasteboard.box, "akuo", "the box is untouched")
            XCTAssertTrue(rig.pasteboard.holdsUserClipboard)
        }
    }

    @TextActor func testNoSnapshotFallsBackToTheRememberedBufferWithOneClaim() async {
        let rig = rig(box: "akuo")
        rig.pasteboard.snapshotFails = true   // nothing posted: the caret is still where the buffer ends
        let out = await rig.sut.handle(request(buffer("akuo"), gen: 1), layouts: layouts)
        XCTAssertEqual(out, .converted(to: IDs.hebrew, by: .backspaceAndType(count: 4), switched: true))
        XCTAssertEqual(clipboardKeys(rig.poster), 0)
        XCTAssertEqual(log.claims, [1])
        XCTAssertTrue(rig.pasteboard.holdsUserClipboard)
    }

    // P3-37 QA: an unseeded app could be a terminal Kytkin doesn't know (xterm.js reads as an AXTextArea).
    @TextActor func testAnUnseededAppNeverGetsAPastedLineBreak() async {
        let rig = rig(box: "akuo\nls")
        let out = await rig.sut.handle(request(empty(), gen: 1, app: "com.example.Chat"), layouts: layouts)
        XCTAssertEqual(out, .noop(.replacement(.refused(.unsafeSelection))))
        XCTAssertEqual(log.beeps, 1)
        XCTAssertEqual(pastes(rig.poster), 0)
        XCTAssertEqual(rig.pasteboard.box, "akuo\nls")
        XCTAssertTrue(rig.pasteboard.holdsUserClipboard)
    }

    @TextActor func testAnUnseededAppsKnownMultiLineSelectionIsNotPasted() async {
        let selected = FocusInfo(role: "AXTextArea", isSecure: false, hasMarkedText: false, selTextSettable: false,
                                 selRangeSettable: false, selection: "akuo\nvh")
        let rig = rig(box: "", focus: selected)
        _ = await rig.sut.handle(request(empty(), gen: 1, app: "com.example.Chat"), layouts: layouts)
        XCTAssertEqual(pastes(rig.poster), 0)
        XCTAssertTrue(rig.pasteboard.transientWrites.isEmpty)
        XCTAssertTrue(rig.pasteboard.holdsUserClipboard)
    }

    // P3-37 QA: ⌘ + key 0 is read in the layout in front; one outside the pair is unchecked (AZERTY: ⌘Q).
    @TextActor func testNeverWhenTheLayoutInFrontIsOutsideThePair() async {
        let rig = rig(box: "akuo")
        let out = await rig.sut.handle(request(empty(), gen: 1, current: InputSourceID("com.apple.keylayout.French")),
                                       layouts: layouts)
        XCTAssertEqual(clipboardKeys(rig.poster), 0)
        if case .converted = out { XCTFail("no clipboard convert") }
    }

    @TextActor func testAnAppThatCantCopyWithNothingRememberedJustSwitches() async {
        let rig = rig(box: "akuo")
        rig.pasteboard.copyDelayNanos = nil
        let out = await rig.sut.handle(request(empty(), gen: 1), layouts: layouts)
        XCTAssertEqual(out, .toggledOnly(to: IDs.hebrew, because: .nothingToConvert))
        XCTAssertEqual(log.beeps, 0)
        XCTAssertTrue(rig.pasteboard.holdsUserClipboard)
    }

    @TextActor func testABoxWithNothingToConvertJustSwitches() async {
        let rig = rig(box: "123 !!")
        let out = await rig.sut.handle(request(empty(), gen: 1), layouts: layouts)
        XCTAssertEqual(out, .toggledOnly(to: IDs.hebrew, because: .nothingToConvert))
        XCTAssertEqual(pastes(rig.poster), 0)
        XCTAssertTrue(rig.pasteboard.holdsUserClipboard)
    }

    @TextActor func testABoxOverTheCapBeeps() async {
        let rig = rig(box: String(repeating: "a", count: ReplacementPlanner.maxFieldReadChars + 1))
        let out = await rig.sut.handle(request(empty(), gen: 1), layouts: layouts)
        XCTAssertEqual(out, .noop(.runTooLong))
        XCTAssertEqual(log.beeps, 1)
        XCTAssertTrue(rig.pasteboard.holdsUserClipboard)
    }

    @TextActor func testFocusMovingAwayStopsWithABeep() async {
        let rig = rig(box: "akuo")
        rig.replacer.setNowFocused(FakeElement())
        let out = await rig.sut.handle(request(empty(), gen: 1), layouts: layouts)
        XCTAssertEqual(out, .noop(.replacement(.halted(after: .pasteboard))))
        XCTAssertEqual(clipboardKeys(rig.poster), 0)
        XCTAssertTrue(rig.pasteboard.holdsUserClipboard)
    }

    // MARK: - Where the clipboard is never used

    @TextActor func testTheSettingOffNeverTouchesTheClipboard() async {
        let rig = rig(box: "akuo")
        let out = await rig.sut.handle(request(buffer("akuo"), gen: 1, useClipboard: false), layouts: layouts)
        XCTAssertEqual(out, .converted(to: IDs.hebrew, by: .backspaceAndType(count: 4), switched: true))
        XCTAssertEqual(clipboardKeys(rig.poster), 0)
        XCTAssertEqual(rig.pasteboard.restores, 0)
    }

    @TextActor func testNeverInATerminal() async {
        let rig = rig(box: "akuo")
        let out = await rig.sut.handle(request(empty(), gen: 1, app: terminal), layouts: layouts)
        XCTAssertEqual(out, .toggledOnly(to: IDs.hebrew, because: .nothingToConvert))
        XCTAssertTrue(rig.poster.events.isEmpty)
        // P3-37 QA: more terminals seeded (Electron / xterm.js ones would otherwise be `.auto`).
        for id in ["org.tabby", "dev.commandline.waveterm", "com.raphaelamorim.rio", "dev.warp.Warp-Preview",
                   "com.cmuxterm.app"] {
            XCTAssertEqual(ReplacementCapabilities().method(for: id), .terminal, id)
        }
    }

    @TextActor func testNeverInACodeEditor() async {
        let rig = rig(box: "let x = 1")
        let out = await rig.sut.handle(request(empty(), gen: 1, app: vscode), layouts: layouts)
        XCTAssertEqual(out, .toggledOnly(to: IDs.hebrew, because: .nothingToConvert))
        XCTAssertTrue(rig.poster.events.isEmpty)
        XCTAssertTrue(ReplacementCapabilities.isEditor("com.jetbrains.intellij"))
    }

    @TextActor func testTheUsersKeysOnlyChoiceMeansNoClipboard() async {
        let rig = rig(box: "akuo", caps: ReplacementCapabilities(overrides: [slack: .keysOnly]))
        let out = await rig.sut.handle(request(empty(), gen: 1), layouts: layouts)
        XCTAssertEqual(out, .toggledOnly(to: IDs.hebrew, because: .nothingToConvert))
        XCTAssertTrue(rig.poster.events.isEmpty)
    }

    @TextActor func testASeededKeysOnlyBrowserUsesIt() async {
        let rig = rig(box: "akuo")
        let out = await rig.sut.handle(request(empty(), gen: 1, app: chrome), layouts: layouts)
        XCTAssertEqual(out, .converted(to: IDs.hebrew, by: .pasteboard, switched: true))
    }

    @TextActor func testAnOtherAppsUnreadableTextBoxUsesIt() async {
        let rig = rig(box: "akuo")   // an `.auto` app whose AXTextArea can't be written through AX
        let out = await rig.sut.handle(request(empty(), gen: 1, app: "com.example.Chat"), layouts: layouts)
        XCTAssertEqual(out, .converted(to: IDs.hebrew, by: .pasteboard, switched: true))
    }

    @TextActor func testNeverOnAListTableOrFileBrowserInAnOtherApp() async {
        for role in ["AXTable", "AXList", "AXOutline", "AXGroup"] {
            let focus = FocusInfo(role: role, isSecure: false, hasMarkedText: false, selTextSettable: false,
                                  selRangeSettable: false, selection: nil)
            let rig = rig(box: "akuo", focus: focus)
            let out = await rig.sut.handle(request(empty(), gen: 1, app: "com.apple.finder"), layouts: layouts)
            XCTAssertEqual(out, .toggledOnly(to: IDs.hebrew, because: .nothingToConvert), role)
            XCTAssertTrue(rig.poster.events.isEmpty, "⌘A there would select every item: \(role)")
        }
    }

    @TextActor func testNeverInABrowsersAddressBar() async {
        let rig = rig(box: "github.com")
        let r = ConvertRequest(snapshot: empty(), gen: 1, bundleID: chrome, mode: .convert, pair: ConvertFixtures.pair,
                               currentSource: IDs.abc, useClipboard: true, inAddressBar: true)
        let out = await rig.sut.handle(r, layouts: layouts)
        XCTAssertEqual(out, .toggledOnly(to: IDs.hebrew, because: .nothingToConvert))
        XCTAssertTrue(rig.poster.events.isEmpty, "a focused address bar is never read")
    }

    @TextActor func testNeverInAPasswordFieldItJustSwitches() async {
        let secure = FocusInfo(role: FocusInfo.secureTextFieldRole, isSecure: true, hasMarkedText: false,
                               selTextSettable: false, selRangeSettable: false, selection: nil)
        let rig = rig(box: "akuo", focus: secure)
        let out = await rig.sut.handle(request(empty(), gen: 1), layouts: layouts)
        XCTAssertEqual(out, .toggledOnly(to: IDs.hebrew, because: .fieldUnreadable))
        XCTAssertTrue(rig.poster.events.isEmpty)
        XCTAssertEqual(log.beeps, 0)
    }

    @TextActor func testNeverWhileComposingItJustSwitches() async {
        let composing = FocusInfo(role: "AXTextArea", isSecure: false, hasMarkedText: true, selTextSettable: false,
                                  selRangeSettable: false, selection: nil)
        let rig = rig(box: "akuo", focus: composing)
        let out = await rig.sut.handle(request(empty(), gen: 1), layouts: layouts)
        XCTAssertEqual(out, .toggledOnly(to: IDs.hebrew, because: .fieldUnreadable))
        XCTAssertTrue(rig.poster.events.isEmpty)
    }

    @TextActor func testNeverWithoutAFocusedElementItJustSwitches() async {
        let rig = rig(box: "akuo")
        rig.replacer.focus = nil
        let out = await rig.sut.handle(request(empty(), gen: 1), layouts: layouts)
        XCTAssertEqual(out, .toggledOnly(to: IDs.hebrew, because: .fieldUnreadable))
        XCTAssertTrue(rig.poster.events.isEmpty)
    }

    @TextActor func testAReadableFieldUsesAXNotTheClipboard() async {
        let readable = FocusInfo(role: "AXTextArea", isSecure: false, hasMarkedText: false, selTextSettable: true,
                                 selRangeSettable: true, selection: nil, canReadBeforeCaret: true)
        let rig = rig(box: "akuo", focus: readable)
        rig.replacer.foundWord = "akuo"
        let out = await rig.sut.handle(request(empty(), gen: 1, app: textEdit), layouts: layouts)
        XCTAssertEqual(out, .converted(to: IDs.hebrew, by: .axWriteSelection(verify: true), switched: true))
        XCTAssertTrue(rig.poster.events.isEmpty)
    }

    @TextActor func testNoClipboardSeamsNoClipboard() async {
        let rig = rig(box: "akuo", clipboardSeams: false)
        let out = await rig.sut.handle(request(buffer("akuo"), gen: 1), layouts: layouts)
        XCTAssertEqual(out, .converted(to: IDs.hebrew, by: .backspaceAndType(count: 4), switched: true))
    }

    // MARK: - A known selection

    @TextActor func testAKnownMultiLineSelectionIsPastedOver() async {
        let selected = FocusInfo(role: "AXTextArea", isSecure: false, hasMarkedText: false, selTextSettable: false,
                                 selRangeSettable: false, selection: "akuo\nvh")
        let rig = rig(box: "", focus: selected)
        let out = await rig.sut.handle(request(empty(), gen: 1), layouts: layouts)
        XCTAssertEqual(out, .converted(to: IDs.hebrew, by: .pasteboard, switched: true))
        XCTAssertEqual(rig.pasteboard.transientWrites, ["שלום\nהי"])
        XCTAssertEqual(clipboardKeys(rig.poster), 2, "⌘V only")
        XCTAssertNil(rig.sut.lastClip, "a selection keeps no clipboard undo")
        XCTAssertTrue(rig.pasteboard.holdsUserClipboard)
    }

    @TextActor func testAKnownOneLineSelectionIsStillTypedOver() async {
        let selected = FocusInfo(role: "AXTextArea", isSecure: false, hasMarkedText: false, selTextSettable: false,
                                 selRangeSettable: false, selection: "akuo")
        let rig = rig(box: "", focus: selected)
        let out = await rig.sut.handle(request(empty(), gen: 1), layouts: layouts)
        XCTAssertEqual(out, .converted(to: IDs.hebrew, by: .typeOverSelection, switched: true))
        XCTAssertTrue(rig.poster.events.isEmpty)
    }
}
