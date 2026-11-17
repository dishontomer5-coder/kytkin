// P2-23: Settings → About (001 §5.2): name, version, MIT license and the GitHub address. The address opens in the
// browser only when the user clicks it.
// P3-15: acknowledgements (the Public Suffix List, MPL-2.0, with its version).
// P6-0g (design v2, proposed-about): the icon larger, the dark-appearance one in dark mode (the `AboutIcon` image set);
// the name is "Kytkin" ("Dev" is on the version line); the privacy promise; "An independent project, not affiliated
// with any other app." (no other app named); the Public Suffix List text behind "Acknowledgements…".

import AppKit
import SwiftUI

struct AboutSettingsView: View {
    let info: AboutInfo
    @State private var showsAcknowledgements = false

    /// The icon for an appearance. The app reads the `AboutIcon` image set (light and dark); the headless renderer,
    /// which has no asset catalog, sets this to the repo's PNGs.
    nonisolated(unsafe) static var iconImage: (_ dark: Bool) -> NSImage? = { _ in NSImage(named: "AboutIcon") }

    @Environment(\.colorScheme) private var scheme

    var body: some View {
        SettingsPage {
            VStack(spacing: 8) {
                Image(nsImage: Self.iconImage(scheme == .dark) ?? NSApp.applicationIconImage ?? NSImage())
                    .resizable()
                    .interpolation(.high)
                    .frame(width: 128, height: 128)
                    .accessibilityHidden(true)
                Text(info.name).font(.system(size: 22, weight: .bold))
                Text(info.version).foregroundStyle(.secondary).textSelection(.enabled)
                Link(info.repositoryText, destination: info.repositoryURL).foregroundStyle(Color.kytkinLink)

                Divider().padding(.vertical, 8)

                PrivacyLine(centered: true)
                VStack(spacing: 2) {
                    Text(info.license)
                    Text(info.cleanRoom)
                }
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .padding(.top, 4)

                Button("Acknowledgements…") { showsAcknowledgements = true }
                    .buttonStyle(.kytkinLink)
                    .padding(.top, 4)
                    .popover(isPresented: $showsAcknowledgements, arrowEdge: .bottom) {
                        AcknowledgementsView(acknowledgements: info.acknowledgements)
                    }
            }
            .frame(maxWidth: .infinity)
        }
    }
}

/// P3-15: third-party data shipped inside Kytkin (behind About → "Acknowledgements…").
struct AcknowledgementsView: View {
    let acknowledgements: [AboutInfo.Acknowledgement]

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            ForEach(acknowledgements) { ack in
                VStack(alignment: .leading, spacing: 4) {
                    Text(ack.title).font(.system(size: SettingsMetrics.titleSize, weight: .semibold))
                    Text(ack.detail).font(.system(size: 12)).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                    Link(ack.license, destination: ack.licenseURL).foregroundStyle(Color.kytkinLink)
                        .font(.system(size: 12))
                }
            }
        }
        .padding(16)
        .frame(width: 380, alignment: .leading)
    }
}
