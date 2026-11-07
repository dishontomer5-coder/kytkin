// P2-15: The contract SwitchController (P2-20) uses to hear about context changes (001 §2.2).
// System/Context/ContextMonitor implements it; controller tests use a fake.
// P3-5: Phase 3 additions from 001 §14.5 that need no Core/Browser types: `setHostsWithOverrides` and
// `currentAppIsGone`.
// P3-14: the tier-1 wiring (001 §14.5): `setSitePolicy` (AppController pushes it on every relevant change),
// `browserSupport` (session only, for Settings → Browsers & Sites, P3-15) and a DEBUG line about site reads.

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
    /// P3-14: which browsers to watch, and how (001 §14.5). Re-attaches or detaches the browser in front at once.
    func setSitePolicy(_ policy: SitePolicy)
    /// QA (P3-14): a browser in front that Kytkin just started watching again (Resume, turned on, Accessibility
    /// granted, site rules on) is held for its first site read (≤ 150 ms, the D4 site grace); the next Context brings
    /// it. SwitchController's Resume / turn-on re-apply waits for that Context instead of switching twice.
    var isAwaitingSite: Bool { get }
    /// P3-14: what the reads so far say about each browser (session only, D15).
    var browserSupport: BrowserSupportTracker { get }
    /// P3-14: one DEBUG line about the browser watch (engine, attach, update count, last page state and source).
    /// Never a host, a URL or a title.
    var siteDebug: String { get }
}
