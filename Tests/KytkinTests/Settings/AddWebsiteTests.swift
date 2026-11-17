// P3-15: Rules → "Add Website…" (001 §14.8, D7, D13, D14): parsing what was typed or pasted (only the host is kept;
// gov.il refused; the subdomain choice; IPs and localhost), the form (default choice, the "replaces" line, Esc keeps
// typed text), saving a pinned Punycode rule through RuleWriter, read-only and missing-PSL refusals; plus the Rules
// kind filter and the Unicode name with the Punycode second line.

import XCTest

final class WebsiteInputTests: XCTestCase {
    private func parse(_ text: String, file: StaticString = #filePath, line: UInt = #line) throws -> WebsiteInput {
        let extractor = try XCTUnwrap(DomainExtractor.bundled, "public_suffix_list.dat is missing", file: file, line: line)
        return WebsiteInput.parse(text, extractor: extractor)
    }

    func testEmptyAndInvalid() throws {
        XCTAssertEqual(try parse(""), .empty)
        XCTAssertEqual(try parse("   \n"), .empty)
        XCTAssertEqual(try parse("hello"), .invalid, "a word is not an address")
        XCTAssertEqual(try parse("node.js"), .invalid, "not a real top-level domain")
        XCTAssertEqual(try parse("about:blank"), .invalid)
        XCTAssertEqual(try parse("file:///Users/me/a.html"), .invalid)
        XCTAssertEqual(try parse("chrome://settings"), .invalid)
        XCTAssertNil(try parse("hello").scope(extent: .wholeSite))
        XCTAssertNotNil(try parse("hello").message)
        XCTAssertNil(try parse("").message)
    }

    func testATypedRegistrableDomainIsOneWholeSiteRule() throws {
        let input = try parse("ynet.co.il")
        XCTAssertEqual(input, .single(siteKey: "ynet.co.il", isHostOnly: false))
        XCTAssertEqual(input.scope(extent: .wholeSite), .site(domain: "ynet.co.il"))
        XCTAssertEqual(input.scope(extent: .onlyHost), .site(domain: "ynet.co.il"), "no choice to make")
        XCTAssertEqual(input.message, "All of ynet.co.il, including its subdomains")
    }

    func testAPastedURLKeepsOnlyTheHost() throws {
        let input = try parse("  https://user:pw@News.YNET.co.il:8443/article/1?id=5#top ")
        XCTAssertEqual(input, .choice(site: "ynet.co.il", host: "news.ynet.co.il"))
        XCTAssertEqual(input.scope(extent: .wholeSite), .site(domain: "ynet.co.il"))
        XCTAssertEqual(input.scope(extent: .onlyHost), .siteHost(host: "news.ynet.co.il"))
        XCTAssertEqual(input.title(for: .wholeSite), "All of ynet.co.il")
        XCTAssertEqual(input.title(for: .onlyHost), "Only news.ynet.co.il")
        XCTAssertNil(WebsiteInput.single(siteKey: "a.com", isHostOnly: false).title(for: .wholeSite))
    }

    func testPublicSuffixHostsAreRefused() throws {
        XCTAssertEqual(try parse("gov.il"), .sharedSuffix("gov.il"))
        XCTAssertEqual(try parse("https://github.io/"), .sharedSuffix("github.io"))
        XCTAssertEqual(try parse("co.il"), .sharedSuffix("co.il"))
        XCTAssertEqual(try parse("https://il/"), .sharedSuffix("il"), "a bare top-level domain")
        XCTAssertNil(try parse("gov.il").scope(extent: .wholeSite))
        XCTAssertEqual(try parse("gov.il").message,
                       "gov.il is shared by many websites. Enter one site, like www.gov.il.")
    }

    func testOneSiteUnderASharedSuffixIsItsOwnSite() throws {
        XCTAssertEqual(try parse("www.gov.il"), .single(siteKey: "www.gov.il", isHostOnly: false))
        XCTAssertEqual(try parse("https://police.gov.il/x"), .single(siteKey: "police.gov.il", isHostOnly: false))
        XCTAssertEqual(try parse("alice.github.io"), .single(siteKey: "alice.github.io", isHostOnly: false))
    }

    func testIPsLocalhostAndIntranetNamesAreKeyedByTheHost() throws {
        XCTAssertEqual(try parse("192.168.1.1"), .single(siteKey: "192.168.1.1", isHostOnly: true))
        XCTAssertEqual(try parse("http://[::1]:8080/"), .single(siteKey: "::1", isHostOnly: true))
        XCTAssertEqual(try parse("localhost:3000"), .single(siteKey: "localhost", isHostOnly: true))
        XCTAssertEqual(try parse("http://intranet/wiki"), .single(siteKey: "intranet", isHostOnly: true))
        XCTAssertEqual(try parse("192.168.1.1").scope(extent: .wholeSite), .site(domain: "192.168.1.1"))
        XCTAssertEqual(try parse("192.168.1.1").message, "Only 192.168.1.1")
    }

    func testUnicodeIsStoredAsPunycodeAndShownInUnicode() throws {
        let input = try parse("שלום.co.il")
        XCTAssertEqual(input, .single(siteKey: "xn--9dbne9b.co.il", isHostOnly: false))
        XCTAssertEqual(input.message, "All of שלום.co.il, including its subdomains")
        let sub = try parse("https://www.שלום.co.il/")
        XCTAssertEqual(sub.scope(extent: .onlyHost), .siteHost(host: "www.xn--9dbne9b.co.il"))
        XCTAssertEqual(sub.title(for: .onlyHost), "Only www.שלום.co.il")
    }
}

@MainActor
final class AddWebsiteRulesTests: XCTestCase {
    private let tNow = Date(timeIntervalSince1970: 9_000)
    private var store: PreferencesStore!
    private var sut: RulesSettingsModel!

    private func info(_ id: InputSourceID, _ name: String) -> InputSourceInfo {
        InputSourceInfo(id: id, name: name, languageCode: "", isEnabled: true, isConvertible: true,
                        isInputMethod: false)
    }

    private func make(_ rules: [Rule] = [], readOnly: Bool = false, extractor: DomainExtractor? = DomainExtractor.bundled) {
        var prefs = Preferences()
        prefs.rules = rules
        store = readOnly ? makeReadOnlyStore(prefs) : makeStore(prefs, clock: FakeClock())
        sut = RulesSettingsModel(store: store, appName: { _ in nil },
                                 sources: { [unowned self] in [self.info(IDs.abc, "ABC"), self.info(IDs.hebrew, "Hebrew")] },
                                 now: { [tNow] in tNow }, extractor: extractor)
        sut.refresh()
    }

    private func site(_ d: String, _ s: InputSourceID, _ o: RuleOrigin = .learned) -> Rule {
        Rule(scope: .site(domain: d), inputSource: s, origin: o, updatedAt: Date(timeIntervalSince1970: 1_000))
    }

    func testAddWebsiteWritesAPinnedRuleAndClosesTheSheet() throws {
        make()
        XCTAssertTrue(sut.canAddWebsite)
        sut.beginAddWebsite()
        let form = try XCTUnwrap(sut.addWebsite)
        XCTAssertEqual(form.title, "Add Website")
        XCTAssertEqual(form.text, "")
        XCTAssertFalse(form.canSave, "nothing typed")
        XCTAssertEqual(form.languageOptions.map(\.name), ["ABC", "Hebrew"])
        XCTAssertEqual(form.language, IDs.abc, "the pair's first language by default")
        form.text = "https://www.ynet.co.il/news?id=1"
        XCTAssertTrue(form.showsChoice)
        XCTAssertEqual(form.extent, .wholeSite, "the whole site by default")
        form.language = IDs.hebrew
        XCTAssertTrue(sut.saveAddWebsite())
        XCTAssertNil(sut.addWebsite, "closed, the typed address dropped")
        let rule = try XCTUnwrap(store.prefs.rules.only)
        XCTAssertEqual(rule.scope, .site(domain: "ynet.co.il"))
        XCTAssertEqual(rule.inputSource, IDs.hebrew)
        XCTAssertEqual(rule.origin, .pinned)
        XCTAssertEqual(rule.updatedAt, tNow)
    }

    func testOnlyThisAddressWritesASiteHostRule() throws {
        make()
        sut.beginAddWebsite()
        let form = try XCTUnwrap(sut.addWebsite)
        form.text = "news.ynet.co.il"
        form.extent = .onlyHost
        sut.saveAddWebsite()
        XCTAssertEqual(store.prefs.rules.map(\.scope), [.siteHost(host: "news.ynet.co.il")])
    }

    func testAUnicodeAddressIsStoredInPunycode() throws {
        make()
        sut.beginAddWebsite()
        try XCTUnwrap(sut.addWebsite).text = "שלום.co.il"
        sut.saveAddWebsite()
        XCTAssertEqual(store.prefs.rules.map(\.scope), [.site(domain: "xn--9dbne9b.co.il")])
        let row = try XCTUnwrap(sut.rows.only)
        XCTAssertEqual(row.name, "שלום.co.il", "shown in Unicode")
        XCTAssertEqual(row.detail, "xn--9dbne9b.co.il", "the stored Punycode as the second line")
        XCTAssertEqual(row.kindTitle, "Website")
    }

    func testRefusedInputWritesNothing() throws {
        make()
        sut.beginAddWebsite()
        let form = try XCTUnwrap(sut.addWebsite)
        for text in ["gov.il", "github.io", "hello", "about:blank", ""] {
            form.text = text
            XCTAssertFalse(form.canSave, text)
            XCTAssertFalse(sut.saveAddWebsite(), text)
        }
        XCTAssertTrue(store.prefs.rules.isEmpty)
        XCTAssertNotNil(sut.addWebsite, "the sheet stays open with what was typed")
    }

    func testCancelDropsTheDraft() throws {
        make()
        sut.beginAddWebsite()
        try XCTUnwrap(sut.addWebsite).text = "ynet.co.il"
        sut.cancelAddWebsite()
        XCTAssertNil(sut.addWebsite)
        XCTAssertTrue(store.prefs.rules.isEmpty)
        sut.beginAddWebsite()
        XCTAssertEqual(sut.addWebsite?.text, "", "a new sheet starts empty")
    }

    func testEscClosesTheSheetOnlyWhenNothingIsTyped() throws {
        make()
        sut.beginAddWebsite()
        let form = try XCTUnwrap(sut.addWebsite)
        XCTAssertTrue(form.escapeCloses)
        form.text = "yn"
        XCTAssertFalse(form.escapeCloses, "P3-12 QA note: Esc never loses typed input")
        form.text = "  "
        XCTAssertTrue(form.escapeCloses)
    }

    func testAnExistingRuleIsReplacedAndSaid() throws {
        make([site("ynet.co.il", IDs.abc)])
        sut.beginAddWebsite()
        let form = try XCTUnwrap(sut.addWebsite)
        form.text = "YNET.co.il"
        XCTAssertEqual(form.replacesText, "ynet.co.il already has a rule (ABC, learned). Saving replaces it.")
        form.language = IDs.hebrew
        sut.saveAddWebsite()
        let rule = try XCTUnwrap(store.prefs.rules.only, "replaced, not duplicated")
        XCTAssertEqual(rule.inputSource, IDs.hebrew)
        XCTAssertEqual(rule.origin, .pinned)
        form.text = "news.ynet.co.il"
        form.extent = .onlyHost
        XCTAssertNil(form.replacesText, "a single-address rule is a different scope")
    }

    func testAddSubdomainRuleIsOfferedForRealSitesAndPrefilled() throws {
        make([site("ynet.co.il", IDs.hebrew), site("192.168.1.1", IDs.abc), site("intranet", IDs.abc),
              .app("com.apple.Notes", IDs.abc),
              Rule(scope: .siteHost(host: "news.ynet.co.il"), inputSource: IDs.abc, origin: .pinned,
                   updatedAt: Date(timeIntervalSince1970: 1_000))])
        sut.sortOrder = .name
        let offered = sut.rows.filter(sut.offersSubdomainRule).map(\.name)
        XCTAssertEqual(offered, ["ynet.co.il"])
        sut.beginAddWebsite(subdomainOf: "ynet.co.il")
        let form = try XCTUnwrap(sut.addWebsite)
        XCTAssertEqual(form.title, "Add Subdomain Rule")
        XCTAssertEqual(form.text, "ynet.co.il")
        XCTAssertEqual(form.extent, .onlyHost)
        XCTAssertEqual(form.hint, "Type the address that should get its own language, like news.ynet.co.il.")
        form.text = "sport.ynet.co.il"
        XCTAssertTrue(form.canSave)
        sut.saveAddWebsite()
        XCTAssertTrue(store.prefs.rules.contains { $0.scope == .siteHost(host: "sport.ynet.co.il") && $0.origin == .pinned })
    }

    /// QA (P3-15): the prefilled site in "Add Subdomain Rule…" must not be saved as is: Return would otherwise pin the
    /// whole site to the sheet's default language and replace its rule.
    func testTheUnchangedPrefilledSiteIsNotSavedFromTheSubdomainSheet() throws {
        make([site("ynet.co.il", IDs.hebrew)])
        sut.beginAddWebsite(subdomainOf: "ynet.co.il")
        let form = try XCTUnwrap(sut.addWebsite)
        XCTAssertEqual(form.language, IDs.hebrew, "P3-24: the site rule's language")
        XCTAssertTrue(form.isStillTheParentSite)
        XCTAssertFalse(form.canSave)
        XCTAssertFalse(sut.saveAddWebsite())
        form.text = "https://WWW.ynet.co.il./"
        form.extent = .wholeSite
        XCTAssertEqual(form.scope, .site(domain: "ynet.co.il"), "the whole site, chosen for a typed subdomain")
        XCTAssertFalse(form.canSave, "still the parent site, however it is typed")
        form.extent = .onlyHost
        XCTAssertTrue(form.canSave, "only www.ynet.co.il is a subdomain rule")
        let rule = try XCTUnwrap(store.prefs.rules.only)
        XCTAssertEqual(rule.inputSource, IDs.hebrew, "the site's rule is untouched")
        XCTAssertEqual(rule.origin, .learned)
    }

    func testTheSubdomainSheetStartsWithTheSiteRulesLanguage() throws {
        // P3-24 (Coordinator): not the first option.
        make([site("ynet.co.il", IDs.hebrew)])
        sut.beginAddWebsite(subdomainOf: "ynet.co.il")
        XCTAssertEqual(try XCTUnwrap(sut.addWebsite).language, IDs.hebrew)
    }

    func testASiteRuleInALanguageNotOfferedFallsBackToTheFirstOption() throws {
        make([site("ynet.co.il", InputSourceID("com.apple.keylayout.Russian"))])
        sut.beginAddWebsite(subdomainOf: "ynet.co.il")
        XCTAssertEqual(try XCTUnwrap(sut.addWebsite).language, IDs.abc)
    }

    func testAddWebsiteStillStartsWithTheFirstOption() throws {
        make([site("ynet.co.il", IDs.hebrew)])
        sut.beginAddWebsite()
        XCTAssertEqual(try XCTUnwrap(sut.addWebsite).language, IDs.abc)
    }

    func testClosingSettingsResetsTheKindFilter() {
        // P3-24: "Show in Rules" sets Websites; the next opening shows All again.
        make()
        sut.kindFilter = .websites
        sut.settingsClosed()
        XCTAssertEqual(sut.kindFilter, .all)
    }

    /// QA (P3-15): a pasted URL never leaves its path, query, fragment or user info in the file.
    func testOnlyTheHostReachesThePreferences() throws {
        make()
        sut.beginAddWebsite()
        let form = try XCTUnwrap(sut.addWebsite)
        form.text = "https://alice:secret@news.ynet.co.il:8443/private/path?token=tokenvalue#fragpart"
        form.extent = .onlyHost
        XCTAssertTrue(sut.saveAddWebsite())
        XCTAssertEqual(store.prefs.rules.map(\.scope), [.siteHost(host: "news.ynet.co.il")])
        let data = try JSONEncoder().encode(store.prefs)
        let json = String(decoding: data, as: UTF8.self)
        for secret in ["alice", "secret", "private", "token", "tokenvalue", "fragpart", "8443"] {
            XCTAssertFalse(json.contains(secret), secret)
        }
        XCTAssertFalse(json.contains("https"), "no scheme either")
    }

    /// QA (P3-15): a scheme-less address with user info could be a mail address: refused, nothing written.
    func testUserInfoWithoutASchemeIsRefused() throws {
        make()
        sut.beginAddWebsite()
        let form = try XCTUnwrap(sut.addWebsite)
        form.text = "me@ynet.co.il"
        XCTAssertFalse(form.canSave)
        XCTAssertFalse(sut.saveAddWebsite())
        XCTAssertTrue(store.prefs.rules.isEmpty)
    }

    func testReadOnlyPreferencesAddNothing() {
        make(readOnly: true)
        XCTAssertFalse(sut.canAddWebsite)
        sut.beginAddWebsite()
        XCTAssertNil(sut.addWebsite)
        XCTAssertFalse(sut.saveAddWebsite())
        XCTAssertTrue(store.prefs.rules.isEmpty)
    }

    func testMissingSuffixListAddsNothing() {
        make(extractor: nil)
        XCTAssertFalse(sut.canAddWebsite)
        sut.beginAddWebsite()
        XCTAssertNil(sut.addWebsite)
        XCTAssertFalse(RulesSettingsModel.websiteDataMissingText.isEmpty)
    }

    // MARK: - Kind filter and display

    func testKindFilter() {
        let host = Rule(scope: .siteHost(host: "news.ynet.co.il"), inputSource: IDs.abc, origin: .pinned,
                        updatedAt: Date(timeIntervalSince1970: 1_000))
        let chat = Rule(scope: .chat(bundleID: "com.tinyspeck.slackmacgap", key: ChatKey(kind: .id, value: "T1")),
                        inputSource: IDs.abc, origin: .learned, label: "Team", updatedAt: Date(timeIntervalSince1970: 1_000))
        make([site("ynet.co.il", IDs.hebrew), host, .app("com.apple.Notes", IDs.abc), chat])
        sut.sortOrder = .name
        XCTAssertEqual(sut.rows.count, 4)
        sut.kindFilter = .apps
        XCTAssertEqual(sut.rows.map(\.scope), [.app(bundleID: "com.apple.Notes")])
        sut.kindFilter = .websites
        XCTAssertEqual(Set(sut.rows.map(\.scope)), [.site(domain: "ynet.co.il"), .siteHost(host: "news.ynet.co.il")])
        sut.originFilter = .pinned
        XCTAssertEqual(sut.rows.map(\.scope), [.siteHost(host: "news.ynet.co.il")], "both filters apply")
        XCTAssertEqual(RuleKindFilter.allCases.map(\.title), ["All", "Apps", "Websites"])
    }

    func testAnASCIIHostHasNoSecondLineAndSearchFindsThePunycode() {
        make([site("ynet.co.il", IDs.hebrew), site("xn--9dbne9b.co.il", IDs.hebrew),
              Rule(scope: .siteHost(host: "www.xn--9dbne9b.co.il"), inputSource: IDs.abc, origin: .pinned,
                   updatedAt: Date(timeIntervalSince1970: 1_000))])
        sut.sortOrder = .name
        let byName = Dictionary(uniqueKeysWithValues: sut.rows.map { ($0.name, $0) })
        XCTAssertNil(byName["ynet.co.il"]?.detail)
        XCTAssertEqual(byName["www.שלום.co.il"]?.detail, "www.xn--9dbne9b.co.il")
        XCTAssertEqual(byName["www.שלום.co.il"]?.kindTitle, "Website, only this address")
        sut.searchText = "xn--9dbne9b"
        XCTAssertEqual(sut.rows.count, 2, "IDN look-alikes stay findable by their stored key")
    }
}

private extension Array {
    var only: Element? { count == 1 ? first : nil }
}
