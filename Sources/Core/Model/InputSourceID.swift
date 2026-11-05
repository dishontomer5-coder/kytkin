// P2-5: A TIS input-source ID, e.g. "com.apple.keylayout.Hebrew" (001 §2.2, Core/Model).
// Created here because LayoutMap needs it; it encodes as a bare JSON string.

import Foundation

struct InputSourceID: Hashable, Codable, Sendable, RawRepresentable {
    let rawValue: String

    init(rawValue: String) { self.rawValue = rawValue }
    init(_ rawValue: String) { self.rawValue = rawValue }
}
