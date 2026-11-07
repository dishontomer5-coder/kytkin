// P2-25: The logic behind Settings → Rules (001 §5.2), so the SwiftUI view stays a thin layout.
//
// - One row per scope: the scope's winning rule (RuleEngine's own tie-break), so a hand-made duplicate never shows
//   twice. A rule whose key is empty can never match and isn't listed.
// - Every write goes through `RuleWriter` (001 §12 S3), which collapses duplicates of the scope it touches:
//   changing the language pins the rule (a choice made by hand is a pin, like the menu's Pin), Pin / Unpin keep the
//   language, Delete forgets the scope, and "Forget all learned rules" keeps every pin.
// - Site, host and chat rules (Phase 3/4) are listed and can be edited or deleted. P3-15 (001 §14.8, D7): website and
//   single-address rules are created only here, by "Add Website…" / "Add Subdomain Rule…" (`AddWebsiteForm`), as a
//   pinned rule through `RuleWriter.pin` (Punycode keys, D13). Chat rules are never created here.
// - P3-15: a kind filter (All / Apps / Websites). Hosts are shown with `HostNormalizer.unicodeForm`, and the stored
//   Punycode key is the second line when it differs (D13; IDN look-alikes stay visible).
// - Read-only preferences (§12 S1): every action does nothing and the notice says why.
// - App names come from the injected lookup (the UI's LaunchServices lookup, cached for the session); a miss shows
//   the bundle ID. Language names come from the injected source list, read on `refresh()`.

import Foundation
import Observation

@MainActor @Observable final class RulesSettingsModel {
    @ObservationIgnored private let store: PreferencesStore
    @ObservationIgnored private let appNames: AppDisplayNames
    @ObservationIgnored private let readSources: @MainActor () -> [InputSourceInfo]
    @ObservationIgnored private let now: () -> Date
    /// P3-15: nil when the bundled Public Suffix List is missing (D11): no website rule can be added then.
    @ObservationIgnored private let extractor: DomainExtractor?

    /// All input sources (enabled or not), read on `refresh()`, for names and the language picker.
    private(set) var sources: [InputSourceInfo] = []
    var sortOrder: RuleSortOrder = .lastUpdated
    var originFilter: RuleOriginFilter = .all
    /// P3-15: All / Apps / Websites.
    var kindFilter: RuleKindFilter = .all
    /// P3-15: the open "Add Website…" sheet (nil = closed).
    var addWebsite: AddWebsiteForm?
    /// Matches the name, the second line, the language or the kind, ignoring case and accents.
    var searchText = ""

    init(store: PreferencesStore, appName: @escaping @MainActor (String) -> String?,
         sources: @escaping @MainActor () -> [InputSourceInfo], now: @escaping () -> Date = Date.init,
         extractor: DomainExtractor? = nil) {
        self.store = store
        self.extractor = extractor
        self.appNames = AppDisplayNames(lookup: appName)
        self.readSources = sources
        self.now = now
    }

    /// When Settings opens or comes to the front.
    func refresh() {
        sources = readSources()
    }

    var isEditable: Bool { !store.isReadOnly }
    var notices: [SettingsNotice] { SettingsNotice.notices(for: store) }

    // MARK: - Rows

    /// Every listed rule, unsorted and unfiltered.
    var allRows: [RuleRow] {
        let engine = RuleEngine(rules: store.prefs.rules)
        var seen = Set<RuleScope>()
        var rows: [RuleRow] = []
        for rule in store.prefs.rules {
            guard let key = RuleEngine.normalized(rule.scope), seen.insert(key).inserted,
                  let winner = engine.rule(for: key) else { continue }
            rows.append(row(for: winner))
        }
        return rows
    }

    /// What the list shows: filtered, then sorted.
    var rows: [RuleRow] {
        let query = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        let filtered = allRows.filter { row in
            guard originFilter.includes(row.origin), kindFilter.includes(row.scope) else { return false }
            guard !query.isEmpty else { return true }
            return [row.name, row.detail ?? "", row.languageName, row.kindTitle].contains {
                $0.range(of: query, options: [.caseInsensitive, .diacriticInsensitive]) != nil
            }
        }
        return sortOrder.sorted(filtered)
    }

    var hasRules: Bool { !allRows.isEmpty }

    /// Shown when the list is empty.
    var emptyText: String {
        if !hasRules {
            return "No rules yet. Switch the language yourself in an app and Kytkin remembers it, "
                + "or use \"Always use…\" in the menu."
        }
        return "No rules match."
    }

    var learnedCount: Int { allRows.filter { $0.origin == .learned }.count }

    func languageOptions(for row: RuleRow) -> [LanguageOption] {
        LanguageOption.options(pair: store.prefs.languagePair, sources: sources, current: row.inputSource)
    }

    // MARK: - Actions (all through RuleWriter)

    /// Changing the language by hand pins the rule.
    func setLanguage(_ source: InputSourceID, for ruleID: UUID) {
        guard let rule = rule(ruleID), !source.rawValue.isEmpty else { return }
        guard source != rule.inputSource || rule.origin != .pinned else { return }
        write { RuleWriter.pin(rule.scope, to: source, in: $0, now: now()) }
    }

    func pin(_ ruleID: UUID) {
        guard let rule = rule(ruleID), rule.origin != .pinned else { return }
        write { RuleWriter.pin(rule.scope, to: rule.inputSource, in: $0, now: now()) }
    }

    func unpin(_ ruleID: UUID) {
        guard let rule = rule(ruleID), rule.origin == .pinned else { return }
        write { RuleWriter.unpin(rule.scope, in: $0, now: now()) }
    }

    func delete(_ ruleID: UUID) {
        guard let rule = rule(ruleID) else { return }
        write { RuleWriter.forget(rule.scope, in: $0) }
    }

    /// The confirmation's wording, e.g. "Forget 3 learned rules?".
    var forgetAllLearnedQuestion: String {
        let n = learnedCount
        return n == 1 ? "Forget 1 learned rule?" : "Forget \(n) learned rules?"
    }

    static let forgetAllLearnedMessage = "Kytkin will learn them again as you switch languages. Pinned rules stay."

    /// After the user confirmed. Pinned rules stay.
    func forgetAllLearned() {
        write { RuleWriter.forgetAllLearned(in: $0) }
    }

    // MARK: - Add Website (P3-15)

    /// False when the Public Suffix List is missing (D11) or the preferences are read-only.
    var canAddWebsite: Bool { extractor != nil && isEditable }

    static let websiteDataMissingText = "Website rules are unavailable: a file inside Kytkin is missing. Reinstall Kytkin."

    /// "Add Website…". `subdomainOf` = a site row's "Add Subdomain Rule…": the field starts with that site.
    func beginAddWebsite(subdomainOf site: String? = nil) {
        guard canAddWebsite, let extractor else { return }
        let options = LanguageOption.options(pair: store.prefs.languagePair, sources: sources)
        addWebsite = AddWebsiteForm(
            extractor: extractor, text: site.map(HostNormalizer.unicodeForm) ?? "",
            extent: site == nil ? .wholeSite : .onlyHost, languageOptions: options, subdomainOf: site,
            existingRule: { [weak self] scope in self.flatMap { RuleEngine(rules: $0.store.prefs.rules).rule(for: scope) } },
            languageName: { [weak self] id in LanguageOption.name(of: id, in: self?.sources ?? []) })
    }

    /// "Add Subdomain Rule…" is offered for a whole-site rule with a real domain (not an IP, localhost or intranet name).
    func offersSubdomainRule(_ row: RuleRow) -> Bool {
        guard canAddWebsite, case .site(let key) = row.scope else { return false }
        return key.contains(".") && !IPAddress.isIPLiteral(key)
    }

    /// Cancel (or Esc in the sheet): the typed address is dropped.
    func cancelAddWebsite() {
        addWebsite = nil
    }

    /// Save: a pinned rule through RuleWriter (Punycode). Closes the sheet on success; false = nothing written.
    @discardableResult func saveAddWebsite() -> Bool {
        guard let form = addWebsite, form.canSave, let scope = form.scope, isEditable else { return false }
        write { RuleWriter.pin(scope, to: form.language, in: $0, now: now()) }
        addWebsite = nil
        return true
    }

    // MARK: - Private

    private func rule(_ id: UUID) -> Rule? {
        store.prefs.rules.first { $0.id == id }
    }

    private func write(_ change: ([Rule]) -> [Rule]) {
        guard isEditable else { return }
        store.update { $0.rules = change($0.rules) }
    }

    private func row(for rule: Rule) -> RuleRow {
        let kind: String
        let name: String
        var detail: String?
        switch rule.scope {
        case .app(let bundleID):
            kind = "App"
            name = appNames.name(for: bundleID)
            detail = name == bundleID ? nil : bundleID
        case .site(let domain):
            // P3-15 (D13): shown in Unicode, the stored Punycode key underneath when it differs.
            kind = "Website"
            name = HostNormalizer.unicodeForm(domain)
            detail = name == domain ? nil : domain
        case .siteHost(let host):
            kind = "Website, only this address"
            name = HostNormalizer.unicodeForm(host)
            detail = name == host ? nil : host
        case .chat(let bundleID, _):
            kind = "Chat"
            let app = appNames.name(for: bundleID)
            name = rule.label.flatMap { $0.isEmpty ? nil : $0 } ?? "\(app) chat"
            detail = app
        }
        return RuleRow(id: rule.id, scope: rule.scope, kindTitle: kind, name: name, detail: detail,
                       inputSource: rule.inputSource,
                       languageName: LanguageOption.name(of: rule.inputSource, in: sources),
                       origin: rule.origin, updatedAt: rule.updatedAt)
    }
}
