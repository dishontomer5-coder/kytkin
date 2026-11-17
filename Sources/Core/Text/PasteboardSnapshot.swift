// P3-37: the user's whole pasteboard, copied before a clipboard convert and written back exactly afterwards
// (`PasteboardAccess`). In memory only, for that one convert; never logged or stored (B12).

import Foundation

/// One item's data for one type, exactly as the pasteboard gave it.
struct PasteboardEntry: Sendable, Equatable {
    /// The pasteboard type (a UTI string such as `public.utf8-plain-text`).
    let type: String
    let data: Data
}

/// P3-37: the whole pasteboard (every item, every type), so it can be put back exactly.
struct PasteboardSnapshot: Sendable, Equatable {
    /// Items in order; each item's entries in the order its types were listed.
    let items: [[PasteboardEntry]]

    var byteCount: Int { items.reduce(0) { $0 + $1.reduce(0) { $0 + $1.data.count } } }

    /// P3-65 (P3-18 audit H1): the user's clipboard is a secret or a short-lived value (a password manager's copied
    /// password waiting for its auto-clear, nspasteboard.org markers). Restoring it would make a new `changeCount`,
    /// so the manager would think the user copied something else and never clear it: no clipboard convert then.
    var isConcealedOrTransient: Bool {
        items.contains { $0.contains { Self.secretMarkers.contains($0.type) } }
    }

    static let secretMarkers: Set<String> = ["org.nspasteboard.ConcealedType", "org.nspasteboard.TransientType"]
}
