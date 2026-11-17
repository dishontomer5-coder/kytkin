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
                "These settings come from a newer Kytkin, so you can’t change them here. "   // P6-0c (S-1)
                    + "Update Kytkin to change them."
            } else {
                // P6-0c (copy review S-2): a way out.
                "Kytkin couldn’t read its settings, so it is using the defaults. Your file is left as it is. "
                    + "To start fresh, move it out of the Settings folder (Advanced → Open Settings Folder)."
            }
            result.append(SettingsNotice(kind: .readOnly, message: message))
        }
        if lastSaveFailed, !isReadOnly {
            result.append(SettingsNotice(kind: .saveFailed,
                                         message: "Settings couldn’t be saved. Your changes work until "
                                             + "Kytkin quits."))   // P6-0c (S-3)
        }
        if case .corruptQuarantined(let url)? = loadIssue {
            result.append(SettingsNotice(kind: .quarantined,
                                         message: "Your settings file was damaged, so Kytkin started fresh. "
                                             + "The old file was moved to \(display(url))."))
        }
        if loadWasLossy {
            var message = "Some settings couldn’t be read and were reset."
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
