// P3-13: The Gecko (Zen, Firefox) read strategy (001 §14.3.3 "Gecko", R3b §1). Pure Core over `AXNodeReading`.
//
// Order:
//   1. The page's own address: the AXWebArea the prelude found above the focused element → AXURL. (QA: the prelude
//      now walks 40 parents and takes the outermost web area, so a field deep in a page, e.g. a web-mail compose
//      box, is "in page", and this strategy no longer walks on by itself.) Zen doesn't list the web area under its
//      parent, so the walk from focus is the only way to it (R3b §1); the prelude keeps it in the window's cache
//      only as the point where the next walk may stop (`isSame`), and this strategy never reads it from there.
//   2. Else the window's `urlbar-input` (an AXComboBox), found once by a bounded scan of the main window and
//      cached per window. Its AXValue is read **only** when the bar isn't focused (D2): focused (or focus in any
//      text field outside the page) → `.editingAddress`, kept site, the value never asked for. Focus is checked
//      again right after the value read; if the bar took focus in between, the read is dropped.
//   3. The value goes to `SiteReader` as `.geckoAddressBar`, the only source where scheme-less text counts.
//      Search terms, empty text → `.unknown` with the kept site, never "no site" (D10). `about:` → `.notWebPage`.
//   4. No web area and no bar (Zen compact mode hides the toolbar, focus in the sidebar) → `.unknown`, kept site.
// Never sets anything on the browser (no AXEnhancedUserInterface): `AXNodeReading` can't.

enum GeckoReadLimits {
    /// Firefox's DOM id for the address bar input; Zen keeps it (R3b §1, [V] for Zen).
    static let urlbarID = "urlbar-input"
    /// Last-resort match when no element has the id: a **combo box** (Firefox's urlbar is one; its find bar and
    /// other search boxes are text fields holding the user's own text, QA) described like an address bar.
    /// Lowercased; descriptions are localized, so this is only a fallback.
    static let barDescriptionWords = ["search", "address"]
}

struct GeckoReadStrategy<Tree: AXNodeReading>: BrowserReadStrategy {
    func read(_ tree: Tree, prelude: BrowserReadPrelude<Tree.Node>, window: inout BrowserWindowState<Tree.Node>,
              siteReader: SiteReader, now: UInt64) throws(AXReadError) -> BrowserReadOutcome {
        // Focus on the cached bar: editing, nothing else to ask (isSame asks the browser nothing).
        if let focused = prelude.focused, let bar = window.addressBar, tree.isSame(focused, bar) { return .editingKept }

        // 1. The web area above the focus.
        if let webArea = prelude.webAreaFromFocus {
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

    /// Breadth-first from the window. Per node: its role; for a combo box or text field also its DOM id, and (for
    /// a combo box whose id isn't the urlbar's) its description for the fallback. Never descends into a web area
    /// or a field.
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
            if byDescription == nil, role == AXRoleName.comboBox,
               let text = try tree.string(.description, of: n)?.lowercased(),
               GeckoReadLimits.barDescriptionWords.contains(where: { text.contains($0) }) {
                byDescription = n
            }
            return .skipChildren
        }
        return byID ?? byDescription
    }

    /// D2: the value is asked for only when the bar says it isn't focused (`false`, not nil), and it counts only if
    /// the bar still isn't focused right after (QA: closes the gap between the check and the read; one more call).
    static func readBar(_ bar: Tree.Node, tree: Tree, prelude: BrowserReadPrelude<Tree.Node>,
                        siteReader: SiteReader) throws(AXReadError) -> BrowserReadOutcome {
        if let focused = prelude.focused, tree.isSame(focused, bar) { return .editingKept }
        switch try tree.isFocused(bar) {
        case .some(true): return .editingKept
        case nil: return .unknown   // can't tell whether the user is typing in it: don't read it
        case .some(false): break
        }
        // The string is reduced at once; only the SiteRead (a host) waits for the second focus check.
        guard let read = try tree.string(.value, of: bar).map({ siteReader.read($0, from: .geckoAddressBar) }) else {
            return .unknown
        }
        guard try tree.isFocused(bar) == false else { return .editingKept }
        // D10: search terms or empty text say nothing about the page: unknown (kept site), not "no site".
        return read == .unreadable ? .unknown : BrowserReadOutcome(read: read, via: .addressBar)
    }
}
