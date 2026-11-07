// P2-23: Settings → About (001 §5.2): name, version, MIT license, clean-room statement and the GitHub address.
// The address opens in the browser only when the user clicks it.

import SwiftUI

struct AboutSettingsView: View {
    let info: AboutInfo

    var body: some View {
        VStack(spacing: 10) {
            Text(info.name).font(.title).bold()
            Text(info.version).foregroundStyle(.secondary).textSelection(.enabled)
            Text(info.license).multilineTextAlignment(.center)
            Text(info.cleanRoom)
                .font(.callout).foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
            Link(info.repositoryText, destination: info.repositoryURL)
        }
        .frame(maxWidth: .infinity, minHeight: 220)
        .padding()
    }
}
