// P2-23: The banners at the top of Settings about the preferences file (001 §2.2 PreferencesStore, §12 S1):
// read-only, the last save failed, something couldn't be read and was reset, or a damaged file was moved aside.
// Plain, short English. Paths are shown with "~" for the home folder; nothing else from the file is shown.

import Foundation

struct SettingsNotice: Equatable, Sendable, Identifiable {
    enum Kind: Sendable, Equatable, Hashable { case readOnly, saveFailed, lossy, quarantined }

    let kind: Kind
    let message: String
    var id: Kind { kind }

    static func notices(loadIssue: PreferencesLoadIssue?, isReadOnly: Bool, lastSaveFailed: Bool,
                        loadWasLossy: Bool, originalBackupURL: URL?) -> [SettingsNotice] {
        var result: [SettingsNotice] = []
        if isReadOnly {
            let message = if loadIssue == .newerSchemaReadOnly {
                "Your settings file comes from a newer version of Kytkin, so settings can't be changed here. "
                    + "Update Kytkin to change them."
            } else {
                "Kytkin couldn't read its settings file, so it is using the defaults and won't touch the file. "
                    + "Settings can't be changed until Kytkin can read it again."
            }
            result.append(SettingsNotice(kind: .readOnly, message: message))
        }
        if lastSaveFailed, !isReadOnly {
            result.append(SettingsNotice(kind: .saveFailed,
                                         message: "Couldn't save settings. Your changes work for now, "
                                             + "but may be lost when Kytkin quits."))
        }
        if case .corruptQuarantined(let url)? = loadIssue {
            result.append(SettingsNotice(kind: .quarantined,
                                         message: "Your settings file was damaged, so Kytkin started fresh. "
                                             + "The old file was moved to \(display(url))."))
        }
        if loadWasLossy {
            var message = "Some settings couldn't be read and were reset."
            if let url = originalBackupURL { message += " The original file is kept at \(display(url))." }
            result.append(SettingsNotice(kind: .lossy, message: message))
        }
        return result
    }

    @MainActor static func notices(for store: PreferencesStore) -> [SettingsNotice] {
        notices(loadIssue: store.loadIssue, isReadOnly: store.isReadOnly, lastSaveFailed: store.lastSaveFailed,
                loadWasLossy: store.loadWasLossy, originalBackupURL: store.originalBackupURL)
    }

    static func display(_ url: URL) -> String {
        (url.path as NSString).abbreviatingWithTildeInPath
    }
}
