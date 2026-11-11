// P3-37 (b): ConvertController with a terminal buffer kept across a click or an app switch (`crossedFocus`): it converts
// by keys only in the element the buffer started in (`anchorTerminalBuffer`), else forgets it and just switches. Never a
// line break typed, never the clipboard, never AX. Fakes only.

import XCTest

final class ConvertControllerTerminalTests: XCTestCase {
    private let terminal = "com.apple.Terminal"
    private let cmux = "com.cmuxterm.app"
    private let layouts = ConvertFixtures.layouts

    private var log: ConvertLog!
    private var watcher: ConvertKeyWatcher!
    private var switches: SwitchRecorder!

    override func setUp() {
        log = ConvertLog()
        watcher = ConvertKeyWatcher(log: log)
        switches = SwitchRecorder(log: log)
    }

    @TextActor private func make() -> (ConvertController, ScriptedReplacer, FakeElement) {
        let r = ScriptedReplacer(log: log)
        r.focus = FocusInfo(role: "AXTextArea", isSecure: false, hasMarkedText: false, selTextSettable: true,
                            selRangeSettable: true, selection: nil, canReadBeforeCaret: true)
        let element = FakeElement()
        r.element = element
        let log = self.log!
        let sut = ConvertController(keyWatcher: watcher, clock: FakeClock(), beep: { log.add(.beep) },
                                    makeReplacer: { r }, switchLanguage: switches.hook)
        return (sut, r, element)
    }

    private func kept(_ text: String, epoch: UInt64, crossed: Bool = true) -> WordSnapshot {
        WordSnapshot(strokes: ConvertFixtures.strokes(text), previousWords: [], renderedIn: IDs.abc, isValid: true,
                     epoch: epoch, crossedFocus: crossed)
    }

    private func request(_ snap: WordSnapshot, gen: UInt64, app: String? = nil) -> ConvertRequest {
        ConvertRequest(snapshot: snap, gen: gen, bundleID: app ?? terminal, mode: .convert, pair: ConvertFixtures.pair,
                       currentSource: IDs.abc, switchAfterConvert: true, useClipboard: true)
    }

    @TextActor func testAKeptBufferInTheSameElementConvertsByKeys() async {
        let (sut, _, _) = make()
        sut.anchorTerminalBuffer(epoch: 7)
        let out = await sut.handle(request(kept("akuo", epoch: 7), gen: 1), layouts: layouts)
        XCTAssertEqual(out, .converted(to: IDs.hebrew, by: .backspaceAndType(count: 4), switched: true))
        XCTAssertEqual(log.performs, [.backspaceAndType(count: 4)], "never AX, never the clipboard in a terminal")
    }

    @TextActor func testAKeptBufferInAnotherWindowIsForgottenAndDoubleShiftJustSwitches() async {
        let (sut, r, _) = make()
        sut.anchorTerminalBuffer(epoch: 7)
        r.setNowFocused(FakeElement())    // another window / tab / split now
        let out = await sut.handle(request(kept("akuo", epoch: 7), gen: 1), layouts: layouts)
        XCTAssertEqual(out, .toggledOnly(to: IDs.hebrew, because: .nothingToConvert))
        XCTAssertTrue(log.performs.isEmpty, "no keys into the wrong window")
        XCTAssertEqual(log.finishes, [.finish(gen: 1, newRendering: nil, bufferAfter: [])], "forgotten")
        XCTAssertEqual(log.beeps, 0)
    }

    @TextActor func testAKeptBufferWithoutAnAnchorForItsEpochIsForgotten() async {
        let (sut, _, _) = make()
        sut.anchorTerminalBuffer(epoch: 6)
        let out = await sut.handle(request(kept("akuo", epoch: 7), gen: 1, app: cmux), layouts: layouts)
        XCTAssertEqual(out, .toggledOnly(to: IDs.hebrew, because: .nothingToConvert))
        XCTAssertTrue(log.performs.isEmpty)
    }

    @TextActor func testAnUnknownFocusForgetsAKeptBuffer() async {
        let (sut, r, element) = make()
        sut.anchorTerminalBuffer(epoch: 7)
        r.setNowFocused(nil)
        _ = element
        let out = await sut.handle(request(kept("akuo", epoch: 7), gen: 1), layouts: layouts)
        XCTAssertEqual(out, .toggledOnly(to: IDs.hebrew, because: .nothingToConvert))
    }

    @TextActor func testABufferTypedWithoutAClickNeedsNoAnchor() async {
        let (sut, _, _) = make()
        let out = await sut.handle(request(kept("akuo", epoch: 3, crossed: false), gen: 1), layouts: layouts)
        XCTAssertEqual(out, .converted(to: IDs.hebrew, by: .backspaceAndType(count: 4), switched: true))
    }

    func testCmuxIsATerminal() {
        XCTAssertEqual(ReplacementCapabilities().method(for: cmux), .terminal)
    }
}
