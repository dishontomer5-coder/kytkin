// P2-12: Who made a key event, from its `eventSourceUserData` marker (design.md, R4 §5).
// `ours` = text Kytkin posted (never buffered); `replay` = user keys Kytkin held back and re-posted
// (buffered as user typing); anything else is the user.

import Foundation

enum EventOrigin: Sendable, Equatable {
    case user, ours, replay

    /// "KYTK": events Kytkin posts as replacement text.
    static let oursMarker: Int64 = 0x4B59544B
    /// "KYRP": held user events Kytkin re-posts after a replacement.
    static let replayMarker: Int64 = 0x4B595250

    /// P2-12: the adapter reads `eventSourceUserData` and classifies with this, before anything else.
    init(userData: Int64) {
        switch userData {
        case Self.oursMarker: self = .ours
        case Self.replayMarker: self = .replay
        default: self = .user
        }
    }

    /// The marker to put on a posted event of this origin (`nil` for user events, which are never posted).
    var marker: Int64? {
        switch self {
        case .user: return nil
        case .ours: return Self.oursMarker
        case .replay: return Self.replayMarker
        }
    }
}
