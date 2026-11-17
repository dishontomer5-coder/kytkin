// P6-3: the optional update check, over a fake HTTP client (no real network in tests): off until opted in, at most
// once a day, only the fixed headers, the menu line, quiet failures, and the version compare.

import XCTest

final class FakeHTTP: HTTPGetting, @unchecked Sendable {
    private let lock = NSLock()
    private var _requests: [(URL, [String: String])] = []
    var answer: (status: Int, body: Data)?
    var requests: [(URL, [String: String])] { lock.withLock { _requests } }

    func get(_ url: URL, headers: [String: String]) async -> (status: Int, body: Data)? {
        lock.withLock { _requests.append((url, headers)) }
        return answer
    }
}

@MainActor
final class UpdateCheckTests: XCTestCase {
    private var store: PreferencesStore!
    private var http: FakeHTTP!
    private var now = Date(timeIntervalSince1970: 1_000_000)
    private var sut: UpdateChecker!

    override func setUp() async throws {
        store = makeStore(clock: FakeClock())
        http = FakeHTTP()
        sut = UpdateChecker(store: store, http: http, appVersion: "1.0.0", now: { [unowned self] in self.now })
    }

    private func release(_ tag: String, page: String = "https://github.com/dishontomer5-coder/kytkin/releases/tag/v1.1.0",
                         prerelease: Bool = false) -> Data {
        Data(#"{"tag_name":"\#(tag)","html_url":"\#(page)","draft":false,"prerelease":\#(prerelease),"body":"x"}"#.utf8)
    }

    // MARK: - Opt-in

    func testOffUntilTheUserOptsIn() async {
        XCTAssertFalse(Preferences().general.updateCheckOptedIn)
        http.answer = (200, release("v1.1.0"))
        await sut.checkIfDue()
        await sut.checkNow()
        XCTAssertTrue(http.requests.isEmpty, "not one request while off")
        XCTAssertNil(sut.notice)
        XCTAssertNil(store.prefs.general.lastUpdateCheck)
    }

    func testOneGETWithOnlyTheFixedHeaders() async {
        store.update { $0.general.updateCheckOptedIn = true }
        http.answer = (200, release("v1.1.0"))
        await sut.checkIfDue()
        XCTAssertEqual(http.requests.count, 1)
        let (url, headers) = http.requests[0]
        XCTAssertEqual(url.absoluteString, "https://api.github.com/repos/dishontomer5-coder/kytkin/releases/latest")
        XCTAssertNil(url.query, "no query parameters")
        // P6-3 QA: Accept-Language fixed too (the system would send the Mac's preferred languages).
        XCTAssertEqual(headers, ["User-Agent": "Kytkin/1.0.0", "Accept": "application/vnd.github+json",
                                 "Accept-Language": "en"])
        XCTAssertEqual(store.prefs.general.lastUpdateCheck, now, "only the date is stored")
    }

    func testAtMostOnceADay() async {
        store.update { $0.general.updateCheckOptedIn = true }
        http.answer = (200, release("v1.0.0"))
        await sut.checkIfDue()
        now += 23 * 3600
        await sut.checkIfDue()
        XCTAssertEqual(http.requests.count, 1)
        now += 3600
        await sut.checkIfDue()
        XCTAssertEqual(http.requests.count, 2)
        await sut.checkNow()
        XCTAssertEqual(http.requests.count, 3, "Check Now asks whenever clicked")
    }

    // MARK: - The menu line

    func testANewerReleaseIsOneMenuLine() async {
        store.update { $0.general.updateCheckOptedIn = true }
        http.answer = (200, release("v1.1.0"))
        await sut.checkNow()
        XCTAssertEqual(sut.notice, UpdateNotice(version: "1.1.0",
                                                pageURL: URL(string: "https://github.com/dishontomer5-coder/kytkin/releases/tag/v1.1.0")!))
        XCTAssertEqual(sut.notice?.menuTitle, "Update available: Kytkin 1.1.0…")
        XCTAssertEqual(sut.statusText, "Kytkin 1.1.0 is available.")

        var state = MenuState()
        state.updateNotice = sut.notice
        let items = MenuModel.items(state: state, currentSource: nil, settingsAvailable: true,
                                    includeDebug: false, sourceName: { $0.rawValue }, appName: { $0 })
        XCTAssertTrue(items.contains(.action("Update available: Kytkin 1.1.0…",
                                             .openURL(URL(string: "https://github.com/dishontomer5-coder/kytkin/releases/tag/v1.1.0")!))))

        sut.setOn(false)
        XCTAssertNil(sut.notice, "turned off: the line goes")
    }

    func testTheSameOrOlderVersionIsUpToDate() async {
        store.update { $0.general.updateCheckOptedIn = true }
        for tag in ["v1.0.0", "1.0", "v0.9.9"] {
            http.answer = (200, release(tag))
            await sut.checkNow()
            XCTAssertNil(sut.notice, tag)
            XCTAssertEqual(sut.statusText, "Kytkin is up to date.", tag)
        }
    }

    func testFailuresAreQuiet() async {
        store.update { $0.general.updateCheckOptedIn = true }
        for answer: (status: Int, body: Data)? in [nil, (404, Data(#"{"message":"Not Found"}"#.utf8)), (403, Data()),
                                                     (200, Data("not json".utf8)),
                                                     (200, release("v2.0.0", page: "http://evil.example/x")),
                                                     (200, release("v2.0.0", prerelease: true))] {
            http.answer = answer
            await sut.checkNow()
            XCTAssertNil(sut.notice)
            XCTAssertEqual(sut.status, .failed)
        }
    }

    // MARK: - Versions

    func testSemanticVersions() {
        XCTAssertLessThan(SemanticVersion("1.0.0")!, SemanticVersion("v1.0.1")!)
        XCTAssertLessThan(SemanticVersion("1.9")!, SemanticVersion("1.10")!)
        XCTAssertEqual(SemanticVersion("1.0")!, SemanticVersion("1.0.0")!)
        XCTAssertEqual(SemanticVersion("v2.1.0-beta")?.description, "2.1.0")
        XCTAssertNil(SemanticVersion("latest"))
        XCTAssertNil(SemanticVersion("1..2"))
        XCTAssertNil(SemanticVersion(""))
    }

    // MARK: - Setup screen 3

    func testTheSetupBoxIsUncheckedAndAppliedOnDone() {
        let general = GeneralSettingsModel(store: store, loginItems: FakeLoginItems(), sources: { [] }, updates: sut)
        let permissions = RecordingPermissions()
        let fs = InMemoryLayoutFileSystem()
        let imported = ImportedLayoutStore(directory: URL(fileURLWithPath: "/tmp/kytkin-tests-never-written/layouts"),
                                           fileSystem: fs)
        let languages = LanguagesSettingsModel(store: store, imported: imported,
                                               catalog: LayoutMapCatalog(system: FakeSystemLayouts.standard(),
                                                                         imported: imported),
                                               fileSystem: fs, inputMethods: { [] })
        let setup = OnboardingModel(store: store, permissions: permissions,
                                    polling: PermissionPollingDemand(permissions: permissions), general: general,
                                    languages: languages, appName: "Kytkin Dev", updates: sut)
        setup.begin(firstLaunch: true)
        XCTAssertFalse(setup.checkForUpdates, "never ticked for the user")
        setup.done()
        XCTAssertFalse(store.prefs.general.updateCheckOptedIn)
        setup.checkForUpdates = true
        setup.done()
        XCTAssertTrue(store.prefs.general.updateCheckOptedIn)
    }

    // MARK: - P6-3 QA

    func testOnlyThisRepositorysReleasePageIsEverOpened() async {
        store.update { $0.general.updateCheckOptedIn = true }
        for page in ["https://github.com/someone-else/kytkin/releases/tag/v2.0.0",
                     "https://github.com/dishontomer5-coder/kytkin-fork/releases/tag/v2.0.0",
                     "https://github.com/dishontomer5-coder/kytkin/issues/1",
                     "https://github.com.evil.example/dishontomer5-coder/kytkin/releases/tag/v2.0.0",
                     "https://user@github.com/dishontomer5-coder/kytkin/releases/tag/v2.0.0",
                     "https://github.com:8443/dishontomer5-coder/kytkin/releases/tag/v2.0.0",
                     "https://github.com/dishontomer5-coder/kytkin/releases/tag/v2.0.0?x=1"] {
            http.answer = (200, release("v2.0.0", page: page))
            await sut.checkNow()
            XCTAssertNil(sut.notice, page)
        }
        XCTAssertTrue(UpdateCheck.isReleasePage(URL(string: "https://github.com/dishontomer5-coder/kytkin/releases/tag/v2.0.0")!))
    }

    func testRedirectsOnlyToTheGitHubAPI() {
        XCTAssertTrue(UpdateCheck.allowsRedirect(to: URL(string: "https://api.github.com/repositories/1/releases/latest")))
        XCTAssertFalse(UpdateCheck.allowsRedirect(to: URL(string: "http://api.github.com/x")))
        XCTAssertFalse(UpdateCheck.allowsRedirect(to: URL(string: "https://evil.example/x")))
        XCTAssertFalse(UpdateCheck.allowsRedirect(to: URL(string: "https://api.github.com.evil.example/x")))
        XCTAssertFalse(UpdateCheck.allowsRedirect(to: nil))
    }

    func testPreReleasesAreNeverOfferedAndSortBeforeTheirRelease() async {
        XCTAssertLessThan(SemanticVersion("1.0.0-beta.2")!, SemanticVersion("1.0.0")!)
        XCTAssertLessThan(SemanticVersion("0.9.9")!, SemanticVersion("1.0.0-beta")!)
        XCTAssertEqual(SemanticVersion("1.0.0+build.7")!, SemanticVersion("1.0.0")!)
        store.update { $0.general.updateCheckOptedIn = true }
        http.answer = (200, release("v1.1.0-rc.1"))   // a pre-release tag not flagged as one
        await sut.checkNow()
        XCTAssertNil(sut.notice)
        // A beta user is told about the release.
        let beta = UpdateChecker(store: store, http: http, appVersion: "1.1.0-beta", now: { [unowned self] in self.now })
        http.answer = (200, release("v1.1.0"))
        await beta.checkNow()
        XCTAssertEqual(beta.notice?.version, "1.1.0")
    }

    func testReadOnlyPreferencesStillCheckOnlyOnceADay() async {
        var prefs = Preferences()
        prefs.general.updateCheckOptedIn = true
        let readOnly = makeReadOnlyStore(prefs)
        XCTAssertTrue(readOnly.isReadOnly)
        let checker = UpdateChecker(store: readOnly, http: http, appVersion: "1.0.0", now: { [unowned self] in self.now })
        http.answer = (500, Data())
        await checker.checkIfDue()
        now = now.addingTimeInterval(60 * 60)
        await checker.checkIfDue()
        XCTAssertEqual(http.requests.count, 1, "the hourly timer doesn't ask again while the date can't be saved")
    }
}
