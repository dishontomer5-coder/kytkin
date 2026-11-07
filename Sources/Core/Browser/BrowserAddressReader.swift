// P3-6: The frame every per-engine read plugs into (001 §14.2, §14.3.3). P3-6 builds the common prelude, the
// per-window cache, the private-window gate (D12), the timeout latch and the "kept site" rule; the engine strategies
// (which element holds the address) come in P3-11 (Chromium, WebKit, unknown) and P3-13 (Gecko), and the
// private-window probes in P3-16. Until then every engine uses `UnsupportedEngineStrategy` (always `.unknown`).
//
// One read:
//   1. F = the app's focused element. W = its main window; else the focused window, only if its subrole is
//      AXStandardWindow (Chrome's focused window can be a popup, R3b). No window → `.unknown`, sawWindow = false.
//   2. Focus class: walk AXParent up from F (F itself, then ≤ 16 parents). An AXWebArea → in page (Zen's web area is
//      reachable only this way). Else F's role is a text field, combo box, search field or text area → editing (an
//      address bar, a find bar). Else other.
//   3. The window's cache entry (≤ 8 windows, most recent first, matched with `isSame`).
//   4. The private flag, probed once per window (re-checked after `noteTrigger` of a window or title change). If it's
//      true and the user ignores private windows → `(nil, .unknown, private)` without reading any address.
//   5. The strategy reads. A `.site`/`.notWebPage` updates the window's kept site; anything else reports the kept site.
// The first timeout stops the read (`LatchedAXTree`) → `.unknown` with the kept site. `invalidElement` drops the
// window's cached handles and allows one rescan.
// Kept sites are hosts in memory only and die with the reader (one reader per attach).

/// Limits shared by the reader and its strategies (B13). Not inside the generic reader: generic types can't have
/// stored statics.
enum BrowserReadLimits {
    static let cachedWindows = 8
    static let focusWalkSteps = 16
    static let scanNodes = 400
    /// At most one full scan per window per 2 s, unless the window changed (§14.3.3).
    static let fullScanIntervalNanos: UInt64 = 2_000_000_000
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
    /// The AXWebArea that contains F (set exactly when `focusClass == .inPage`).
    let webAreaFromFocus: Node?
}

/// One window's cache entry. The strategies fill `webArea`, `addressBar` and `lastFullScanAt`.
struct BrowserWindowState<Node> {
    let window: Node
    var webArea: Node?
    var addressBar: Node?
    /// The last site a `.page` read gave in this window (nil after `.notWebPage`).
    var lastSite: SiteAddress?
    /// nil = not probed yet; `.some(nil)` = probed, can't tell.
    var isPrivate: Bool??
    var lastFullScanAt: UInt64?

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
    }
}

/// What a strategy found. `read == nil` = nothing read (no web area, no bar, a focused bar that must not be read).
struct BrowserReadOutcome: Sendable, Equatable {
    var read: SiteRead?
    var via: BrowserObservation.Via
    /// A text field outside the page has focus: the page state is `.editingAddress` whatever was read.
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

/// Placeholder until P3-11/P3-13: reads nothing, always `.unknown` (editing while a text field has focus).
struct UnsupportedEngineStrategy<Tree: AXNodeReading>: BrowserReadStrategy {
    func read(_ tree: Tree, prelude: BrowserReadPrelude<Tree.Node>, window: inout BrowserWindowState<Tree.Node>,
              siteReader: SiteReader, now: UInt64) throws(AXReadError) -> BrowserReadOutcome {
        prelude.focusClass == .editing ? .editingKept : .unknown
    }
}

/// P3-16 plugs the per-engine private-window probes in here; it returns only a `Bool?` (§14.4).
typealias PrivateWindowProbe<Tree: AXNodeReading> = (Tree, Tree.Node) throws(AXReadError) -> Bool?

struct BrowserAddressReader<Tree: AXNodeReading> {
    typealias Latched = LatchedAXTree<Tree>

    let request: BrowserWatchRequest
    private let siteReader: SiteReader
    private let strategy: any BrowserReadStrategy<Latched>
    private let privateProbe: PrivateWindowProbe<Latched>
    /// Most recently read first.
    private(set) var windows: [BrowserWindowState<Tree.Node>] = []

    init(request: BrowserWatchRequest, siteReader: SiteReader) {
        self.init(request: request, siteReader: siteReader, strategy: Self.defaultStrategy(for: request.engine),
                  privateProbe: { (_: Latched, _: Tree.Node) throws(AXReadError) -> Bool? in nil })
    }

    init(request: BrowserWatchRequest, siteReader: SiteReader, strategy: any BrowserReadStrategy<Latched>,
         privateProbe: @escaping PrivateWindowProbe<Latched>) {
        self.request = request
        self.siteReader = siteReader
        self.strategy = strategy
        self.privateProbe = privateProbe
    }

    /// The strategy per engine. P3-11 and P3-13 replace their lines.
    static func defaultStrategy(for engine: BrowserEngine) -> any BrowserReadStrategy<Latched> {
        switch engine {
        case .chromium: UnsupportedEngineStrategy<Latched>()   // P3-11
        case .webkit: UnsupportedEngineStrategy<Latched>()     // P3-11
        case .unknown: UnsupportedEngineStrategy<Latched>()    // P3-11
        case .gecko: UnsupportedEngineStrategy<Latched>()      // P3-13
        }
    }

    /// A window or title change: re-check every cached window's private flag on its next read (§14.4).
    mutating func noteTrigger(_ t: BrowserTrigger) {
        switch t {
        case .focusedWindowChanged, .mainWindowChanged, .titleChanged, .attached, .wake:
            for i in windows.indices { windows[i].isPrivate = nil }
        case .focusedElementChanged, .loadComplete, .addressValueChanged:
            break
        }
    }

    mutating func read(_ tree: Tree, now: UInt64) -> (observation: BrowserObservation, sawWindow: Bool) {
        let latched = LatchedAXTree(tree, latch: AXReadLatch())
        var sawWindow = false
        do {
            let o = try readThrowing(latched, now: now, sawWindow: &sawWindow)
            return (o, sawWindow)
        } catch {
            guard sawWindow, !windows.isEmpty else { return (.unknown(), sawWindow) }
            if error == .invalidElement { windows[0].dropHandles() }
            let isPrivate = windows[0].isPrivate ?? request.privateFlag(probed: nil)
            return (.unknown(kept: windows[0].lastSite, isPrivate: isPrivate), sawWindow)
        }
    }

    // MARK: - Prelude

    private mutating func readThrowing(_ tree: Latched, now: UInt64,
                                       sawWindow: inout Bool) throws(AXReadError) -> BrowserObservation {
        let focused = try tree.focusedElement()
        guard let window = try Self.pickWindow(tree) else { return .unknown() }
        sawWindow = true
        moveToFront(window, tree: tree)

        let (focusClass, webArea) = try Self.classifyFocus(focused, tree: tree)

        let isPrivate: Bool?
        if let cached = windows[0].isPrivate {
            isPrivate = cached
        } else if request.alwaysPrivate {
            isPrivate = true   // Tor Browser: no probe needed
            windows[0].isPrivate = .some(isPrivate)
        } else {
            isPrivate = try privateProbe(tree, window)   // P3-16's probe; nil until it lands
            windows[0].isPrivate = .some(isPrivate)
        }
        guard request.readsAddress(isPrivate: isPrivate) else {
            return BrowserObservation(site: nil, pageState: .unknown, isPrivate: true, via: .kept)   // D12: not read
        }

        let prelude = BrowserReadPrelude(focused: focused, window: window, focusClass: focusClass,
                                         webAreaFromFocus: webArea)
        let outcome = try strategy.read(tree, prelude: prelude, window: &windows[0], siteReader: siteReader, now: now)
        return Self.observation(from: outcome, window: &windows[0], isPrivate: isPrivate)
    }

    /// The main window; else the focused window when it's a standard window (not Chrome's popup).
    static func pickWindow<T: AXNodeReading>(_ tree: T) throws(AXReadError) -> T.Node? {
        if let main = try tree.mainWindow() { return main }
        guard let focused = try tree.focusedWindow(),
              try tree.string(.subrole, of: focused) == AXRoleName.standardWindow else { return nil }
        return focused
    }

    static func classifyFocus<T: AXNodeReading>(_ focused: T.Node?,
                                                tree: T) throws(AXReadError) -> (FocusClass, T.Node?) {
        guard let focused else { return (.other, nil) }
        var node: T.Node? = focused
        var steps = 0
        while let n = node, steps <= BrowserReadLimits.focusWalkSteps {
            if try tree.string(.role, of: n) == AXRoleName.webArea { return (.inPage, n) }
            node = try tree.parent(of: n)
            steps += 1
        }
        if let role = try tree.string(.role, of: focused), AXRoleName.editing.contains(role) { return (.editing, nil) }
        return (.other, nil)
    }

    private static func observation(from outcome: BrowserReadOutcome, window: inout BrowserWindowState<Tree.Node>,
                                    isPrivate: Bool?) -> BrowserObservation {
        switch outcome.read {
        case .site(let site):
            window.lastSite = site
            return BrowserObservation(site: site, pageState: outcome.editing ? .editingAddress : .page,
                                      isPrivate: isPrivate, via: outcome.via)
        case .notWebPage:
            window.lastSite = nil
            return BrowserObservation(site: nil, pageState: outcome.editing ? .editingAddress : .notWebPage,
                                      isPrivate: isPrivate, via: outcome.via)
        case .unreadable, nil:
            return BrowserObservation(site: window.lastSite, pageState: outcome.editing ? .editingAddress : .unknown,
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
