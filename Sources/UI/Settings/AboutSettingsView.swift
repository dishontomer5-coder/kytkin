// P2-23: Settings → About (001 §5.2): name, version, MIT license, clean-room statement and the GitHub address.
// The address opens in the browser only when the user clicks it.
// P3-15: acknowledgements (the Public Suffix List, MPL-2.0, with its version) and "Open Settings Folder" (Finder, on
// click only).

import SwiftUI

struct AboutSettingsView: View {
    let info: AboutInfo
    /// P3-15: "Open Settings Folder".
    let openSettingsFolder: @MainActor () -> Void

    var body: some View {
        ScrollView {
            VStack(spacing: 10) {
                Text(info.name).font(.title).bold()
                Text(info.version).foregroundStyle(.secondary).textSelection(.enabled)
                Text(info.license).multilineTextAlignment(.center)
                Text(info.cleanRoom)
                    .font(.callout).foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
                Link(info.repositoryText, destination: info.repositoryURL)
                Button("Open Settings Folder") { openSettingsFolder() }

                Divider().padding(.vertical, 4)
                Text("Acknowledgements").font(.headline)
                ForEach(info.acknowledgements) { ack in
                    VStack(spacing: 4) {
                        Text(ack.title).bold()
                        Text(ack.detail)
                            .font(.callout).foregroundStyle(.secondary)
                            .multilineTextAlignment(.center)
                            .fixedSize(horizontal: false, vertical: true)
                        Link(ack.license, destination: ack.licenseURL).font(.callout)
                    }
                }
            }
            .frame(maxWidth: .infinity)
            .padding()
        }
    }
}
