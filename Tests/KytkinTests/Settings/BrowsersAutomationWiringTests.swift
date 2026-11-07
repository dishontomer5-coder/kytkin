// P3-7 QA: Settings → Browsers & Sites wired to the Automation controller (001 §14.7–14.8). The rows show the
// controller's state and button; the toggle, Ask and Open System Settings are passed through only as clicks (a
// repeated set, a Gecko/Orion row, read-only preferences or a disabled Ask never reach it); `refresh()` asks only
// for silent checks of the opted-in browsers listed; "Can't read this browser" points to the toggle (P3-24).
// End to end with the real BrowserAutomationController over RecordingPermissions: opening Settings never prompts.

import XCTest

@MainActor
private final class FakeAutomation: AutomationControlling {
    enum Call: Equatable {
        case set(Bool, String), ask(String), openSettings, refresh([String])
    }

    var calls: [Call] = []
    var states: [String: BrowserAutomationState] = [:]

    func automationState(for bundleID: String) -> BrowserAutomationState {
        states[bundleID] ?? BrowserAutomationState.make(bundleID: bundleID, optedIn: false, permission: nil,
                                                       browserIsRunning: false)
    }
    func setAutomationEnabled(_ on: Bool, for bundleID: String) { calls.append(.set(on, bundleID)) }
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

    private func make(_ prefs: Preferences = Preferences(), readOnly: Bool = false,
                      automation: (any AutomationControlling)? = nil) {
        store = readOnly ? makeReadOnlyStore(prefs) : makeStore(prefs, clock: FakeClock())
        fake = FakeAutomation()
        let names = [safari: "Safari", chrome: "Google Chrome", arc: "Arc"]
        sut = BrowsersSettingsModel(store: store, appName: { names[$0] }, suffixListLoaded: true,
                                    ownBundleIDPrefix: "io.github.kytkin.",
                                    inventory: { [unowned self] in inventory },
                                    support: { [unowned self] in support[$0] ?? .notSeenYet },
                                    automation: automation ?? fake)
    }

    private func row(_ id: String) throws -> BrowserRow {
        try XCTUnwrap(sut.rows.first { $0.bundleID == id }, id)
    }

    private func state(_ s: BrowserAutomationState.Status, running: Bool = true) -> BrowserAutomationState {
        BrowserAutomationState(status: s, browserIsRunning: running)
    }

    // MARK: - Rows

    func testZenFirefoxAndOrionHaveNoToggle() throws {
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
        sut.setAutomationEnabled(true, for: zen)
        sut.setAutomationEnabled(true, for: orion)
        XCTAssertFalse(fake.calls.contains { if case .set = $0 { true } else { false } }, "no toggle → no call")
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
        prefs.browsers.appleEventsOptIn[chrome] = true
        store = makeStore(prefs, clock: FakeClock())
        sut = BrowsersSettingsModel(store: store, appName: { _ in nil }, suffixListLoaded: true,
                                    ownBundleIDPrefix: "", inventory: { [unowned self] in inventory },
                                    support: { _ in .notSeenYet })
        sut.refresh()
        XCTAssertEqual(try row(chrome).automationState?.status, .notAsked)
        sut.setAutomationEnabled(false, for: chrome)
        XCTAssertEqual(store.prefs.browsers.appleEventsOptIn, [chrome: true], "no controller: nothing written")
    }

    // MARK: - Clicks

    func testToggleIsPassedThroughOnlyWhenItChanges() {
        inventory = BrowserInventorySnapshot(installedCatalog: [chrome])
        make()
        sut.setAutomationEnabled(false, for: chrome)
        XCTAssertTrue(fake.calls.isEmpty, "already off")
        sut.setAutomationEnabled(true, for: chrome)
        XCTAssertEqual(fake.calls, [.set(true, chrome)])
        fake.states[chrome] = state(.checking)
        sut.setAutomationEnabled(true, for: chrome)
        XCTAssertEqual(fake.calls, [.set(true, chrome)], "a repeated set never asks macOS again")
        sut.setAutomationEnabled(false, for: chrome)
        XCTAssertEqual(fake.calls, [.set(true, chrome), .set(false, chrome)])
        sut.setAutomationEnabled(true, for: "")
        XCTAssertEqual(fake.calls.count, 2)
    }

    func testReadOnlyPreferencesDisableTheToggle() {
        make(readOnly: true)
        sut.setAutomationEnabled(true, for: chrome)
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

    func testRefreshChecksOnlyListedOptedInBrowsers() {
        inventory = BrowserInventorySnapshot(installedCatalog: [chrome, arc, zen])
        var prefs = Preferences()
        prefs.browsers.appleEventsOptIn = [chrome: true, safari: true, arc: false]
        make(prefs)
        sut.refresh()
        XCTAssertEqual(fake.calls, [.refresh([chrome])], "Safari isn't installed, Arc is off: not checked")
        make()
        sut.refresh()
        XCTAssertTrue(fake.calls.isEmpty, "nothing opted in: no check at all")
    }

    // MARK: - P3-24: "Can't read this browser"

    func testCantReadPointsToTheAutomationToggle() throws {
        inventory = BrowserInventorySnapshot(installedCatalog: [chrome, arc, safari, zen])
        support = [chrome: .cantRead, arc: .cantRead, safari: .cantRead, zen: .cantRead]
        make()
        fake.states = [arc: state(.notAsked), safari: state(.allowed)]
        sut.refresh()
        XCTAssertEqual(try row(chrome).statusHint, "Kytkin can't see the page address. Turn on Automation below.")
        XCTAssertEqual(try row(arc).statusHint, "Kytkin can't see the page address. Allow Automation below.")
        XCTAssertEqual(try row(safari).statusHint, "Kytkin can't see the page address, even with Automation.")
        XCTAssertEqual(try row(zen).statusHint, "Kytkin can't see the page address here. Not supported yet.")
    }

    // MARK: - End to end with the real controller: opening Settings never prompts

    func testOpeningSettingsWithTheRealControllerOnlyChecksSilently() throws {
        let permissions = RecordingPermissions()
        var prefs = Preferences()
        prefs.browsers.appleEventsOptIn = [chrome: true]
        store = makeStore(prefs, clock: FakeClock())
        let controller = BrowserAutomationController(store: store, permissions: permissions,
                                                     isRunning: { $0 == self.chrome })
        inventory = BrowserInventorySnapshot(installedCatalog: [chrome, zen])
        sut = BrowsersSettingsModel(store: store, appName: { _ in nil }, suffixListLoaded: true,
                                    ownBundleIDPrefix: "", inventory: { [unowned self] in inventory },
                                    support: { _ in .notSeenYet }, automation: controller)
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
        sut.setAutomationEnabled(false, for: chrome)
        XCTAssertEqual(store.prefs.browsers.appleEventsOptIn, [:])
        XCTAssertEqual(try row(chrome).automationStatusText, "Off")
    }
}
