// P6-0c (visual review §2.2): Settings → Advanced. Layout only.
// P6-0g (design v2, proposed-advanced): one pane, no tabs inside the tab: Keyboard Layouts (the import/export of layout
// files) and Troubleshooting (Double-Shift, Accessibility, Secure typing, the Settings folder and Copy Diagnostics).
// App Exceptions moved into Rules.

import SwiftUI

struct AdvancedSettingsView: View {
    let permissions: PermissionsSettingsModel
    let openSettingsFolder: @MainActor () -> Void
    let copyDiagnostics: @MainActor () -> Void

    var body: some View {
        SettingsPage {
            KeyboardLayoutsSection()   // its model comes from the environment
            TroubleshootingSection(model: permissions, openSettingsFolder: openSettingsFolder,
                                   copyDiagnostics: copyDiagnostics)
        }
    }
}
