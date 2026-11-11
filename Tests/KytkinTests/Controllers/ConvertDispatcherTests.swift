// P2-21: ConvertDispatcher, the main → @TextActor hop (001 §12 W9): requests reach the controller in order and are
// always finished, toggle-only needs no maps, missing maps just switch (P2-54(a)), the LayoutSnapshot follows
// the pair, and the per-app hints reach the controller's capabilities.

import XCTest

@MainActor
final class ConvertDispatcherTests: XCTestCase {
    private var log: ConvertLog!
    private var watcher: ConvertKeyWatcher!
    private var switches: SwitchRecorder!
    private var maps: FakeLayoutMaps!
    private var sut: ConvertDispatcher!

    override func setUp() async throws {
        log = ConvertLog()
        watcher = ConvertKeyWatcher(log: log)
        switches = SwitchRecorder(log: log)
        maps = FakeLayoutMaps()
        let log = self.log!
        let replacer = ScriptedReplacer(log: log)   // focus nil: a convert-mode run is refused (focusUnknown)
        let controller = ConvertController(keyWatcher: watcher, clock: FakeClock(), beep: { log.add(.beep) },
                                           makeReplacer: { replacer }, switchLanguage: switches.hook)
        sut = ConvertDispatcher(controller: controller, maps: maps)
    }

    private func request(gen: UInt64, mode: ConvertRequest.Mode, pair: LanguagePair = ConvertFixtures.pair)
        -> ConvertRequest {
        ConvertRequest(snapshot: WordSnapshot(strokes: [], previousWords: [], renderedIn: IDs.abc, isValid: false),
                       gen: gen, bundleID: "com.apple.TextEdit", mode: mode, pair: pair, currentSource: IDs.abc,
                       switchAfterConvert: true)
    }

    private func drain() async { await sut.lastTask?.value }

    func testToggleOnlyHopsSwitchesAndFinishesWithoutMaps() async {
        sut.convert(request(gen: 1, mode: .toggleOnly))
        await drain()
        XCTAssertEqual(maps.lookups, 0)
        XCTAssertEqual(log.entries, [.switchTo(IDs.hebrew, keepsBuffer: false),
                                     .finish(gen: 1, newRendering: nil, bufferAfter: nil)])
    }

    /// P2-54(a): missing maps with an empty buffer just switch the language (no beep).
    func testMissingMapsWithAnEmptyBufferSwitchAndFinish() async {
        sut.convert(request(gen: 1, mode: .convert))
        await drain()
        XCTAssertEqual(log.entries, [.switchTo(IDs.hebrew, keepsBuffer: false),
                                     .finish(gen: 1, newRendering: nil, bufferAfter: nil)])
    }

    /// P3-35 QA (owner): `forgetUndo` hops only when a convert ran since the last drop (it is called on every Space).
    func testForgetUndoHopsOnlyAfterAConvert() async {
        sut.forgetUndo()
        XCTAssertNil(sut.lastTask, "no convert yet: nothing to drop, no hop")
        sut.convert(request(gen: 1, mode: .convert))
        XCTAssertTrue(sut.undoMayBeHeld)
        let convertTask = sut.lastTask
        sut.forgetUndo()
        XCTAssertFalse(sut.undoMayBeHeld)
        XCTAssertNotNil(sut.lastTask)
        XCTAssertFalse(sut.lastTask == convertTask, "queued after the convert")
        let dropTask = sut.lastTask
        sut.forgetUndo()
        XCTAssertTrue(sut.lastTask == dropTask, "already dropped: no second hop")
        await drain()
        let controller = sut.controller
        let hasRecord = await Task { @TextActor in controller.lastRun != nil }.value
        XCTAssertFalse(hasRecord)
    }

    func testRequestsReachTheControllerInOrder() async {
        for gen in UInt64(1)...20 { sut.convert(request(gen: gen, mode: .toggleOnly)) }
        await drain()
        XCTAssertEqual(log.finishes, (UInt64(1)...20).map { .finish(gen: $0, newRendering: nil, bufferAfter: nil) })
        let outcome = await sut.controller.lastOutcome
        XCTAssertEqual(outcome, .toggledOnly(to: IDs.hebrew, because: .toggleMode), "none was taken as stale")
    }

    func testSnapshotFollowsThePairAndItsMaps() {
        XCTAssertNil(sut.snapshot(for: ConvertFixtures.pair), "no maps yet")
        maps.maps = [IDs.abc: ConvertFixtures.abc, IDs.hebrew: ConvertFixtures.hebrew]
        let s = sut.snapshot(for: ConvertFixtures.pair)
        XCTAssertEqual(s?.pair, ConvertFixtures.pair)
        XCTAssertEqual(s?.render(ConvertFixtures.strokes("akuo"), from: IDs.abc)?.text, "שלום")
        // Reversed pair: a new snapshot, and directions follow it.
        let reversed = LanguagePair(a: IDs.hebrew, b: IDs.abc)
        XCTAssertEqual(sut.snapshot(for: reversed)?.pair, reversed)
        XCTAssertNil(sut.snapshot(for: LanguagePair(a: IDs.abc, b: IDs.abc)), "a pair of one layout converts nothing")
        maps.maps[IDs.hebrew] = nil
        XCTAssertNil(sut.snapshot(for: ConvertFixtures.pair), "a map went away (layout removed)")
    }

    func testConvertModeUsesTheSnapshot() async {
        maps.maps = [IDs.abc: ConvertFixtures.abc, IDs.hebrew: ConvertFixtures.hebrew]
        sut.convert(request(gen: 1, mode: .convert))
        await drain()
        // Maps present, focus unknown, empty buffer: P2-54(a) just switches, not "layouts unavailable".
        let outcome = await sut.controller.lastOutcome
        XCTAssertEqual(outcome, .toggledOnly(to: IDs.hebrew, because: .fieldUnreadable))
        XCTAssertEqual(log.entries, [.focus, .end, .end, .switchTo(IDs.hebrew, keepsBuffer: false),
                                     .finish(gen: 1, newRendering: nil, bufferAfter: nil)])
    }

    func testMethodHintsReachTheController() async {
        sut.methodHintsChanged(["com.apple.TextEdit": .disabled])
        await drain()
        let hint = await sut.controller.capabilities.method(for: "com.apple.TextEdit")
        XCTAssertEqual(hint, .disabled)
    }
}
