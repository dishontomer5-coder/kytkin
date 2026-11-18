// P4-3: "Keep Kytkin up to date" over Sparkle 2 (MIT, THIRD_PARTY_NOTICES.md). The only file that imports Sparkle
// (scripts/lint.sh), and the only network use in Kytkin: Sparkle's own requests, none of them while the switch is off.
// No decisions here: UpdateController (Core) decides, `UpdaterConfiguration.forUser` maps the choice.
//
// - Created only in Release builds whose Info.plist carries the owner's real EdDSA public key (AppEnvironment).
// - Started quietly (`SPUUpdater.start`, not the controller's `startUpdater`, which would show an alert on failure).
// - Scheduled checks are "gentle": Sparkle never opens its window by itself; the found version goes to the menu line
//   (`onNotice`), and the window opens only when the user clicks that line or "Check Now…".
// - `updater(_:mayPerformUpdateCheck:)` refuses every check while the switch is off, whatever Sparkle's own defaults say.
// - Never compiled into the tests (Core's UpdateController is tested with a fake updater).

import AppKit
@preconcurrency import Sparkle

@MainActor final class SparkleUpdater: NSObject, SoftwareUpdating {
    private var controller: SPUStandardUpdaterController!
    private var configuration: UpdaterConfiguration?
    private(set) var isAvailable = false
    var onNotice: (@MainActor (String?) -> Void)?

    override init() {
        super.init()
        controller = SPUStandardUpdaterController(startingUpdater: false, updaterDelegate: self,
                                                  userDriverDelegate: self)
    }

    var canCheckForUpdates: Bool { isAvailable && controller.updater.canCheckForUpdates }
    var lastUpdateCheckDate: Date? { controller.updater.lastUpdateCheckDate }

    func apply(_ configuration: UpdaterConfiguration) {
        self.configuration = configuration
        let updater = controller.updater
        updater.automaticallyDownloadsUpdates = configuration.automaticallyDownloads
        updater.updateCheckInterval = configuration.checkInterval
        updater.sendsSystemProfile = configuration.sendsSystemProfile
        updater.userAgentString = configuration.userAgent
        updater.httpHeaders = configuration.httpHeaders
        updater.automaticallyChecksForUpdates = configuration.automaticallyChecks
        if !isAvailable {
            // First apply (at launch): start only now, so Sparkle's first schedule already follows the user's choice.
            isAvailable = (try? updater.start()) != nil
        }
    }

    func checkForUpdates() {
        guard isAvailable, configuration?.automaticallyChecks == true else { return }
        controller.checkForUpdates(nil)
    }
}

extension SparkleUpdater: SPUUpdaterDelegate {
    /// No check of any kind while "Keep Kytkin up to date" is off.
    func updater(_ updater: SPUUpdater, mayPerform updateCheck: SPUUpdateCheck) throws {
        guard configuration?.automaticallyChecks == true else {
            throw NSError(domain: "io.github.kytkin.updates", code: 1,
                          userInfo: [NSLocalizedDescriptionKey: "Keep Kytkin up to date is off."])
        }
    }

    /// Kytkin's own setup asks; Sparkle never does.
    func updaterShouldPromptForPermissionToCheck(forUpdates updater: SPUUpdater) -> Bool { false }
}

extension SparkleUpdater: @preconcurrency SPUStandardUserDriverDelegate {
    var supportsGentleScheduledUpdateReminders: Bool { true }

    /// A scheduled check never opens a window: Kytkin shows the menu line instead.
    func standardUserDriverShouldHandleShowingScheduledUpdate(_ update: SUAppcastItem,
                                                              andInImmediateFocus immediateFocus: Bool) -> Bool {
        false
    }

    func standardUserDriverWillHandleShowingUpdate(_ handleShowingUpdate: Bool, forUpdate update: SUAppcastItem,
                                                   state: SPUUserUpdateState) {
        if !handleShowingUpdate { onNotice?(update.displayVersionString) }
    }

    func standardUserDriverDidReceiveUserAttention(forUpdate update: SUAppcastItem) {
        onNotice?(nil)
    }

    func standardUserDriverWillFinishUpdateSession() {
        onNotice?(nil)
    }
}
