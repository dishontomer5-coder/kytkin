// P2-20: PreferencesMapping: the clamped KeyProcessorConfig (P2-50), FeatureSettings with Pause, and the
// AppOverride → MethodHint table (001 §12 T5).

import XCTest

final class PreferencesMappingTests: XCTestCase {
    private let ms: UInt64 = 1_000_000

    func testDefaultsGiveTheDefaultConfigWithAutoFixOff() {
        let c = PreferencesMapping.processorConfig(Preferences())
        XCTAssertEqual(c.doubleShift, DoubleShiftConfig())
        XCTAssertTrue(c.doubleShiftEnabled)
        XCTAssertFalse(c.autoFixEnabled, "P4 only: would hold every Space with no worker")
        XCTAssertEqual(c.convertDeadlineNanos, 400 * ms)
        XCTAssertEqual(c.postingHardCapNanos, 1_000 * ms)
    }

    func testConvertSettingsMap() {
        var p = Preferences()
        p.convert.doubleShiftEnabled = false
        p.convert.doubleShiftSides = .either
        p.convert.doubleShiftWindowMs = 450
        p.autoFix.enabled = true
        let c = PreferencesMapping.processorConfig(p)
        XCTAssertFalse(c.doubleShiftEnabled)
        XCTAssertEqual(c.doubleShift.sides, .either)
        XCTAssertEqual(c.doubleShift.windowNanos, 450 * ms)
        XCTAssertFalse(c.autoFixEnabled)
    }

    func testClampKeepsEveryRangeInBudget() {
        var c = KeyProcessorConfig()
        c.doubleShift.windowNanos = 5 * ms
        c.doubleShift.maxHoldNanos = 10_000 * ms
        c.convertDeadlineNanos = 5_000 * ms
        c.autoFixDeadlineNanos = 0
        c.postingHardCapNanos = 60_000 * ms
        c.holdBackCapacity = 1_000
        let k = PreferencesMapping.clamped(c)
        XCTAssertEqual(k.doubleShift.windowNanos, 200 * ms)
        XCTAssertEqual(k.doubleShift.maxHoldNanos, 500 * ms)
        XCTAssertEqual(k.convertDeadlineNanos, 400 * ms)
        XCTAssertEqual(k.autoFixDeadlineNanos, 20 * ms)
        XCTAssertEqual(k.postingHardCapNanos, 1_000 * ms)
        XCTAssertEqual(k.holdBackCapacity, 32)

        c.doubleShift.windowNanos = 90_000 * ms
        c.holdBackCapacity = 0
        let k2 = PreferencesMapping.clamped(c)
        XCTAssertEqual(k2.doubleShift.windowNanos, 500 * ms)
        XCTAssertEqual(k2.holdBackCapacity, 1)
    }

    func testClampLeavesTheDefaultsAlone() {
        XCTAssertEqual(PreferencesMapping.clamped(KeyProcessorConfig()), KeyProcessorConfig())
    }

    func testFeatureSettingsAndPause() {
        var p = Preferences()
        p.general.learnFromManualSwitches = false
        p.browsers.appleEventsOptIn = ["com.google.Chrome": true, "com.apple.Safari": false]
        let s = PreferencesMapping.featureSettings(p, paused: false)
        XCTAssertTrue(s.enabled)
        XCTAssertFalse(s.learnFromManualSwitches)
        XCTAssertTrue(s.doubleShiftEnabled)
        XCTAssertFalse(s.autoFixEnabled)
        XCTAssertEqual(s.appleEventsOptIn, ["com.google.Chrome"])
        XCTAssertFalse(PreferencesMapping.featureSettings(p, paused: true).enabled)
        p.general.enabled = false
        XCTAssertFalse(PreferencesMapping.featureSettings(p, paused: false).enabled)
    }

    func testMethodHintTable() {
        typealias O = Preferences.AppOverride
        XCTAssertNil(PreferencesMapping.methodHint(O()))
        XCTAssertEqual(PreferencesMapping.methodHint(O(disabled: true, replacementMethod: .keysOnly)), .disabled)
        XCTAssertEqual(PreferencesMapping.methodHint(O(convertEnabled: false, replacementMethod: .auto)), .disabled)
        XCTAssertNil(PreferencesMapping.methodHint(O(disabled: false, convertEnabled: true)))
        XCTAssertNil(PreferencesMapping.methodHint(O(autoFixEnabled: false)), "autoFix stays separate (P4)")
        let pairs: [(O.ReplacementMethod, MethodHint)] = [(.auto, .auto), (.keysOnly, .keysOnly),
                                                         (.noUnicode, .noUnicode), (.preferPaste, .preferPaste),
                                                         (.terminal, .terminal)]
        for (method, hint) in pairs {
            XCTAssertEqual(PreferencesMapping.methodHint(O(replacementMethod: method)), hint)
        }
    }

    func testMethodHintOverridesDropAppsWithNothingSet() {
        let apps: [String: Preferences.AppOverride] = [
            "a": .init(disabled: true), "b": .init(autoFixEnabled: true), "c": .init(replacementMethod: .terminal),
        ]
        XCTAssertEqual(PreferencesMapping.methodHintOverrides(apps), ["a": .disabled, "c": .terminal])
    }
}
