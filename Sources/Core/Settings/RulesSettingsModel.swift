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
//   Punycode key is the tooltip when it differs (D13; IDN look-alikes stay visible).
// - Read-only preferences (§12 S1): every action does nothing and the notice says why.
// - App names come from the injected lookup (the UI's LaunchServices lookup, cached for the session); a miss shows
//   the bundle ID. Language names come from the injected source list, read on `refresh()`.
// - P6-0g (design v2, Rules P2): the app exceptions (was Advanced → App Exceptions) are in this table. An app row
//   merges the app's rule and its settings (`apps[id]`, written through `AppsSettingsModel`'s rules: a field back at
//   its default is stored as nil). The Language column is the Kytkin key: a click on a half pins that pair language
//   (and ends "Leave Alone"); a click on the filled half of an app leaves the app alone (`disabled`; its rule is kept
//   for when it is chosen again). The Double-Shift checkbox is `convertEnabled`. "+" adds an app (an empty settings
//   entry: a row with no language yet) or a website; "−" removes the row's rule and its app settings. These are the
//   very preferences the menu's "Always use", "Follow My Last Switch" and "Turn Off Double-Shift" change.
// - P6-0g (P1): sorting comes from the column headers (`sortOrder` + `sortReversed`), not a pop-up.

import Foundation
import Observation

@MainActor @Observable final class RulesSettingsModel {
    @ObservationIgnored private let store: PreferencesStore
    @ObservationIgnored private let appNames: AppDisplayNames
    @ObservationIgnored private let readSources: @MainActor () -> [InputSourceInfo]
    @ObservationIgnored private let now: () -> Date
    /// P3-15: nil when the bundled Public Suffix List is missing (D11): no website rule can be added then.
    @ObservationIgnored private let extractor: DomainExtractor?
    /// P6-0g: adding apps (running apps, the chosen app) and the per-app text method.
    @ObservationIgnored let apps: AppsSettingsModel
    /// P6-0g: the input source Kytkin switches to for a pair member (an imported map's base keyboard).
    @ObservationIgnored private let inputSourceForPairMember: @MainActor (InputSourceID) -> InputSourceID?
    /// P6-0g: stable ids for app rows without a rule (for the table's selection).
    @ObservationIgnored private var settingsOnlyIDs: [String: UUID] = [:]

    /// All input sources (enabled or not), read on `refresh()`, for names and the language picker.
    private(set) var sources: [InputSourceInfo] = []
    var sortOrder: RuleSortOrder = .lastUpdated
    /// P6-0g: the column header clicked twice: the other direction.
    var sortReversed = false
    var originFilter: RuleOriginFilter = .all
    /// P3-15: All / Apps / Websites.
    var kindFilter: RuleKindFilter = .all
    /// P3-15: the open "Add Website…" sheet (nil = closed).
    var addWebsite: AddWebsiteForm?
    /// Matches the name, the tooltip, the language or the kind, ignoring case and accents.
    var searchText = ""

    init(store: PreferencesStore, appName: @escaping @MainActor (String) -> String?,
         sources: @escaping @MainActor () -> [InputSourceInfo], now: @escaping () -> Date = Date.init,
         extractor: DomainExtractor? = nil, apps: AppsSettingsModel? = nil,
         inputSourceForPairMember: @escaping @MainActor (InputSourceID) -> InputSourceID? = { $0 }) {
        self.store = store
        self.extractor = extractor
        self.appNames = AppDisplayNames(lookup: appName)
        self.readSources = sources
        self.now = now
        self.apps = apps ?? AppsSettingsModel(store: store, appName: appName, runningApps: { [] }, ownBundleID: "")
        self.inputSourceForPairMember = inputSourceForPairMember
    }

    /// When Settings opens or comes to the front.
    func refresh() {
        sources = readSources()
        apps.refresh()
    }

    /// P3-24: Settings closed. The kind filter goes back to All, so "Show in Rules" (Websites) doesn't leave the next
    /// opening showing only websites with nothing to say why.
    func settingsClosed() {
        kindFilter = .all
    }

    var isEditable: Bool { !store.isReadOnly }
    var notices: [SettingsNotice] { SettingsNotice.notices(for: store) }

    // MARK: - Rows

    /// Every listed rule and app setting, unsorted and unfiltered.
    var allRows: [RuleRow] {
        let engine = RuleEngine(rules: store.prefs.rules)
        let settings = store.prefs.apps
        var seen = Set<RuleScope>()
        var withRule = Set<String>()
        var rows: [RuleRow] = []
        for rule in store.prefs.rules {
            guard let key = RuleEngine.normalized(rule.scope), seen.insert(key).inserted,
                  let winner = engine.rule(for: key) else { continue }
            if case .app(let id) = key { withRule.insert(id) }
            rows.append(row(for: winner, settings: settings))
        }
        for (bundleID, o) in settings where !withRule.contains(bundleID) && !bundleID.isEmpty {
            rows.append(settingsOnlyRow(bundleID, o))
        }
        return rows
    }

    /// What the list shows: filtered, then sorted.
    var rows: [RuleRow] {
        let query = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        let filtered = allRows.filter { row in
            guard originFilter.includes(row.effectiveOrigin), kindFilter.includes(row.scope) else { return false }
            guard !query.isEmpty else { return true }
            return [row.name, row.detail ?? "", row.languageName, row.kindTitle].contains {
                $0.range(of: query, options: [.caseInsensitive, .diacriticInsensitive]) != nil
            }
        }
        return sortOrder.sorted(filtered, reversed: sortReversed)
    }

    /// P6-0g: a column header was clicked: that order, or the other direction when it already was.
    func sort(by order: RuleSortOrder) {
        if sortOrder == order { sortReversed.toggle() } else { sortOrder = order; sortReversed = false }
    }

    var hasRules: Bool { !allRows.isEmpty }

    /// Shown when the list is empty.
    var emptyText: String {
        if !hasRules {
            // P6-0c (copy review R-3); P6-0g: the menu's words.
            return "No rules yet. Switch the language yourself in an app or website, and Kytkin remembers it. "
                + "To set one now, use “Always use” in the menu, or + below."
        }
        return "No rules match."
    }

    var learnedCount: Int { allRows.filter { $0.hasRule && $0.origin == .learned }.count }

    func languageOptions(for row: RuleRow) -> [LanguageOption] {
        LanguageOption.options(pair: store.prefs.languagePair, sources: sources,
                               current: row.hasRule ? row.inputSource : nil)
    }

    // MARK: - The Kytkin key (P6-0g)

    /// The pair as the input sources rules store (an imported map's base keyboard).
    var pairSources: LanguagePair {
        let pair = store.prefs.languagePair
        return LanguagePair(a: inputSourceForPairMember(pair.a) ?? pair.a, b: inputSourceForPairMember(pair.b) ?? pair.b)
    }

    /// "EN" / "HE" for a pair side, from the layout's language; else the first two letters of its name.
    func letters(_ side: PairSide) -> String {
        let pair = store.prefs.languagePair
        let id = side == .a ? pair.a : pair.b
        let base = side == .a ? pairSources.a : pairSources.b
        let info = sources.first { $0.id == id } ?? sources.first { $0.id == base }
        let code = InputSourceLabel.label(forLanguages: [info?.languageCode ?? ""])
        if code != InputSourceLabel.unknown { return code }
        return String(languageName(side).prefix(2)).uppercased()
    }

    /// "English" / "Hebrew".
    func languageName(_ side: PairSide) -> String {
        let pair = store.prefs.languagePair
        return LanguageOption.name(of: side == .a ? pair.a : pair.b, in: sources)
    }

    /// The filled half: the rule's language when it is a pair language and the app isn't left alone.
    func chosenSide(_ row: RuleRow) -> PairSide? {
        guard row.hasRule, !row.leftAlone else { return nil }
        let pair = pairSources
        if row.inputSource == pair.a { return .a }
        if row.inputSource == pair.b { return .b }
        return nil
    }

    /// The rule's language when it is outside the pair ("Russian"), shown beside the key; nil otherwise.
    func otherLanguage(_ row: RuleRow) -> String? {
        guard row.hasRule, !row.leftAlone, chosenSide(row) == nil else { return nil }
        return row.languageName
    }

    /// A click on a half of a row's key: that language, pinned (and an app's "Leave Alone" ends); the filled half of an
    /// app again leaves the app alone (its rule is kept). The filled half of a website or chat does nothing.
    func choose(_ side: PairSide, for rowID: UUID) {
        guard isEditable, let row = allRows.first(where: { $0.id == rowID }) else { return }
        let target = side == .a ? pairSources.a : pairSources.b
        if let bundleID = row.bundleID, chosenSide(row) == side {
            setLeftAlone(true, bundleID: bundleID)
            return
        }
        if let bundleID = row.bundleID, row.leftAlone { setLeftAlone(false, bundleID: bundleID) }
        if row.hasRule && row.inputSource == target && row.isPinned { return }
        write { RuleWriter.pin(row.scope, to: target, in: $0, now: now()) }
    }

    /// P6-0g: the Double-Shift checkbox of an app row.
    func setDoubleShift(_ on: Bool, for rowID: UUID) {
        guard isEditable, let row = allRows.first(where: { $0.id == rowID }), let bundleID = row.bundleID else { return }
        editSettings(bundleID, keepEmpty: !row.hasRule) { $0.convertEnabled = on ? nil : false }
    }

    /// P6-0g: the app's text method (a row's context menu), through `AppsSettingsModel`.
    func methodOptions(for row: RuleRow) -> [AppMethodOption] {
        guard let bundleID = row.bundleID else { return [] }
        return AppMethodOption.options(for: bundleID, current: store.prefs.apps[bundleID]?.replacementMethod)
    }

    func methodID(for row: RuleRow) -> String {
        AppMethodOption.id(for: row.bundleID.flatMap { store.prefs.apps[$0]?.replacementMethod })
    }

    func setMethod(_ optionID: String, for row: RuleRow) {
        guard isEditable, let bundleID = row.bundleID,
              let option = AppMethodOption.options(for: bundleID).first(where: { $0.id == optionID }) else { return }
        editSettings(bundleID, keepEmpty: !row.hasRule) { $0.replacementMethod = option.method }
    }

    private func setLeftAlone(_ on: Bool, bundleID: String) {
        let hasRule = RuleEngine(rules: store.prefs.rules).rule(for: .app(bundleID: bundleID)) != nil
        editSettings(bundleID, keepEmpty: !hasRule) { $0.disabled = on ? true : nil }
    }

    /// Writes one app's settings; an entry back at every default is removed when the app's rule keeps the row.
    private func editSettings(_ bundleID: String, keepEmpty: Bool, _ change: (inout Preferences.AppOverride) -> Void) {
        guard isEditable else { return }
        store.update { prefs in
            var o = prefs.apps[bundleID] ?? Preferences.AppOverride()
            change(&o)
            prefs.apps[bundleID] = (o == Preferences.AppOverride() && !keepEmpty) ? nil : o
        }
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

    /// "−": the row's rule, and for an app its settings too (back to every default).
    func delete(_ rowID: UUID) {
        guard isEditable, let row = allRows.first(where: { $0.id == rowID }) else { return }
        if row.hasRule { write { RuleWriter.forget(row.scope, in: $0) } }
        if let bundleID = row.bundleID, store.prefs.apps[bundleID] != nil {
            store.update { $0.apps[bundleID] = nil }
        }
    }

    // MARK: - Add App (P6-0g: "+" → Add App…)

    /// Running apps that can be added (no row yet; not Kytkin).
    var appCandidates: [AppCandidate] {
        let listed = Set(allRows.compactMap(\.bundleID))
        return apps.candidates.filter { !listed.contains($0.bundleID) }
    }

    /// Adds an app with no changes yet (a row with no language). False for a blank ID, Kytkin itself, or read-only
    /// preferences; an app already listed is left as it is (true).
    @discardableResult func addApp(bundleID: String) -> Bool {
        let id = bundleID.trimmingCharacters(in: .whitespacesAndNewlines)
        if !id.isEmpty, allRows.contains(where: { $0.bundleID == id }) { return isEditable }
        return apps.addApp(bundleID: id)
    }

    /// The row of an app (after Add App, to select it).
    func rowID(forApp bundleID: String) -> UUID? {
        allRows.first { $0.bundleID == bundleID }?.id
    }

    /// The confirmation's wording, e.g. "Forget 3 learned rules?".
    var forgetAllLearnedQuestion: String {
        let n = learnedCount
        return n == 1 ? "Forget 1 learned rule?" : "Forget \(n) learned rules?"
    }

    static let forgetAllLearnedMessage = "Kytkin will learn them again as you switch languages. Always rules stay."

    /// After the user confirmed. Pinned rules stay.
    func forgetAllLearned() {
        write { RuleWriter.forgetAllLearned(in: $0) }
    }

    // MARK: - Add Website (P3-15)

    /// False when the Public Suffix List is missing (D11) or the preferences are read-only.
    var canAddWebsite: Bool { extractor != nil && isEditable }

    static let websiteDataMissingText = BrowsersSettingsModel.dataMissingText   // P6-0c (R-5)

    /// P6-0c (copy review R-4): the site row's action for a single-address rule.
    static let addPartTitle = "Add Rule for Part of a Website…"

    /// P6-0c (copy review R-6): defines learned and pinned once. P6-0g (design v2): the review's wording, after how
    /// the key works (lg-rules).
    static let pinFooter = "Click a half of the key to choose that language; click it again to leave the app alone. "
        + "Learned rules follow your latest switch. Always rules stay until you change them. Choosing a language "
        + "here makes the rule Always."

    /// "Add Website…". `subdomainOf` = a site row's "Add Subdomain Rule…": the field starts with that site.
    func beginAddWebsite(subdomainOf site: String? = nil) {
        guard canAddWebsite, let extractor else { return }
        let options = LanguageOption.options(pair: store.prefs.languagePair, sources: sources)
        // P3-24 (Coordinator): a subdomain sheet starts with the site rule's language, not the first option.
        let siteLanguage = site.flatMap { RuleEngine(rules: store.prefs.rules).rule(for: .site(domain: $0))?.inputSource }
        addWebsite = AddWebsiteForm(
            extractor: extractor, text: site.map(HostNormalizer.unicodeForm) ?? "",
            extent: site == nil ? .wholeSite : .onlyHost, languageOptions: options, language: siteLanguage,
            subdomainOf: site,
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

    private func row(for rule: Rule, settings: [String: Preferences.AppOverride]) -> RuleRow {
        let kind: String
        let name: String
        var detail: String?
        var bundleID: String?
        switch rule.scope {
        case .app(let id):
            kind = "App"
            name = appNames.name(for: id)
            detail = name == id ? nil : id
            bundleID = id
        case .site(let domain):
            // P3-15 (D13): shown in Unicode, the stored Punycode key in the tooltip when it differs.
            kind = "Website"
            name = HostNormalizer.unicodeForm(domain)
            detail = name == domain ? nil : domain
        case .siteHost(let host):
            kind = "Part of a website"   // P6-0c (R-2)
            name = HostNormalizer.unicodeForm(host)
            detail = name == host ? nil : host
        case .chat(let id, _):
            kind = "Chat"
            let app = appNames.name(for: id)
            name = rule.label.flatMap { $0.isEmpty ? nil : $0 } ?? "\(app) chat"
            detail = app
        }
        let o = bundleID.flatMap { settings[$0] }
        let leftAlone = o?.disabled == true
        var row = RuleRow(id: rule.id, scope: rule.scope, kindTitle: kind, name: name, detail: detail,
                          inputSource: rule.inputSource,
                          languageName: leftAlone ? Self.leaveAloneTitle : LanguageOption.name(of: rule.inputSource, in: sources),
                          origin: rule.origin, updatedAt: rule.updatedAt)
        row.bundleID = bundleID
        row.leftAlone = leftAlone
        row.doubleShiftOn = bundleID.map { _ in o?.convertEnabled != false }
        return row
    }

    private func settingsOnlyRow(_ bundleID: String, _ o: Preferences.AppOverride) -> RuleRow {
        let id = settingsOnlyIDs[bundleID] ?? UUID()
        settingsOnlyIDs[bundleID] = id
        let name = appNames.name(for: bundleID)
        let leftAlone = o.disabled == true
        var row = RuleRow(id: id, scope: .app(bundleID: bundleID), kindTitle: "App", name: name,
                          detail: name == bundleID ? nil : bundleID, inputSource: InputSourceID(""),
                          languageName: leftAlone ? Self.leaveAloneTitle : "", origin: .learned,
                          updatedAt: .distantPast)
        row.hasRule = false
        row.bundleID = bundleID
        row.leftAlone = leftAlone
        row.doubleShiftOn = o.convertEnabled != false
        return row
    }

    /// P6-0g (design v2): the language of an app Kytkin leaves alone.
    static let leaveAloneTitle = "Leave Alone"
}
