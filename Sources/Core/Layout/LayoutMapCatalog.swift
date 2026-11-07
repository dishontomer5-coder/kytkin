// P2-32: Every layout map Kytkin can convert with: the system's (UCKeyTranslate, P2-6), else the user's imported ones
// (P2-24's ImportedLayoutStore), as 001 §2.2 says ("system, else imported"). ConvertDispatcher and the Languages tab
// use this; the system provider stays system-only.
//
// Imported maps (001 §4.3):
// - `user`: override cells on top of `base`. Its map is `overlaid(on: base's system map)`, so it exists only while
//   the base layout is installed. Kytkin switches to the base when this map is in the pair.
// - `imported`: a full map. Its map is used as is. It can be in the pair only when it names a `base` that is
//   installed (the keyboard macOS types with, which Kytkin switches to); without one it can't be switched to.
// A system layout always wins over an imported map with the same id (imported ids start with `user.`, so that is only
// a hand-made clash).

import Foundation

@MainActor final class LayoutMapCatalog: LayoutMapProviding {
    let system: any LayoutMapProviding
    let imported: ImportedLayoutStore

    init(system: any LayoutMapProviding, imported: ImportedLayoutStore) {
        self.system = system
        self.imported = imported
    }

    /// The system's convertible layouts, then each imported map that can be in the pair (its base is installed;
    /// with `includeDisabled == false`, its base is also turned on). An imported map is "enabled" when its base is.
    func convertibleLayouts(includeDisabled: Bool) -> [InputSourceInfo] {
        let systemList = system.convertibleLayouts(includeDisabled: includeDisabled)
        let enabled = Set(system.convertibleLayouts(includeDisabled: false).map(\.id))
        let known = Set(systemList.map(\.id))
        var result = systemList
        for map in imported.maps where !known.contains(map.id) {
            guard let base = inputSource(for: map.id), includeDisabled || enabled.contains(base) else { continue }
            result.append(InputSourceInfo(id: map.id, name: map.name, languageCode: map.language,
                                          isEnabled: enabled.contains(base), isConvertible: true,
                                          isInputMethod: false))
        }
        return result
    }

    func map(for id: InputSourceID) -> LayoutMap? {
        if let map = system.map(for: id) { return map }
        guard let map = imported.map(for: id) else { return nil }
        switch map.source {
        case .user:
            guard let baseID = map.base, let base = system.map(for: baseID) else { return nil }
            return map.overlaid(on: base)
        case .imported:
            return map
        case .system:
            return nil   // never stored (P2-30), checked anyway
        }
    }

    func inputSource(for id: InputSourceID) -> InputSourceID? {
        if system.map(for: id) != nil { return id }
        guard let map = imported.map(for: id), map.source != .system,
              let base = map.base, system.map(for: base) != nil else { return nil }
        return base
    }

    /// The map to write for Export: a system map as generated, an imported map as stored (not overlaid), so the file
    /// imports again.
    func exportMap(for id: InputSourceID) -> LayoutMap? {
        system.map(for: id) ?? imported.map(for: id)
    }
}
