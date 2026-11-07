// P2-25: Helpers for the Rules, Apps and Convert tab tests. Nothing here touches LaunchServices, NSWorkspace, the
// real preferences file or the window server.

import Foundation

/// A store that loaded `prefs` from a file with a newer schema, so it is read-only (§12 S1). In memory only.
@MainActor func makeReadOnlyStore(_ prefs: Preferences) -> PreferencesStore {
    let url = URL(fileURLWithPath: "/tmp/kytkin-tests-never-written/preferences.json")
    let fs = InMemoryPreferencesFileSystem()
    fs[url] = try? PreferencesCodec.encode(prefs, schemaVersion: Preferences.currentSchemaVersion + 1)
    return PreferencesStore(fileURL: url, clock: FakeClock(), fileSystem: fs)
}

/// An app-name lookup that counts its calls.
@MainActor final class FakeAppNames {
    var names: [String: String] = [:]
    private(set) var lookups = 0

    init(_ names: [String: String] = [:]) { self.names = names }

    func lookup(_ bundleID: String) -> String? {
        lookups += 1
        return names[bundleID]
    }
}
