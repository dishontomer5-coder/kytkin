// P2-25: Settings → Rules logic: rows (names, kinds, duplicates, site/chat shown), sorting and filtering, language
// change = pin, pin / unpin / delete / forget all learned through RuleWriter, and read-only mode.

import XCTest

@MainActor
final class RulesSettingsModelTests: XCTestCase {
    private let notes = "com.apple.Notes"
    private let term = "com.apple.Terminal"
    private let slack = "com.tinyspeck.slackmacgap"
    private let unknown = "com.example.Gone"
    private let t0 = Date(timeIntervalSince1970: 1_000)
    private let t1 = Date(timeIntervalSince1970: 2_000)
    private let t2 = Date(timeIntervalSince1970: 3_000)
    private let tNow = Date(timeIntervalSince1970: 9_000)

    private var store: PreferencesStore!
    private var names: FakeAppNames!
    private var sourceReads = 0
    private var sut: RulesSettingsModel!

    private func info(_ id: InputSourceID, _ name: String, enabled: Bool = true) -> InputSourceInfo {
        InputSourceInfo(id: id, name: name, languageCode: "", isEnabled: enabled, isConvertible: true,
                        isInputMethod: false)
    }

    private func make(_ rules: [Rule], readOnly: Bool = false) {
        var prefs = Preferences()
        prefs.rules = rules
        store = readOnly ? makeReadOnlyStore(prefs) : makeStore(prefs, clock: FakeClock())
        names = FakeAppNames([notes: "Notes", term: "Terminal", slack: "Slack"])
        let names = self.names!
        sut = RulesSettingsModel(store: store, appName: { names.lookup($0) }, sources: { [unowned self] in
            self.sourceReads += 1
            return [self.info(IDs.abc, "ABC"), self.info(IDs.hebrew, "Hebrew"),
                    self.info(IDs.russian, "Russian", enabled: false)]
        }, now: { [tNow] in tNow })
        sut.refresh()
    }

    private var rules: [Rule] { store.prefs.rules }

    // MARK: - Rows

    func testRowsResolveAppNamesAndFallBackToTheBundleID() {
        make([Rule.app(notes, IDs.hebrew), Rule.app(unknown, IDs.abc, .pinned)])
        sut.sortOrder = .name
        let rows = sut.rows
        XCTAssertEqual(rows.map(\.name), [unknown, "Notes"])
        XCTAssertEqual(rows[1].detail, notes, "the bundle ID under a resolved name")
        XCTAssertNil(rows[0].detail, "no second copy of the bundle ID")
        XCTAssertEqual(rows.map(\.kindTitle), ["App", "App"])
        XCTAssertEqual(rows.map(\.languageName), ["ABC", "Hebrew"])
        XCTAssertEqual(rows.map(\.originTitle), ["Pinned", "Learned"])
    }

    func testLanguageNameForADisabledOrUnknownSource() {
        let odd = InputSourceID("com.apple.keylayout.Greek")
        make([Rule.app(notes, IDs.russian), Rule.app(term, odd)])
        sut.sortOrder = .name
        XCTAssertEqual(sut.rows.map(\.languageName), ["Russian", "Greek"])
    }

    func testSiteHostAndChatRulesAreShown() {
        let site = Rule(scope: .site(domain: "ynet.co.il"), inputSource: IDs.hebrew, origin: .learned, updatedAt: t0)
        let host = Rule(scope: .siteHost(host: "docs.google.com"), inputSource: IDs.abc, origin: .pinned,
                        updatedAt: t0)
        let chat = Rule(scope: .chat(bundleID: slack, key: ChatKey(kind: .id, value: "T1/C2")),
                        inputSource: IDs.hebrew, origin: .learned, label: "Slack chat 1", updatedAt: t0)
        let unlabeled = Rule(scope: .chat(bundleID: slack, key: ChatKey(kind: .hashed, value: "abc")),
                             inputSource: IDs.hebrew, origin: .learned, updatedAt: t0)
        make([site, host, chat, unlabeled])
        sut.sortOrder = .name
        let rows = sut.rows
        XCTAssertEqual(rows.map(\.name), ["docs.google.com", "Slack chat", "Slack chat 1", "ynet.co.il"])
        XCTAssertEqual(rows.map(\.kindTitle), ["Part of a website", "Chat", "Chat", "Website"])
        XCTAssertEqual(rows[1].detail, "Slack")
    }

    func testDuplicateScopesShowOnlyTheWinner() {
        let loser = Rule.app(notes, IDs.abc, at: t2)
        let winner = Rule.app(notes, IDs.hebrew, .pinned, at: t0)
        make([loser, winner])
        XCTAssertEqual(sut.rows.map(\.id), [winner.id])
    }

    func testEmptyKeyRulesAreNotListed() {
        make([Rule.app("", IDs.abc), Rule.app(notes, IDs.hebrew)])
        XCTAssertEqual(sut.rows.map(\.name), ["Notes"])
    }

    func testAppNamesAreCachedAcrossRedraws() {
        make([Rule.app(notes, IDs.hebrew)])
        _ = sut.rows
        _ = sut.rows
        XCTAssertEqual(names.lookups, 1)
    }

    func testSourcesAreReadOnlyOnRefresh() {
        make([Rule.app(notes, IDs.hebrew)])
        XCTAssertEqual(sourceReads, 1)
        _ = sut.rows
        XCTAssertEqual(sourceReads, 1)
        sut.refresh()
        XCTAssertEqual(sourceReads, 2)
    }

    func testEmptyText() {
        make([])
        XCTAssertFalse(sut.hasRules)
        XCTAssertTrue(sut.emptyText.hasPrefix("No rules yet."))
        make([Rule.app(notes, IDs.hebrew)])
        sut.searchText = "zzz"
        XCTAssertEqual(sut.rows, [])
        XCTAssertEqual(sut.emptyText, "No rules match.")
    }

    // MARK: - Sorting

    private func sortFixture() -> (a: Rule, b: Rule, c: Rule) {
        let a = Rule.app(notes, IDs.hebrew, .learned, at: t1)          // Notes, Hebrew, learned, middle
        let b = Rule.app(term, IDs.abc, .pinned, at: t0)               // Terminal, ABC, pinned, oldest
        let c = Rule.app(slack, IDs.hebrew, .pinned, at: t2)           // Slack, Hebrew, pinned, newest
        make([a, b, c])
        return (a, b, c)
    }

    func testDefaultSortIsNewestFirst() {
        let f = sortFixture()
        XCTAssertEqual(sut.sortOrder, .lastUpdated)
        XCTAssertEqual(sut.rows.map(\.id), [f.c.id, f.a.id, f.b.id])
    }

    func testSortByName() {
        _ = sortFixture()
        sut.sortOrder = .name
        XCTAssertEqual(sut.rows.map(\.name), ["Notes", "Slack", "Terminal"])
    }

    func testSortByLanguageThenName() {
        _ = sortFixture()
        sut.sortOrder = .language
        XCTAssertEqual(sut.rows.map(\.name), ["Terminal", "Notes", "Slack"])
    }

    func testSortPinnedFirstThenName() {
        _ = sortFixture()
        sut.sortOrder = .origin
        XCTAssertEqual(sut.rows.map(\.name), ["Slack", "Terminal", "Notes"])
    }

    func testSortTieBreaksOnIDSoTheOrderIsStable() {
        let id1 = UUID(uuidString: "00000000-0000-0000-0000-000000000001")!
        let id2 = UUID(uuidString: "00000000-0000-0000-0000-000000000002")!
        let rows = [id2, id1].map {
            RuleRow(id: $0, scope: .app(bundleID: "x"), kindTitle: "App", name: "Same", detail: nil,
                    inputSource: IDs.abc, languageName: "ABC", origin: .learned, updatedAt: t0)
        }
        for order in RuleSortOrder.allCases {
            XCTAssertEqual(order.sorted(rows).map(\.id), [id1, id2], "\(order)")
        }
    }

    // MARK: - Filtering

    func testFilterByOrigin() {
        _ = sortFixture()
        sut.sortOrder = .name
        sut.originFilter = .pinned
        XCTAssertEqual(sut.rows.map(\.name), ["Slack", "Terminal"])
        sut.originFilter = .learned
        XCTAssertEqual(sut.rows.map(\.name), ["Notes"])
        sut.originFilter = .all
        XCTAssertEqual(sut.rows.count, 3)
    }

    func testSearchMatchesNameBundleIDLanguageAndKindIgnoringCase() {
        _ = sortFixture()
        sut.sortOrder = .name
        sut.searchText = "  notes "
        XCTAssertEqual(sut.rows.map(\.name), ["Notes"])
        sut.searchText = "tinyspeck"
        XCTAssertEqual(sut.rows.map(\.name), ["Slack"])
        sut.searchText = "HEBREW"
        XCTAssertEqual(sut.rows.map(\.name), ["Notes", "Slack"])
        sut.searchText = "app"
        XCTAssertEqual(sut.rows.count, 3)
    }

    func testSearchAndOriginFilterCombine() {
        _ = sortFixture()
        sut.searchText = "hebrew"
        sut.originFilter = .pinned
        XCTAssertEqual(sut.rows.map(\.name), ["Slack"])
    }

    // MARK: - Language options

    func testLanguageOptionsArePairThenEnabledThenTheSavedOne() {
        let greek = InputSourceID("com.apple.keylayout.Greek")
        make([Rule.app(notes, greek)])
        let row = sut.rows[0]
        XCTAssertEqual(sut.languageOptions(for: row).map(\.name), ["ABC", "Hebrew", "Greek (not turned on)"])
        make([Rule.app(notes, IDs.hebrew)])
        XCTAssertEqual(sut.languageOptions(for: sut.rows[0]).map(\.id), [IDs.abc, IDs.hebrew])
    }

    // MARK: - Writes

    func testChangingTheLanguagePinsTheRule() {
        let rule = Rule.app(notes, IDs.hebrew, .learned, at: t0)
        make([rule, Rule.app(term, IDs.abc)])
        sut.setLanguage(IDs.abc, for: rule.id)
        XCTAssertEqual(rules.count, 2)
        XCTAssertEqual(rules[0].id, rule.id)
        XCTAssertEqual(rules[0].inputSource, IDs.abc)
        XCTAssertEqual(rules[0].origin, .pinned)
        XCTAssertEqual(rules[0].updatedAt, tNow)
    }

    func testChoosingTheSameLanguageOnALearnedRulePinsIt() {
        let rule = Rule.app(notes, IDs.hebrew)
        make([rule])
        sut.setLanguage(IDs.hebrew, for: rule.id)
        XCTAssertEqual(rules[0].origin, .pinned)
    }

    func testChoosingTheSameLanguageOnAPinChangesNothing() {
        let rule = Rule.app(notes, IDs.hebrew, .pinned, at: t0)
        make([rule])
        sut.setLanguage(IDs.hebrew, for: rule.id)
        XCTAssertEqual(rules, [rule], "no new updatedAt for nothing")
    }

    func testLanguageChangeCollapsesDuplicates() {
        let loser = Rule.app(notes, IDs.russian, at: t0)
        let winner = Rule.app(notes, IDs.hebrew, at: t2)
        make([loser, winner])
        sut.setLanguage(IDs.abc, for: winner.id)
        XCTAssertEqual(rules.count, 1)
        XCTAssertEqual(rules[0].id, winner.id)
        XCTAssertEqual(rules[0].inputSource, IDs.abc)
    }

    func testPinAndUnpinKeepTheLanguage() {
        let rule = Rule.app(notes, IDs.hebrew)
        make([rule])
        sut.pin(rule.id)
        XCTAssertEqual(rules.map(\.origin), [.pinned])
        XCTAssertEqual(rules[0].inputSource, IDs.hebrew)
        XCTAssertEqual(rules[0].id, rule.id)
        sut.unpin(rule.id)
        XCTAssertEqual(rules.map(\.origin), [.learned])
        XCTAssertEqual(rules[0].inputSource, IDs.hebrew)
        XCTAssertEqual(rules[0].updatedAt, tNow)
    }

    func testPinOfAPinAndUnpinOfALearnedRuleDoNothing() {
        let pin = Rule.app(notes, IDs.hebrew, .pinned, at: t0)
        let learned = Rule.app(term, IDs.abc, at: t0)
        make([pin, learned])
        sut.pin(pin.id)
        sut.unpin(learned.id)
        XCTAssertEqual(rules, [pin, learned])
    }

    func testDeleteForgetsTheWholeScope() {
        let a = Rule.app(notes, IDs.hebrew, .pinned)
        let dupe = Rule.app(notes, IDs.abc)
        let other = Rule.app(term, IDs.abc)
        make([a, dupe, other])
        sut.delete(a.id)
        XCTAssertEqual(rules, [other])
    }

    func testEditsOnASiteRuleDoNotCreateNewScopes() {
        let site = Rule(scope: .site(domain: "ynet.co.il"), inputSource: IDs.hebrew, origin: .learned, updatedAt: t0)
        make([site])
        sut.setLanguage(IDs.abc, for: site.id)
        XCTAssertEqual(rules.map(\.scope), [.site(domain: "ynet.co.il")])
        XCTAssertEqual(rules.map(\.origin), [.pinned])
        sut.delete(site.id)
        XCTAssertEqual(rules, [])
    }

    func testUnknownRuleIDsDoNothing() {
        let rule = Rule.app(notes, IDs.hebrew)
        make([rule])
        let missing = UUID()
        sut.setLanguage(IDs.abc, for: missing)
        sut.pin(missing)
        sut.unpin(missing)
        sut.delete(missing)
        XCTAssertEqual(rules, [rule])
    }

    func testForgetAllLearnedKeepsPins() {
        let a = Rule.app(notes, IDs.hebrew)
        let b = Rule.app(term, IDs.abc, .pinned)
        let c = Rule.app(slack, IDs.hebrew)
        make([a, b, c])
        XCTAssertEqual(sut.learnedCount, 2)
        XCTAssertEqual(sut.forgetAllLearnedQuestion, "Forget 2 learned rules?")
        sut.forgetAllLearned()
        XCTAssertEqual(rules, [b])
        XCTAssertEqual(sut.learnedCount, 0)
    }

    func testForgetAllLearnedQuestionSingular() {
        make([Rule.app(notes, IDs.hebrew)])
        XCTAssertEqual(sut.forgetAllLearnedQuestion, "Forget 1 learned rule?")
    }

    // MARK: - Read-only

    func testReadOnlyBlocksEveryWriteAndShowsTheNotice() {
        let a = Rule.app(notes, IDs.hebrew)
        let b = Rule.app(term, IDs.abc, .pinned)
        make([a, b], readOnly: true)
        XCTAssertFalse(sut.isEditable)
        XCTAssertEqual(sut.notices.first?.kind, .readOnly)
        sut.setLanguage(IDs.abc, for: a.id)
        sut.pin(a.id)
        sut.unpin(b.id)
        sut.delete(a.id)
        sut.forgetAllLearned()
        XCTAssertEqual(rules.map(\.id), [a.id, b.id])
        XCTAssertEqual(rules.map(\.origin), [.learned, .pinned])
        XCTAssertEqual(rules.map(\.inputSource), [IDs.hebrew, IDs.abc])
        XCTAssertEqual(sut.rows.count, 2, "still listed")
    }

    func testEditableStoreHasNoNotices() {
        make([])
        XCTAssertTrue(sut.isEditable)
        XCTAssertEqual(sut.notices, [])
    }

    /// P2-25 QA: opening the tab (refresh, rows, sorting, filtering, options) never writes, even with duplicates
    /// and an empty-key rule in the file.
    func testReadingTheTabNeverWrites() {
        let a = Rule.app(notes, IDs.hebrew)
        let dup = Rule(id: UUID(), scope: .app(bundleID: notes), inputSource: IDs.abc, origin: .pinned, updatedAt: t1)
        let empty = Rule(id: UUID(), scope: .app(bundleID: "  "), inputSource: IDs.abc, origin: .learned, updatedAt: t0)
        make([a, dup, empty])
        let changed = WriteSpy()
        withObservationTracking { _ = store.prefs } onChange: { changed.fired = true }
        sut.refresh()
        for order in RuleSortOrder.allCases {
            sut.sortOrder = order
            for filter in RuleOriginFilter.allCases {
                sut.originFilter = filter
                for row in sut.rows { _ = sut.languageOptions(for: row) }
            }
        }
        sut.searchText = "note"
        _ = sut.rows
        _ = sut.forgetAllLearnedQuestion
        XCTAssertFalse(changed.fired)
        XCTAssertEqual(rules, [a, dup, empty])
    }

}
