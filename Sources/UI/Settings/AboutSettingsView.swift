// P2-23: Settings → About (001 §5.2): name, version, MIT license, clean-room statement and the GitHub address.
// The address opens in the browser only when the user clicks it.
// P3-15: acknowledgements (the Public Suffix List, MPL-2.0, with its version).
// P6-0c (visual review Ab1–Ab3): the app icon on top; name → version → GitHub, then the license, the clean-room note
// (wording unchanged: owner sign-off needed, copy review AB-1) and acknowledgements in small text. "Open Settings
// Folder" moved to Advanced → Diagnostics.

import AppKit
import SwiftUI

struct AboutSettingsView: View {
    let info: AboutInfo

    var body: some View {
        ScrollView {
            VStack(spacing: 8) {
                Image(nsImage: NSImage(named: NSImage.applicationIconName) ?? NSImage())
                    .resizable()
                    .frame(width: 64, height: 64)
                    .accessibilityHidden(true)
                Text(info.name).font(.title2).bold()
                Text(info.version).foregroundStyle(.secondary).textSelection(.enabled)
                Link(info.repositoryText, destination: info.repositoryURL)

                Divider().padding(.vertical, 6)
                VStack(spacing: 6) {
                    Text(info.license)
                    Text(info.cleanRoom).fixedSize(horizontal: false, vertical: true)
                    ForEach(info.acknowledgements) { ack in
                        VStack(spacing: 2) {
                            Text(ack.title).bold()
                            Text(ack.detail).fixedSize(horizontal: false, vertical: true)
                            Link(ack.license, destination: ack.licenseURL)
                        }
                        .padding(.top, 4)
                    }
                }
                .font(.footnote)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
            }
            .frame(maxWidth: 480)
            .frame(maxWidth: .infinity)
            .padding()
        }
    }
}
