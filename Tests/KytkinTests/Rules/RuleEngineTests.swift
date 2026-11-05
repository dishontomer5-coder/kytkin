// P2-9: RuleEngine precedence, missing context fields, duplicates/ties, pinned vs learned,
// private windows, and learnableScope (001 §2.2, §10 P2-9).

import XCTest

final class RuleEngineTests: XCTestCase {
    private let hebrew = InputSourceID("com.apple.keylayout.Hebrew")
    private let abc = InputSourceID("com.apple.keylayout.ABC")
    private let us = InputSourceID("com.apple.keylayout.US")
    private let russian = InputSourceID("com.apple.keylayout.Russian")
    private let slack = "com.tinyspeck.slackmacgap"
    private let chrome = "com.google.Chrome"
    private let chatKey = ChatKey(kind: .id, value: "T0123/C0456")
    private let t0 = Date(timeIntervalSince1970: 1_800_000_000)

    private func rule(_ scope: RuleScope, _ source: InputSourceID, _ origin: RuleOrigin = .learned,
                      at offset: TimeInterval = 0, id: UUID = UUID()) -> Rule {
        Rule(id: id, scope: scope, inputSource: source, origin: origin, updatedAt: t0.addingTimeInterval(offset))
    }

    private func ctx(_ bundleID: String, host: String? = nil, domain: String? = nil,
                     isPrivate: Bool? = nil, chat: ChatKey? = nil) -> Context {
        Context(bundleID: bundleID, pid: 42, host: host, siteDomain: domain,
                isPrivateWindow: isPrivate, chatKey: chat, generation: 1)
    }

    /// One rule at every level, each with a different language, so the winning level is obvious.
    private var allLevels: [Rule] {
        [rule(.app(bundleID: chrome), abc),
         rule(.site(domain: "google.com"), hebrew),
         rule(.siteHost(host: "docs.google.com"), us),
         rule(.chat(bundleID: chrome, key: chatKey), russian)]
    }

    // MARK: - Precedence

    func testChatBeatsEverything() {
        let r = RuleEngine(rules: allLevels).resolve(ctx(chrome, host: "docs.google.com", domain: "google.com", chat: chatKey))
        XCTAssertEqual(r.level, .chat)
        XCTAssertEqual(r.target, russian)
        XCTAssertEqual(r.matched?.scope, .chat(bundleID: chrome, key: chatKey))
    }

    func testSiteHostBeatsSiteAndApp() {
        let r = RuleEngine(rules: allLevels).resolve(ctx(chrome, host: "docs.google.com", domain: "google.com"))
        XCTAssertEqual(r.level, .siteHost)
        XCTAssertEqual(r.target, us)
    }

    func testSiteBeatsApp() {
        let r = RuleEngine(rules: allLevels).resolve(ctx(chrome, host: "mail.google.com", domain: "google.com"))
        XCTAssertEqual(r.level, .site)
        XCTAssertEqual(r.target, hebrew)
    }

    func testAppWhenNoSiteMatches() {
        let r = RuleEngine(rules: allLevels).resolve(ctx(chrome, host: "www.ynet.co.il", domain: "ynet.co.il"))
        XCTAssertEqual(r.level, .app)
        XCTAssertEqual(r.target, abc)
    }

    func testPrecedenceIsIndependentOfRuleOrderAndAge() {
        // Reversed order, and the app rule is the newest: precedence still wins.
        var rules = Array(allLevels.reversed())
        rules[3].updatedAt = t0.addingTimeInterval(10_000)
        let r = RuleEngine(rules: rules).resolve(ctx(chrome, host: "docs.google.com", domain: "google.com"))
        XCTAssertEqual(r.level, .siteHost)
    }

    func testLearnedChatBeatsPinnedApp() {
        // Origin only breaks ties within a scope; it never changes precedence between levels.
        let rules = [rule(.app(bundleID: slack), abc, .pinned), rule(.chat(bundleID: slack, key: chatKey), hebrew, .learned)]
        let r = RuleEngine(rules: rules).resolve(ctx(slack, chat: chatKey))
        XCTAssertEqual(r.level, .chat)
        XCTAssertEqual(r.target, hebrew)
    }

    // MARK: - Default behavior

    func testNoRuleKeepsCurrentByDefault() {
        // Owner decision: apps with no rule leave the language alone.
        let r = RuleEngine(rules: allLevels).resolve(ctx("com.apple.TextEdit"))
        XCTAssertEqual(r, Resolution(target: nil, matched: nil, level: .none))
        XCTAssertEqual(RuleEngine(rules: []).defaultBehavior, .keepCurrent)
    }

    func testNoRuleSwitchesToChosenDefault() {
        let r = RuleEngine(rules: allLevels, defaultBehavior: .switchTo(hebrew)).resolve(ctx("com.apple.TextEdit"))
        XCTAssertEqual(r, Resolution(target: hebrew, matched: nil, level: .defaultRule))
    }

    func testMatchingRuleBeatsDefault() {
        let r = RuleEngine(rules: allLevels, defaultBehavior: .switchTo(hebrew)).resolve(ctx(chrome))
        XCTAssertEqual(r.level, .app)
        XCTAssertEqual(r.target, abc)
    }

    func testEmptyEngine() {
        XCTAssertEqual(RuleEngine(rules: []).resolve(ctx(chrome, host: "a.b.com", domain: "b.com", chat: chatKey)).level, .none)
    }

    // MARK: - Missing or partial context fields

    func testChatRuleNeedsChatKeyInContext() {
        let r = RuleEngine(rules: allLevels).resolve(ctx(chrome))
        XCTAssertEqual(r.level, .app)
    }

    func testChatRuleIsScopedToItsApp() {
        // Same chat key in a different app must not match.
        let rules = [rule(.chat(bundleID: slack, key: chatKey), hebrew)]
        XCTAssertEqual(RuleEngine(rules: rules).resolve(ctx(chrome, chat: chatKey)).level, .none)
    }

    func testChatKeyKindMatters() {
        let rules = [rule(.chat(bundleID: slack, key: ChatKey(kind: .hashed, value: "T0123/C0456")), hebrew)]
        XCTAssertEqual(RuleEngine(rules: rules).resolve(ctx(slack, chat: chatKey)).level, .none)
    }

    func testDifferentChatFallsBackToApp() {
        let rules = [rule(.app(bundleID: slack), abc), rule(.chat(bundleID: slack, key: chatKey), hebrew)]
        let other = ChatKey(kind: .id, value: "T0123/C9999")
        let r = RuleEngine(rules: rules).resolve(ctx(slack, chat: other))
        XCTAssertEqual(r.level, .app)
        XCTAssertEqual(r.target, abc)
    }

    func testHostOnlyContextMatchesSiteHostButNotSite() {
        // siteDomain not computed (e.g. IP literal): host overrides still apply, domain rules can't.
        let engine = RuleEngine(rules: allLevels)
        XCTAssertEqual(engine.resolve(ctx(chrome, host: "docs.google.com")).level, .siteHost)
        XCTAssertEqual(engine.resolve(ctx(chrome, host: "mail.google.com")).level, .app)
    }

    func testDomainOnlyContextMatchesSite() {
        XCTAssertEqual(RuleEngine(rules: allLevels).resolve(ctx(chrome, domain: "google.com")).level, .site)
    }

    func testSiteRulesApplyInAnyApp() {
        // Site scopes have no bundle ID: the same domain in another browser matches.
        let r = RuleEngine(rules: allLevels).resolve(ctx("com.apple.Safari", host: "mail.google.com", domain: "google.com"))
        XCTAssertEqual(r.level, .site)
    }

    func testEmptyStringsInContextCountAsMissing() {
        let rules = allLevels + [rule(.site(domain: ""), us), rule(.siteHost(host: ""), us), rule(.app(bundleID: ""), us)]
        let engine = RuleEngine(rules: rules)
        XCTAssertEqual(engine.resolve(ctx(chrome, host: "", domain: "")).level, .app)
        XCTAssertEqual(engine.resolve(ctx("")).level, .none)
    }

    func testRulesWithEmptyKeysNeverMatch() {
        let rules = [rule(.app(bundleID: ""), hebrew), rule(.site(domain: ""), hebrew), rule(.siteHost(host: "."), hebrew),
                     rule(.chat(bundleID: "", key: chatKey), hebrew), rule(.chat(bundleID: slack, key: ChatKey(kind: .id, value: "")), hebrew)]
        let engine = RuleEngine(rules: rules)
        XCTAssertEqual(engine.resolve(ctx(slack, host: "", domain: "", chat: ChatKey(kind: .id, value: ""))).level, .none)
        XCTAssertNil(engine.rule(for: .app(bundleID: "")))
    }

    func testHostAndDomainMatchingIsCaseInsensitiveAndIgnoresTrailingDot() {
        let rules = [rule(.siteHost(host: "Docs.Google.COM"), us), rule(.site(domain: "ynet.co.il."), hebrew)]
        let engine = RuleEngine(rules: rules)
        XCTAssertEqual(engine.resolve(ctx(chrome, host: "docs.google.com.", domain: "google.com")).level, .siteHost)
        XCTAssertEqual(engine.resolve(ctx(chrome, host: "www.ynet.co.il", domain: "YNET.co.il")).level, .site)
    }

    func testBundleIDMatchingIsExact() {
        let rules = [rule(.app(bundleID: chrome), abc)]
        XCTAssertEqual(RuleEngine(rules: rules).resolve(ctx("com.google.chrome")).level, .none)
    }

    // MARK: - Private windows

    func testPrivateWindowStillAppliesSiteRules() {
        let r = RuleEngine(rules: allLevels).resolve(ctx(chrome, host: "docs.google.com", domain: "google.com", isPrivate: true))
        XCTAssertEqual(r.level, .siteHost)
    }

    func testIgnorePrivateWindowsCompletelySkipsSiteRules() {
        let engine = RuleEngine(rules: allLevels, ignorePrivateWindowsCompletely: true)
        let priv = engine.resolve(ctx(chrome, host: "docs.google.com", domain: "google.com", isPrivate: true))
        XCTAssertEqual(priv.level, .app)
        // Unknown and non-private windows are unaffected.
        XCTAssertEqual(engine.resolve(ctx(chrome, host: "docs.google.com", domain: "google.com", isPrivate: nil)).level, .siteHost)
        XCTAssertEqual(engine.resolve(ctx(chrome, host: "docs.google.com", domain: "google.com", isPrivate: false)).level, .siteHost)
    }

    func testIgnorePrivateWindowsCompletelyKeepsChatRules() {
        let engine = RuleEngine(rules: allLevels, ignorePrivateWindowsCompletely: true)
        XCTAssertEqual(engine.resolve(ctx(chrome, domain: "google.com", isPrivate: true, chat: chatKey)).level, .chat)
    }

    // MARK: - Duplicates, ties, updatedAt, pinned vs learned

    func testPinnedBeatsNewerLearnedForSameScope() {
        let pinned = rule(.app(bundleID: slack), hebrew, .pinned, at: 0)
        let learned = rule(.app(bundleID: slack), abc, .learned, at: 1000)
        for order in [[pinned, learned], [learned, pinned]] {
            let r = RuleEngine(rules: order).resolve(ctx(slack))
            XCTAssertEqual(r.matched, pinned)
            XCTAssertEqual(r.target, hebrew)
        }
    }

    func testNewerWinsWithinSameOrigin() {
        for origin in RuleOrigin.allCases {
            let old = rule(.site(domain: "ynet.co.il"), abc, origin, at: 0)
            let new = rule(.site(domain: "ynet.co.il"), hebrew, origin, at: 60)
            for order in [[old, new], [new, old]] {
                XCTAssertEqual(RuleEngine(rules: order).resolve(ctx(chrome, domain: "ynet.co.il")).matched, new)
            }
        }
    }

    func testExactTieIsBrokenBySmallerIDRegardlessOfOrder() {
        let a = rule(.app(bundleID: slack), hebrew, id: UUID(uuidString: "00000000-0000-0000-0000-000000000001")!)
        let b = rule(.app(bundleID: slack), abc, id: UUID(uuidString: "00000000-0000-0000-0000-000000000002")!)
        XCTAssertEqual(RuleEngine(rules: [a, b]).resolve(ctx(slack)).matched, a)
        XCTAssertEqual(RuleEngine(rules: [b, a]).resolve(ctx(slack)).matched, a)
    }

    func testDuplicatesThatDifferOnlyByCaseAreTheSameScope() {
        let old = rule(.siteHost(host: "Docs.Google.com"), abc, at: 0)
        let new = rule(.siteHost(host: "docs.google.com"), hebrew, at: 5)
        XCTAssertEqual(RuleEngine(rules: [new, old]).resolve(ctx(chrome, host: "docs.google.com")).matched, new)
    }

    func testRuleForScope() {
        let pinned = rule(.app(bundleID: slack), hebrew, .pinned)
        let engine = RuleEngine(rules: [pinned, rule(.site(domain: "ynet.co.il"), abc)])
        XCTAssertEqual(engine.rule(for: .app(bundleID: slack))?.origin, .pinned)
        XCTAssertEqual(engine.rule(for: .site(domain: "YNET.co.il"))?.inputSource, abc)
        XCTAssertNil(engine.rule(for: .app(bundleID: chrome)))
    }

    // MARK: - learnableScope

    func testLearnableScopeMostSpecificFirst() {
        let engine = RuleEngine(rules: [])
        XCTAssertEqual(engine.learnableScope(for: ctx(slack, chat: chatKey)), .chat(bundleID: slack, key: chatKey))
        XCTAssertEqual(engine.learnableScope(for: ctx(chrome, host: "docs.google.com", domain: "google.com")),
                       .site(domain: "google.com"))
        XCTAssertEqual(engine.learnableScope(for: ctx(chrome, host: "10.0.0.1")), .app(bundleID: chrome))
        XCTAssertEqual(engine.learnableScope(for: ctx(chrome)), .app(bundleID: chrome))
    }

    func testLearnableScopeNormalizesDomain() {
        XCTAssertEqual(RuleEngine(rules: []).learnableScope(for: ctx(chrome, domain: "Google.com.")), .site(domain: "google.com"))
    }

    func testLearnableScopeUsesExistingHostOverride() {
        let engine = RuleEngine(rules: allLevels)
        XCTAssertEqual(engine.learnableScope(for: ctx(chrome, host: "Docs.google.com", domain: "google.com")),
                       .siteHost(host: "docs.google.com"))
        XCTAssertEqual(engine.learnableScope(for: ctx(chrome, host: "mail.google.com", domain: "google.com")),
                       .site(domain: "google.com"))
    }

    func testLearnableScopeInPrivateWindowIsAppOnly() {
        let engine = RuleEngine(rules: allLevels)
        XCTAssertEqual(engine.learnableScope(for: ctx(chrome, host: "docs.google.com", domain: "google.com", isPrivate: true, chat: chatKey)),
                       .app(bundleID: chrome))
        // Unknown privacy is treated as not private.
        XCTAssertEqual(engine.learnableScope(for: ctx(chrome, domain: "google.com", isPrivate: nil)), .site(domain: "google.com"))
    }

    func testLearnableScopeIgnoresEmptyFields() {
        let engine = RuleEngine(rules: [])
        XCTAssertEqual(engine.learnableScope(for: ctx(slack, host: "", domain: "", chat: ChatKey(kind: .id, value: ""))),
                       .app(bundleID: slack))
    }
}
