// P2-9: What a rule applies to (001 §2.2). Precedence lives in RuleEngine, not here.
// JSON shape (001 §4.2) is a flat object tagged by "kind":
//   { "kind": "app", "bundleID": "…" }          { "kind": "site", "domain": "…" }
//   { "kind": "siteHost", "host": "…" }         { "kind": "chat", "bundleID": "…", "key": { ChatKey } }
// Swift's synthesized enum Codable would nest by case name, so this is hand-written.

import Foundation

enum RuleScope: Hashable, Sendable {
    case app(bundleID: String)
    /// Registrable domain (eTLD+1), the default for sites (owner decision, plan.md Phase 1).
    case site(domain: String)
    /// Optional per-subdomain override. Beats `site`.
    case siteHost(host: String)
    case chat(bundleID: String, key: ChatKey)

    /// The JSON "kind" tag.
    enum Kind: String, Codable, Sendable, CaseIterable {
        case app, site, siteHost, chat
    }

    var kind: Kind {
        switch self {
        case .app: return .app
        case .site: return .site
        case .siteHost: return .siteHost
        case .chat: return .chat
        }
    }
}

extension RuleScope: Codable {
    private enum CodingKeys: String, CodingKey {
        case kind, bundleID, domain, host, key
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        // P2-9: an unknown kind throws; P2-8 decides whether to drop that one rule or fail the file.
        switch try c.decode(Kind.self, forKey: .kind) {
        case .app:
            self = .app(bundleID: try c.decode(String.self, forKey: .bundleID))
        case .site:
            self = .site(domain: try c.decode(String.self, forKey: .domain))
        case .siteHost:
            self = .siteHost(host: try c.decode(String.self, forKey: .host))
        case .chat:
            self = .chat(bundleID: try c.decode(String.self, forKey: .bundleID),
                         key: try c.decode(ChatKey.self, forKey: .key))
        }
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(kind, forKey: .kind)
        switch self {
        case .app(let bundleID):
            try c.encode(bundleID, forKey: .bundleID)
        case .site(let domain):
            try c.encode(domain, forKey: .domain)
        case .siteHost(let host):
            try c.encode(host, forKey: .host)
        case .chat(let bundleID, let key):
            try c.encode(bundleID, forKey: .bundleID)
            try c.encode(key, forKey: .key)
        }
    }
}
