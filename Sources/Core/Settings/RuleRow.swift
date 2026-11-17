// P2-25: One line of Settings → Rules (001 §5.2): what the rule is for, its language, learned or pinned, and when
// it last changed. Built by `RulesSettingsModel` from the winning rule of each scope; the view only lays it out.
// Chat rules are Phase 4: shown if the file has them, never created here. Website rules: P3-15 ("Add Website…").
// P6-0g (design v2): app exceptions moved into this table. An app row also carries its app settings (`apps[id]`):
// "Leave Alone" (`disabled`, Kytkin doesn't switch, learn or convert there) and the Double-Shift checkbox
// (`convertEnabled`). An app with settings but no rule is a row too (`hasRule` false).

import Foundation

struct RuleRow: Identifiable, Equatable, Sendable {
    let id: UUID
    let scope: RuleScope
    /// "App", "Website", "Part of a website" (P3-15), "Chat".
    let kindTitle: String
    /// The app's name (the bundle ID when the app isn't found), the domain or host, or the chat's label.
    let name: String
    /// P6-0g: the tooltip: the bundle ID under a resolved app name, the chat's app, the stored Punycode key under a
    /// Unicode host (P3-15, D13).
    let detail: String?
    /// The rule's language; empty without a rule.
    let inputSource: InputSourceID
    let languageName: String
    let origin: RuleOrigin
    let updatedAt: Date

    /// P6-0g: false = an app with settings and no rule (no language yet).
    var hasRule = true
    /// P6-0g: the app's bundle ID (app rows only).
    var bundleID: String? = nil
    /// P6-0g: "Leave Alone": Kytkin doesn't switch, learn or convert in this app (`apps[id].disabled`).
    var leftAlone = false
    /// P6-0g: the Double-Shift checkbox (`apps[id].convertEnabled != false`); nil for websites and chats.
    var doubleShiftOn: Bool? = nil

    var isPinned: Bool { origin == .pinned }

    /// P6-0g (design v2, P2): the menu's words: "Always" and "Learned". "Leave Alone" is a choice made by hand
    /// ("Always"); an app with settings and no rule has none ("—").
    var originTitle: String {
        if leftAlone { return "Always" }
        guard hasRule else { return "—" }
        return isPinned ? "Always" : "Learned"
    }

    /// What the origin filter and the "Status" sort see (nil = no rule).
    var effectiveOrigin: RuleOrigin? {
        if leftAlone { return .pinned }
        return hasRule ? origin : nil
    }

    /// P6-0g (design v2, P2): "Today, 15:28", "Yesterday, 09:05", "10 Nov, 15:58", "10 Nov 2025, 15:58"; "—" without a
    /// rule.
    func dateText(now: Date, calendar: Calendar = .current, locale: Locale = .current) -> String {
        guard hasRule else { return "—" }
        return Self.shortDate(updatedAt, now: now, calendar: calendar, locale: locale)
    }

    static func shortDate(_ date: Date, now: Date, calendar: Calendar = .current, locale: Locale = .current) -> String {
        let time = DateFormatter()
        time.locale = locale
        time.calendar = calendar
        time.timeZone = calendar.timeZone
        time.setLocalizedDateFormatFromTemplate("jmm")
        let clock = time.string(from: date)
        if calendar.isDate(date, inSameDayAs: now) { return "Today, \(clock)" }
        if let yesterday = calendar.date(byAdding: .day, value: -1, to: now), calendar.isDate(date, inSameDayAs: yesterday) {
            return "Yesterday, \(clock)"
        }
        let day = DateFormatter()
        day.locale = locale
        day.calendar = calendar
        day.timeZone = calendar.timeZone
        let sameYear = calendar.component(.year, from: date) == calendar.component(.year, from: now)
        day.setLocalizedDateFormatFromTemplate(sameYear ? "dMMM" : "dMMMy")
        return "\(day.string(from: date)), \(clock)"
    }
}
