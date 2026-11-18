// P4-3: "Keep Kytkin up to date" (replaces P6-3's UpdateChecker and its own GitHub client). Main actor; the updater
// (Sparkle) does the network and the install, behind `SoftwareUpdating`, so this is unit-tested with a fake.
//
// - The choice lives in preferences.json (`general.keepUpToDate`, off until the user ticks it in setup screen 3 or
//   Settings → General) and is pushed to the updater at launch and on every flip (`UpdaterConfiguration.forUser`).
// - A quiet daily check that finds a newer version → one menu line "Update available: Kytkin x.y.z…"; clicking it
//   opens the updater's window (Install / Skip / Remind Me Later). Nothing downloads before that click.
// - "Check Now…" (Settings) and the menu line only while the switch is on.
// - P4-4: turning the switch off only hides a found version (no check, no network while off); turning it back on shows
//   the line again. Sparkle's gentle-reminder session stays open meanwhile and reports nothing new, so forgetting the
//   version on "off" left the line missing until Kytkin restarted. The version is still dropped when Sparkle ends
//   that session or the user opens its window.

import Foundation
import Observation

@MainActor @Observable final class UpdateController {
    @ObservationIgnored private let store: PreferencesStore
    @ObservationIgnored private let updater: any SoftwareUpdating
    @ObservationIgnored let appVersion: String
    /// Called when `notice` changes (the menu-bar menu refreshes).
    @ObservationIgnored var onChange: (@MainActor () -> Void)?

    private var foundVersion: String?

    init(store: PreferencesStore, updater: any SoftwareUpdating, appVersion: String) {
        self.store = store
        self.updater = updater
        self.appVersion = appVersion
        updater.onNotice = { [weak self] version in self?.noticeChanged(version) }
    }

    /// At launch: the user's saved choice goes to the updater (which starts its daily schedule only when on).
    func start() {
        updater.apply(configuration)
    }

    var configuration: UpdaterConfiguration {
        .forUser(keepUpToDate: isOn, appVersion: appVersion)
    }

    var isOn: Bool { store.prefs.general.keepUpToDate }

    /// False in builds that can't update (Debug, no public key yet).
    var isAvailable: Bool { updater.isAvailable }

    /// The switch (setup screen 3's box, Settings → General).
    func setOn(_ on: Bool) {
        guard !store.isReadOnly, on != isOn else { return }
        store.update { $0.general.keepUpToDate = on }
        updater.apply(configuration)
        // P4-4: keep `foundVersion`; `notice` hides it while off and shows it again when on.
        if foundVersion != nil { onChange?() }
    }

    /// The menu line, while a newer version is known and the switch is on (P4-4: hidden, not forgotten, while off).
    var notice: UpdateNotice? {
        guard isOn, let foundVersion else { return nil }
        return UpdateNotice(version: foundVersion)
    }

    var canCheckNow: Bool { isOn && updater.isAvailable && updater.canCheckForUpdates }

    /// "Check Now…" (a click): the updater's window says "up to date" or offers the new version.
    func checkNow() {
        guard canCheckNow else { return }
        updater.checkForUpdates()
    }

    /// The menu's "Update available" line (a click): the updater's window for the version it found.
    func showUpdate() {
        guard isOn, updater.isAvailable else { return }
        updater.checkForUpdates()
    }

    /// Settings → General, under the switch.
    var statusText: String {
        guard updater.isAvailable else { return "Updates work only in the Kytkin you download from GitHub." }
        if let notice { return "Kytkin \(notice.version) is available." }
        guard let last = updater.lastUpdateCheckDate else { return "Not checked yet." }
        return "Last checked \(last.formatted(date: .abbreviated, time: .shortened))."
    }

    private func noticeChanged(_ version: String?) {
        guard version != foundVersion else { return }
        foundVersion = version
        onChange?()
    }
}
