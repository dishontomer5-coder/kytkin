// P6-0k (owner 2026-11-18): Settings → Statistics, a quiet helper. The tab's toolbar title is the total ("1,234");
// the pane shows "Kytkin at Work", the total, one row per count, "Reset Statistics…" (with a confirmation) and the
// privacy footer. No milestone popups (owner: feedback in the menu bar only). The counts come from
// `PreferencesStore.stats` (UsageStats.swift); this model only reads and formats them, and resets them on the user's
// confirmed click.

import Foundation
import Observation

@MainActor @Observable final class StatisticsSettingsModel {
    @ObservationIgnored private let store: PreferencesStore
    @ObservationIgnored private let locale: Locale

    static let header = "Kytkin at Work"
    static let subtitle = "language switches and fixes Kytkin handled for you"
    static let footer = "Counted on your Mac only. Nothing is sent."
    static let resetButton = "Reset Statistics…"
    static let resetConfirmTitle = "Reset statistics?"
    static let resetConfirmMessage = "All counts go back to zero. Your settings and rules stay as they are."
    static let resetConfirmButton = "Reset"

    struct Row: Identifiable, Equatable {
        let kind: UsageStats.Kind
        let title: String
        let count: String
        var id: String { title }
    }

    init(store: PreferencesStore, locale: Locale = .current) {
        self.store = store
        self.locale = locale
    }

    var stats: UsageStats { store.stats }

    /// The big number, and the tab's toolbar title.
    var totalText: String { Self.format(stats.total, locale: locale) }

    var rows: [Row] {
        UsageStats.Kind.allCases.map { Row(kind: $0, title: Self.title(of: $0), count: Self.format(stats.count($0), locale: locale)) }
    }

    /// The user confirmed "Reset Statistics…".
    func reset() { store.resetStats() }

    static func title(of kind: UsageStats.Kind) -> String {
        switch kind {
        case .converted: "Converted with Double-Shift"
        case .switchedByApp: "Switched by app"
        case .switchedByWebsite: "Switched by website"
        }
    }

    /// "1,234" in English; the user's own grouping elsewhere.
    static func format(_ n: Int, locale: Locale = .current) -> String {
        n.formatted(.number.locale(locale))
    }
}
