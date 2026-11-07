// P2-22: App display names for the menu ("Notes" for com.apple.Notes), cached for the session so opening the menu
// doesn't ask LaunchServices every time. The lookup itself is the UI's (NSWorkspace); this only caches it.
// A miss isn't cached (the app may be installed later) and shows the bundle ID. Bounded: when full it starts over.

import Foundation

@MainActor final class AppDisplayNames {
    private let lookup: @MainActor (String) -> String?
    private let capacity: Int
    private var cache: [String: String] = [:]

    init(capacity: Int = 128, lookup: @escaping @MainActor (String) -> String?) {
        self.capacity = max(1, capacity)
        self.lookup = lookup
    }

    func name(for bundleID: String) -> String {
        if let hit = cache[bundleID] { return hit }
        guard let found = lookup(bundleID)?.trimmingCharacters(in: .whitespaces), !found.isEmpty else {
            return bundleID
        }
        if cache.count >= capacity { cache.removeAll(keepingCapacity: true) }
        cache[bundleID] = found
        return found
    }

    var cachedCount: Int { cache.count }
}
