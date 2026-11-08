// P3-6: The frame every per-engine read plugs into (001 §14.2, §14.3.3): the common prelude, the per-window cache,
// the private-window gate (D12), the timeout latch and the "kept site" rule. The engine strategies (which element
// holds the address) are `WebAreaReadStrategy` (P3-11: Chromium, WebKit, unknown) and `GeckoReadStrategy` (P3-13).
// P3-16: the private-window probes per engine are `PrivateWindowProbes`, picked by `request.privateSignal`.
//
// One read:
//   1. F = the app's focused element. W = its main window; else the focused window, only if its subrole is
//      AXStandardWindow (Chrome's focused window can be a popup, R3b). No window → `.unknown`, sawWindow = false.
//   2. Focus class: walk AXParent up from F (F itself, then ≤ 40 parents, stopping at W). An AXWebArea → in page,
//      and the outermost one found is the page (an iframe's own web area isn't; Zen's web area is reachable only
//      this way). Else F's role is a text field, combo box, search field or text area → editing (an address bar,
//      a find bar). Else other.
//   3. The window's cache entry (≤ 8 windows, most recent first, matched with `isSame`).
//   4. The private flag, probed once per window (re-checked after `noteTrigger` of a window change or attach; a title
//      change re-checks only a window whose probe couldn't tell, since a window can't become private later, and only
//      while it has had fewer than `titleRecheckProbes` probes: QA P3-16). If it's
//      true and the user ignores private windows → `(nil, .unknown, private)` without reading any address.
//      Precedence (P3-16): the AX probe's answer wins when non-nil; else the P3-7 Apple Event flag.
//   5. The strategy reads. A `.site`/`.notWebPage` updates the window's kept site; anything else reports the kept site.
// The first timeout stops the read (`LatchedAXTree`) → `.unknown` with the kept site. `invalidElement` drops the
// window's cached handles and allows one rescan.
// P3-7 (001 §14.7, D9): with an opted-in, granted browser (`appleEvents` set by the engine), step 4 asks the window's
// private flag by Apple Event once per window when the AX probe gave nil (Chromium/Arc), and a read that ends
// `.unknown` with a window (step 5, or an AX timeout) asks for the address by Apple Event. ≤ 1 send per second:
// a send the rate limit holds back sets `appleEventRetryAt`, and the engine reads again then.
// Kept sites are hosts in memory only and die with the reader (one reader per attach).
// P3-31: when a read ends "editing" (focus in a text field outside the page), the request's `AddressBarClassifier`
// says whether that field is the real address bar (`.editingAddress`, the browser's language) or another field such
// as the Find box (`.editingBrowserField`, the site's language). Unknown → `.editingAddress` (P3-29). The answer is
// cached per window for the focused element, so it costs at most one id read per focus change; a failed read
// (timeout, element gone) gives `.unknown` for this read only and isn't cached.

/// Limits shared by the reader and its strategies (B13). Not inside the generic reader: generic types can't have
/// stored statics.
enum BrowserReadLimits {
    static let cachedWindows = 8
    /// Parents walked up from the focused element (QA P3-11/P3-13: was 16, which made a text field deep in a real
    /// page, like a web-mail compose box, count as "editing" and blocked learning there). The walk ends at the
    /// window, so a shallow toolbar field costs only its own depth.
    static let focusWalkSteps = 40
    static let scanNodes = 400
    /// At most one full scan per window per 2 s, unless the window changed (§14.3.3).
    static let fullScanIntervalNanos: UInt64 = 2_000_000_000
    /// QA P3-16: a title change re-probes a window whose probe couldn't tell only while that window has had fewer
    /// than this many probes. The late-title case is a new window (its first one or two probes); without the cap a
    /// page that keeps changing its title (a ticker, an unread counter) re-ran the probe on every read, which in
    /// Safari is a toolbar scan of up to 80 nodes.
    static let titleRecheckProbes = 4
}

enum FocusClass: Sendable, Equatable {
    case inPage    // F is in an AXWebArea
    case editing   // F is a text field outside the page: never read it (D2)
    case other
}

/// What the common prelude found, for the strategy.
struct BrowserReadPrelude<Node> {
    let focused: Node?
    let window: Node
    let focusClass: FocusClass
    /// The outermost AXWebArea that contains F (set exactly when `focusClass == .inPage`).
    let webAreaFromFocus: Node?
    /// The focus walk proved `webAreaFromFocus` sits in `window` (it reached the window, or the window's known top
    /// web area). False also when the walk ran out of steps: the strategy may still check.
    let webAreaInWindow: Bool
}

/// The focus walk's result (prelude step 2).
struct FocusWalk<Node> {
    let focusClass: FocusClass
    let webArea: Node?
    let webAreaInWindow: Bool
    /// QA (P3-31): the focused element's role, from the walk's first step (no extra AX call); set for `.editing`.
    var focusedRole: String? = nil
}

/// One window's cache entry. The strategies fill `webArea`, `addressBar` and `lastFullScanAt`.
struct BrowserWindowState<Node> {
    let window: Node
    /// A top-level web area of this window (never an iframe's): set by the prelude when the focus walk proves it,
    /// and by `WebAreaReadStrategy`. Gecko uses it only as the focus walk's stop point.
    var webArea: Node?
    var addressBar: Node?
    /// The last site a `.page` read gave in this window (nil after `.notWebPage`).
    var lastSite: SiteAddress?
    /// nil = not probed yet; `.some(nil)` = probed, can't tell.
    var isPrivate: Bool??
    /// QA P3-16: how many times the private-window probe ran for this window (gates the title-change re-check).
    var privateProbes = 0
    var lastFullScanAt: UInt64?
    /// P3-7: the private flag an Apple Event gave for this window (nil = not asked yet; `.some(nil)` = asked, can't
    /// tell). A window's private mode can't change, so it is asked once per window and kept for the attach.
    var appleEventPrivate: Bool??
    /// P3-31: the address-bar verdict for the last focused field outside the page (matched with `isSame`), so the
    /// classifier runs once per focus change. Only definite answers and "can't tell by design" are kept, never a
    /// verdict a failed read gave.
    var fieldVerdict: (field: Node, verdict: AddressBarVerdict)?
    /// P3-7: the page state the last Apple Event address gave in this window (`.page` / `.notWebPage`) while AX keeps
    /// answering `.unknown`. A read the rate limit kept from sending reports it, so one held-back send doesn't flip
    /// the page to `.unknown` and back (D5: that would cancel a learning candidate). Cleared by any AX answer.
    var appleEventState: BrowserPageState?

    init(window: Node) {
        self.window = window
    }

    /// May a full scan run now? (≤ 1 per window per 2 s.)
    func mayFullScan(now: UInt64) -> Bool {
        guard let last = lastFullScanAt else { return true }
        return now >= last + BrowserReadLimits.fullScanIntervalNanos
    }

    /// After `invalidElement`: forget the handles and allow one rescan.
    mutating func dropHandles() {
        webArea = nil
        addressBar = nil
        lastFullScanAt = nil
        fieldVerdict = nil
    }
}

/// What a strategy found. `read == nil` = nothing read (no web area, no bar, a focused bar that must not be read).
struct BrowserReadOutcome: Sendable, Equatable {
    var read: SiteRead?
    var via: BrowserObservation.Via
    /// A text field outside the page has focus: the page state is `.editingAddress` (or, P3-31, `.editingBrowserField`
    /// for a field known not to be the bar) whatever was read.
    var editing: Bool

    init(read: SiteRead?, via: BrowserObservation.Via, editing: Bool = false) {
        self.read = read
        self.via = via
        self.editing = editing
    }

    static let unknown = BrowserReadOutcome(read: nil, via: .kept)
    static let editingKept = BrowserReadOutcome(read: nil, via: .kept, editing: true)
}

/// One engine's way to find the address (P3-11, P3-13). Reads go through the latched tree: the first timeout ends
/// the read. A strategy hands address strings straight to `siteReader` and keeps nothing else (§14.3.6).
protocol BrowserReadStrategy<Tree> {
    associatedtype Tree: AXNodeReading
    func read(_ tree: Tree, prelude: BrowserReadPrelude<Tree.Node>, window: inout BrowserWindowState<Tree.Node>,
              siteReader: SiteReader, now: UInt64) throws(AXReadError) -> BrowserReadOutcome
}

/// P3-16: the per-engine private-window probe (`PrivateWindowProbes`); it returns only a `Bool?` (§14.4).
typealias PrivateWindowProbe<Tree: AXNodeReading> = (Tree, Tree.Node) throws(AXReadError) -> Bool?

struct BrowserAddressReader<Tree: AXNodeReading> {
    typealias Latched = LatchedAXTree<Tree>

    let request: BrowserWatchRequest
    private let siteReader: SiteReader
    private let strategy: any BrowserReadStrategy<Latched>
    private let privateProbe: PrivateWindowProbe<Latched>
    /// Most recently read first.
    private(set) var windows: [BrowserWindowState<Tree.Node>] = []
    /// P3-10: with a clock, a read also stops once it has run for `AXReadLatch.readBudgetNanos` (B13: a slow browser
    /// that answers each call just under the 0.25 s timeout). The AX thread sets it; nil = first-timeout rule only.
    var deadlineClock: (any Clock)?
    /// P3-31: tells the real address bar from the Find box (from `request.addressBarSignal`; tests may swap it).
    var addressBarClassifier: AddressBarClassifier
    /// P3-7: set by the engine only when `request.appleScript != nil` (opted in, granted, Kytkin on). nil = no Apple
    /// Events from this reader at all.
    var appleEvents: AppleEventSession?
    /// P3-7: a wanted Apple Event was held back by the rate limit; read again at this time (the engine takes it).
    private(set) var appleEventRetryAt: UInt64?

    init(request: BrowserWatchRequest, siteReader: SiteReader) {
        self.init(request: request, siteReader: siteReader, strategy: Self.defaultStrategy(for: request.engine),
                  privateProbe: { [signal = request.privateSignal] (t: Latched, w: Tree.Node) throws(AXReadError) -> Bool? in
                      try PrivateWindowProbes.isPrivate(signal, tree: t, window: w)   // P3-16
                  })
    }

    init(request: BrowserWatchRequest, siteReader: SiteReader, strategy: any BrowserReadStrategy<Latched>,
         privateProbe: @escaping PrivateWindowProbe<Latched>) {
        self.request = request
        addressBarClassifier = AddressBarClassifier(signal: request.addressBarSignal)
        self.siteReader = siteReader
        self.strategy = strategy
        self.privateProbe = privateProbe
    }

    /// The strategy per engine: the web-area search (P3-11) or the Gecko walk + address bar (P3-13).
    static func defaultStrategy(for engine: BrowserEngine) -> any BrowserReadStrategy<Latched> {
        switch engine {
        case .chromium: WebAreaReadStrategy<Latched>(engine: .chromium)   // P3-11
        case .webkit: WebAreaReadStrategy<Latched>(engine: .webkit)       // P3-11: unverified, no address field
        case .unknown: WebAreaReadStrategy<Latched>(engine: .unknown)     // P3-11: best effort
        case .gecko: GeckoReadStrategy<Latched>()                         // P3-13
        }
    }

    /// A window change: re-check every cached window's private flag on its next read (§14.4). P3-16: a title change
    /// re-checks only windows whose probe couldn't tell (a window can't become private later, but a new Chrome window
    /// may not have its title yet); a `true` stays.
    mutating func noteTrigger(_ t: BrowserTrigger) {
        switch t {
        case .focusedWindowChanged, .mainWindowChanged, .attached, .wake:
            for i in windows.indices { windows[i].isPrivate = nil }
        case .titleChanged:
            // QA P3-16: only while the window is new (fewer than `titleRecheckProbes` probes), so a page whose title
            // keeps changing can't re-run the probe on every read.
            for i in windows.indices where windows[i].isPrivate == .some(nil)
                && windows[i].privateProbes < BrowserReadLimits.titleRecheckProbes {
                windows[i].isPrivate = nil
            }
        case .focusedElementChanged, .loadComplete, .addressValueChanged:
            break
        }
    }

    mutating func read(_ tree: Tree, now: UInt64) -> (observation: BrowserObservation, sawWindow: Bool) {
        let latch = deadlineClock.map { AXReadLatch(clock: $0, startedAt: now) } ?? AXReadLatch()
        let latched = LatchedAXTree(tree, latch: latch)
        var sawWindow = false
        do {
            let o = try readThrowing(latched, now: now, sawWindow: &sawWindow)
            return (o, sawWindow)
        } catch {
            guard sawWindow, !windows.isEmpty else { return (.unknown(), sawWindow) }
            if error == .invalidElement { windows[0].dropHandles() }
            let probed: Bool? = (windows[0].isPrivate ?? nil) ?? (windows[0].appleEventPrivate ?? nil)
            let isPrivate = request.privateFlag(probed: probed)
            let kept = BrowserObservation.unknown(kept: windows[0].lastSite, isPrivate: isPrivate)
            // P3-7: an AX timeout with a window is "couldn't tell" too (§14.7 rule 1); not in an ignored private
            // window (D12).
            guard request.readsAddress(isPrivate: isPrivate) else { return (kept, sawWindow) }
            return (appleEventAddress(after: kept, now: now), sawWindow)
        }
    }

    /// P3-7: the engine takes the retry time after each read (nil = none wanted).
    mutating func takeAppleEventRetry() -> UInt64? {
        defer { appleEventRetryAt = nil }
        return appleEventRetryAt
    }

    // MARK: - Prelude

    private mutating func readThrowing(_ tree: Latched, now: UInt64,
                                       sawWindow: inout Bool) throws(AXReadError) -> BrowserObservation {
        let focused = try tree.focusedElement()
        guard let window = try Self.pickWindow(tree) else { return .unknown() }
        sawWindow = true
        moveToFront(window, tree: tree)

        let walk = try Self.walkFocus(focused, window: window, knownTopWebArea: windows[0].webArea, tree: tree)
        if walk.webAreaInWindow, let top = walk.webArea {
            windows[0].webArea = top   // a top-level web area of this window: the next walk may stop at it
        }

        var isPrivate: Bool?
        if let cached = windows[0].isPrivate {
            isPrivate = cached
        } else if request.alwaysPrivate {
            isPrivate = true   // Tor Browser: no probe needed
            windows[0].isPrivate = .some(isPrivate)
        } else {
            windows[0].privateProbes += 1
            isPrivate = try privateProbe(tree, window)   // P3-16: true or nil; the title never leaves the probe
            windows[0].isPrivate = .some(isPrivate)
        }
        if isPrivate == nil { isPrivate = appleEventPrivateFlag(now: now) }   // P3-7: only when AX can't tell
        guard request.readsAddress(isPrivate: isPrivate) else {
            // D12: not read. P3-29: the focus class is still told (no address involved), so the address bar of an
            // ignored private window also gets the browser's language.
            // P3-31: and a Find box there keeps the site's (here: no site, the app's) language.
            let state: BrowserPageState = walk.focusClass == .editing
                ? Self.editingState(fieldVerdict(focused, role: walk.focusedRole, tree: tree)) : .unknown
            return BrowserObservation(site: nil, pageState: state, isPrivate: true, via: .kept)
        }

        let prelude = BrowserReadPrelude(focused: focused, window: window, focusClass: walk.focusClass,
                                         webAreaFromFocus: walk.webArea, webAreaInWindow: walk.webAreaInWindow)
        let outcome = try strategy.read(tree, prelude: prelude, window: &windows[0], siteReader: siteReader, now: now)
        let verdict: AddressBarVerdict = outcome.editing
            ? fieldVerdict(focused, role: walk.focusedRole, tree: tree) : .unknown
        let observation = Self.observation(from: outcome, window: &windows[0], isPrivate: isPrivate,
                                           editingState: Self.editingState(verdict))
        switch observation.pageState {
        case .page, .notWebPage: windows[0].appleEventState = nil   // AX answered: it wins
        case .editingAddress, .editingBrowserField: return observation   // never an Apple Event while editing (D2)
        case .unknown: break
        }
        return appleEventAddress(after: observation, now: now)
    }

    // MARK: - Address bar or another field (P3-31)

    /// P3-31: the page state for "a text field outside the page has focus". Only a field known not to be the bar is
    /// `.editingBrowserField`; unknown stays `.editingAddress` (P3-29).
    static func editingState(_ verdict: AddressBarVerdict) -> BrowserPageState {
        verdict == .otherField ? .editingBrowserField : .editingAddress
    }

    /// P3-31: the classifier's answer for `focused` in `windows[0]`, cached per focused element. A failed AX call
    /// (timeout, element gone) → `.unknown` for this read, not cached; the observation itself still stands.
    /// QA (P3-31): a cached `.unknown` (a Gecko id-less combo box seen before the window's bar was known) is asked
    /// again once the bar is known, so a bar found later (by a scan, or by focusing it) can't leave it stale.
    private mutating func fieldVerdict(_ focused: Tree.Node?, role: String?, tree: Latched) -> AddressBarVerdict {
        guard let focused, addressBarClassifier.isActive else { return .unknown }
        if let cached = windows[0].fieldVerdict, tree.isSame(cached.field, focused),
           !(cached.verdict == .unknown && windows[0].addressBar != nil) {
            return cached.verdict
        }
        do {
            let verdict = try addressBarClassifier.classify(focused, role: role, window: &windows[0], tree: tree)
            windows[0].fieldVerdict = (focused, verdict)
            return verdict
        } catch {
            windows[0].fieldVerdict = nil
            return .unknown
        }
    }

    // MARK: - Apple Events (P3-7, 001 §14.7)

    /// Rule 2: the window's private flag by Apple Event, once per window, when the AX probe gave nil.
    private mutating func appleEventPrivateFlag(now: UInt64) -> Bool? {
        guard let session = appleEvents, session.dialect.hasPrivateFlag else { return nil }
        if let asked = windows[0].appleEventPrivate { return asked }
        switch session.readPrivateFlag(now: now) {
        case .answered(let flag):
            windows[0].appleEventPrivate = .some(flag)
            return flag
        case .notSent(let retryAt):
            noteRetry(retryAt)
            return nil
        }
    }

    /// Rule 1: the read couldn't tell (`.unknown`) and saw a window → ask for the address. The caller has checked
    /// that `windows[0]` may be read (D12) and isn't being edited (D2).
    private mutating func appleEventAddress(after observation: BrowserObservation,
                                            now: UInt64) -> BrowserObservation {
        guard let session = appleEvents,
              AppleEventFallback.wantsAddress(pageState: observation.pageState, sawWindow: true) else {
            return observation
        }
        let isPrivate = observation.isPrivate
        switch session.readAddress(siteReader: siteReader, now: now) {
        case .answered(.site(let site)):
            windows[0].lastSite = site
            windows[0].appleEventState = .page
            return BrowserObservation(site: site, pageState: .page, isPrivate: isPrivate, via: .appleEvent)
        case .answered(.notWebPage):
            windows[0].lastSite = nil
            windows[0].appleEventState = .notWebPage
            return BrowserObservation(site: nil, pageState: .notWebPage, isPrivate: isPrivate, via: .appleEvent)
        case .answered(.unreadable), .answered(nil):
            windows[0].appleEventState = nil
            return observation
        case .notSent(let retryAt):
            noteRetry(retryAt)
            // Held back by the rate limit: keep reporting what the last Apple Event said in this window.
            guard let state = windows[0].appleEventState else { return observation }
            return BrowserObservation(site: state == .page ? windows[0].lastSite : nil, pageState: state,
                                      isPrivate: isPrivate, via: .appleEvent)
        }
    }

    private mutating func noteRetry(_ at: UInt64?) {
        guard let at else { return }
        appleEventRetryAt = min(appleEventRetryAt ?? at, at)
    }

    /// The main window; else the focused window when it's a standard window (not Chrome's popup).
    static func pickWindow<T: AXNodeReading>(_ tree: T) throws(AXReadError) -> T.Node? {
        if let main = try tree.mainWindow() { return main }
        guard let focused = try tree.focusedWindow(),
              try tree.string(.subrole, of: focused) == AXRoleName.standardWindow else { return nil }
        return focused
    }

    static func classifyFocus<T: AXNodeReading>(_ focused: T.Node?, window: T.Node? = nil,
                                                tree: T) throws(AXReadError) -> (FocusClass, T.Node?) {
        let walk = try walkFocus(focused, window: window, knownTopWebArea: nil, tree: tree)
        return (walk.focusClass, walk.webArea)
    }

    /// QA (P3-11/P3-13 review): the walk keeps going past the first web area and returns the **outermost** one: an
    /// iframe has its own AXWebArea and AXURL (an ad, an embedded video, the `about:blank` frame many rich-text
    /// editors type into), and the page's address is the top document's. It ends (with `isSame`, no AX call) at
    /// `window`, since nothing above it is a page, or at `knownTopWebArea`, this window's web area from an earlier
    /// read that is known to be top-level, so a steady in-page read costs what it did before. Else at the top or
    /// after `focusWalkSteps` parents.
    static func walkFocus<T: AXNodeReading>(_ focused: T.Node?, window: T.Node?, knownTopWebArea: T.Node?,
                                            tree: T) throws(AXReadError) -> FocusWalk<T.Node> {
        guard let focused else { return FocusWalk(focusClass: .other, webArea: nil, webAreaInWindow: false) }
        var node: T.Node? = focused
        var steps = 0
        var outermost: T.Node?
        var inWindow = false
        var focusedRole: String?
        while let n = node, steps <= BrowserReadLimits.focusWalkSteps {
            if let window, tree.isSame(n, window) {
                inWindow = true
                break
            }
            if let top = knownTopWebArea, tree.isSame(n, top) {
                outermost = n
                inWindow = true
                break
            }
            let role = try tree.string(.role, of: n)
            if steps == 0 { focusedRole = role }
            if role == AXRoleName.webArea { outermost = n }
            node = try tree.parent(of: n)
            steps += 1
        }
        if let outermost { return FocusWalk(focusClass: .inPage, webArea: outermost, webAreaInWindow: inWindow) }
        // F's role from the walk's first step (nil only if F is the window itself: not a field).
        if let focusedRole, AXRoleName.editing.contains(focusedRole) {
            return FocusWalk(focusClass: .editing, webArea: nil, webAreaInWindow: false, focusedRole: focusedRole)
        }
        return FocusWalk(focusClass: .other, webArea: nil, webAreaInWindow: false)
    }

    /// `editingState`: P3-31, the state an editing outcome reports (`.editingAddress` or `.editingBrowserField`).
    private static func observation(from outcome: BrowserReadOutcome, window: inout BrowserWindowState<Tree.Node>,
                                    isPrivate: Bool?, editingState: BrowserPageState) -> BrowserObservation {
        switch outcome.read {
        case .site(let site):
            window.lastSite = site
            return BrowserObservation(site: site, pageState: outcome.editing ? editingState : .page,
                                      isPrivate: isPrivate, via: outcome.via)
        case .notWebPage:
            window.lastSite = nil
            return BrowserObservation(site: nil, pageState: outcome.editing ? editingState : .notWebPage,
                                      isPrivate: isPrivate, via: outcome.via)
        case .unreadable, nil:
            return BrowserObservation(site: window.lastSite, pageState: outcome.editing ? editingState : .unknown,
                                      isPrivate: isPrivate, via: .kept)
        }
    }

    private mutating func moveToFront(_ window: Tree.Node, tree: Latched) {
        if let i = windows.firstIndex(where: { tree.isSame($0.window, window) }) {
            if i != 0 { windows.insert(windows.remove(at: i), at: 0) }
        } else {
            windows.insert(BrowserWindowState(window: window), at: 0)
            if windows.count > BrowserReadLimits.cachedWindows { windows.removeLast() }
        }
    }
}

/// A bounded breadth-first walk for the strategies' full scans (≤ 400 nodes, B13).
enum AXTreeScan {
    enum Step: Sendable, Equatable {
        case descend       // visit this node's children too
        case skipChildren  // e.g. never descend into a web area
        case stop          // found it
    }

    /// Visits `root` and its descendants breadth-first, at most `limit` nodes. Returns how many were visited.
    @discardableResult
    static func breadthFirst<T: AXNodeReading>(_ tree: T, from root: T.Node, limit: Int = BrowserReadLimits.scanNodes,
                                               visit: (T.Node) throws(AXReadError) -> Step) throws(AXReadError) -> Int {
        var queue: [T.Node] = [root]
        var head = 0
        var visited = 0
        while head < queue.count, visited < limit {
            let node = queue[head]
            head += 1
            visited += 1
            switch try visit(node) {
            case .stop: return visited
            case .skipChildren: continue
            case .descend: queue.append(contentsOf: try tree.children(of: node))
            }
        }
        return visited
    }
}
