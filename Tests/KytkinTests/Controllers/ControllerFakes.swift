// P2-20: Fakes for the controller tests. None of them touches the system: no TIS, no tap, no permissions, no files.

import Foundation


enum IDs {
    static let abc = InputSourceID("com.apple.keylayout.ABC")
    static let hebrew = InputSourceID("com.apple.keylayout.Hebrew")
    static let russian = InputSourceID("com.apple.keylayout.Russian")
}

@MainActor final class FakeSwitcher: InputSourceSwitching {
    var current: InputSourceID
    var selectSucceeds = true
    private(set) var selects: [(InputSourceID, SwitchReason)] = []
    var onChange: (@MainActor (InputSourceChange) -> Void)?
    var onSourcesListChanged: (@MainActor () -> Void)?

    init(current: InputSourceID = IDs.abc) { self.current = current }

    var currentInfo: InputSourceInfo? {
        InputSourceInfo(id: current, name: current.rawValue, languageCode: "en", isEnabled: true,
                        isConvertible: true, isInputMethod: false)
    }

    func sources(includeDisabled: Bool) -> [InputSourceInfo] { [] }

    func select(_ id: InputSourceID, reason: SwitchReason) -> Bool {
        if id == current { return true }
        selects.append((id, reason))
        guard selectSucceeds else { return false }
        current = id
        return true
    }

    var selectedIDs: [InputSourceID] { selects.map(\.0) }
}

@MainActor final class FakeContextMonitor: ContextMonitoring {
    var current: Context?
    var onChange: (@MainActor (Context) -> Void)?
    private(set) var startCount = 0
    private(set) var stopCount = 0
    /// Emitted from start() (the frontmost app), like the real monitor.
    var emitOnStart: Context?
    private var generation: UInt64 = 0

    func start() {
        startCount += 1
        if let c = emitOnStart { current = c; onChange?(c) }
    }
    func stop() { stopCount += 1 }

    /// A new app comes to the front.
    @discardableResult func activate(_ bundleID: String, pid: Int32) -> Context {
        generation += 1
        let c = Context(bundleID: bundleID, pid: pid, generation: generation)
        current = c
        onChange?(c)
        return c
    }
}

@MainActor final class FakePermissions: PermissionsProviding {
    var status = PermissionStatus()
    var onChange: (@MainActor (PermissionStatus) -> Void)?
    private(set) var startCount = 0
    private(set) var stopCount = 0
    private(set) var refreshCount = 0
    /// Status published by start() (the launch read).
    var statusOnStart: PermissionStatus?

    func start() {
        startCount += 1
        if let s = statusOnStart { status = s; onChange?(s) }
    }
    func stop() { stopCount += 1 }
    func refresh() { refreshCount += 1 }
    func setInteractive(_ visible: Bool) {}
    func requestAccessibility() { XCTFailNoPrompt() }
    func requestInputMonitoring() { XCTFailNoPrompt() }
    func openSystemSettings(_ pane: PermissionPane) { XCTFailNoPrompt() }

    func grant(accessibility: PermissionState, inputMonitoring: PermissionState = .notDetermined,
               needsRelaunch: Bool = false) {
        status = PermissionStatus(grants: PermissionGrants(accessibility: accessibility,
                                                           inputMonitoring: inputMonitoring),
                                  inputMonitoringNeedsRelaunch: needsRelaunch)
        onChange?(status)
    }

    private func XCTFailNoPrompt() { preconditionFailure("controllers must never prompt") }
}

@MainActor final class FakeConflicts: ConflictDetecting {
    var conflicts = Conflicts.none
    var repeatedFights = 0
    var onChange: (@MainActor (Conflicts) -> Void)?
    private(set) var ourSwitches = 0
    private(set) var externalSwitches = 0
    private(set) var refreshCount = 0
    private(set) var startCount = 0
    private(set) var stopCount = 0

    func start() { startCount += 1 }
    func stop() { stopCount += 1 }
    func refresh() { refreshCount += 1 }
    func noteOurSwitch() { ourSwitches += 1 }
    func noteExternalSwitch() { externalSwitches += 1 }

    func setPerDocument(_ on: Bool) {
        conflicts.perDocumentInputEnabled = on
        onChange?(conflicts)
    }
}

/// Records every call. `start` answers `startAnswer` (nil = the requested mode).
final class FakeKeyWatcher: KeyWatching, @unchecked Sendable { // @unchecked: main-thread tests only
    enum Call: Equatable {
        case start(TapMode), stop, perform(KeyWatcherOperation), checkSecureInput
        case finish(gen: UInt64)
    }

    private(set) var calls: [Call] = []
    var startAnswer: TapMode?

    func start(mode: TapMode) -> TapMode {
        calls.append(.start(mode))
        return startAnswer ?? mode
    }
    func stop() { calls.append(.stop) }
    func perform(_ operation: KeyWatcherOperation) { calls.append(.perform(operation)) }
    func checkSecureInputNow() { calls.append(.checkSecureInput) }
    func claimPosting(gen: UInt64) -> Bool { true }
    func finishReplacement(gen: UInt64, newRendering: InputSourceID?, bufferAfter: [Stroke]?,
                           bufferRenderedIn: InputSourceID?) {
        calls.append(.finish(gen: gen))
    }

    var starts: [TapMode] { calls.compactMap { if case .start(let m) = $0 { m } else { nil } } }
    var stops: Int { calls.filter { $0 == .stop }.count }
    var finishes: [UInt64] { calls.compactMap { if case .finish(let g) = $0 { g } else { nil } } }
    var configs: [KeyProcessorConfig] {
        calls.compactMap { if case .perform(.updateConfig(let c)) = $0 { c } else { nil } }
    }
    func clear() { calls = [] }
}

@MainActor final class FakeTicker: RepeatingTicking {
    private var handler: (@MainActor () -> Void)?
    private(set) var startCount = 0
    var isRunning: Bool { handler != nil }
    func start(_ handler: @escaping @MainActor () -> Void) { startCount += 1; self.handler = handler }
    func stop() { handler = nil }
    func fire() { handler?() }
}

@MainActor final class FakeConvert: ConvertControlling {
    private(set) var requests: [ConvertRequest] = []
    private(set) var hints: [[String: MethodHint]] = []
    func convert(_ request: ConvertRequest) { requests.append(request) }
    func methodHintsChanged(_ overrides: [String: MethodHint]) { hints.append(overrides) }
}

@MainActor func makeStore(_ prefs: Preferences = Preferences(), clock: any Clock) -> PreferencesStore {
    let url = URL(fileURLWithPath: "/tmp/kytkin-tests-never-written/preferences.json")
    let fs = InMemoryPreferencesFileSystem()
    if prefs != Preferences() { fs[url] = try? PreferencesCodec.encode(prefs) }
    return PreferencesStore(fileURL: url, clock: clock, fileSystem: fs)
}

extension Rule {
    static func app(_ bundleID: String, _ source: InputSourceID, _ origin: RuleOrigin = .learned,
                    id: UUID = UUID(), at date: Date = Date(timeIntervalSince1970: 1_000)) -> Rule {
        Rule(id: id, scope: .app(bundleID: bundleID), inputSource: source, origin: origin, updatedAt: date)
    }
}
