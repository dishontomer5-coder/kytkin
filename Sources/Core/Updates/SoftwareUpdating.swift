// P4-3: the updater behind "Keep Kytkin up to date". The live one is System/Updates/SparkleUpdater (Sparkle 2); Debug
// builds, a build without the owner's public key, the UI renderer and the tests use `UnavailableUpdater` or a fake.

import Foundation

@MainActor protocol SoftwareUpdating: AnyObject {
    /// False when updates can't work in this build (Debug, no public key yet): the switch still saves the choice.
    var isAvailable: Bool { get }
    /// False while a check or an update is already in progress.
    var canCheckForUpdates: Bool { get }
    /// When the last check ran (Sparkle keeps it), for Settings.
    var lastUpdateCheckDate: Date? { get }
    /// Applied at launch and whenever the user flips the switch.
    func apply(_ configuration: UpdaterConfiguration)
    /// A user's click ("Check Now…" or the menu's "Update available" line): the updater's own window, which offers
    /// Install for a newer version.
    func checkForUpdates()
    /// A quiet (scheduled) check found this version (shown as one menu line), or nil when that is over (the user
    /// looked at it, installed it or chose Skip / Remind Me Later).
    var onNotice: (@MainActor (String?) -> Void)? { get set }
}

/// P4-3: no updater in this build. Nothing checks, nothing is downloaded.
@MainActor final class UnavailableUpdater: SoftwareUpdating {
    var isAvailable: Bool { false }
    var canCheckForUpdates: Bool { false }
    var lastUpdateCheckDate: Date? { nil }
    var onNotice: (@MainActor (String?) -> Void)?
    init() {}
    func apply(_ configuration: UpdaterConfiguration) {}
    func checkForUpdates() {}
}
