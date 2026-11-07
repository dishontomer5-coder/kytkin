// P3-11: The web-area read strategy for Chromium (Chrome, Arc, Edge, Brave, …), WebKit (Safari, Orion) and
// unknown engines (001 §14.3.3; R3b §2–§4). The page address is the `AXURL` of the window's content `AXWebArea`.
//
// One read, after the reader's prelude (window W = AXMainWindow, never Chrome's popup focused window; focus class):
//   1. Focus is in a web area that belongs to W → read its AXURL. Before caching a walked-up web area that isn't
//      W's cached one, walk AXParent up from it until W: focus can sit in another window's web area (devtools,
//      picture-in-picture), whose `devtools://` page must not become W's address.
//   2. Else W's cached web area → AXURL. A stale handle (`invalidElement`) is dropped and the scan below runs at once.
//   3. Else scan W breadth-first (≤ 400 nodes, never into a web area, ≤ 1 full scan per window per 2 s unless the
//      window is new or its handles were dropped): take the web area holding focus, else the largest (R3b: Chrome
//      has 1728×871 and 1728×56); cache it.
//   4. Nothing → `.unknown` (the reader keeps the window's last site). Automation (P3-7, opt-in) covers a browser
//      that exposes no web area.
// `chrome:`, `about:`, `arc:`, `edge:` and every other non-web scheme come back from `SiteReader` as `.notWebPage`.
// A focused text field outside the page (the omnibox, a find bar) makes the page state `.editingAddress`, but the web
// area is still read: its site is the page's own, so it is kept (§14.3.3 Chromium step 5).
//
// Never read: any text field. The Chromium omnibox (D16: dynamic id, localized description) and, by Coordinator
// decision (plan.md, P3-6 QA), Safari's address field: Safari uses AXURL plus opt-in Automation only.
// WebKit is UNVERIFIED (Safari wasn't running in R3b; ⏳ P3-3 item 3), and `KnownBrowser.verified` stays false.
// Unknown engines (apps registered for https links, "best effort", owner decision) get the same web-area search.
// Address strings go straight from `url(of:)` into `SiteReader` and are never kept (§14.3.6).

struct WebAreaReadStrategy<Tree: AXNodeReading>: BrowserReadStrategy {
    /// How far up a walked-up web area may be from its window. Parent calls only (no role reads); Chrome's content
    /// web area is 8 below its window (R3b), Arc's 3.
    static var ownerWalkSteps: Int { 32 }

    let engine: BrowserEngine

    init(engine: BrowserEngine) {
        self.engine = engine
    }

    func read(_ tree: Tree, prelude: BrowserReadPrelude<Tree.Node>, window: inout BrowserWindowState<Tree.Node>,
              siteReader: SiteReader, now: UInt64) throws(AXReadError) -> BrowserReadOutcome {
        let editing = prelude.focusClass == .editing

        // 1. Focus in a web area of this window.
        if let focusArea = prelude.webAreaFromFocus {
            var owned = window.webArea.map { tree.isSame($0, focusArea) } ?? false
            if !owned { owned = try Self.belongs(focusArea, to: prelude.window, tree: tree) }
            if owned {
                window.webArea = focusArea
                return try Self.readURL(of: focusArea, tree: tree, siteReader: siteReader, editing: editing)
            }
        }

        // 2. The window's cached web area.
        if let cached = window.webArea {
            do {
                return try Self.readURL(of: cached, tree: tree, siteReader: siteReader, editing: editing)
            } catch {
                guard error == .invalidElement else { throw error }
                window.dropHandles()   // the tab closed or the page was replaced: rescan now
            }
        }

        // 3. A bounded scan of the window.
        guard window.mayFullScan(now: now) else { return Self.nothing(editing) }
        window.lastFullScanAt = now
        guard let found = try Self.scan(prelude.window, focusArea: prelude.webAreaFromFocus, tree: tree) else {
            return Self.nothing(editing)
        }
        window.webArea = found
        return try Self.readURL(of: found, tree: tree, siteReader: siteReader, editing: editing)
    }

    // MARK: - Steps

    private static func nothing(_ editing: Bool) -> BrowserReadOutcome {
        editing ? .editingKept : .unknown
    }

    private static func readURL(of webArea: Tree.Node, tree: Tree, siteReader: SiteReader,
                                editing: Bool) throws(AXReadError) -> BrowserReadOutcome {
        // The URL string never outlives this expression (§14.3.6).
        guard let read = try tree.url(of: webArea).map({ siteReader.read($0, from: .axURL) }) else {
            return nothing(editing)   // no AXURL (still loading): can't tell
        }
        return BrowserReadOutcome(read: read, via: .axURL, editing: editing)
    }

    /// Does `webArea` sit inside `window`? Walks AXParent up, comparing with `isSame` (no AX call).
    static func belongs(_ webArea: Tree.Node, to window: Tree.Node, tree: Tree) throws(AXReadError) -> Bool {
        var node = try tree.parent(of: webArea)
        var steps = 1
        while let n = node {
            if tree.isSame(n, window) { return true }
            guard steps < ownerWalkSteps else { return false }
            node = try tree.parent(of: n)
            steps += 1
        }
        return false
    }

    /// Breadth-first over `window` (≤ 400 nodes, never into a web area). The web area holding focus, else the
    /// largest by AXSize (ties: the first found).
    static func scan(_ window: Tree.Node, focusArea: Tree.Node?, tree: Tree) throws(AXReadError) -> Tree.Node? {
        var webAreas: [Tree.Node] = []
        try AXTreeScan.breadthFirst(tree, from: window) { (n: Tree.Node) throws(AXReadError) -> AXTreeScan.Step in
            guard try tree.string(.role, of: n) == AXRoleName.webArea else { return .descend }
            webAreas.append(n)
            return .skipChildren
        }
        if let focusArea, let hit = webAreas.first(where: { tree.isSame($0, focusArea) }) { return hit }
        guard webAreas.count > 1 else { return webAreas.first }
        var best: (node: Tree.Node, area: Double)?
        for area in webAreas {
            let size = try tree.area(of: area) ?? 0
            if best == nil || size > best!.area { best = (area, size) }
        }
        return best?.node
    }
}
