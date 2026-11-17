// P3-7 QA: Settings → Browsers & Sites wired to the Automation controller (001 §14.7–14.8). The rows show the
// controller's state and button; the switch, Ask and Open System Settings are passed through only as clicks (a
// repeated set, read-only preferences or a disabled Ask never reach it); `refresh()` asks only for silent checks;
// "Can't read this browser" points to Automation (P3-24).
// P3-26: one global "Use Automation" switch. Turning it on asks macOS (from that click only) for the running browsers
// that support it and aren't allowed yet, in a stable order; turning it off only stores the choice; Zen, Firefox and
// Orion are ignored. End to end with the real BrowserAutomationController over RecordingPermissions: opening
// Settings never prompts.

import XCTest

@MainActor
private final class FakeAutomation: AutomationControlling {
    enum Call: Equatable {
        case setGlobal(Bool), ask(String), openSettings, refresh([String])
    }

    var calls: [Call] = []
    var states: [String: BrowserAutomationState] = [:]
    /// Mirrors the real controller: the switch writes the preference.
    var store: PreferencesStore?

    func automationState(for bundleID: String) -> BrowserAutomationState {
        states[bundleID] ?? BrowserAutomationState.make(bundleID: bundleID,
                                                       optedIn: store?.prefs.browsers.useAutomation ?? false,
                                                       permission: nil, browserIsRunning: false)
    }
    func setUseAutomation(_ on: Bool) {
        calls.append(.setGlobal(on))
        store?.update { $0.browsers.useAutomation = on }
    }
    func askAutomation(for bundleID: String) { calls.append(.ask(bundleID)) }
    func openAutomationSettings() { calls.append(.openSettings) }
    func refreshAutomation(for bundleIDs: [String]) { calls.append(.refresh(bundleIDs)) }
}

@MainActor
final class BrowsersAutomationWiringTests: XCTestCase {
    private let zen = "app.zen-browser.zen"
    private let firefox = "org.mozilla.firefox"
    private let orion = "com.kagi.kagimacOS"
    private let chrome = "com.google.Chrome"
    private let arc = "company.thebrowser.Browser"
    private let safari = "com.apple.Safari"

    private var store: PreferencesStore!
    private var fake: FakeAutomation!
    private var support: [String: BrowserSupport] = [:]
    private var inventory = BrowserInventorySnapshot()
    private var sut: BrowsersSettingsModel!

    private func make(_ prefs: Preferences = Preferences(), readOnly: Bool = false) {
        store = readOnly ? makeReadOnlyStore(prefs) : makeStore(prefs, clock: FakeClock())
        fake = FakeAutomation()
        fake.store = store
        let names = [safari: "Safari", chrome: "Google Chrome", arc: "Arc", zen: "Zen"]
        sut = BrowsersSettingsModel(store: store, appName: { names[$0] }, suffixListLoaded: true,
                                    ownBundleIDPrefix: "io.github.kytkin.",
                                    inventory: { [unowned self] in inventory },
                                    support: { [unowned self] in support[$0] ?? .notSeenYet },
                                    automation: fake)
    }

    private func row(_ id: String) throws -> BrowserRow {
        try XCTUnwrap(sut.rows.first { $0.bundleID == id }, id)
    }

    private func state(_ s: BrowserAutomationState.Status, running: Bool = true) -> BrowserAutomationState {
        BrowserAutomationState(status: s, browserIsRunning: running)
    }

    // MARK: - Rows

    func testZenFirefoxAndOrionSayAutomationIsNotAvailable() throws {
        inventory = BrowserInventorySnapshot(installedCatalog: [zen, firefox, orion, chrome])
        make()
        sut.refresh()
        for id in [zen, firefox, orion] {
            XCTAssertNil(try row(id).automationState, id)
            XCTAssertNil(try row(id).automationStatusText, id)
            guard case .notAvailable(let text) = try row(id).automation else { return XCTFail(id) }
            XCTAssertTrue(text.hasPrefix("Automation isn't available"), id)
        }
        XCTAssertNotNil(try row(chrome).automationState)
        sut.askAutomation(for: zen)
        XCTAssertTrue(fake.calls.isEmpty, "no Ask for Zen")
    }

    func testRowsShowTheControllersStateAndButton() throws {
        inventory = BrowserInventorySnapshot(installedCatalog: [chrome, arc, safari])
        make()
        fake.states = [chrome: state(.allowed), arc: state(.denied), safari: state(.notAsked, running: false)]
        sut.refresh()
        XCTAssertEqual(try row(chrome).automationStatusText, "Allowed")
        XCTAssertNil(try row(chrome).automationState?.actionTitle())
        XCTAssertEqual(try row(arc).automationState?.actionTitle(), "Open System Settings")
        XCTAssertTrue(try XCTUnwrap(row(arc).automationStatusText).hasPrefix("Denied."))
        XCTAssertEqual(try row(safari).automationState?.actionTitle(), "Ask")
        XCTAssertEqual(try row(safari).automationState?.actionEnabled, false, "Ask needs the browser running")
        XCTAssertEqual(try row(safari).automationStatusText, "Not asked yet. Open Safari, then click Ask.")
    }

    func testWithoutAControllerTheStoredChoiceShowsAndNothingIsCalled() throws {
        inventory = BrowserInventorySnapshot(installedCatalog: [chrome])
        var prefs = Preferences()
        prefs.browsers.useAutomation = true
        store = makeStore(prefs, clock: FakeClock())
        sut = BrowsersSettingsModel(store: store, appName: { _ in nil }, suffixListLoaded: true,
                                    ownBundleIDPrefix: "", inventory: { [unowned self] in inventory },
                                    support: { _ in .notSeenYet })
        sut.refresh()
        XCTAssertEqual(try row(chrome).automationState?.status, .notAsked)
        sut.setUseAutomation(false)
        XCTAssertTrue(store.prefs.browsers.useAutomation, "no controller: nothing written")
    }

    // MARK: - Clicks

    func testGlobalSwitchIsPassedThroughOnlyWhenItChanges() {
        inventory = BrowserInventorySnapshot(installedCatalog: [chrome])
        make()
        sut.setUseAutomation(false)
        XCTAssertTrue(fake.calls.isEmpty, "already off")
        sut.setUseAutomation(true)
        XCTAssertEqual(fake.calls, [.setGlobal(true)])
        XCTAssertTrue(sut.useAutomation)
        sut.setUseAutomation(true)
        XCTAssertEqual(fake.calls, [.setGlobal(true)], "a repeated set never asks macOS again")
        sut.setUseAutomation(false)
        XCTAssertEqual(fake.calls, [.setGlobal(true), .setGlobal(false)])
    }

    func testReadOnlyPreferencesDisableTheSwitch() {
        make(readOnly: true)
        sut.setUseAutomation(true)
        XCTAssertTrue(fake.calls.isEmpty)
    }

    func testAskOnlyWhenTheButtonIsThereAndEnabled() {
        make()
        sut.askAutomation(for: chrome)                                   // Off: no Ask button
        fake.states[chrome] = state(.notAsked, running: false)
        sut.askAutomation(for: chrome)                                   // greyed out
        fake.states[chrome] = state(.denied)
        sut.askAutomation(for: chrome)                                   // the button is Open System Settings
        XCTAssertTrue(fake.calls.isEmpty)
        fake.states[chrome] = state(.notAsked, running: true)
        sut.askAutomation(for: chrome)
        XCTAssertEqual(fake.calls, [.ask(chrome)])
        sut.openAutomationSettings()
        XCTAssertEqual(fake.calls.last, .openSettings)
    }

    // MARK: - Refresh (silent)

    func testRefreshChecksListedBrowsersThatSupportItWhileTheSwitchIsOn() {
        inventory = BrowserInventorySnapshot(installedCatalog: [chrome, arc, zen])
        var prefs = Preferences()
        prefs.browsers.useAutomation = true
        make(prefs)
        sut.refresh()
        XCTAssertEqual(fake.calls, [.refresh([chrome, arc])], "Safari isn't installed, Zen has no Automation")
        make()
        sut.refresh()
        XCTAssertTrue(fake.calls.isEmpty, "switch off: no check at all")
    }

    // MARK: - P3-24: "Can't read this browser"

    func testCantReadPointsToAutomation() throws {
        inventory = BrowserInventorySnapshot(installedCatalog: [chrome, arc, safari, zen])
        support = [chrome: .cantRead, arc: .cantRead, safari: .cantRead, zen: .cantRead]
        make()
        fake.states = [arc: state(.notAsked), safari: state(.allowed)]
        sut.refresh()
        XCTAssertEqual(try row(chrome).statusHint,
                       "Kytkin can't see the page address. Turn on \"Use Automation\" above.")
        XCTAssertEqual(try row(arc).statusHint, "Kytkin can't see the page address. Allow Automation below.")
        XCTAssertEqual(try row(safari).statusHint, "Kytkin can't see the page address, even with Automation.")
        XCTAssertEqual(try row(zen).statusHint, "Kytkin can't see the page address here. Not supported yet.")
    }

    // MARK: - End to end with the real controller

    private func makeReal(_ prefs: Preferences = Preferences(), running: Set<String>,
                          permissions: RecordingPermissions) -> BrowserAutomationController {
        store = makeStore(prefs, clock: FakeClock())
        let controller = BrowserAutomationController(store: store, permissions: permissions,
                                                     isRunning: { running.contains($0) })
        sut = BrowsersSettingsModel(store: store, appName: { $0 == "com.apple.Safari" ? "Safari" : nil },
                                    suffixListLoaded: true, ownBundleIDPrefix: "", inventory: { [unowned self] in inventory },
                                    support: { _ in .notSeenYet }, automation: controller)
        return controller
    }

    func testALaunchOrQuitWhileSettingsIsOpenRedrawsTheRowsAndChecksSilently() {
        // P3-25: the Ask button follows whether the browser runs; it must not wait for Settings to come to the front.
        let permissions = RecordingPermissions()
        var prefs = Preferences()
        prefs.browsers.useAutomation = true
        inventory = BrowserInventorySnapshot(installedCatalog: [chrome])
        _ = makeReal(prefs, running: [chrome], permissions: permissions)
        sut.refresh()
        let generation = sut.statusGeneration
        let inventoryReads = permissions.calls.count
        sut.runningAppsChanged()
        XCTAssertEqual(sut.statusGeneration, generation + 1, "SwiftUI re-reads the rows")
        XCTAssertEqual(permissions.calls.count, inventoryReads + 1)
        XCTAssertEqual(permissions.calls.last, .refreshAutomation([chrome]))
        XCTAssertTrue(permissions.promptingCalls.isEmpty, "never a prompt")
    }

    func testOpeningSettingsWithTheRealControllerOnlyChecksSilently() throws {
        let permissions = RecordingPermissions()
        var prefs = Preferences()
        prefs.browsers.useAutomation = true
        inventory = BrowserInventorySnapshot(installedCatalog: [chrome, zen])
        _ = makeReal(prefs, running: [chrome], permissions: permissions)
        sut.refresh()
        _ = sut.rows
        XCTAssertEqual(permissions.calls, [.refreshAutomation([chrome])])
        XCTAssertTrue(permissions.promptingCalls.isEmpty, "no prompt without a click")
        XCTAssertEqual(try row(chrome).automationState?.status, .checking)
        permissions.set(automation: chrome, .notDetermined)
        XCTAssertEqual(try row(chrome).automationState?.actionTitle(), "Ask")
        sut.askAutomation(for: chrome)
        XCTAssertEqual(permissions.calls.last, .requestAutomation(chrome), "the click asks")
        permissions.set(automation: chrome, .granted)
        XCTAssertEqual(try row(chrome).automationStatusText, "Allowed")
        sut.setUseAutomation(false)
        XCTAssertFalse(store.prefs.browsers.useAutomation)
        XCTAssertEqual(try row(chrome).automationStatusText, "Off (\"Use Automation\" is off above)")
    }

    func testTurningTheSwitchOnAsksOnlyRunningBrowsersThatAreNotAllowed() throws {
        let permissions = RecordingPermissions()
        permissions.set(automation: arc, .granted)
        inventory = BrowserInventorySnapshot(installedCatalog: [chrome, arc, safari, zen, firefox, orion])
        // Running: Chrome, Arc (already allowed), Zen, Firefox, Orion (no Automation). Safari is not running.
        _ = makeReal(running: [chrome, arc, zen, firefox, orion], permissions: permissions)
        sut.refresh()
        XCTAssertTrue(permissions.calls.isEmpty, "switch off: no check")
        sut.setUseAutomation(true)
        XCTAssertTrue(store.prefs.browsers.useAutomation)
        XCTAssertEqual(permissions.promptingCalls, [.requestAutomation(chrome)],
                       "only the running browser that supports it and isn't allowed yet")
        XCTAssertEqual(try row(safari).automationStatusText, "Not asked yet. Open Safari, then click Ask.",
                       "the others: open it, then Ask")
        XCTAssertEqual(try row(arc).automationStatusText, "Allowed")
        sut.setUseAutomation(true)
        XCTAssertEqual(permissions.promptingCalls.count, 1, "a repeated set never asks again")
    }

    func testSeveralRunningBrowsersAreAskedInAStableOrder() {
        let permissions = RecordingPermissions()
        _ = makeReal(running: [safari, chrome, arc], permissions: permissions)
        sut.setUseAutomation(true)
        // PermissionsManager shows these one at a time (AutomationPermissionTracker's queue).
        XCTAssertEqual(permissions.promptingCalls, [.requestAutomation(chrome), .requestAutomation(arc),
                                                    .requestAutomation(safari)], "catalog order")
    }

    func testTurningTheSwitchOffOnlyStoresTheChoice() {
        let permissions = RecordingPermissions()
        var prefs = Preferences()
        prefs.browsers.useAutomation = true
        _ = makeReal(prefs, running: [chrome, safari], permissions: permissions)
        sut.setUseAutomation(false)
        XCTAssertFalse(store.prefs.browsers.useAutomation)
        XCTAssertEqual(permissions.calls, [.cancelQueuedAutomationRequests],
                       "off asks nothing and checks nothing; it only drops questions still waiting (P3-26 QA)")
        XCTAssertTrue(permissions.promptingCalls.isEmpty)
    }
}
