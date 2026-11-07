// P2-15: The contract SwitchController (P2-20) uses to hear about context changes (001 §2.2).
// System/Context/ContextMonitor implements it; controller tests use a fake.
// P3-5: Phase 3 additions from 001 §14.5 that need no Core/Browser types: `setHostsWithOverrides` and
// `currentAppIsGone`. `setSitePolicy` and `browserSupport` use P3-6's `SitePolicy`/`BrowserSupportTracker` and
// arrive with the tier-1 wiring (P3-14).

import Foundation

@MainActor protocol ContextMonitoring: AnyObject {
    /// The last emitted Context; nil until an app other than Kytkin has been frontmost.
    var current: Context? { get }
    /// Called once per new Context (deduplicated and debounced by `ContextAssembler`).
    var onChange: (@MainActor (Context) -> Void)? { get set }
    /// P2-41: the app in `current` has quit (cleared by the next Context). Nothing is learned for it and its rule
    /// isn't re-applied; Pin/Forget still work (they act on rules, not on the process).
    var currentAppIsGone: Bool { get }
    func start()
    func stop()
    /// P3-5: the hosts of all siteHost rules (HostNormalizer form, see `RuleEngine.overrideHosts`). May emit a
    /// new Context at once when the page in front gains or loses its override.
    func setHostsWithOverrides(_ hosts: Set<String>)
}
