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

            }
            .frame(maxWidth: .infinity)

            // P6-0h (owner: every tab looks like General): the promise and the legal lines in the shared card.
            SettingsCard {
                VStack(spacing: 8) {
                    PrivacyLine(centered: true)
                    VStack(spacing: 2) {
                        Text(info.license)
                        Text(info.cleanRoom)
                    }
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)

                    Button("Acknowledgements…") { showsAcknowledgements = true }
                        .buttonStyle(.kytkinLink)
                        .popover(isPresented: $showsAcknowledgements, arrowEdge: .bottom) {
                            AcknowledgementsView(acknowledgements: info.acknowledgements)
                        }
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 14)
                .padding(.horizontal, 12)
            }
        }
    }
}

/// P3-15: third-party data shipped inside Kytkin (behind About → "Acknowledgements…").
/// P6-0l (owner): a personal dedication first; the licence credit (notice and MPL link) small at the bottom.
struct AcknowledgementsView: View {
    let acknowledgements: [AboutInfo.Acknowledgement]

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            VStack(alignment: .leading, spacing: 6) {
                Text(AboutInfo.acknowledgementsTitle)
                    .font(.system(size: SettingsMetrics.titleSize, weight: .semibold))
                Text(AboutInfo.dedication).font(.system(size: 12))
                    .fixedSize(horizontal: false, vertical: true)
            }
            Divider()
            VStack(alignment: .leading, spacing: 4) {
                Text(AboutInfo.thirdPartyTitle)
                    .font(.system(size: SettingsMetrics.secondarySize, weight: .semibold))
                    .foregroundStyle(.secondary)
                ForEach(acknowledgements) { ack in
                    VStack(alignment: .leading, spacing: 2) {
                        Text(ack.detail)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                        // P6-0l: the popover focuses this link when it opens; no ring then (Tab still reaches it).
                        Link(ack.license, destination: ack.licenseURL).foregroundStyle(Color.kytkinLink)
                            .focusEffectDisabled()
                    }
                    .font(.system(size: SettingsMetrics.secondarySize))
                }
            }
        }
        .padding(16)
        .frame(width: 380, alignment: .leading)
    }
}
