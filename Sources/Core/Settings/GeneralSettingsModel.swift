// P2-23: The logic behind Settings → General (001 §5.2), so the SwiftUI view stays a thin layout.
//
// - "Kytkin is on" = `general.enabled`, "Learn from my manual switches", and "When an app has no rule" read and write
//   PreferencesStore. AppController observes the store, so a change takes effect at once (P2-52 item 3: turning
//   Kytkin back on re-applies the current app's rule, like resuming from Pause).
// - Read-only preferences (newer schema or unreadable, §12 S1): every preferences control is disabled, the setters
//   do nothing, and a notice explains why. Launch at login isn't stored in the file, so it stays usable.
// - Launch at login (R8 §8) goes through `LoginItemManaging`. `register`/`unregister` run only from
//   `setLaunchAtLogin`, which only the user's click on the switch calls. The status is read fresh on `refresh()`
//   (when Settings opens) and after every toggle, never cached across opens.

import Foundation
import Observation

@MainActor @Observable final class GeneralSettingsModel {
    @ObservationIgnored private let store: PreferencesStore
    @ObservationIgnored private let loginItems: any LoginItemManaging
    @ObservationIgnored private let readSources: @MainActor () -> [InputSourceInfo]

    /// Enabled input sources, read on `refresh()` (not on every redraw).
    private(set) var sources: [InputSourceInfo] = []
    /// nil until the first `refresh()`.
    private(set) var loginItemStatus: LoginItemStatus?
    /// Set when the last toggle failed; cleared by the next toggle or refresh.
    private(set) var loginItemError: String?

    /// P6-0d: the language selected now, for the "Show in menu bar" preview (read when drawn).
    @ObservationIgnored let currentLanguage: @MainActor () -> InputSourceInfo?

    /// P4-3: "Keep Kytkin up to date" (nil = not wired, e.g. some tests).
    @ObservationIgnored let updates: UpdateController?

    init(store: PreferencesStore, loginItems: any LoginItemManaging,
         sources: @escaping @MainActor () -> [InputSourceInfo],
         currentLanguage: @escaping @MainActor () -> InputSourceInfo? = { nil },
         updates: UpdateController? = nil) {
        self.store = store
        self.loginItems = loginItems
        self.readSources = sources
        self.currentLanguage = currentLanguage
        self.updates = updates
    }

    /// P4-3: the switch in setup screen 3 and Settings → General → Updates (owner wording, 2026-11-18).
    static let keepUpToDateTitle = "Keep Kytkin up to date"
    static let keepUpToDateHelp = "Once a day, checks GitHub for a new version. You choose when to install. "
        + "Nothing about you is sent."

    /// P6-0d: how the status item looks with `menuBarDisplay` (the real label model, the normal look).
    var menuBarPreview: MenuModel.Label { menuBarPreview(for: menuBarDisplay) }

    /// P6-0g (lg-general): the three "Show in menu bar" tiles each show the real item in their mode.
    func menuBarPreview(for display: Preferences.General.MenuBarLabel) -> MenuModel.Label {
        let info = currentLanguage()
        var state = MenuState()
        state.pairInputSources = store.prefs.languagePair   // P6-0e: the filled half of the language that is on
        return MenuModel.label(languageCode: info?.languageCode ?? "en", languageName: info.map(LanguageNames.friendly),
                               state: state, display: display, current: info?.id)
    }

    /// P6-0g (review P3): the switch's title is just "Kytkin" (the switch shows the state).
    static let enabledTitle = "Kytkin"
    static let enabledHelp = "Switches languages and fixes text. To stop it for a while, use Pause in the menu."
    static let learnTitle = "Learn from my switches"
    static let learnHelp = "When you switch the language yourself, Kytkin remembers it for that app or website."
    static let languagesTitle = "Your two languages"
    static let languagesHelp = "Press Shift twice to convert text between them. The first language is the left half "
        + "of the menu-bar icon."

    /// When Settings opens or comes to the front: fresh login-item status and layout list.
    func refresh() {
        sources = readSources()
        loginItemStatus = loginItems.status
        loginItemError = nil
    }

    // MARK: - Preferences

    var isEditable: Bool { !store.isReadOnly }
    var notices: [SettingsNotice] { SettingsNotice.notices(for: store) }

    var enabled: Bool {
        get { store.prefs.general.enabled }
        set { write { $0.general.enabled = newValue } }
    }

    /// P6-0c (copy review §4.2, owner 2026-11-17): Settings → General → "Show in menu bar".
    var menuBarDisplay: Preferences.General.MenuBarLabel {
        get { store.prefs.general.menuBarLabel }
        set { write { $0.general.menuBarLabel = newValue } }
    }

    static func title(of display: Preferences.General.MenuBarLabel) -> String {
        switch display {
        // P6-0g (lg-general): title case, like the tiles.
        case .iconAndLanguage: "Icon and Language"
        case .iconOnly: "Icon Only"
        case .languageOnly: "Language Only"
        }
    }

    /// P6-0e (mock-up settings-general): the filled half of the logo is the language that is on.
    /// P6-0g (lg-general): the short line of the v2 mock-up.
    static let menuBarDisplayHelp = "The filled half shows which language is on."

    var learnFromManualSwitches: Bool {
        get { store.prefs.general.learnFromManualSwitches }
        set { write { $0.general.learnFromManualSwitches = newValue } }
    }

    var defaultBehaviorOptions: [DefaultBehaviorOption] {
        DefaultBehaviorOption.options(current: store.prefs.general.defaultBehavior, sources: sources)
    }

    /// The picker's selection, as a `DefaultBehaviorOption.id`. Unknown ids are ignored.
    var defaultBehaviorID: String {
        get { DefaultBehaviorOption.id(for: store.prefs.general.defaultBehavior) }
        set {
            guard let option = defaultBehaviorOptions.first(where: { $0.id == newValue }) else { return }
            write { $0.general.defaultBehavior = option.behavior }
        }
    }

    private func write(_ change: (inout Preferences) -> Void) {
        guard isEditable else { return }
        store.update(change)
    }

    // MARK: - Launch at login

    var launchAtLogin: Bool { loginItemStatus?.isOn ?? false }

    /// The user's click on the switch. The only caller of `register`/`unregister`.
    func setLaunchAtLogin(_ on: Bool) {
        let before = loginItems.status
        guard on != before.isOn else {
            loginItemStatus = before
            return
        }
        var threw = false
        do {
            if on { try loginItems.register() } else { try loginItems.unregister() }
        } catch {
            threw = true
        }
        let after = loginItems.status
        loginItemStatus = after
        if on, after == .requiresApproval {
            // macOS may refuse with "needs approval"; the hint below says what to do, so that's not an error.
            loginItemError = nil
        } else if threw || after.isOn != on {
            // QA (P2-23): also when the call "succeeded" but the status didn't follow (e.g. `.notFound` for a copy
            // macOS can't register), so the switch never flips back silently.
            // P6-0c (copy review S-8): what to do.
            loginItemError = on ? "Couldn’t turn on Open at Login. Try again, or add Kytkin in System Settings → "
                + "General → Login Items." : "Couldn’t turn off Open at Login."
        } else {
            loginItemError = nil
        }
    }

    /// Shown under the switch while macOS waits for the user's approval.
    var loginItemHint: String? {
        guard loginItemStatus == .requiresApproval else { return nil }
        return "macOS needs your OK: in System Settings → General → Login Items, turn on Kytkin."   // P6-0c (S-7)
    }

    var showsOpenLoginItems: Bool { loginItemStatus == .requiresApproval }

    /// The user's click on "Open Login Items…".
    func openLoginItems() {
        loginItems.openSystemSettingsLoginItems()
    }
}
