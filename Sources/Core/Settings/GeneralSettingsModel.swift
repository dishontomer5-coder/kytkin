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

    init(store: PreferencesStore, loginItems: any LoginItemManaging,
         sources: @escaping @MainActor () -> [InputSourceInfo]) {
        self.store = store
        self.loginItems = loginItems
        self.readSources = sources
    }

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
        do {
            if on { try loginItems.register() } else { try loginItems.unregister() }
            loginItemError = nil
        } catch {
            loginItemError = on ? "Couldn't turn on Open at Login." : "Couldn't turn off Open at Login."
        }
        loginItemStatus = loginItems.status
        // macOS may refuse with "needs approval"; the hint below says what to do, so that's not an error.
        if loginItemStatus == .requiresApproval { loginItemError = nil }
    }

    /// Shown under the switch while macOS waits for the user's approval.
    var loginItemHint: String? {
        guard loginItemStatus == .requiresApproval else { return nil }
        return "macOS needs your OK: turn Kytkin on in System Settings → General → Login Items."
    }

    var showsOpenLoginItems: Bool { loginItemStatus == .requiresApproval }

    /// The user's click on "Open Login Items…".
    func openLoginItems() {
        loginItems.openSystemSettingsLoginItems()
    }
}
