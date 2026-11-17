// P6-0j (owner 2026-11-18): Spotlight's inline completion is selected after the typed text. The key path (Backspace ×
// N + type) deleted only the selection with its first Backspace, so one typed letter survived (`akuo` → `aשלום`). With
// a selected range in the focused box the key path never runs: the selection converts through the AX path when it
// can, else double-Shift just switches. And the trace says when the focus owner was not the frontmost app.

import XCTest

final class ConvertControllerSelectionSafetyTests: XCTestCase {
    private let akuo = ConvertFixtures.strokes("akuo")

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

    @TextActor private func make(_ replacer: ScriptedReplacer,
                                 diagnose: (@Sendable (ConvertTrace) -> Void)? = nil) -> ConvertController {
        let log = self.log!
        return ConvertController(keyWatcher: watcher, clock: clock, beep: { log.add(.beep) },
                                 makeReplacer: { replacer }, switchLanguage: switches.hook, diagnose: diagnose)
    }

    @TextActor private func field(role: String = "AXTextField", selection: String?, selectedLength: Int?,
                                  readsBeforeCaret: Bool = false) -> ScriptedReplacer {
        let r = ScriptedReplacer(log: log)
        r.focus = FocusInfo(role: role, isSecure: false, hasMarkedText: false, selTextSettable: true,
                            selRangeSettable: true, selection: selection, canReadBeforeCaret: readsBeforeCaret,
                            selectedLength: selectedLength)
        return r
    }

    private func request(bundleID: String, gen: UInt64 = 1) -> ConvertRequest {
        let snap = WordSnapshot(strokes: akuo, previousWords: [], renderedIn: IDs.abc, isValid: true)
        return ConvertRequest(snapshot: snap, gen: gen, bundleID: bundleID, mode: .convert,
                              pair: ConvertFixtures.pair, currentSource: IDs.abc, switchAfterConvert: true,
                              processID: 40)
    }

    private var keyPosts: [ReplacementStep] {
        log.performs.filter { if case .backspaceAndType = $0 { true } else { false } }
    }

    /// The owner's case as it reached the controller: frontmost cmux (a terminal), focus in Spotlight's search field
    /// with an inline completion selected. Never Backspace × 4 + type.
    @TextActor func testAnInlineCompletionInATerminalAppsFieldNeverGetsBlindBackspaces() async {
        let sut = make(field(selection: "ab", selectedLength: 2))
        let out = await sut.handle(request(bundleID: "com.cmuxterm.app"), layouts: ConvertFixtures.layouts)
        XCTAssertEqual(out, .toggledOnly(to: IDs.hebrew, because: .selectionPresent))
        XCTAssertEqual(keyPosts, [])
        XCTAssertTrue(log.claims.isEmpty, "nothing written")
        XCTAssertEqual(log.finishes, [.finish(gen: 1, newRendering: nil, bufferAfter: [])])
    }

    /// A selected range whose text AX won't read (so the selection can't convert): just switch, no keys.
    @TextActor func testASelectedRangeWithoutReadableTextJustSwitches() async {
        let sut = make(field(role: "AXTextArea", selection: nil, selectedLength: 5))
        let out = await sut.handle(request(bundleID: "com.apple.TextEdit"), layouts: ConvertFixtures.layouts)
        XCTAssertEqual(out, .toggledOnly(to: IDs.hebrew, because: .selectionPresent))
        XCTAssertEqual(keyPosts, [])
        XCTAssertEqual(log.beeps, 0)
    }

    /// Spotlight as the focus owner (`.auto`): a readable selection takes the normal AX selection path.
    @TextActor func testSpotlightsReadableSelectionTakesTheAXSelectionPath() async {
        let sut = make(field(selection: "akuo", selectedLength: 4))
        let out = await sut.handle(request(bundleID: "com.apple.Spotlight"), layouts: ConvertFixtures.layouts)
        XCTAssertEqual(out, .converted(to: IDs.hebrew, by: .axWriteSelection(verify: true), switched: true))
        XCTAssertEqual(keyPosts, [])
    }

    /// Nothing selected: the remembered run still converts by keys where AX can't read the box.
    @TextActor func testACaretWithNothingSelectedStillConvertsByKeys() async {
        let sut = make(field(selection: "", selectedLength: 0))
        let out = await sut.handle(request(bundleID: "com.apple.TextEdit"), layouts: ConvertFixtures.layouts)
        XCTAssertEqual(out, .converted(to: IDs.hebrew, by: .backspaceAndType(count: 4), switched: true))
    }

    /// P2-36 / P3-37 (a) kept: a terminal screen's selection is display only; the line still converts by keys.
    @TextActor func testATerminalScreenSelectionStillConvertsTheLineByKeys() async {
        let sut = make(field(role: "AXTextArea", selection: "ls", selectedLength: 2))
        let out = await sut.handle(request(bundleID: "com.apple.Terminal"), layouts: ConvertFixtures.layouts)
        XCTAssertEqual(out, .converted(to: IDs.hebrew, by: .backspaceAndType(count: 4), switched: true))
    }

    @TextActor func testTheTraceNotesAFocusOwnerThatIsNotTheFrontmostApp() async {
        let traces = TraceBox()
        let sut = make(field(selection: "", selectedLength: 0), diagnose: { traces.add($0) })
        var r = request(bundleID: "com.apple.Spotlight")
        r.focusOwnerDiffers = true
        _ = await sut.handle(r, layouts: ConvertFixtures.layouts)
        let t = try! XCTUnwrap(traces.all.first)
        XCTAssertEqual(t.bundleID, "com.apple.Spotlight")
        XCTAssertTrue(t.line.contains("focusOwner≠frontmost"))

        _ = await sut.handle(request(bundleID: "com.apple.TextEdit", gen: 2), layouts: ConvertFixtures.layouts)
        XCTAssertFalse(try! XCTUnwrap(traces.all.last).line.contains("focusOwner"))
    }
}

private final class TraceBox: @unchecked Sendable {
    private let lock = NSLock()
    private var traces: [ConvertTrace] = []
    func add(_ t: ConvertTrace) { lock.lock(); traces.append(t); lock.unlock() }
    var all: [ConvertTrace] { lock.lock(); defer { lock.unlock() }; return traces }
}
