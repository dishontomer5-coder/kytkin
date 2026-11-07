// P2-25: One app in Settings → Apps (001 §5.2): the user's differences from Kytkin's defaults for that app.

import Foundation

struct AppRow: Identifiable, Equatable, Sendable {
    let bundleID: String
    /// The app's name, or the bundle ID when the app isn't found.
    let name: String
    /// `disabled != true`.
    let kytkinOn: Bool
    /// `convertEnabled != false`.
    let convertOn: Bool
    /// `AppMethodOption.id`.
    let methodID: String
    /// What Kytkin will actually do for text in this app (001 §12 T5 mapping, then the built-in choice).
    let effectiveMethod: MethodHint

    var id: String { bundleID }
    /// The bundle ID as a second line, when the name was found.
    var detail: String? { name == bundleID ? nil : bundleID }
}
