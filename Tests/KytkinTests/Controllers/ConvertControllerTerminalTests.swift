// P3-37 (b): ConvertController with a terminal buffer kept across a click or an app switch (`crossedFocus`): it converts
// by keys only in the element the buffer started in (`anchorTerminalBuffer`), else forgets it and just switches. Never a
// line break typed, never the clipboard, never AX. Fakes only.
// P3-41 (owner 2026-11-11, cmux "the switch doesn't work at all"): a Ghostty-based terminal whose AX names no focused
// element, a different one on every read, or answers the secure / marked-text reads with errors still converts the
// buffer by keys (`postTerminalKeys`), or at least switches; a buffer kept across an app switch is trusted when AX
// can't name the element, unless a click happened since its first key.

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

    private func kept(_ text: String, epoch: UInt64, crossed: Bool = true, clicked: Bool = false) -> WordSnapshot {
        WordSnapshot(strokes: ConvertFixtures.strokes(text), previousWords: [], renderedIn: IDs.abc,
                     isValid: !text.isEmpty, epoch: epoch, crossedFocus: crossed, clickedSinceStart: clicked)
    }

    private func request(_ snap: WordSnapshot, gen: UInt64, app: String? = nil) -> ConvertRequest {
        ConvertRequest(snapshot: snap, gen: gen, bundleID: app ?? terminal, mode: .convert, pair: ConvertFixtures.pair,
                       currentSource: IDs.abc, switchAfterConvert: true, useClipboard: true, processID: 4242)
    }

    private func typed(_ text: String) -> WordSnapshot { kept(text, epoch: 1, crossed: false) }

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

    /// P3-41: was "a kept buffer without an anchor for its epoch is forgotten". No anchor = identity unknown: forgotten
    /// after a click, trusted after only an app switch away and back.
    @TextActor func testAKeptBufferWithoutAnAnchorForItsEpochIsForgottenOnlyAfterAClick() async {
        let (sut, _, _) = make()
        sut.anchorTerminalBuffer(epoch: 6)
        let out = await sut.handle(request(kept("akuo", epoch: 7, clicked: true), gen: 1, app: cmux), layouts: layouts)
        XCTAssertEqual(out, .toggledOnly(to: IDs.hebrew, because: .nothingToConvert))
        XCTAssertTrue(log.performs.isEmpty)
        let again = await sut.handle(request(kept("akuo", epoch: 7), gen: 2, app: cmux), layouts: layouts)
        XCTAssertEqual(again, .converted(to: IDs.hebrew, by: .backspaceAndType(count: 4), switched: true))
    }

    /// P3-41: was "an unknown focus forgets a kept buffer" (always). Now only after a click.
    @TextActor func testAnUnknownFocusForgetsAKeptBufferOnlyAfterAClick() async {
        let (sut, r, _) = make()
        sut.anchorTerminalBuffer(epoch: 7)
        r.setNowFocused(nil)
        let out = await sut.handle(request(kept("akuo", epoch: 7, clicked: true), gen: 1), layouts: layouts)
        XCTAssertEqual(out, .toggledOnly(to: IDs.hebrew, because: .nothingToConvert))
        XCTAssertTrue(log.performs.isEmpty, "a click may have moved to another split: no keys")
    }

    // MARK: - P3-41: cmux (Ghostty-based) with missing or unstable AX

    /// The anchor found no element at the buffer's first key (AX names nothing in the terminal), then an app switch
    /// away and back: before P3-41 the buffer was always forgotten.
    @TextActor func testABufferAnchoredToNoElementIsTrustedAfterOnlyAnAppSwitch() async {
        let (sut, r, _) = make()
        r.setNowFocused(nil)
        sut.anchorTerminalBuffer(epoch: 7)
        let out = await sut.handle(request(kept("akuo", epoch: 7), gen: 1, app: cmux), layouts: layouts)
        XCTAssertEqual(out, .converted(to: IDs.hebrew, by: .backspaceAndType(count: 4), switched: true))
        XCTAssertEqual(r.writes.map(\.new), ["שלום"])
    }

    @TextActor func testNoFocusedElementAtAllStillConvertsTheTypedWords() async {
        let (sut, r, _) = make()
        r.focus = nil                       // focusInfo: AX names no focused element
        r.setNowFocused(nil)
        let out = await sut.handle(request(typed("akuo"), gen: 1, app: cmux), layouts: layouts)
        XCTAssertEqual(out, .converted(to: IDs.hebrew, by: .backspaceAndType(count: 4), switched: true))
        XCTAssertEqual(r.terminalKeyPosts, 1)
        XCTAssertEqual(r.writes.map(\.new), ["שלום"])
        XCTAssertEqual(log.claims, [1])
        XCTAssertEqual(log.beeps, 0)
        XCTAssertEqual(log.finishes, [.finish(gen: 1, newRendering: IDs.hebrew, bufferAfter: nil)], "kept, re-rendered")
    }

    @TextActor func testErrorAnswersThatLookSecureOrComposingStillConvert() async {
        for focus in [FocusInfo(role: "AXTextArea", isSecure: true, hasMarkedText: false, selTextSettable: false,
                                selRangeSettable: false, selection: nil),
                      FocusInfo(role: "AXTextArea", isSecure: false, hasMarkedText: true, selTextSettable: false,
                                selRangeSettable: false, selection: nil)] {
            log.clear()
            let (sut, r, _) = make()
            r.focus = focus
            let out = await sut.handle(request(typed("akuo"), gen: 1, app: cmux), layouts: layouts)
            XCTAssertEqual(out, .converted(to: IDs.hebrew, by: .backspaceAndType(count: 4), switched: true))
            XCTAssertEqual(r.terminalKeyPosts, 1)
        }
    }

    /// A fresh element on every read: the P2-49 same-element check fails the key step; the terminal keys still go.
    @TextActor func testAnUnstableElementStillConverts() async {
        let (sut, r, _) = make()
        r.results[.backspace] = .unavailable
        let out = await sut.handle(request(typed("akuo vh"), gen: 1, app: cmux), layouts: layouts)
        XCTAssertEqual(out, .converted(to: IDs.hebrew, by: .backspaceAndType(count: 7), switched: true))
        XCTAssertEqual(r.writes.map(\.new), ["שלום הי", "שלום הי"], "the chain's try, then the terminal keys")
        XCTAssertEqual(log.claims, [1], "one claim")
    }

    @TextActor func testAFocusInAnotherProcessGetsNoKeysButSwitches() async {
        let (sut, r, _) = make()
        r.focus = nil
        r.setNowFocused(FakeElement(pid: 999))
        let out = await sut.handle(request(typed("akuo"), gen: 1, app: cmux), layouts: layouts)
        XCTAssertEqual(out, .toggledOnly(to: IDs.hebrew, because: .fieldUnreadable))
        XCTAssertEqual(r.terminalKeyPosts, 0)
        XCTAssertEqual(log.beeps, 0)
    }

    @TextActor func testARealPasswordFieldGetsNoKeys() async {
        let (sut, r, _) = make()
        r.focus = FocusInfo(role: FocusInfo.secureTextFieldRole, isSecure: true, hasMarkedText: false,
                            selTextSettable: false, selRangeSettable: false, selection: nil)
        _ = await sut.handle(request(typed("akuo"), gen: 1, app: cmux), layouts: layouts)
        XCTAssertEqual(r.terminalKeyPosts, 0)
        XCTAssertTrue(r.writes.isEmpty)
    }

    @TextActor func testNothingTypedAndNoFocusJustSwitches() async {
        let (sut, r, _) = make()
        r.focus = nil
        let out = await sut.handle(request(kept("", epoch: 0, crossed: false), gen: 1, app: cmux), layouts: layouts)
        XCTAssertEqual(out, .toggledOnly(to: IDs.hebrew, because: .fieldUnreadable))
        XCTAssertEqual(r.terminalKeyPosts, 0)
    }

    @TextActor func testTerminalKeysThatFailBeforePostingJustSwitch() async {
        let (sut, r, _) = make()
        r.focus = nil
        r.terminalKeysResult = .unavailable
        let out = await sut.handle(request(typed("akuo"), gen: 1, app: cmux), layouts: layouts)
        XCTAssertEqual(out, .toggledOnly(to: IDs.hebrew, because: .fieldUnreadable))
        XCTAssertEqual(log.beeps, 0)
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
