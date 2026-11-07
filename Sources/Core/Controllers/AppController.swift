// P2-20: The decisions behind the composition root (001 §10 P2-20 wiring notes). `AppEnvironment` (App) builds the
// concrete adapters, sets every `on…` closure exactly once (P2-43, §12 W3) and forwards each event to one method here;
// this type fans it out. Everything it talks to is a Core protocol, so the whole fan-out is unit-tested with fakes.
//
// Fan-out (001 §2.2, §3):
//   context change      → SwitchController (rule + learner), KeyWatcher `.reset(.contextChange)` + `checkSecureInputNow()` (P2-45)
//   Kytkin active/resign → SwitchController (P2-39), KeyWatcher `.reset(.contextChange)` (+ Secure Input check on resign)
//                         P2-52 item 1: a resign whose frontmost app still reads as Kytkin (or unknown) is looked at
//                         again after 150 ms (up to 3 times) → SwitchController.recheckAfterResign
//                         P2-55: an activation while another app is frontmost (the status-bar menu) is not Kytkin's
//                         window; looked at again the same way in case frontmost lagged (Settings). A resign with no
//                         real activation does nothing. An external switch or word while the flag is on but another
//                         app is frontmost ends the stale flag.
//   input-source change → SwitchController (learner / fights / re-assert), KeyWatcher `.inputSourceChanged`
//                         (P2-52 item 7: `isOurs: true`, "keep the buffer", only for our own after-convert switch
//                         that re-rendered the buffer; rule, menu and toggle switches reset it like any change)
//   permission change   → FeatureAvailability + TapModePolicy (retry only on a real change, §12 W7)
//   conflicts change    → the learning flag (P2-38)
//   KeyWatcher status   → achieved tap mode, Secure Input → FeatureAvailability (§12 W5) → dwell vs words
//   KeyWatcher signal   → word boundary → learner; double-Shift → ConvertControlling or finished at once
//   after-convert switch ← ConvertController (P2-21, via the root's hook) → SwitchController.selectAfterConvert
//   preferences change  → rules, learning flag, `.updateConfig` (only when it changed, clamped), method hints, tap mode
//   menu (P2-22)        → MenuState for MenuModel; "Restart Keyboard Features" → TapModePolicy.restartAction
// The label/menu refresh (`onDisplayChange`) runs after every event except key signals (P2-52 item 4).
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
    private let clock: any Clock
    /// P2-52 item 7: our after-convert switch whose buffer was re-rendered into `target`; its change notification
    /// (10–20 ms later) is the only `.ours` change that keeps the tap's word buffer. Expires like a switch token.
    private var bufferKeepingSwitch: (target: InputSourceID, untilNanos: UInt64)?
    static let bufferKeepingSwitchWindowNanos: UInt64 = 500_000_000

    /// P2-52 item 1: right after Kytkin resigns, `frontmostApplication` can still be Kytkin. Look again this much
    /// later, at most this many times, until another app is in front.
    static let resignRecheckDelayNanos: UInt64 = 150_000_000
    static let resignRecheckAttempts = 3
    private let ownPID: Int32
    private let frontmostPID: @MainActor () -> Int32?
    private let scheduler: (any OneShotScheduling)?
    private var looksLeft = 0
    /// What the pending look is for: a resign whose frontmost app read as Kytkin/unknown (P2-52 item 1), and/or an
    /// activation whose frontmost app didn't read as Kytkin yet (P2-55 QA).
    private var resignLookPending = false
    private var activationLookPending = false

    init(switcher: any InputSourceSwitching, context: any ContextMonitoring, store: PreferencesStore,
         permissions: any PermissionsProviding, conflicts: any ConflictDetecting, keyWatcher: any KeyWatching,
         ticker: any RepeatingTicking, convert: (any ConvertControlling)? = nil, clock: any Clock,
         now: @escaping () -> Date = Date.init, scheduler: (any OneShotScheduling)? = nil,
         ownPID: Int32 = ProcessInfo.processInfo.processIdentifier,
         frontmostPID: @escaping @MainActor () -> Int32? = { nil }) {
        self.scheduler = scheduler
        self.ownPID = ownPID
        self.frontmostPID = frontmostPID
        self.switcher = switcher
        self.context = context
        self.store = store
        self.permissions = permissions
        self.conflicts = conflicts
        self.keyWatcher = keyWatcher
        self.ticker = ticker
        self.clock = clock
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
        // P2-21: the processor learns the layout its strokes are typed in only from changes; tell it the
        // current one at launch, so the first double-Shift knows which way to convert.
        keyWatcher.perform(.inputSourceChanged(to: switcher.current, isOurs: false))
        context.start()            // emits the frontmost app at once → its rule applies
        recompute(grantsChanged: false)
        observePreferences()
    }

    /// On quit. `keyWatcher.stop()` flushes held keys before the tap goes; a timed-out stop counts as `.off`.
    func stop() {
        guard isStarted else { return }
        isStarted = false
        cancelLooks()
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
        cancelLooks()                 // the new app got its own rule
        switching.contextDidChange(c)
        keyWatcher.perform(.reset(.contextChange))
        keyWatcher.checkSecureInputNow()      // P2-45: on every app change
        afterEvent()
    }

    func inputSourceDidChange(_ change: InputSourceChange) {
        if case .external = change { healStaleOwnWindow() }   // P2-55 QA
        switching.inputSourceDidChange(change)
        // P2-52 item 7: `isOurs` tells the processor "keep the buffer, it is already rendered in `id`". That is true
        // only for the after-convert switch that re-rendered it. A rule, menu or toggle switch is ours for the
        // learner (SwitchController above) but the strokes were typed in the old layout, so the buffer must go.
        switch change {
        case .ours(let id):
            keyWatcher.perform(.inputSourceChanged(to: id, isOurs: consumeBufferKeepingSwitch(id)))
        case .external(let id, _):
            bufferKeepingSwitch = nil
            keyWatcher.perform(.inputSourceChanged(to: id, isOurs: false))
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
            healStaleOwnWindow()              // P2-55 QA
            switching.wordBoundary()
        case .bufferInvalidated:
            break
        case let .doubleShift(snapshot, gen):
            doubleShiftCount += 1
            route(snapshot: snapshot, gen: gen)
        case let .wordEnded(_, gen), let .undoCandidate(gen):
            finish(gen)   // auto-fix is P4: nothing may keep these keys waiting
        }
        afterEvent(refreshDisplay: false)
    }

    /// P2-20 QA: ContextMonitor ignores Kytkin, so no `.contextChange` reset happens when Kytkin's own window comes
    /// to the front or goes away. Without these resets the word buffer would carry the previous app's word into
    /// Settings, and (worse) words typed in Settings back into that app when the user returns with ⌘Tab (a
    /// duplicate activation, so no new Context): a later double-Shift there would backspace over the wrong text.
    /// P2-55: `isFrontmost` is false when only the status-bar menu opened (another app stays frontmost): that is not
    /// Kytkin's own window, so nothing is reset or cancelled. The root reads it from NSWorkspace.
    /// P2-55 QA: `frontmostApplication` can lag behind didBecomeActive (Settings comes forward with
    /// `NSApp.activate()`), so a not-frontmost activation is looked at again like a resign (150 ms × 3). If Kytkin is
    /// in front by then, it was Settings after all: otherwise a switch typed there would be learned for the previous app.
    func kytkinDidBecomeActive(isFrontmost: Bool = true) {
        guard isFrontmost else {
            guard !switching.isOwnAppActive else { return }
            activationLookPending = true
            startLooking()
            return
        }
        ownWindowBecameActive()
    }

    private func ownWindowBecameActive() {
        cancelLooks()
        switching.kytkinDidBecomeActive(isFrontmost: true)
        keyWatcher.perform(.reset(.contextChange))
        afterEvent()
    }

    func kytkinDidResignActive(frontmostPID: Int32?) {
        activationLookPending = false          // whatever that activation was, it is over
        let known = frontmostPID.flatMap { $0 == ownPID ? nil : $0 }
        // P2-55: a resign with no real activation before it (the status-bar menu closed) changes nothing. A look still
        // pending from an earlier real resign keeps going.
        guard switching.kytkinDidResignActive(frontmostPID: known) else {
            if !resignLookPending { cancelLooks() }
            return
        }
        keyWatcher.perform(.reset(.contextChange))
        keyWatcher.checkSecureInputNow()      // P2-45: like any other app change
        if known == nil {
            resignLookPending = true
            startLooking()
        } else {
            cancelLooks()
        }
        afterEvent()
    }

    /// P2-55 QA: the own-window flag can only be stale (a resign AppKit never posted). Before an external switch or a
    /// word reaches the gate, a frontmost app that is known and not Kytkin ends it, without re-applying a rule (the
    /// user is switching right now). The next Context would clear it too, but the owner stays in one app.
    private func healStaleOwnWindow() {
        guard switching.isOwnAppActive, let pid = frontmostPID(), pid != ownPID else { return }
        cancelLooks()
        switching.ownWindowFlagWasStale()
        keyWatcher.checkSecureInputNow()      // P2-45: we are back in another app
    }

    // MARK: - P2-52 item 1 + P2-55 QA: second looks at the frontmost app

    private func startLooking() {
        looksLeft = Self.resignRecheckAttempts
        scheduleLook()
    }

    private func scheduleLook() {
        guard isStarted, let scheduler, looksLeft > 0 else {
            resignLookPending = false
            activationLookPending = false
            return
        }
        looksLeft -= 1
        scheduler.schedule(afterNanos: Self.resignRecheckDelayNanos) { [weak self] in self?.look() }
    }

    private func look() {
        guard isStarted else { return }
        let pid = frontmostPID()
        if pid == ownPID, activationLookPending {
            ownWindowBecameActive()           // Settings after all (frontmost lagged behind didBecomeActive)
        } else if let pid, pid != ownPID {
            let wasResign = resignLookPending
            cancelLooks()
            if wasResign, !switching.isOwnAppActive {
                switching.recheckAfterResign(frontmostPID: pid)
                afterEvent()
            }
        } else {
            scheduleLook()
        }
    }

    private func cancelLooks() {
        looksLeft = 0
        resignLookPending = false
        activationLookPending = false
        scheduler?.cancel()
    }

    /// Any writer changed the preferences (Settings, our own learn/pin/forget). Idempotent.
    func preferencesDidChange() {
        applyPreferences(force: false)
        recompute(grantsChanged: false)
    }

    // MARK: - MenuControlling

    var menuState: MenuState {
        let status = permissions.status
        return MenuState(
            currentRule: switching.currentRule, paused: switching.paused, enabled: store.prefs.general.enabled,
            tapMode: policy.achieved, secureInputOn: keyWatcherStatus.secureInputOn,
            degradedByWatchdog: keyWatcherStatus.degradedByWatchdog,
            canRestartKeyboard: keyWatcherStatus.degradedByWatchdog && isStarted
                && policy.restartAction(desired: desiredTapMode()) != nil,
            tapReEnableCount: keyWatcherStatus.health.reEnableCount, doubleShiftCount: doubleShiftCount,
            conflicts: conflicts.conflicts, learnerDebug: switching.learnerDebug,
            showsQuitAndReopen: policy.showsQuitAndReopen(needsRelaunch: status.inputMonitoringNeedsRelaunch),
            accessibility: status.grants.accessibility, inputMonitoring: status.grants.inputMonitoring,
            store: MenuState.StoreFlags(loadIssue: store.loadIssue, isReadOnly: store.isReadOnly,
                                        lastSaveFailed: store.lastSaveFailed, loadWasLossy: store.loadWasLossy,
                                        originalBackupURL: store.originalBackupURL))
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

    /// P2-22: "Restart Keyboard Features" (a user click, shown only after a watchdog downgrade): start the desired
    /// mode again through the policy. A user-initiated start clears the watchdog's history (KeyTapEngine).
    func restartKeyboard() {
        guard isStarted, keyWatcherStatus.degradedByWatchdog,
              let action = policy.restartAction(desired: desiredTapMode()) else { return }
        if case .start(let mode) = action { policy.restarting(mode) }
        apply(action)
        recompute(grantsChanged: false)
    }

    /// P2-21: ConvertController's switch after a convert or toggle (flow (c) step 8), hopped onto main by the root.
    /// `keepsBuffer`: the tap's buffer was re-rendered into `target` (last-word convert), so the change notification
    /// must not reset it. True when `target` is now selected.
    @discardableResult func switchAfterConvert(to target: InputSourceID, keepsBuffer: Bool) -> Bool {
        guard isStarted else { return false }
        if switcher.current == target { return true }
        bufferKeepingSwitch = keepsBuffer ? (target, clock.nowNanos + Self.bufferKeepingSwitchWindowNanos) : nil
        guard switching.selectAfterConvert(target) else {
            bufferKeepingSwitch = nil
            return false
        }
        afterEvent()
        return true
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
        guard app?.disabled != true else { return finish(gen) }
        let mode: ConvertRequest.Mode
        if availability.doubleShiftConvert {
            // P2-21: "convert off" for this app (Settings → Apps) leaves double-Shift as a language toggle.
            mode = app?.convertEnabled == false ? .toggleOnly : .convert
        } else if availability.doubleShiftToggleOnly {
            mode = .toggleOnly
        } else {
            return finish(gen)
        }
        convert.convert(ConvertRequest(snapshot: snapshot, gen: gen, bundleID: c.bundleID, mode: mode,
                                       pair: prefs.languagePair, currentSource: switcher.current,
                                       switchAfterConvert: prefs.convert.switchLanguageAfterConvert))
    }

    /// P2-52 item 7: true only for the notification of our own buffer-keeping after-convert switch.
    private func consumeBufferKeepingSwitch(_ id: InputSourceID) -> Bool {
        defer { bufferKeepingSwitch = nil }
        guard let k = bufferKeepingSwitch else { return false }
        return k.target == id && clock.nowNanos <= k.untilNanos
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
            apply(action)
        }
        availability = FeatureAvailability.compute(grants: grants, tapMode: policy.achieved,
                                                   secureInput: keyWatcherStatus.secureInputOn, settings: settings)
        switching.setKeyboardTapAvailable(availability.learningWithWords)
        afterEvent()
    }

    private func apply(_ action: TapModePolicy.Action) {
        switch action {
        case .start(let mode):
            // Blocks main ≤ 1 s (≈ 2 s right after a timed-out stop, P2-50); only on a real change or a user click.
            policy.started(achieved: keyWatcher.start(mode: mode))
        case .stop:
            keyWatcher.stop()
            policy.stopped()   // a timed-out stop is treated as `.off`
        }
    }

    private func desiredTapMode() -> TapMode {
        FeatureAvailability.desiredTapMode(
            grants: permissions.status.grants,
            settings: PreferencesMapping.featureSettings(store.prefs, paused: switching.paused))
    }

    /// `refreshDisplay: false` for key signals (P2-52 item 4): they never change the label (language, Pause,
    /// warnings), and the menu reads everything fresh when it opens, so a refresh per word is wasted work.
    private func afterEvent(refreshDisplay: Bool = true) {
        if switching.wantsTicks {
            if !ticker.isRunning { ticker.start { [weak self] in self?.tick() } }
        } else if ticker.isRunning {
            ticker.stop()
        }
        if refreshDisplay { onDisplayChange?() }
    }

    /// Re-arms after every change: Observation reports once per registration, before the value changes.
    /// P2-22 QA: also the file flags the menu warns about (a debounced save failing or recovering, the kept
    /// original's URL), so the label's dot follows them without waiting for the next app switch.
    private func observePreferences() {
        guard isStarted else { return }
        withObservationTracking {
            _ = store.prefs
            _ = store.lastSaveFailed
            _ = store.originalBackupURL
        } onChange: { [weak self] in
            Task { @MainActor [weak self] in
                guard let self, self.isStarted else { return }
                self.preferencesDidChange()
                self.observePreferences()
            }
        }
    }
}
