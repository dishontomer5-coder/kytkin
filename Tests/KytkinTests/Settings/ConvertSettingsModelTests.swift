// P2-25: Settings → Convert logic: the four settings write `prefs.convert`, the window slider clamps to 200–500 ms,
// the Shift-side options, the processor config AppController sends with `updateConfig`, and read-only mode.

import XCTest

@MainActor
final class ConvertSettingsModelTests: XCTestCase {
    private var store: PreferencesStore!
    private var sut: ConvertSettingsModel!

    private func make(_ convert: Preferences.Convert = .init(), readOnly: Bool = false) {
        var prefs = Preferences()
        prefs.convert = convert
        store = readOnly ? makeReadOnlyStore(prefs) : makeStore(prefs, clock: FakeClock())
        sut = ConvertSettingsModel(store: store)
    }

    func testDefaultsAreShown() {
        make()
        XCTAssertTrue(sut.doubleShiftEnabled)
        XCTAssertEqual(sut.sidesID, "sameSide")
        XCTAssertEqual(sut.windowMs, 300)
        XCTAssertEqual(sut.windowText, "300 ms")
        XCTAssertTrue(sut.switchLanguageAfterConvert)
        XCTAssertTrue(sut.isEditable)
    }

    func testTogglesWriteTheStore() {
        make()
        sut.doubleShiftEnabled = false
        XCTAssertFalse(store.prefs.convert.doubleShiftEnabled)
        XCTAssertFalse(PreferencesMapping.processorConfig(store.prefs).doubleShiftEnabled, "what updateConfig sends")
        sut.switchLanguageAfterConvert = false
        XCTAssertFalse(store.prefs.convert.switchLanguageAfterConvert)
    }

    func testSides() {
        make()
        XCTAssertEqual(sut.sidesOptions.map(\.id), ["sameSide", "either"])
        sut.sidesID = "either"
        XCTAssertEqual(store.prefs.convert.doubleShiftSides, .either)
        XCTAssertEqual(PreferencesMapping.processorConfig(store.prefs).doubleShift.sides, .either)
        sut.sidesID = "leftOnly"
        XCTAssertEqual(store.prefs.convert.doubleShiftSides, .either, "not offered, so ignored")
        sut.sidesID = "nonsense"
        XCTAssertEqual(store.prefs.convert.doubleShiftSides, .either)
    }

    func testAHandEditedSideIsStillListed() {
        var c = Preferences.Convert()
        c.doubleShiftSides = .rightOnly
        make(c)
        XCTAssertEqual(sut.sidesOptions.map(\.id), ["sameSide", "either", "rightOnly"])
        XCTAssertEqual(sut.sidesID, "rightOnly")
        sut.sidesID = "sameSide"
        XCTAssertEqual(sut.sidesOptions.map(\.id), ["sameSide", "either"])
    }

    func testWindowClampsAndRounds() {
        make()
        sut.windowMs = 420
        XCTAssertEqual(store.prefs.convert.doubleShiftWindowMs, 420)
        XCTAssertEqual(sut.windowText, "420 ms")
        XCTAssertEqual(PreferencesMapping.processorConfig(store.prefs).doubleShift.windowNanos, 420_000_000)
        sut.windowMs = 50
        XCTAssertEqual(store.prefs.convert.doubleShiftWindowMs, 200)
        sut.windowMs = 9_000
        XCTAssertEqual(store.prefs.convert.doubleShiftWindowMs, 500)
        sut.windowMs = 333.6
        XCTAssertEqual(store.prefs.convert.doubleShiftWindowMs, 334)
        sut.windowMs = -.infinity
        XCTAssertEqual(store.prefs.convert.doubleShiftWindowMs, 334, "not finite: ignored")
        sut.windowMs = .nan
        XCTAssertEqual(store.prefs.convert.doubleShiftWindowMs, 334)
        sut.windowMs = 1e300
        XCTAssertEqual(store.prefs.convert.doubleShiftWindowMs, 500)
    }

    func testSliderRangeIs200To500() {
        XCTAssertEqual(ConvertSettingsModel.sliderRange, 200...500)
        XCTAssertEqual(ConvertSettingsModel.windowStepMs, 10)
    }

    func testExplanationDescribesTheWholeBoxConvertSelectionAndUndo() {
        let text = ConvertSettingsModel.explanation.joined(separator: " ")
        // P3-35: the whole text box (was "before the cursor … where the other language starts", P3-33).
        XCTAssertTrue(text.contains("whole text box"))
        XCTAssertTrue(text.contains("every line"))
        XCTAssertTrue(text.contains("already in the other language stays"))
        XCTAssertFalse(text.contains("before the cursor"))
        XCTAssertFalse(text.contains("current line"))
        XCTAssertTrue(text.contains("converts only the selection"))
        XCTAssertTrue(text.contains("again"))
        XCTAssertTrue(text.contains("undo"))
        XCTAssertTrue(ConvertSettingsModel.autoFixNote.contains("later version"))
    }

    func testReadOnlyBlocksEveryWrite() {
        make(readOnly: true)
        XCTAssertFalse(sut.isEditable)
        XCTAssertEqual(sut.notices.first?.kind, .readOnly)
        sut.doubleShiftEnabled = false
        sut.sidesID = "either"
        sut.windowMs = 450
        sut.switchLanguageAfterConvert = false
        XCTAssertEqual(store.prefs.convert, Preferences.Convert())
    }

    func testAChangeReachesTheObservingController() {
        // AppController re-reads preferences through withObservationTracking on `store.prefs` (P2-50); a write from
        // this tab must trigger that observation.
        make()
        let fired = Fired()
        withObservationTracking { _ = store.prefs } onChange: { fired.value = true }
        sut.windowMs = 250
        XCTAssertTrue(fired.value)
    }

    /// P2-25 QA: a slider drag sends one store change per distinct value, so AppController (which sends
    /// `updateConfig` only when the clamped config changed) can't storm the tap thread; reading never writes.
    func testReadingNeverWritesAndRepeatedValuesAreNoOps() {
        var convert = Preferences.Convert()
        convert.doubleShiftWindowMs = 305
        make(convert)
        let changed = Fired()
        withObservationTracking {
            _ = store.prefs
        } onChange: { changed.value = true }
        _ = (sut.doubleShiftEnabled, sut.sidesID, sut.windowMs, sut.windowText, sut.switchLanguageAfterConvert,
             sut.sidesOptions)
        sut.windowMs = 305
        sut.windowMs = 305.2
        sut.sidesID = "sameSide"
        sut.sidesID = "bogus"
        sut.doubleShiftEnabled = true
        XCTAssertFalse(changed.value, "same values and unknown ids write nothing")
        XCTAssertEqual(store.prefs.convert.doubleShiftWindowMs, 305, "an off-step saved value is kept")
    }

}

private final class Fired: @unchecked Sendable { var value = false }
