// P2-24: One entry of the Languages tab's A and B pickers (001 §5.2): turned-on layouts first, then imported maps whose
// keyboard is installed, then "other installed layouts (convert only)", then input methods greyed out ("can't
// convert"). A saved pair member that isn't available any more is listed as missing, so the picker never shows a
// blank or silently changes the pair.

import Foundation

struct LanguagePairOption: Identifiable, Equatable, Sendable {
    enum Kind: Int, Sendable, Equatable, CaseIterable {
        /// A keyboard layout turned on in System Settings.
        case enabled
        /// An imported map (P2-32) whose base keyboard is installed.
        case imported
        /// Installed but not turned on: Kytkin can convert with it, but macOS won't switch to it.
        case installed
        /// An input method (Chinese, Japanese…): no key map, can't convert.
        case inputMethod
        /// The saved choice, which isn't available any more.
        case missing

        /// The picker's section header.
        var groupTitle: String {
            switch self {
            case .enabled: "Turned on"
            case .imported: "Imported"
            case .installed: "Other installed layouts (convert only)"
            case .inputMethod: "Can't convert"
            case .missing: "Not available"
            }
        }
    }

    /// The value stored in `languagePair`.
    let id: InputSourceID
    /// The plain name ("Hebrew"), for messages.
    let name: String
    /// What the picker shows ("Hebrew (not turned on)").
    let title: String
    let kind: Kind
    /// The input source Kytkin switches to for this choice (the base of an imported map). nil = none.
    let inputSource: InputSourceID?

    /// Whether choosing it can make a valid pair member.
    var isSelectable: Bool {
        switch kind {
        case .enabled, .imported, .installed: inputSource != nil
        case .inputMethod, .missing: false
        }
    }

    /// The picker's tag.
    var tag: String { id.rawValue }

    /// Builds the list from what the system reports (`installed`: convertible layouts, turned on or not; imported
    /// maps listed by `LayoutMapCatalog` come in with ids not in `systemIDs`), the input methods, and the saved
    /// pair. `baseName` gives any id's display name. Order: the groups above, the system's order within a group, duplicates dropped.
    static func options(installed: [InputSourceInfo], systemIDs: Set<InputSourceID>, inputMethods: [InputSourceInfo],
                        pair: LanguagePair, inputSource: (InputSourceID) -> InputSourceID?,
                        baseName: (InputSourceID) -> String) -> [LanguagePairOption] {
        var result: [LanguagePairOption] = []
        var seen = Set<InputSourceID>()
        func name(_ info: InputSourceInfo) -> String {
            info.name.isEmpty ? DefaultBehaviorOption.fallbackName(info.id) : info.name
        }
        for info in installed where !info.id.rawValue.isEmpty && seen.insert(info.id).inserted {
            let source = inputSource(info.id)
            if !systemIDs.contains(info.id) {
                let base = source.map(baseName) ?? "?"
                let suffix = info.isEnabled ? "types with \(base)" : "\(base) isn't turned on"
                result.append(LanguagePairOption(id: info.id, name: name(info), title: "\(name(info)) (imported, \(suffix))",
                                                 kind: .imported, inputSource: source))
            } else if info.isEnabled {
                result.append(LanguagePairOption(id: info.id, name: name(info), title: name(info), kind: .enabled, inputSource: source))
            } else {
                result.append(LanguagePairOption(id: info.id, name: name(info), title: "\(name(info)) (not turned on)",
                                                 kind: .installed, inputSource: source))
            }
        }
        for info in inputMethods where !info.id.rawValue.isEmpty && seen.insert(info.id).inserted {
            result.append(LanguagePairOption(id: info.id, name: name(info), title: "\(name(info)) (can't convert)", kind: .inputMethod,
                                             inputSource: nil))
        }
        for saved in [pair.a, pair.b] where seen.insert(saved).inserted {
            result.append(LanguagePairOption(id: saved, name: baseName(saved), title: "\(baseName(saved)) (missing)",
                                             kind: .missing, inputSource: nil))
        }
        return result.enumerated()
            .sorted { ($0.element.kind.rawValue, $0.offset) < ($1.element.kind.rawValue, $1.offset) }
            .map(\.element)
    }
}
