// P2-20: The decisions behind the composition root (001 §10 P2-20 wiring notes). `AppEnvironment` (App) builds the
// concrete adapters, sets every `on…` closure exactly once (P2-43, §12 W3) and forwards each event to one method here;
// this type fans it out. Everything it talks to is a Core protocol, so the whole fan-out is unit-tested with fakes.
//
// Fan-out (001 §2.2, §3):
//   context change      → SwitchController (rule + learner), KeyWatcher `.reset(.contextChange)` + `checkSecureInputNow()` (P2-45)
//   Kytkin active/resign → SwitchController (P2-39), KeyWatcher `.reset(.contextChange)` (+ Secure Input check on resign)
//   input-source change → SwitchController (learner / fights / re-assert), KeyWatcher `.inputSourceChanged`
//   permission change   → FeatureAvailability + TapModePolicy (retry only on a real change, §12 W7)
//   conflicts change    → the learning flag (P2-38)
//   KeyWatcher status   → achieved tap mode, Secure Input → FeatureAvailability (§12 W5) → dwell vs words
//   KeyWatcher signal   → word boundary → learner; double-Shift → ConvertControlling or finished at once
//   preferences change  → rules, learning flag, `.updateConfig` (only when it changed, clamped), method hints, tap mode
// FeatureSettings come from the preferences plus the session-only Pause (PreferencesMapping).

import Foundation
import Observation

@MainActor final class AppController: MenuControlling {
    let switching: SwitchController
    private(set) var availability: FeatureAvailability
    private(set) var policy = TapModePolicy()
    private(set) var keyWatcherStatus = KeyWatcherStatus()
    private(set) var doubleShiftCount = 0
    private(set) var isStarted = false

    /// Something the menu-bar label or menu shows changed. Set by the composition root only.
    var onDisplayChange: (@MainActor () -> Void)?

    private let switcher: any InputSourceSwitching
    private let context: any ContextMonitoring
    private let store: PreferencesStore
    private let permissions: any PermissionsProviding
    private let conflicts: any ConflictDetecting
    private let keyWatcher: any KeyWatching
    private let ticker: any RepeatingTicking
    private(set) var convert: any ConvertControlling

    private var lastPrefs: Preferences?
    private var lastConfig: KeyProcessorConfig?
    private var lastHints: [String: MethodHint]?

    init(switcher: any InputSourceSwitching, context: any ContextMonitoring, store: PreferencesStore,
         permissions: any PermissionsProviding, conflicts: any ConflictDetecting, keyWatcher: any KeyWatching,
         ticker: any RepeatingTicking, convert: (any ConvertControlling)? = nil, clock: any Clock,
         now: @escaping () -> Date = Date.init) {
        self.switcher = switcher
        self.context = context
        self.store = store
        self.permissions = permissions
        self.conflicts = conflicts
        self.keyWatcher = keyWatcher
        self.ticker = ticker
        // P2-21 passes the real ConvertController; until then every generation is finished at once.
        self.convert = convert ?? FinishOnlyConvertController { [keyWatcher] gen in
            keyWatcher.finishReplacement(gen: gen, newRendering: nil, bufferAfter: nil)
        }
        switching = SwitchController(switcher: switcher, context: context, store: store, conflicts: conflicts,
                                     clock: clock, now: now)
        availability = FeatureAvailability.compute(
            grants: permissions.status.grants, tapMode: .off, secureInput: false,
            settings: PreferencesMapping.featureSettings(store.prefs, paused: false))
    }

    /// The processor config the KeyWatcher should be built with (the root calls this before `init`).
    static func initialProcessorConfig(_ store: PreferencesStore) -> KeyProcessorConfig {
        PreferencesMapping.processorConfig(store.prefs)
    }

    // MARK: - Lifecycle

    /// The root sets every callback first, then calls this. Callbacks fired from inside a `start()` are handled.
    func start() {
        guard !isStarted else { return }
        isStarted = true
        conflicts.start()
        permissions.start()
        applyPreferences(force: true)
        context.start()            // emits the frontmost app at once → its rule applies
        recompute(grantsChanged: false)
        observePreferences()
    }

    /// On quit. `keyWatcher.stop()` flushes held keys before the tap goes; a timed-out stop counts as `.off`.
    func stop() {
        guard isStarted else { return }
        isStarted = false
        ticker.stop()
        context.stop()
        keyWatcher.stop()
        policy.stopped()
        permissions.stop()
        conflicts.stop()
        store.flush()
    }

    // MARK: - Events (one per callback the root owns)

    func contextDidChange(_ c: Context) {
        switching.contextDidChange(c)
        keyWatcher.perform(.reset(.contextChange))
        keyWatcher.checkSecureInputNow()      // P2-45: on every app change
        afterEvent()
    }

    func inputSourceDidChange(_ change: InputSourceChange) {
        switching.inputSourceDidChange(change)
        switch change {
        case .ours(let id): keyWatcher.perform(.inputSourceChanged(to: id, isOurs: true))
        case .external(let id, _): keyWatcher.perform(.inputSourceChanged(to: id, isOurs: false))
        }
        afterEvent()
    }

    func sourcesListDidChange() {
        onDisplayChange?()
    }

    func permissionsDidChange(_ status: PermissionStatus) {
        recompute(grantsChanged: true)
    }

    func conflictsDidChange(_ conflicts: Conflicts) {
        switching.refreshLearning()
        afterEvent()
    }

    func keyWatcherStatusDidChange(_ status: KeyWatcherStatus) {
        keyWatcherStatus = status
        policy.statusReported(mode: status.health.mode)
        recompute(grantsChanged: false)
    }

    func keySignal(_ signal: KeySignal) {
        switch signal {
        case .wordBoundary:
            switching.wordBoundary()
        case .bufferInvalidated:
            break
        case let .doubleShift(snapshot, gen):
            doubleShiftCount += 1
            route(snapshot: snapshot, gen: gen)
        case let .wordEnded(_, gen), let .undoCandidate(gen):
            finish(gen)   // auto-fix is P4: nothing may keep these keys waiting
        }
        afterEvent()
    }

    /// P2-20 QA: ContextMonitor ignores Kytkin, so no `.contextChange` reset happens when Kytkin's own window comes
    /// to the front or goes away. Without these resets the word buffer would carry the previous app's word into
    /// Settings, and (worse) words typed in Settings back into that app when the user returns with ⌘Tab (a
    /// duplicate activation, so no new Context): a later double-Shift there would backspace over the wrong text.
    func kytkinDidBecomeActive() {
        switching.kytkinDidBecomeActive()
        keyWatcher.perform(.reset(.contextChange))
        afterEvent()
    }

    func kytkinDidResignActive(frontmostPID: Int32?) {
        switching.kytkinDidResignActive(frontmostPID: frontmostPID)
        keyWatcher.perform(.reset(.contextChange))
        keyWatcher.checkSecureInputNow()      // P2-45: like any other app change
        afterEvent()
    }

    /// Any writer changed the preferences (Settings, our own learn/pin/forget). Idempotent.
    func preferencesDidChange() {
        applyPreferences(force: false)
        recompute(grantsChanged: false)
    }

    // MARK: - MenuControlling

    var menuState: MenuState {
        MenuState(currentRule: switching.currentRule, paused: switching.paused, tapMode: policy.achieved,
                  secureInputOn: keyWatcherStatus.secureInputOn,
                  degradedByWatchdog: keyWatcherStatus.degradedByWatchdog,
                  tapReEnableCount: keyWatcherStatus.health.reEnableCount, doubleShiftCount: doubleShiftCount,
                  conflicts: conflicts.conflicts,
                  showsQuitAndReopen: policy.showsQuitAndReopen(
                    needsRelaunch: permissions.status.inputMonitoringNeedsRelaunch))
    }

    func menuWillOpen() {
        conflicts.refresh()
        permissions.refresh()
    }

    func pinCurrent() {
        switching.pinCurrent()
        preferencesDidChange()
        onDisplayChange?()
    }

    func forgetCurrent() {
        switching.forgetCurrent()
        preferencesDidChange()
        onDisplayChange?()
    }

    func setPaused(_ on: Bool) {
        switching.setPaused(on)
        recompute(grantsChanged: false)   // Pause turns the tap off; resume turns it back on
        onDisplayChange?()
    }

    @discardableResult func selectFromMenu(_ id: InputSourceID) -> Bool {
        switching.selectFromMenu(id)
    }

    /// Dwell tick (only while `switching.wantsTicks`).
    func tick() {
        switching.tick()
        afterEvent()
    }

    // MARK: - Private

    private func route(snapshot: WordSnapshot, gen: UInt64) {
        let prefs = store.prefs
        guard !switching.paused, prefs.general.enabled, !switching.isOwnAppActive,
              let c = context.current else { return finish(gen) }
        let app = prefs.apps[c.bundleID]
        guard app?.disabled != true, app?.convertEnabled != false else { return finish(gen) }
        let mode: ConvertRequest.Mode
        if availability.doubleShiftConvert {
            mode = .convert
        } else if availability.doubleShiftToggleOnly {
            mode = .toggleOnly
        } else {
            return finish(gen)
        }
        convert.convert(ConvertRequest(snapshot: snapshot, gen: gen, bundleID: c.bundleID, mode: mode))
    }

    private func finish(_ gen: UInt64) {
        keyWatcher.finishReplacement(gen: gen, newRendering: nil, bufferAfter: nil)
    }

    private func applyPreferences(force: Bool) {
        let prefs = store.prefs
        guard force || prefs != lastPrefs else { return }
        lastPrefs = prefs
        switching.preferencesDidChange()
        let config = PreferencesMapping.processorConfig(prefs)
        if force || config != lastConfig {
            lastConfig = config
            keyWatcher.perform(.updateConfig(config))   // P2-50, already clamped
        }
        let hints = PreferencesMapping.methodHintOverrides(prefs.apps)
        if force || hints != lastHints {
            lastHints = hints
            convert.methodHintsChanged(hints)
        }
    }

    /// FeatureAvailability + the tap decision (§12 W7) + the learner's dwell/words flag.
    private func recompute(grantsChanged: Bool) {
        let grants = permissions.status.grants
        let settings = PreferencesMapping.featureSettings(store.prefs, paused: switching.paused)
        let desired = FeatureAvailability.desiredTapMode(grants: grants, settings: settings)
        if isStarted, let action = policy.decide(desired: desired, grantsChanged: grantsChanged) {
            switch action {
            case .start(let mode):
                // Blocks main ≤ 1 s (≈ 2 s right after a timed-out stop, P2-50); only on a real change.
                policy.started(achieved: keyWatcher.start(mode: mode))
            case .stop:
                keyWatcher.stop()
                policy.stopped()   // a timed-out stop is treated as `.off`
            }
        }
        availability = FeatureAvailability.compute(grants: grants, tapMode: policy.achieved,
                                                   secureInput: keyWatcherStatus.secureInputOn, settings: settings)
        switching.setKeyboardTapAvailable(availability.learningWithWords)
        afterEvent()
    }

    private func afterEvent() {
        if switching.wantsTicks {
            if !ticker.isRunning { ticker.start { [weak self] in self?.tick() } }
        } else if ticker.isRunning {
            ticker.stop()
        }
        onDisplayChange?()
    }

    /// Re-arms after every change: Observation reports once per registration, before the value changes.
    private func observePreferences() {
        guard isStarted else { return }
        withObservationTracking {
            _ = store.prefs
        } onChange: { [weak self] in
            Task { @MainActor [weak self] in
                guard let self, self.isStarted else { return }
                self.preferencesDidChange()
                self.observePreferences()
            }
        }
    }
}
