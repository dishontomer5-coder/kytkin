// P3-15 (001 §14.8): the state of Rules → "Add Website…" / "Add Subdomain Rule…" while its sheet is open.
// `RulesSettingsModel` creates one when the sheet opens and drops it on Save or Cancel, so the typed address lives
// only in memory while the sheet shows (it is a preference the user is entering, never logged). The sheet is a real
// sheet: the Settings window's Esc handling leaves it alone (P3-12 note). P3-12 QA note: Esc must not lose the input,
// so Esc closes the sheet only while the field is empty (`escapeCloses`); with text in it, Cancel is a click.

import Foundation
import Observation

@MainActor @Observable final class AddWebsiteForm: Identifiable {
    @ObservationIgnored let id = UUID()
    @ObservationIgnored private let extractor: DomainExtractor
    @ObservationIgnored private let existingRule: @MainActor (RuleScope) -> Rule?
    @ObservationIgnored private let languageName: @MainActor (InputSourceID) -> String

    /// What the user typed or pasted.
    var text: String
    var extent: WebsiteInput.Extent
    var language: InputSourceID
    let languageOptions: [LanguageOption]
    /// Opened from a site row's "Add Subdomain Rule…": the sheet says how to type a subdomain.
    let subdomainOf: String?

    /// `language`: the starting choice when it is one of the options (P3-24: a subdomain sheet starts with the site
    /// rule's language); else the first option.
    init(extractor: DomainExtractor, text: String = "", extent: WebsiteInput.Extent = .wholeSite,
         languageOptions: [LanguageOption], language: InputSourceID? = nil, subdomainOf: String? = nil,
         existingRule: @escaping @MainActor (RuleScope) -> Rule?,
         languageName: @escaping @MainActor (InputSourceID) -> String) {
        self.extractor = extractor
        self.text = text
        self.extent = extent
        self.languageOptions = languageOptions
        self.language = language.flatMap { l in languageOptions.first { $0.id == l }?.id }
            ?? languageOptions.first?.id ?? InputSourceID("")
        self.subdomainOf = subdomainOf
        self.existingRule = existingRule
        self.languageName = languageName
    }

    var title: String { subdomainOf == nil ? "Add Website" : "Add Subdomain Rule" }

    var input: WebsiteInput { WebsiteInput.parse(text, extractor: extractor) }

    /// The rule Save writes (Punycode keys); nil while nothing valid is typed.
    var scope: RuleScope? { input.scope(extent: extent) }

    var showsChoice: Bool {
        if case .choice = input { return true }
        return false
    }

    var hint: String? {
        guard let subdomainOf else { return nil }
        let site = HostNormalizer.unicodeForm(subdomainOf)
        return "Type the address that should get its own language, like news.\(site)."
    }

    /// "ynet.co.il already has a rule (Hebrew, learned). Saving replaces it."
    var replacesText: String? {
        guard let scope, let rule = existingRule(scope) else { return nil }
        let name: String = switch scope {
        case .site(let key), .siteHost(let key): HostNormalizer.unicodeForm(key)
        default: ""
        }
        let origin = rule.origin == .pinned ? "pinned" : "learned"
        return "\(name) already has a rule (\(languageName(rule.inputSource)), \(origin)). Saving replaces it."
    }

    /// Esc closes the sheet only when nothing is typed (P3-12 QA note: Esc never loses input).
    var escapeCloses: Bool { text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }

    /// QA (P3-15): "Add Subdomain Rule…" starts with the site itself in the field. Saving that unchanged would pin
    /// the whole site to the sheet's default language, silently replacing the site's rule (Return was enough), so
    /// the sheet saves only once a different address is typed.
    var isStillTheParentSite: Bool {
        guard let subdomainOf, let scope else { return false }
        return scope == .site(domain: subdomainOf)
    }

    var canSave: Bool { scope != nil && !language.rawValue.isEmpty && !isStillTheParentSite }
}
