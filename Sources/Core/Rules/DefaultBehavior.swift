// P2-9: What happens when no rule matches (001 §2.2, Settings → General).
// The default is `keepCurrent`: apps with no rule leave the language alone (owner decision, plan.md Phase 1, 001 §11 Q3).
// JSON (001 §4.2): { "kind": "keepCurrent" } or { "kind": "switchTo", "inputSource": "…" }.

import Foundation

enum DefaultBehavior: Sendable, Equatable {
    case keepCurrent
    case switchTo(InputSourceID)
}

extension DefaultBehavior: Codable {
    private enum CodingKeys: String, CodingKey { case kind, inputSource }
    private enum Kind: String, Codable { case keepCurrent, switchTo }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        switch try c.decode(Kind.self, forKey: .kind) {
        case .keepCurrent: self = .keepCurrent
        case .switchTo: self = .switchTo(try c.decode(InputSourceID.self, forKey: .inputSource))
        }
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .keepCurrent:
            try c.encode(Kind.keepCurrent, forKey: .kind)
        case .switchTo(let id):
            try c.encode(Kind.switchTo, forKey: .kind)
            try c.encode(id, forKey: .inputSource)
        }
    }
}
