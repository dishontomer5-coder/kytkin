// P6-0c (visual review §2.2): Settings → Advanced. Three parts behind a segmented control: App Exceptions (was the
// Apps tab), Keyboard Layouts (was the Languages tab's import/export) and Diagnostics (was the Permissions tab's
// keyboard status and typing protection, plus "Open Settings Folder" from About). Layout only.

import SwiftUI

struct AdvancedSettingsView: View {
    @Bindable var selection: SettingsSelection
    let apps: AppsSettingsModel
    let permissions: PermissionsSettingsModel
    let openSettingsFolder: @MainActor () -> Void

    var body: some View {
        VStack(spacing: 12) {
            Picker("Show", selection: $selection.advancedSection) {
                ForEach(AdvancedSection.allCases) { Text($0.title).tag($0) }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .fixedSize()

            switch selection.advancedSection {
            case .apps: AppsSettingsView(model: apps)
            case .keyboardLayouts: LanguagesSettingsView()   // its model comes from the environment
            case .diagnostics: DiagnosticsView(model: permissions, openSettingsFolder: openSettingsFolder)
            }
        }
    }
}
