// P2-13: FeatureAvailability against 001 §6.2's degraded-mode table.

import XCTest

final class FeatureAvailabilityTests: XCTestCase {
    private func compute(ax: PermissionState = .denied, im: PermissionState = .denied, tap: TapMode,
                         secure: Bool = false, settings: FeatureSettings = FeatureSettings(),
                         automation: [String: PermissionState] = [:]) -> FeatureAvailability {
        FeatureAvailability.compute(grants: PermissionGrants(accessibility: ax, inputMonitoring: im,
                                                             automation: automation),
                                    tapMode: tap, secureInput: secure, settings: settings)
    }

    func testNothingGranted() {
        let f = compute(tap: .off)
        XCTAssertTrue(f.appSwitching)
        XCTAssertTrue(f.learningByDwell)
        XCTAssertFalse(f.learningWithWords)
        XCTAssertFalse(f.doubleShiftConvert)
        XCTAssertFalse(f.doubleShiftToggleOnly)
        XCTAssertFalse(f.wordBuffer)
        XCTAssertFalse(f.siteRules)
        XCTAssertFalse(f.chatRules)
        XCTAssertFalse(f.autoFix)
    }

    func testInputMonitoringOnly() {
        let f = compute(im: .granted, tap: .listenOnly)
        XCTAssertTrue(f.appSwitching)
        XCTAssertTrue(f.learningWithWords)
        XCTAssertFalse(f.learningByDwell)
        XCTAssertTrue(f.doubleShiftToggleOnly)
        XCTAssertFalse(f.doubleShiftConvert)
        XCTAssertFalse(f.siteRules)
        XCTAssertFalse(f.chatRules)
        XCTAssertFalse(f.autoFix)
    }

    func testAccessibilityWithActiveTapIsEverything() {
        let f = compute(ax: .granted, tap: .active)
        XCTAssertEqual(f, FeatureAvailability(appSwitching: true, doubleShiftConvert: true,
                                              doubleShiftToggleOnly: false, wordBuffer: true,
                                              learningWithWords: true, learningByDwell: false, siteRules: true,
                                              chatRules: true, autoFix: true, appleEventsBrowsers: []))
    }

    func testAccessibilityButTapOnlyListenOnlyTogglesOnly() {
        let f = compute(ax: .granted, im: .granted, tap: .listenOnly)
        XCTAssertFalse(f.doubleShiftConvert)
        XCTAssertTrue(f.doubleShiftToggleOnly)
        XCTAssertFalse(f.autoFix)
        XCTAssertTrue(f.siteRules)   // AXURL needs no tap
    }

    func testRevokedAccessibilityWithStaleActiveTapStopsReplacing() {
        let f = compute(ax: .denied, tap: .active)
        XCTAssertFalse(f.doubleShiftConvert)
        XCTAssertFalse(f.autoFix)
        XCTAssertTrue(f.doubleShiftToggleOnly)
        XCTAssertFalse(f.siteRules)
    }

    func testUnknownAndNotDeterminedCountAsNotGranted() {
        for state in [PermissionState.unknown, .notDetermined, .denied] {
            let f = compute(ax: state, tap: .active)
            XCTAssertFalse(f.doubleShiftConvert, "\(state)")
            XCTAssertFalse(f.siteRules, "\(state)")
        }
    }

    func testSecureInput() {
        let f = compute(ax: .granted, tap: .active, secure: true)
        XCTAssertTrue(f.appSwitching)
        XCTAssertTrue(f.doubleShiftToggleOnly)   // flagsChanged still arrives (R4)
        XCTAssertFalse(f.doubleShiftConvert)
        XCTAssertFalse(f.wordBuffer)
        XCTAssertFalse(f.learningWithWords)
        XCTAssertTrue(f.learningByDwell)          // learning degrades to the dwell instead of stopping
        XCTAssertFalse(f.autoFix)
        XCTAssertTrue(compute(im: .granted, tap: .listenOnly, secure: true).learningByDwell)
    }

    func testAutomationNeedsTheGlobalSwitchAndAGrant() {
        // P3-26: one switch for every browser; SitePolicy then keeps only browsers with a dictionary.
        let automation: [String: PermissionState] = ["com.google.Chrome": .granted, "com.brave.Browser": .denied,
                                                     "com.microsoft.edgemac": .granted]
        let on = compute(ax: .granted, tap: .active, settings: FeatureSettings(useAutomation: true),
                         automation: automation)
        XCTAssertEqual(on.appleEventsBrowsers, ["com.google.Chrome", "com.microsoft.edgemac"])
        let off = compute(ax: .granted, tap: .active, settings: FeatureSettings(useAutomation: false),
                          automation: automation)
        XCTAssertEqual(off.appleEventsBrowsers, [])
    }

    func testSettingsSwitchesTurnFeaturesOff() {
        let f = compute(ax: .granted, tap: .active,
                        settings: FeatureSettings(learnFromManualSwitches: false, doubleShiftEnabled: false,
                                                  autoFixEnabled: false))
        XCTAssertFalse(f.doubleShiftConvert)
        XCTAssertFalse(f.doubleShiftToggleOnly)
        XCTAssertFalse(f.learningWithWords)
        XCTAssertFalse(f.learningByDwell)
        XCTAssertFalse(f.autoFix)
        XCTAssertTrue(f.appSwitching)
    }

    func testKytkinDisabledTurnsEverythingOff() {
        let f = compute(ax: .granted, tap: .active, settings: FeatureSettings(enabled: false,
                        useAutomation: true), automation: ["com.google.Chrome": .granted])
        XCTAssertEqual(f, FeatureAvailability(appSwitching: false, doubleShiftConvert: false,
                                              doubleShiftToggleOnly: false, wordBuffer: false,
                                              learningWithWords: false, learningByDwell: false, siteRules: false,
                                              chatRules: false, autoFix: false, appleEventsBrowsers: []))
    }

    func testDesiredTapMode() {
        let s = FeatureSettings()
        XCTAssertEqual(FeatureAvailability.desiredTapMode(grants: .init(accessibility: .granted), settings: s), .active)
        XCTAssertEqual(FeatureAvailability.desiredTapMode(grants: .init(accessibility: .denied,
                                                                        inputMonitoring: .granted), settings: s),
                       .listenOnly)
        XCTAssertEqual(FeatureAvailability.desiredTapMode(grants: .init(), settings: s), .off)
        let noTyping = FeatureSettings(learnFromManualSwitches: false, doubleShiftEnabled: false, autoFixEnabled: false)
        XCTAssertEqual(FeatureAvailability.desiredTapMode(grants: .init(accessibility: .granted), settings: noTyping),
                       .off)
        XCTAssertEqual(FeatureAvailability.desiredTapMode(grants: .init(accessibility: .granted),
                                                          settings: FeatureSettings(enabled: false)), .off)
    }
}
