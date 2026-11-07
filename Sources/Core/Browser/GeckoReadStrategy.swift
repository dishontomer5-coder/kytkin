// P3-13: The Gecko (Zen, Firefox) read strategy (001 §14.3.3 "Gecko", R3b §1). Pure Core over `AXNodeReading`.
//
// Order:
//   1. The page's own address: the AXWebArea above the focused element → AXURL. The prelude walks 16 parents; Gecko
//      pages nest deeper than that (a field in a web mail compose box), so when the prelude found none this walk
//      goes on up to 30 parents. The web area is never cached: Zen doesn't list it under its parent, so the walk
//      from focus is the only way to it (R3b §1).
//   2. Else the window's `urlbar-input` (an AXComboBox), found once by a bounded scan of the main window and
//      cached per window. Its AXValue is read **only** when the bar isn't focused (D2): focused (or focus in any
//      text field outside the page) → `.editingAddress`, kept site, the value never asked for.
//   3. The value goes to `SiteReader` as `.geckoAddressBar`, the only source where scheme-less text counts.
//      Search terms, empty text → `.unknown` with the kept site, never "no site" (D10). `about:` → `.notWebPage`.
//   4. No web area and no bar (Zen compact mode hides the toolbar, focus in the sidebar) → `.unknown`, kept site.
// Never sets anything on the browser (no AXEnhancedUserInterface): `AXNodeReading` can't.

enum GeckoReadLimits {
    /// Parents walked up from the focused element to its AXWebArea (the prelude's 16, extended here).
    static let walkSteps = 30
    /// Firefox's DOM id for the address bar input; Zen keeps it (R3b §1, [V] for Zen).
    static let urlbarID = "urlbar-input"
    /// Last-resort match when no element has the id: a combo box / text field described like an address bar.
    /// Lowercased; descriptions are localized, so this is only a fallback.
    static let barDescriptionWords = ["search", "address"]
}

struct GeckoReadStrategy<Tree: AXNodeReading>: BrowserReadStrategy {
    func read(_ tree: Tree, prelude: BrowserReadPrelude<Tree.Node>, window: inout BrowserWindowState<Tree.Node>,
              siteReader: SiteReader, now: UInt64) throws(AXReadError) -> BrowserReadOutcome {
        // Focus on the cached bar: editing, nothing else to ask (isSame asks the browser nothing).
        if let focused = prelude.focused, let bar = window.addressBar, tree.isSame(focused, bar) { return .editingKept }

        // 1. The web area above the focus.
        var webArea = prelude.webAreaFromFocus
        if webArea == nil, let focused = prelude.focused {
            webArea = try Self.webAreaBeyondPrelude(from: focused, tree: tree)
        }
        if let webArea {
            if let url = try tree.url(of: webArea) {
                let read = siteReader.read(url, from: .axURL)
                if read != .unreadable { return BrowserReadOutcome(read: read, via: .axURL) }
            }
            // A web area without a usable AXURL (a page still loading): the bar may know. Focus is in the page, so
            // the bar isn't being edited, but its focus is still checked before its value is read.
        } else if prelude.focusClass == .editing {
            return .editingKept   // a text field outside the page: the bar or a find/search box (D2)
        }

        // 2. The address bar.
        let hadCachedBar = window.addressBar != nil
        guard let bar = try Self.locateBar(tree, window: &window, now: now) else { return .unknown }
        do {
            return try Self.readBar(bar, tree: tree, prelude: prelude, siteReader: siteReader)
        } catch {
            // A stale cached handle (tab strip rebuilt, window re-laid out): drop it and look once more now.
            guard error == .invalidElement, hadCachedBar else { throw error }
            window.dropHandles()
            guard let fresh = try Self.locateBar(tree, window: &window, now: now) else { return .unknown }
            return try Self.readBar(fresh, tree: tree, prelude: prelude, siteReader: siteReader)
        }
    }

    /// Continues the prelude's walk: ancestors 0…16 of `focused` were already checked (and weren't a web area),
    /// so only their parents are asked for, then roles from 17 up to `GeckoReadLimits.walkSteps`.
    static func webAreaBeyondPrelude(from focused: Tree.Node, tree: Tree) throws(AXReadError) -> Tree.Node? {
        var node: Tree.Node? = focused
        var steps = 0
        while let n = node, steps <= BrowserReadLimits.focusWalkSteps {
            node = try tree.parent(of: n)
            steps += 1
        }
        while let n = node, steps <= GeckoReadLimits.walkSteps {
            if try tree.string(.role, of: n) == AXRoleName.webArea { return n }
            node = try tree.parent(of: n)
            steps += 1
        }
        return nil
    }

    /// The window's cached bar; else one bounded scan for it (≤ 400 nodes, ≤ 1 per window per 2 s), cached.
    static func locateBar(_ tree: Tree, window: inout BrowserWindowState<Tree.Node>,
                          now: UInt64) throws(AXReadError) -> Tree.Node? {
        if let bar = window.addressBar { return bar }
        guard window.mayFullScan(now: now) else { return nil }
        window.lastFullScanAt = now
        let bar = try scanForBar(tree, from: window.window)
        window.addressBar = bar
        return bar
    }

    /// Breadth-first from the window. Per node: its role; for a combo box or text field also its DOM id, and (when
    /// the id isn't the urlbar's) its description for the fallback. Never descends into a web area or a field.
    static func scanForBar(_ tree: Tree, from window: Tree.Node) throws(AXReadError) -> Tree.Node? {
        var byID: Tree.Node?
        var byDescription: Tree.Node?
        try AXTreeScan.breadthFirst(tree, from: window) { (n: Tree.Node) throws(AXReadError) -> AXTreeScan.Step in
            let role = try tree.string(.role, of: n)
            if role == AXRoleName.webArea { return .skipChildren }
            guard role == AXRoleName.comboBox || role == AXRoleName.textField else { return .descend }
            if try tree.string(.domIdentifier, of: n) == GeckoReadLimits.urlbarID {
                byID = n
                return .stop
            }
            if byDescription == nil, let text = try tree.string(.description, of: n)?.lowercased(),
               GeckoReadLimits.barDescriptionWords.contains(where: { text.contains($0) }) {
                byDescription = n
            }
            return .skipChildren
        }
        return byID ?? byDescription
    }

    /// D2: the value is asked for only when the bar says it isn't focused (`false`, not nil).
    static func readBar(_ bar: Tree.Node, tree: Tree, prelude: BrowserReadPrelude<Tree.Node>,
                        siteReader: SiteReader) throws(AXReadError) -> BrowserReadOutcome {
        if let focused = prelude.focused, tree.isSame(focused, bar) { return .editingKept }
        switch try tree.isFocused(bar) {
        case .some(true): return .editingKept
        case nil: return .unknown   // can't tell whether the user is typing in it: don't read it
        case .some(false): break
        }
        guard let value = try tree.string(.value, of: bar) else { return .unknown }
        let read = siteReader.read(value, from: .geckoAddressBar)
        // D10: search terms or empty text say nothing about the page: unknown (kept site), not "no site".
        return read == .unreadable ? .unknown : BrowserReadOutcome(read: read, via: .addressBar)
    }
}
