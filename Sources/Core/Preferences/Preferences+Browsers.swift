// P2-8: preferences.json `browsers` (001 §4.2, Settings → Browsers & Sites, Phase 3).
//
// P3-26 (plan.md Phase 3 decision 2026-11-08): the per-browser switches became two global ones, `siteRulesOn` and
// `useAutomation`. A file written before P3-26 has only the old per-browser keys; they are read (still in schema v1,
// no version bump) and the new keys are written on the next save:
//   - `useAutomation` = on if any browser had `appleEventsOptIn` on. Decided while decoding.
//   - `siteRulesOn` = on unless EVERY browser had `siteRulesEnabled` off. The old map stored only the browsers turned
//     off (absent = on), so "every browser" needs the list of browsers on this Mac, which decoding doesn't have. The
//     off set is kept in `legacySiteRulesOff` until AppController.start() resolves it against the web-link handlers
//     (`resolveLegacySiteRules`); until then `siteRulesOn(among:)` gives the same answer for any caller with a list.
//     A save before that writes the old map back unchanged, so nothing is lost.

import Foundation

extension Preferences {
    struct Browsers: Sendable, Equatable {
        /// With this on, no site rules apply in windows known to be private (001 §3 flow d).
        var ignorePrivateWindowsCompletely = false
        /// P3-26: "Use website rules" for every browser (was per browser in `siteRulesEnabled`, P3-9). Off → no watch
        /// request (SitePolicy), so every browser is app-only. Meaningful only while `legacySiteRulesOff` is empty.
        var siteRulesOn = true
        /// P3-26: "Use Automation when a browser can't be read", for every browser that supports Automation (was
        /// per browser in `appleEventsOptIn`, R3). Ignored for browsers without a scripting dictionary. Off unless set.
        var useAutomation = false
        /// P3-29 (plan.md decision 2026-11-08, owner): "Use the browser's language in the address bar". On: while a
        /// text field outside the page has focus (`.editingAddress`), the browser's app rule applies, else the
        /// Latin-script language of the pair; site rules apply only inside web pages. Off: the old behaviour (the
        /// site's rule stays while the address bar is focused). On unless set.
        var browserLanguageInAddressBar = true
        /// P3-26: the browsers the old per-browser switch turned off, from a file written before P3-26; empty once
        /// resolved (or for a new file). Never written under its own name: see the file comment.
        var legacySiteRulesOff: Set<String> = []

        init() {}

        /// P3-26: the effective global "Use website rules", given the browsers on this Mac (`browsers`, Kytkin
        /// excluded). With an unresolved old file: off only when every one of them was off (empty list → on).
        func siteRulesOn(among browsers: Set<String>) -> Bool {
            guard !legacySiteRulesOff.isEmpty else { return siteRulesOn }
            return browsers.isEmpty || !browsers.isSubset(of: legacySiteRulesOff)
        }

        /// P3-26: settles an old file's per-browser switches into `siteRulesOn` (once; AppController.start()).
        /// An empty browser list leaves it unresolved (a failed Launch Services read shouldn't decide it).
        mutating func resolveLegacySiteRules(among browsers: Set<String>) {
            guard !legacySiteRulesOff.isEmpty, !browsers.isEmpty else { return }
            siteRulesOn = siteRulesOn(among: browsers)
            legacySiteRulesOff = []
        }

        /// P3-26: the user set the global switch: any old per-browser state is settled by that choice.
        mutating func setSiteRulesOn(_ on: Bool) {
            siteRulesOn = on
            legacySiteRulesOff = []
        }
    }
}

extension Preferences.Browsers: Codable {
    private enum CodingKeys: String, CodingKey {
        case ignorePrivateWindowsCompletely, siteRulesOn, useAutomation
        case browserLanguageInAddressBar   // P3-29
        // P3-26: the pre-P3-26 per-browser keys; read when the new key is missing.
        case siteRulesEnabled, appleEventsOptIn
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.init()
        if let v = c.lenient(Bool.self, .ignorePrivateWindowsCompletely) { ignorePrivateWindowsCompletely = v }
        if let v = c.lenient(Bool.self, .siteRulesOn) {
            siteRulesOn = v
        } else if let v = c.lenient([String: Lossy<Bool>].self, .siteRulesEnabled) {
            // P3-9 leniency kept: a mistyped entry drops only that browser (= on).
            legacySiteRulesOff = Set(v.compactMapValues(\.value).filter { !$0.value }.keys)
        }
        if let v = c.lenient(Bool.self, .useAutomation) {
            useAutomation = v
        } else if let v = c.lenient([String: Lossy<Bool>].self, .appleEventsOptIn) {
            useAutomation = v.compactMapValues(\.value).values.contains(true)
        }
        if let v = c.lenient(Bool.self, .browserLanguageInAddressBar) { browserLanguageInAddressBar = v }   // P3-29
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(ignorePrivateWindowsCompletely, forKey: .ignorePrivateWindowsCompletely)
        try c.encode(useAutomation, forKey: .useAutomation)
        try c.encode(browserLanguageInAddressBar, forKey: .browserLanguageInAddressBar)   // P3-29
        if legacySiteRulesOff.isEmpty {
            try c.encode(siteRulesOn, forKey: .siteRulesOn)
        } else {
            // Not resolved yet: keep the old map as it was (off entries only; absent = on).
            let old = Dictionary(uniqueKeysWithValues: legacySiteRulesOff.map { ($0, false) })
            try c.encode(old, forKey: .siteRulesEnabled)
        }
    }
}
