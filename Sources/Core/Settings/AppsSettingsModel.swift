// P2-25: The logic behind Settings → Apps (001 §5.2, §4.2 `apps`), so the SwiftUI view stays a thin layout.
//
// - The list is `prefs.apps`: only apps the user added or changed. Adding an app stores an empty entry (it changes
//   nothing yet); "Remove" deletes the entry, which puts every setting back to Kytkin's default for that app.
// - Each control writes one field. A field set back to its default is stored as nil (left out of the JSON), so the
//   file holds only real differences: `disabled` true or nil, `convertEnabled` false or nil, `replacementMethod`
//   a method or nil ("Default").
// - The effect follows 001 §12 T5 (`PreferencesMapping.methodHint`): Kytkin off or convert off → `.disabled`;
//   AppController reads `disabled` / `convertEnabled` on every double-Shift and pushes method hints to the convert
//   controller when the store changes. With convert off, double-Shift only switches the language (P2-21, P2-54(c)).
// - Adding: from the running apps (`candidates`, read on `refresh()`), or from a bundle ID the UI read from an app the
//   user chose in /Applications. Kytkin itself is never offered.
// - Read-only preferences (§12 S1): every action does nothing and the notice says why.

import Foundation
import Observation

@MainActor @Observable final class AppsSettingsModel {
    @ObservationIgnored private let store: PreferencesStore
    @ObservationIgnored private let appNames: AppDisplayNames
    @ObservationIgnored private let readRunningApps: @MainActor () -> [AppCandidate]
    @ObservationIgnored private let ownBundleID: String

    /// Running apps that can be added, read on `refresh()`.
    private(set) var candidates: [AppCandidate] = []

    /// Under the Convert switch (P2-54(c)): exactly what "convert off" means.
    static let convertOffText = "When off, Double-Shift only switches the language."
    static let kytkinOffText = "When off, Kytkin doesn’t switch the language, learn, or convert in this app."

    init(store: PreferencesStore, appName: @escaping @MainActor (String) -> String?,
         runningApps: @escaping @MainActor () -> [AppCandidate], ownBundleID: String) {
        self.store = store
        self.appNames = AppDisplayNames(lookup: appName)
        self.readRunningApps = runningApps
        self.ownBundleID = ownBundleID
    }

    /// When Settings opens or comes to the front.
    func refresh() {
        let added = Set(store.prefs.apps.keys)
        var seen = Set<String>()
        candidates = readRunningApps()
            .compactMap { c -> AppCandidate? in
                guard let id = Self.cleaned(c.bundleID), id != ownBundleID, !added.contains(id),
                      seen.insert(id).inserted else { return nil }
                let name = c.name.trimmingCharacters(in: .whitespaces)
                return AppCandidate(bundleID: id, name: name.isEmpty ? appNames.name(for: id) : name)
            }
            .sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }

    var isEditable: Bool { !store.isReadOnly }
    var notices: [SettingsNotice] { SettingsNotice.notices(for: store) }

    // MARK: - Rows

    var rows: [AppRow] {
        store.prefs.apps.map { bundleID, o in
            AppRow(bundleID: bundleID, name: appNames.name(for: bundleID),
                   kytkinOn: o.disabled != true, convertOn: o.convertEnabled != false,
                   methodID: AppMethodOption.id(for: o.replacementMethod),
                   // P2-25 QA: through ReplacementCapabilities, so a terminal shows what it really does (T1).
                   effectiveMethod: ReplacementCapabilities(
                       overrides: PreferencesMapping.methodHint(o).map { [bundleID: $0] } ?? [:])
                       .method(for: bundleID))
        }
        .sorted {
            let c = $0.name.localizedStandardCompare($1.name)
            return c == .orderedSame ? $0.bundleID < $1.bundleID : c == .orderedAscending
        }
    }

    var emptyText: String {
        "No apps here yet. Add an app to turn Kytkin or Double-Shift off in it."   // P6-0c (A-9)
    }

    func methodOptions(for row: AppRow) -> [AppMethodOption] {
        AppMethodOption.options(for: row.bundleID, current: store.prefs.apps[row.bundleID]?.replacementMethod)
    }

    // MARK: - Actions

    /// Adds an app with no changes yet. Returns false for a blank ID, Kytkin itself, or read-only preferences.
    /// An app already in the list is left as it is (true).
    @discardableResult func addApp(bundleID: String) -> Bool {
        guard isEditable, let id = Self.cleaned(bundleID), id != ownBundleID else { return false }
        if store.prefs.apps[id] == nil {
            store.update { $0.apps[id] = Preferences.AppOverride() }
        }
        candidates.removeAll { $0.bundleID == id }
        return true
    }

    /// Back to every default for the app.
    func remove(_ bundleID: String) {
        guard isEditable, store.prefs.apps[bundleID] != nil else { return }
        store.update { $0.apps[bundleID] = nil }
    }

    func setKytkinOn(_ on: Bool, for bundleID: String) {
        edit(bundleID) { $0.disabled = on ? nil : true }
    }

    func setConvertOn(_ on: Bool, for bundleID: String) {
        edit(bundleID) { $0.convertEnabled = on ? nil : false }
    }

    /// `optionID` is an `AppMethodOption.id`; an unknown one is ignored.
    func setMethod(_ optionID: String, for bundleID: String) {
        // P2-25 QA: only the offered methods (a terminal can't be set to a method that types at the prompt).
        guard let option = AppMethodOption.options(for: bundleID).first(where: { $0.id == optionID }) else { return }
        edit(bundleID) { $0.replacementMethod = option.method }
    }

    // MARK: - Private

    /// Only apps already in the list are edited (adding is `addApp`).
    private func edit(_ bundleID: String, _ change: (inout Preferences.AppOverride) -> Void) {
        guard isEditable, store.prefs.apps[bundleID] != nil else { return }
        store.update { prefs in
            guard var o = prefs.apps[bundleID] else { return }
            change(&o)
            prefs.apps[bundleID] = o
        }
    }

    private static func cleaned(_ bundleID: String) -> String? {
        let id = bundleID.trimmingCharacters(in: .whitespacesAndNewlines)
        return id.isEmpty ? nil : id
    }
}
