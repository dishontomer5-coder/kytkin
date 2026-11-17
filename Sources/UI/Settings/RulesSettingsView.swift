// P2-25: Settings → Rules (001 §5.2). Layout only; `RulesSettingsModel` (Core) sorts, filters and writes every
// change through RuleWriter, and is tested. Read-only preferences disable every edit (the notice says why).
// P3-15: a kind filter, "Add Website…" / "Add Subdomain Rule…" (a sheet), and the search box is a real search field
// (Esc clears only search fields).
// P6-0g (design v2, Rules + lg-rules): the search field has the room ("Sort by" is gone: a click on a column header
// sorts); each row shows the app's icon and name (the bundle ID in a tooltip) and "App" / "Website"; the Language
// column is the Kytkin key; the app exceptions are here (a Double-Shift checkbox per app, "Leave Alone"); "Always" /
// "Learned"; a "+" menu (Add App…, Add Website…) and "−" replace Pin, Delete and Add Website…; short dates.

import AppKit
import SwiftUI
import UniformTypeIdentifiers

struct RulesSettingsView: View {
    @Bindable var model: RulesSettingsModel
    @State private var selection: UUID?
    @State private var confirmingForgetAll = false
    @State private var chooseError: String?
    @State private var sortComparators = [KeyPathComparator(\RuleRow.updatedAt, order: .reverse)]

    static let rowHeight: CGFloat = 40
    static let sides: CGFloat = 20

    var body: some View {
        let rows = model.rows
        VStack(alignment: .leading, spacing: 10) {
            ForEach(model.notices) { WarningLabel(text: $0.message) }
            HStack(spacing: 10) {
                // P6-0c (visual review R2): a segmented All · Apps · Websites, no bare "All" pop-up.
                Picker("Kind", selection: $model.kindFilter) {
                    ForEach(RuleKindFilter.allCases) { Text($0.title).tag($0) }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .fixedSize()
                SearchField(prompt: "Search", text: $model.searchText)
                    .frame(minWidth: 160, maxWidth: .infinity)
                Picker("Show", selection: $model.originFilter) {
                    ForEach(RuleOriginFilter.allCases) { Text($0.title).tag($0) }
                }
                .labelsHidden()
                .fixedSize()
            }

            if rows.isEmpty {
                Text(model.emptyText)   // P6-0c (visual R6): centred
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                table(rows)
            }

            HStack(spacing: 6) {
                addMenu
                Button { if let selection { model.delete(selection); self.selection = nil } } label: {
                    Image(systemName: "minus").frame(width: 14, height: 14)
                }
                .help("Remove the selected rule and the app’s settings")
                .accessibilityLabel("Remove")
                .disabled(selection == nil || !rows.contains { $0.id == selection } || !model.isEditable)
                if let chooseError {
                    StatusLabel(text: chooseError, symbol: "xmark.circle.fill", tint: .red).font(.caption)
                }
                Spacer()
                Button("Forget All Learned Rules…") { confirmingForgetAll = true }
                    .disabled(model.learnedCount == 0 || !model.isEditable)
            }
            Text(RulesSettingsModel.pinFooter)
                .font(.system(size: SettingsMetrics.secondarySize)).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.top, SettingsMetrics.top)
        .padding(.horizontal, Self.sides)
        .padding(.bottom, SettingsMetrics.bottom)
        .background(Color.clear.preference(key: SettingsContentHeightKey.self,
                                           value: naturalHeight(rows: rows.count)))
        .onChange(of: sortComparators) { _, new in applySort(new) }
        .sheet(item: $model.addWebsite) { form in
            AddWebsiteSheet(form: form, save: { model.saveAddWebsite() }, cancel: { model.cancelAddWebsite() })
        }
        .confirmationDialog(model.forgetAllLearnedQuestion, isPresented: $confirmingForgetAll) {
            Button("Forget Learned Rules", role: .destructive) { model.forgetAllLearned() }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text(RulesSettingsModel.forgetAllLearnedMessage)
        }
    }

    /// The tab's height: every row up to the window's 640 pt (then the table scrolls); at least three rows' room.
    private func naturalHeight(rows: Int) -> CGFloat {
        let notices = CGFloat(model.notices.count) * 26
        return SettingsMetrics.top + notices + 28 + 10 + 28 + CGFloat(max(rows, 3)) * (Self.rowHeight + 4) + 10 + 28
            + 10 + 44 + SettingsMetrics.bottom
    }

    private func table(_ rows: [RuleRow]) -> some View {
        Table(rows, selection: $selection, sortOrder: $sortComparators) {
            TableColumn(RuleSortOrder.name.title, value: \RuleRow.name) { row in
                HStack(spacing: 8) {
                    RuleIcon(row: row)
                    VStack(alignment: .leading, spacing: 1) {
                        Text(row.name).font(.system(size: SettingsMetrics.titleSize)).lineLimit(1)
                        Text(row.kindTitle).font(.system(size: SettingsMetrics.secondarySize))
                            .foregroundStyle(.secondary)
                    }
                }
                .help(row.detail ?? "")   // P6-0g: the bundle ID in a tooltip
                .contextMenu { contextMenu(row) }
            }
            .width(min: 150, ideal: 190)
            TableColumn(RuleSortOrder.language.title, value: \RuleRow.languageName) { row in
                HStack(spacing: 6) {
                    KytkinKey(left: model.letters(.a), right: model.letters(.b), chosen: model.chosenSide(row),
                              leftName: model.languageName(.a), rightName: model.languageName(.b)) { side in
                        model.choose(side, for: row.id)
                    }
                    .disabled(!model.isEditable)
                    if let other = model.otherLanguage(row) {
                        Text(other).font(.system(size: SettingsMetrics.secondarySize)).foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                }
                .help(row.leftAlone ? "Leave Alone: Kytkin doesn’t switch, learn or convert in this app." : "")
            }
            .width(min: 96, ideal: 120)
            TableColumn("Double-Shift") { row in
                if let on = row.doubleShiftOn {
                    Toggle("Double-Shift", isOn: Binding(get: { on && !row.leftAlone },
                                                         set: { model.setDoubleShift($0, for: row.id) }))
                        .labelsHidden()
                        .toggleStyle(.checkbox)
                        .disabled(!model.isEditable || row.leftAlone)
                        .help(row.leftAlone ? "Kytkin leaves this app alone." : AppsSettingsModel.convertOffText)
                }
            }
            .width(78)
            TableColumn(RuleSortOrder.origin.title, value: \RuleRow.originTitle) { row in
                Text(row.originTitle).foregroundStyle(row.effectiveOrigin == .pinned ? .primary : .secondary)
            }
            .width(min: 56, ideal: 64)
            TableColumn(RuleSortOrder.lastUpdated.title, value: \RuleRow.updatedAt) { row in
                Text(row.dateText(now: Date())).foregroundStyle(.secondary).lineLimit(1)
            }
            .width(min: 96, ideal: 110)
        }
    }

    /// P6-0g: "+": Add App… (a file panel on /Applications, or a running app), Add Website…, and on a selected website
    /// "Add Rule for Part of a Website…".
    private var addMenu: some View {
        let selected = model.rows.first { $0.id == selection }
        return Menu {
            Button("Add App…") { chooseApp() }
            Menu("Add Running App") {
                let candidates = model.appCandidates
                if candidates.isEmpty { Text("No other apps are running") }
                ForEach(candidates) { app in
                    Button(app.name) { add(app.bundleID) }
                }
            }
            Divider()
            Button("Add Website…") { model.beginAddWebsite() }
                .disabled(!model.canAddWebsite)
            if let selected, model.offersSubdomainRule(selected), case .site(let domain) = selected.scope {
                Button(RulesSettingsModel.addPartTitle) { model.beginAddWebsite(subdomainOf: domain) }
            }
        } label: {
            Image(systemName: "plus")
        }
        .menuIndicator(.visible)
        .fixedSize()
        .help(model.canAddWebsite ? "Add an app or a website" : RulesSettingsModel.websiteDataMissingText)
        .accessibilityLabel("Add")
        .disabled(!model.isEditable)
    }

    @ViewBuilder private func contextMenu(_ row: RuleRow) -> some View {
        if row.bundleID != nil {
            Picker("Double-Shift Method", selection: Binding(get: { model.methodID(for: row) },
                                                             set: { model.setMethod($0, for: row) })) {
                ForEach(model.methodOptions(for: row)) { Text($0.title).tag($0.id) }
            }
            .disabled(!model.isEditable)
        }
        Button("Remove") { model.delete(row.id) }.disabled(!model.isEditable)
    }

    private func add(_ bundleID: String) {
        if model.addApp(bundleID: bundleID) {
            chooseError = nil
            selection = model.rowID(forApp: bundleID)
        }
    }

    /// User click only: an open panel on /Applications; the chosen app's bundle ID is added.
    private func chooseApp() {
        let panel = NSOpenPanel()
        panel.directoryURL = URL(fileURLWithPath: "/Applications", isDirectory: true)
        panel.allowedContentTypes = [.application]
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        panel.prompt = "Add"
        panel.message = "Choose an app to set Kytkin’s language or Double-Shift for it."
        guard panel.runModal() == .OK, let url = panel.url else { return }
        if let id = Bundle(url: url)?.bundleIdentifier, model.addApp(bundleID: id) {
            chooseError = nil
            selection = model.rowID(forApp: id)
        } else {
            chooseError = "That app can’t be added. Choose an app from the Applications folder."
        }
    }

    /// The header click: the model's order (its natural direction first).
    private func applySort(_ comparators: [KeyPathComparator<RuleRow>]) {
        guard let c = comparators.first else { return }
        let path: PartialKeyPath<RuleRow> = c.keyPath
        let order: RuleSortOrder = if path == \RuleRow.name { .name }
            else if path == \RuleRow.languageName { .language }
            else if path == \RuleRow.originTitle { .origin }
            else { .lastUpdated }
        let natural: SortOrder = order == .lastUpdated ? .reverse : .forward
        model.sortOrder = order
        model.sortReversed = c.order != natural
    }
}

/// P6-0g: an app's icon, or a globe tile for a website (lg-rules).
struct RuleIcon: View {
    let row: RuleRow

    /// The app icon lookup (LaunchServices, read-only); the headless renderer sets it to return nil (fake data).
    nonisolated(unsafe) static var appIcon: (String) -> NSImage? = { bundleID in
        guard let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) else { return nil }
        return NSWorkspace.shared.icon(forFile: url.path)
    }

    var body: some View {
        Group {
            if let id = row.bundleID, let image = Self.appIcon(id) {
                Image(nsImage: image).resizable().interpolation(.high)
            } else if row.bundleID != nil || { if case .chat = row.scope { true } else { false } }() {
                RoundedRectangle(cornerRadius: 6, style: .continuous).fill(Color.secondary.opacity(0.35))
            } else {
                ZStack {
                    RoundedRectangle(cornerRadius: 6, style: .continuous).fill(Color.kytkinAccent.opacity(0.75))
                    Image(systemName: "globe").font(.system(size: 13, weight: .medium)).foregroundStyle(.white)
                }
            }
        }
        .frame(width: 26, height: 26)
        .accessibilityHidden(true)
    }
}
