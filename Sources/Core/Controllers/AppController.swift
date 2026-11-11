// P2-20: The decisions behind the composition root (001 §10 P2-20 wiring notes). `AppEnvironment` (App) builds the
// concrete adapters, sets every `on…` closure exactly once (P2-43, §12 W3) and forwards each event to one method here;
// this type fans it out. Everything it talks to is a Core protocol, so the whole fan-out is unit-tested with fakes.
//
// Fan-out (001 §2.2, §3):
//   context change      → SwitchController (rule + learner), KeyWatcher `.reset(.contextChange)` + `checkSecureInputNow()` (P2-45)
//                         P3-19: no reset for a page-state-only `.page` ↔ `.unknown` change (or bar ↔ AXURL)
//   site policy (P3-14) → availability (Kytkin on/paused, Accessibility, Automation) + browser preferences + the PSL
//                         + web-link handlers → `SitePolicy`, pushed to the context monitor (before it starts, then
//                         on every change); `browserSupport(for:)` for Settings (P3-15)
//   Kytkin active/resign → SwitchController (P2-39), KeyWatcher `.reset(.contextChange)` (+ Secure Input check on resign)
//                         P2-52 item 1: a resign whose frontmost app still reads as Kytkin (or unknown) is looked at
//                         again after 150 ms (up to 3 times) → SwitchController.recheckAfterResign
//                         P2-55: an activation while another app is frontmost (the status-bar menu) is not Kytkin's
//                         window; looked at again the same way in case frontmost lagged (Settings). A resign with no
//                         real activation does nothing. An external switch or word while the flag is on but another
//                         app is frontmost ends the stale flag.
//   input-source change → SwitchController (learner / fights / re-assert), KeyWatcher `.inputSourceChanged`
//                         (P2-52 item 7: `isOurs: true`, "keep the buffer", only for our own after-convert switch
//                         that re-rendered the buffer; rule, menu and toggle switches reset it like any change.
//                         P2-59c: also after an AX run convert, whose finish forgets the buffer itself)
//   permission change   → FeatureAvailability + TapModePolicy (retry only on a real change, §12 W7)
//                         P2-52 item 2: plus one retry on the next app activation if the run's first start came back
//                         below the desired mode (a timeout at launch); TapModePolicy caps it at one per run
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
    /// QA (P2-52 item 2): inside `start()`, so the launch's own context report doesn't fire the activation retry.
    private var launching = false

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
    /// P3-5: the override hosts last given to the context monitor.
    private var lastOverrideHosts: Set<String>?
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

    /// P3-14 (D11): the bundled Public Suffix List loaded. Without it no browser is watched and Settings says why.
    let suffixListLoaded: Bool
    /// P3-14: apps registered for https links (D1, "best effort" browsers). Read at `start()`, and again when Settings
    /// opens (P3-22, `refreshWebLinkHandlers`).
    private let webLinkHandlers: @MainActor () -> Set<String>
    private var webLinkHandlerIDs: Set<String> = []
    /// P3-14: the policy last pushed to the context monitor (nil before `start()`).
    private(set) var sitePolicy: SitePolicy?
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
         frontmostPID: @escaping @MainActor () -> Int32? = { nil },
         suffixListLoaded: Bool = false,
         webLinkHandlers: @escaping @MainActor () -> Set<String> = { [] },
         addressBarLanguage: (@MainActor (LanguagePair) -> InputSourceID?)? = nil) {
        self.suffixListLoaded = suffixListLoaded
        self.webLinkHandlers = webLinkHandlers
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
                                     clock: clock, now: now, addressBarLanguage: addressBarLanguage)   // P3-29
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
        launching = true
        defer { launching = false }
        webLinkHandlerIDs = webLinkHandlers()   // P3-14: before the first policy (the permission read may push one)
        // P3-26: a pre-P3-26 file's per-browser "Use website rules" becomes the global switch, once (on unless every
        // browser here had it off); the next save writes the new key.
        store.update { $0.browsers.resolveLegacySiteRules(among: SitePolicy.browsers(
            webLinkHandlerIDs, ownBundleIDPrefix: KnownSwitchers.ownBundleIDPrefix)) }
        conflicts.start()
        permissions.start()
        // P3-7 (§14.7): a silent Automation check for the browsers the user turned on (never a prompt).
        // P3-26: with the global switch on, every installed browser that supports Automation.
        permissions.refreshAutomation(for: automationOptIns)
        applyPreferences(force: true)
        // P2-21: the processor learns the layout its strokes are typed in only from changes; tell it the
        // current one at launch, so the first double-Shift knows which way to convert.
        keyWatcher.perform(.inputSourceChanged(to: switcher.current, isOurs: false))
        // P3-14: the policy goes in before the monitor starts, so a browser in front at launch gets its site grace
        // (one switch) instead of the browser's rule and then the site's.
        updateSitePolicy()
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
        // P3-7 (§14.7): an opted-in browser came to the front → silent check (≤ 1 per 5 s; catches a revoke).
        // P3-26: silent only; nothing ever prompts when a browser comes to the front.
        if usesAutomation(c.bundleID) { permissions.refreshAutomation(for: [c.bundleID]) }
        noteFrontBrowser(c.bundleID)
        let change = switching.contextDidChange(c)
        // P3-19: a `.page` ↔ `.unknown` flip (one AX timeout) or a bar ↔ AXURL source change on the same site is not a
        // move to another text box: resetting the word buffer there could abort a convert mid-word. Into or out of
        // `.editingAddress` still resets (the address bar is another field).
        if !Self.keepsWordBuffer(change) {
            // P3-37 (b): a reset that parks a terminal's buffer on the way out and restores it on the way back.
            keyWatcher.perform(.contextChanged(terminalPID: terminalPID(of: c)))
        }
        keyWatcher.checkSecureInputNow()      // P2-45: on every app change
        retryTapAfterLaunchTimeout()          // P2-52 item 2: at most once per run
        afterEvent()
    }

    /// P3-7: the browsers the user turned Automation on for. P3-26: the global switch × the installed browsers
    /// (web-link handlers) that support Automation.
    private var automationOptIns: Set<String> {
        guard store.prefs.browsers.useAutomation else { return [] }
        return webLinkHandlerIDs.filter(usesAutomation)
    }

    /// P3-26: the global "Use Automation" is on and `bundleID` has a scripting dictionary.
    private func usesAutomation(_ bundleID: String) -> Bool {
        store.prefs.browsers.useAutomation && BrowserCatalog.known[bundleID]?.appleScript != nil
    }

    /// P3-26: the browser most recently in front this session (Kytkin excluded), for the default choice of the
    /// Browsers & Sites dropdown. Memory only.
    private(set) var lastFrontBrowserID: String?

    private func noteFrontBrowser(_ bundleID: String) {
        guard !bundleID.isEmpty else { return }
        let own = KnownSwitchers.ownBundleIDPrefix.lowercased()
        guard own.isEmpty || !bundleID.lowercased().hasPrefix(own),
              BrowserCatalog.engine(for: bundleID, opensWebLinks: webLinkHandlerIDs.contains(bundleID)) != nil
        else { return }
        lastFrontBrowserID = bundleID
    }

    /// P3-37 (b): the app's pid when Kytkin treats it as a terminal (the seeds and the user's Settings → Apps choice, as
    /// ConvertController does), else nil.
    private func terminalPID(of c: Context) -> Int32? {
        let caps = ReplacementCapabilities(overrides: lastHints ?? PreferencesMapping.methodHintOverrides(store.prefs.apps))
        return caps.method(for: c.bundleID) == .terminal ? c.pid : nil
    }

    /// P3-19: page-state-only changes between `.page` and `.unknown` (either way, or the same state with another
    /// source) keep the KeyWatcher's word buffer.
    static func keepsWordBuffer(_ change: SwitchController.ContextChange) -> Bool {
        guard case let .pageStateOnly(from, to) = change else { return false }
        let quiet: [BrowserPageState?] = [.page, .unknown]
        return quiet.contains(from) && quiet.contains(to)
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
        switching.preferencesDidChange()   // P3-29: the pair's Latin member may only now be installed
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
            break                             // P3-40: no undo record to drop any more (was P3-35 QA `forgetUndo`)
        case let .terminalBufferStarted(epoch):
            convert.anchorTerminalBuffer(epoch: epoch)   // P3-37 (b)
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
        // QA (P3-14): Kytkin turned back on → the policy goes first, so a browser in front is held for its site read
        // and the turn-on re-apply waits for it (one switch, not the browser's rule and then the site's).
        if isStarted, store.prefs.general.enabled, lastPrefs?.general.enabled == false {
            updateSitePolicy(availabilityFor(paused: switching.paused))
        }
        applyPreferences(force: false)
        recompute(grantsChanged: false)
    }

    // MARK: - MenuControlling

    var menuState: MenuState {
        let status = permissions.status
        // P2-27: the learner line is built only for the DEBUG menu (it is read on every label refresh).
        #if DEBUG
        let learnerDebug: String? = switching.learnerDebug
        let siteDebug: String? = context.siteDebug
        #else
        let learnerDebug: String? = nil
        let siteDebug: String? = nil
        #endif
        return MenuState(
            currentRule: switching.currentRule, paused: switching.paused, enabled: store.prefs.general.enabled,
            tapMode: policy.achieved, secureInputOn: keyWatcherStatus.secureInputOn,
            degradedByWatchdog: keyWatcherStatus.degradedByWatchdog,
            // P2-57 item 1: offered whenever the tap runs below the desired mode, not only after a watchdog downgrade.
            canRestartKeyboard: isStarted && policy.restartAction(desired: desiredTapMode()) != nil,
            keyboardBelowDesired: isStarted && policy.runsBelow(desired: desiredTapMode()),
            tapReEnableCount: keyWatcherStatus.health.reEnableCount,
            slowCallbackCount: keyWatcherStatus.health.overBudgetCallbacks, doubleShiftCount: doubleShiftCount,
            conflicts: conflicts.conflicts, learnerDebug: learnerDebug, siteDebug: siteDebug,
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
        // QA (P3-14): on Resume the policy goes first (see `preferencesDidChange`); on Pause it follows, so the
        // browser's dropped site never reaches an unpaused SwitchController.
        if isStarted, !on, switching.paused { updateSitePolicy(availabilityFor(paused: false)) }
        switching.setPaused(on)
        recompute(grantsChanged: false)   // Pause turns the tap off; resume turns it back on
        onDisplayChange?()
    }

    @discardableResult func selectFromMenu(_ id: InputSourceID) -> Bool {
        switching.selectFromMenu(id)
    }

    /// P2-22: "Restart Keyboard Features" (a user click): start the desired mode again through the policy. A
    /// user-initiated start clears the watchdog's history (KeyTapEngine). P2-57 item 1: offered whenever the tap runs
    /// below the desired mode; if the restart fails too, `runsBelow` keeps the warning up.
    func restartKeyboard() {
        guard isStarted, let action = policy.restartAction(desired: desiredTapMode()) else { return }
        if case .start(let mode) = action { policy.restarting(mode) }
        apply(action)
        recompute(grantsChanged: false)
    }

    /// P2-21: ConvertController's switch after a convert or toggle (flow (c) step 8), hopped onto main by the root.
    /// `keepsBuffer`: the change notification must not reset the processor: the convert's finish states the buffer
    /// itself (P2-59c: kept, re-rendered into `target`, or forgotten after an AX run, which keeps the X6 undo alive).
    /// True when `target` is now selected.
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
                                       switchAfterConvert: prefs.convert.switchLanguageAfterConvert,
                                       // P3-37; QA: never on whole-document web apps (Google Docs / Sheets…)
                                       useClipboard: prefs.convert.useClipboardInUnreadableApps
                                           && !ReplacementCapabilities.blocksClipboard(bundleID: c.bundleID,
                                                                                       host: c.host),
                                       inAddressBar: c.pageState == .editingAddress))
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
        // P3-5: siteHost rules → the assembler's override hosts (001 §14.5); it re-checks the page in front.
        let hosts = RuleEngine.overrideHosts(prefs.rules)
        if force || hosts != lastOverrideHosts {
            lastOverrideHosts = hosts
            context.setHostsWithOverrides(hosts)
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
        if isStarted { updateSitePolicy() }
        afterEvent()
    }

    /// P3-14 (001 §14.5): Kytkin on/paused and Accessibility (`availability.siteRules`), the Automation opt-ins, the
    /// browser preferences (`siteRulesOn`, `ignorePrivateWindowsCompletely`), the PSL (D11) and the web-link
    /// handlers → one `SitePolicy`, pushed only when it changed (the monitor re-attaches or detaches at once).
    private func updateSitePolicy(_ availability: FeatureAvailability? = nil) {
        let policy = SitePolicy(availability: availability ?? self.availability, browsers: store.prefs.browsers,
                                suffixListLoaded: suffixListLoaded, webLinkHandlers: webLinkHandlerIDs,
                                ownBundleIDPrefix: KnownSwitchers.ownBundleIDPrefix)
        guard policy != sitePolicy else { return }
        sitePolicy = policy
        context.setSitePolicy(policy)
    }

    /// QA (P3-14): the availability `recompute` is about to compute, for pushing the policy ahead of it. Site rules
    /// and the Automation opt-ins depend only on Kytkin on/paused and the grants, not on the tap.
    private func availabilityFor(paused: Bool) -> FeatureAvailability {
        FeatureAvailability.compute(grants: permissions.status.grants, tapMode: policy.achieved,
                                    secureInput: keyWatcherStatus.secureInputOn,
                                    settings: PreferencesMapping.featureSettings(store.prefs, paused: paused))
    }

    /// P3-14, for Settings → Browsers & Sites (P3-15): what Kytkin knows about reading `bundleID` this session.
    /// P3-15: the request comes from the browser preferences as they are now, not from the pushed policy, so a
    /// "Use website rules" switch just flipped in Settings shows at once (the push follows a moment later, through
    /// the preferences observation).
    func browserSupport(for bundleID: String) -> BrowserSupport {
        let policy = SitePolicy(availability: availability, browsers: store.prefs.browsers,
                                suffixListLoaded: suffixListLoaded, webLinkHandlers: webLinkHandlerIDs,
                                ownBundleIDPrefix: KnownSwitchers.ownBundleIDPrefix)
        return context.browserSupport.status(bundleID: bundleID, request: policy.request(for: bundleID),
                                             availability: availability, suffixListLoaded: suffixListLoaded)
    }

    /// P3-14: the "best effort" browsers (apps registered for https links, read at `start()`), for P3-15's list.
    var otherBrowserBundleIDs: Set<String> {
        webLinkHandlerIDs.filter { BrowserCatalog.known[$0] == nil }
    }

    /// P3-22: Settings opened (or came to the front): read the web-link handlers again, so a browser installed since
    /// launch is listed and watched. Pushes a new policy only when the set changed. Returns every handler.
    @discardableResult func refreshWebLinkHandlers() -> Set<String> {
        guard isStarted else { return webLinkHandlerIDs }
        let fresh = webLinkHandlers()
        if fresh != webLinkHandlerIDs {
            webLinkHandlerIDs = fresh
            updateSitePolicy()
        }
        return webLinkHandlerIDs
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

    /// P2-52 item 2: the one automatic retry after a below-desired first start (TapModePolicy decides; never again).
    /// QA: not for the frontmost app `context.start()` reports from inside `start()`: that comes right after the first
    /// start timed out, so the retry would block main a second time at once, on a system that is still busy. Not after
    /// a watchdog downgrade (B4, never fought) or while only a relaunch can help ("Quit & Reopen"); it stays armed.
    private func retryTapAfterLaunchTimeout() {
        guard isStarted, !launching, !keyWatcherStatus.degradedByWatchdog,
              !policy.showsQuitAndReopen(needsRelaunch: permissions.status.inputMonitoringNeedsRelaunch),
              let action = policy.activationRetry(desired: desiredTapMode()) else { return }
        apply(action)                         // blocks main ≤ 1–2 s, once per run
        recompute(grantsChanged: false)
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
