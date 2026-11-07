// P2-25: The preferences-file banners (§12 S1, `SettingsNotice`) at the top of the Rules, Apps and Convert tabs.

import SwiftUI

struct SettingsNoticeList: View {
    let notices: [SettingsNotice]

    var body: some View {
        ForEach(notices) { notice in
            Label(notice.message, systemImage: "exclamationmark.triangle")
                .foregroundStyle(.orange)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}
