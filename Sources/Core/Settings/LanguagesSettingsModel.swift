// P2-24: The logic behind Settings → Languages (001 §5.2), so the SwiftUI view stays a thin layout.
//
// - Pair picker A ⇄ B: the options are `LanguagePairOption.options` (turned-on layouts, imported maps whose keyboard is
//   installed, other installed layouts "convert only", input methods greyed out, a missing saved one). A choice is
//   saved only if `LanguagePairProblem.check` passes; otherwise nothing is written and `pairProblem` says why.
//   The change is live: AppController reads `languagePair` for every double-Shift, and ConvertDispatcher rebuilds its
//   LayoutSnapshot when the pair or a map changes (no KeyWatcher config depends on the pair).
// - Import: `importFile(at:)` is called with the file the user picked in NSOpenPanel (user click only). The store
//   reads it with the size cap and checks every import rule; the result is a plain-English line.
// - Remove: deletes the stored file; refused while the map is one of the pair (choose another language first).
// - Export: any convertible layout, system or imported, to the file the user picked in NSSavePanel.
// - Read-only preferences (§12 S1): pair, import and remove are disabled and the setters do nothing; the notice says
//   why. Export changes nothing of Kytkin's, so it stays usable.
// The system's layout lists are read on `refresh()` (when Settings opens), not on every redraw.

import Foundation
import Observation

@MainActor @Observable final class LanguagesSettingsModel {
    /// One line under the buttons after an action.
    struct Status: Equatable, Sendable {
        let text: String
        let isError: Bool
    }

    /// One row of the imported list.
    struct ImportedRow: Identifiable, Equatable, Sendable {
        let id: InputSourceID
        let name: String
        let detail: String
        let isInPair: Bool
    }

    @ObservationIgnored private let store: PreferencesStore
    @ObservationIgnored private let imported: ImportedLayoutStore
    @ObservationIgnored private let catalog: LayoutMapCatalog
    @ObservationIgnored private let fileSystem: any LayoutFileSystem
    @ObservationIgnored private let readInputMethods: @MainActor () -> [InputSourceInfo]

    /// System layouts (turned on or not), read on `refresh()`.
    private(set) var systemLayouts: [InputSourceInfo] = []
    private(set) var inputMethods: [InputSourceInfo] = []
    /// Why the last pair choice wasn't saved. Cleared by the next valid choice or `refresh()`.
    private(set) var pairProblem: LanguagePairProblem?
    private(set) var status: Status?
    /// The layout the Export button writes (an option's `tag`).
    var exportSelection: String = ""

    init(store: PreferencesStore, imported: ImportedLayoutStore, catalog: LayoutMapCatalog,
         fileSystem: any LayoutFileSystem, inputMethods: @escaping @MainActor () -> [InputSourceInfo]) {
        self.store = store
        self.imported = imported
        self.catalog = catalog
        self.fileSystem = fileSystem
        self.readInputMethods = inputMethods
    }

    /// When Settings opens or comes to the front: fresh layout lists and imported folder.
    func refresh() {
        systemLayouts = catalog.system.convertibleLayouts(includeDisabled: true)
        inputMethods = readInputMethods().filter(\.isInputMethod)
        imported.reload()
        pairProblem = nil
        if !exportOptions.contains(where: { $0.tag == exportSelection }) {
            exportSelection = exportOptions.first { $0.id == pair.a }?.tag ?? exportOptions.first?.tag ?? ""
        }
    }

    // MARK: - Read-only (§12 S1)

    var isEditable: Bool { !store.isReadOnly }
    var notices: [SettingsNotice] { SettingsNotice.notices(for: store) }

    // MARK: - Pair

    var pair: LanguagePair { store.prefs.languagePair }

    var options: [LanguagePairOption] {
        let systemIDs = Set(systemLayouts.map(\.id))
        let enabledIDs = Set(systemLayouts.filter(\.isEnabled).map(\.id))
        var installed = systemLayouts
        for map in imported.maps where !systemIDs.contains(map.id) {
            guard let base = catalog.inputSource(for: map.id) else { continue }
            installed.append(InputSourceInfo(id: map.id, name: map.name, languageCode: map.language,
                                             isEnabled: enabledIDs.contains(base), isConvertible: true,
                                             isInputMethod: false))
        }
        return LanguagePairOption.options(installed: installed, systemIDs: systemIDs, inputMethods: inputMethods,
                                          pair: pair, inputSource: catalog.inputSource(for:), baseName: name(of:))
    }

    /// The options in picker sections, in order, empty groups left out.
    var optionGroups: [(title: String, options: [LanguagePairOption])] {
        let all = options
        return LanguagePairOption.Kind.allCases.compactMap { kind in
            let group = all.filter { $0.kind == kind }
            return group.isEmpty ? nil : (kind.groupTitle, group)
        }
    }

    var pairA: String {
        get { pair.a.rawValue }
        set { choose(LanguagePair(a: InputSourceID(newValue), b: pair.b)) }
    }

    var pairB: String {
        get { pair.b.rawValue }
        set { choose(LanguagePair(a: pair.a, b: InputSourceID(newValue))) }
    }

    /// Saves `candidate` if it is a valid pair; otherwise leaves the saved pair and sets `pairProblem`.
    func choose(_ candidate: LanguagePair) {
        guard isEditable, candidate != pair else { return }
        if let problem = LanguagePairProblem.check(candidate, options: options, name: name(of:)) {
            pairProblem = problem
            return
        }
        pairProblem = nil
        store.update { $0.languagePair = candidate }
    }

    /// P6-0d: the menu-bar letters for a pair member ("EN", "HE"): its input source's language (an imported map's
    /// base). nil = unknown.
    func code(for id: InputSourceID) -> String? {
        let base = catalog.inputSource(for: id) ?? id
        let system = systemLayouts.first { $0.id == base }?.languageCode ?? ""
        let language = system.isEmpty ? (catalog.map(for: id)?.language ?? "") : system
        let code = InputSourceLabel.label(forLanguages: [language])
        return code == InputSourceLabel.unknown ? nil : code
    }

    /// Swaps A and B (always valid if the pair is).
    func swap() {
        choose(LanguagePair(a: pair.b, b: pair.a))
    }

    /// Problems with the saved pair itself (a layout removed or turned off since it was chosen), 001 §5.2.
    var pairWarnings: [String] {
        let all = options
        var result: [String] = []
        for id in [pair.a, pair.b] {
            guard let option = all.first(where: { $0.id == id }) else { continue }
            switch option.kind {
            case .missing:
                result.append("\(option.name) isn’t on this Mac any more, so Double-Shift can’t convert. "
                              + "Choose another language.")
            case .inputMethod:
                // P6-0c (copy review L-7).
                result.append("Double-Shift can’t convert \(option.name), because it’s not a plain keyboard. "
                              + "Choose another language.")
            case .installed:
                // P6-0c (copy review L-8): effect first, then the fix, with the current macOS path.
                result.append("Kytkin can convert to \(option.name) but can’t switch to it. To fix this, add it in "
                              + "System Settings → Keyboard → Text Input → Edit….")
            case .imported where option.inputSource == nil:
                result.append("\(option.name) needs a keyboard that isn’t installed. Choose another language.")
            case .imported, .enabled:
                break
            }
        }
        if result.isEmpty, pair.a == pair.b {
            result.append(LanguagePairProblem.sameLanguage.message)
        } else if result.isEmpty, let a = catalog.inputSource(for: pair.a), a == catalog.inputSource(for: pair.b) {
            // QA (P2-24): e.g. a map in the pair was re-imported with the other member's keyboard as its base.
            result.append(LanguagePairProblem.sameKeyboard(name(of: a)).message)
        }
        return result
    }

    // MARK: - Imported maps

    var importedRows: [ImportedRow] {
        imported.maps.map { map in
            ImportedRow(id: map.id, name: map.name, detail: detail(for: map),
                        isInPair: map.id == pair.a || map.id == pair.b)
        }
    }

    /// Files in the layouts folder that didn't load.
    var skippedFilesNotice: String? {
        let files = imported.skippedFiles
        guard !files.isEmpty else { return nil }
        return "Kytkin couldn’t load \(files.count == 1 ? "this file" : "these files") in its layouts folder: "
            + files.joined(separator: ", ") + ". Import \(files.count == 1 ? "it" : "them") again to see what’s wrong."
    }

    /// The file the user picked in the open panel.
    func importFile(at url: URL) {
        guard isEditable else { return }
        let file = url.lastPathComponent
        do {
            let result = try imported.importFile(at: url)
            let map = result.map
            let verb = if case .replaced = result { "Updated" } else { "Imported" }
            var text = "\(verb) “\(map.name)”."
            if catalog.inputSource(for: map.id) == nil {
                if let base = map.base {
                    text += " To use it in the pair, install the keyboard it types with "
                        + "(\(DefaultBehaviorOption.fallbackName(base)))."
                } else {
                    text += " To use it in the pair, its file needs a \"base\": the installed keyboard it types with."
                }
            } else {
                text += " You can now choose it as a language."
            }
            status = Status(text: text, isError: false)
        } catch {
            status = Status(text: "Couldn’t import “\(file)”: \(error.message)", isError: true)
        }
    }

    func remove(_ id: InputSourceID) {
        guard isEditable, let map = imported.map(for: id) else { return }
        if id == pair.a || id == pair.b {
            status = Status(text: "“\(map.name)” is one of your two languages. Choose another language first, "
                            + "then remove it.", isError: true)
            return
        }
        do {
            try imported.remove(id: id)
            status = Status(text: "Removed “\(map.name)”.", isError: false)
        } catch {
            status = Status(text: "Couldn’t remove “\(map.name)”: \(error.message)", isError: true)
        }
        if exportSelection == id.rawValue { exportSelection = pair.a.rawValue }
    }

    // MARK: - Export

    /// Every layout that can be written: installed layouts (turned on first) and imported maps.
    var exportOptions: [LanguagePairOption] {
        options.filter { $0.kind == .enabled || $0.kind == .installed || $0.kind == .imported }
            + imported.maps.filter { map in !options.contains { $0.id == map.id } }.map { map in
                LanguagePairOption(id: map.id, name: map.name, title: "\(map.name) (imported)", kind: .imported,
                                   inputSource: nil)
            }
    }

    /// The name the save panel suggests: "com.apple.keylayout.Hebrew.json".
    var suggestedExportFileName: String {
        (exportSelection.isEmpty ? "layout" : exportSelection) + ".json"
    }

    var canExport: Bool { exportOptions.contains { $0.tag == exportSelection } }

    /// The file the user picked in the save panel.
    func export(to url: URL) {
        let id = InputSourceID(exportSelection)
        guard let map = catalog.exportMap(for: id) else {
            status = Status(text: "Couldn’t export: that layout isn’t available any more.", isError: true)
            return
        }
        do {
            let data: Data
            do {
                data = try map.jsonData()
            } catch let error as LayoutMapError {
                throw LayoutImportError.invalid(error)
            }
            do {
                try fileSystem.writeAtomically(data, to: url)
            } catch {
                throw LayoutImportError.exportFailed
            }
            status = Status(text: "Exported “\(map.name)” to \(url.lastPathComponent).", isError: false)
        } catch let error as LayoutImportError {
            status = Status(text: "Couldn’t export “\(map.name)”: \(error.message)", isError: true)
        } catch {
            status = Status(text: "Couldn’t export “\(map.name)”.", isError: true)
        }
    }

    // MARK: - Names

    func name(of id: InputSourceID) -> String {
        // P6-0g: the language ("English"), not the layout ("ABC").
        if let info = systemLayouts.first(where: { $0.id == id }) { return LanguageNames.friendly(info) }
        if let map = imported.map(for: id) { return map.name }
        return DefaultBehaviorOption.fallbackName(id)
    }

    private func detail(for map: LayoutMap) -> String {
        let kind = map.source == .user ? "Changes some keys of" : "Full layout, types with"
        guard let base = map.base else { return "Full layout. It can’t be in the pair: it names no keyboard to type with." }
        if catalog.inputSource(for: map.id) == nil {
            return "\(kind) \(DefaultBehaviorOption.fallbackName(base)), which isn’t installed."
        }
        return "\(kind) \(name(of: base))."
    }
}
