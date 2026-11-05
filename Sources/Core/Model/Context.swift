// P2-9: Where the user is typing right now (001 §2.2, Core/Model). The RuleEngine resolves a
// language for it. Created here because RuleEngine needs it; ContextAssembler (P2-15) builds it.
// Optional fields stay nil until the tier that can read them exists (sites in P3, chats in P4).
// Never holds titles or URLs: only the bundle ID, the host, the registrable domain and a chat key.

import Foundation

struct Context: Sendable, Equatable {
    let bundleID: String
    let pid: Int32
    /// Full host of the active browser tab, e.g. "docs.google.com" (P3).
    var host: String?
    /// Registrable domain (eTLD+1) of `host`, e.g. "google.com" (P3).
    var siteDomain: String?
    /// nil = unknown (detection is best effort, P3).
    var isPrivateWindow: Bool?
    /// The open conversation in a chat app (P4).
    var chatKey: ChatKey?
    /// Increments on every change.
    let generation: UInt64

    init(bundleID: String, pid: Int32, host: String? = nil, siteDomain: String? = nil,
         isPrivateWindow: Bool? = nil, chatKey: ChatKey? = nil, generation: UInt64) {
        self.bundleID = bundleID
        self.pid = pid
        self.host = host
        self.siteDomain = siteDomain
        self.isPrivateWindow = isPrivateWindow
        self.chatKey = chatKey
        self.generation = generation
    }
}
