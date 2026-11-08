// P3-16: The per-engine private-window probes (001 §14.4), from the owner's probe of normal vs private windows
// (2026-11-08, English macOS; `docs/research/r3b/p3-16-results/`). One probe runs per window (on attach and on a
// window change; again on a title change only while the answer is still "can't tell") inside the reader's latched
// read, so it shares the AX thread's timeout latch and read budget.
//
// Privacy (§14.3.6): a window title is read only here, compared, and dropped in the same function. It is never logged,
// stored, compared later or passed on: only `true` or nil leaves a probe.
//
// Answers: `true` = a private marker was found. nil = can't tell (no marker, or no signal for this browser). A probe
// never says `false`: a missing marker may be a language gap, and nil lets the P3-7 Apple Event flag answer instead
// (the reader asks it only when the probe gives nil). A false "private" only stops learning, so a title suffix is
// good enough; it is matched with "ends with", never "contains", because a page's own title can contain the word.
//
// Per browser (`PrivateWindowSignal`, set in `BrowserCatalog`):
// - Chromium family: the window's AXTitle ends with Chromium's IDS_ACCESSIBLE_INCOGNITO_WINDOW_TITLE_FORMAT suffix.
//   Owner probe: Chrome's private window title ends "(Incognito)"; normal windows don't.
// - Safari: the title ends "Private Browsing" (English only), else an element with AXIdentifier
//   `PrivacyReportShieldButton` (only in the private window in the owner's probe; identifiers aren't localized).
//   QA P3-16, known risk: Safari's View > Customize Toolbar offers a "Privacy Report" item. If a user adds it to the
//   normal toolbar it most likely carries the same identifier, and then every Safari window reads as private: nothing
//   is learned in Safari (and with "Don't use website rules in private windows" on, only Safari's app rule applies).
//   The menu shows `, private` on normal windows, so it's visible; checklist §P3-14 step 6 asks the owner to try it.
//   If it does match, the shield needs a second marker or goes (the English title then is the only signal).
//   The title is checked first: one call, and an English private window then needs no toolbar scan.
// - Arc: no AX signal. Its private window's AX tree is a window and one split group (no web area), so the site reads
//   `.unknown` and nothing is learned; only the P3-7 `incognito` Apple Event flag can tell. The probe makes no AX call.
// - Gecko (Zen, Firefox): no signal found yet at depth ≤ 3 (a deeper Zen probe is pending). This is the seam where
//   it will go. Tor Browser needs no probe (`alwaysPrivate`).

/// Which private-window check a browser gets (P3-16). Catalog data, not a user setting.
enum PrivateWindowSignal: Sendable, Equatable {
    case chromiumTitle   // the window title ends with Chromium's incognito suffix
    case safari          // the "Private Browsing" title suffix, else Safari's privacy shield button id
    case arc             // nothing in AX: the P3-7 Apple Event flag only
    case gecko           // P3-16: no signal yet (Zen probe pending): returns nil
    case none            // unknown browsers, other WebKit browsers (Orion)
}

enum PrivateWindowProbes {
    /// Chromium `chrome/app/generated_resources.grd`, IDS_ACCESSIBLE_INCOGNITO_WINDOW_TITLE_FORMAT = "$1 (Incognito)",
    /// and its Hebrew translation (same message, translation id 6751344591405861699) in
    /// `chrome/app/resources/generated_resources_iw.xtb` = "$1 (גלישה בסתר)" (chromium.googlesource.com, main,
    /// read 2026-11-08). Other languages: not included yet (a documented gap; the Apple Event flag covers it when
    /// Automation is on). Brave, Edge and Vivaldi rebrand the word and have no public string file checked here, so
    /// they match only if they keep Chromium's string.
    static let chromiumTitleSuffixes = ["(Incognito)", "(גלישה בסתר)"]
    /// Safari is closed source: only the English suffix the owner's probe saw.
    static let safariTitleSuffixes = ["Private Browsing"]
    /// Owner probe: present only in Safari's private window (a toolbar button at depth 2).
    static let safariShieldIdentifier = "PrivacyReportShieldButton"
    /// The shield search: breadth-first from the window, ≤ this depth (window = 0) and ≤ this many nodes.
    static let shieldScanDepth = 3
    static let shieldScanNodes = 80

    /// The probe for one window. Only `true` or nil leaves it.
    static func isPrivate<T: AXNodeReading>(_ signal: PrivateWindowSignal, tree: T,
                                            window: T.Node) throws(AXReadError) -> Bool? {
        switch signal {
        case .chromiumTitle:
            return try titleEnds(with: chromiumTitleSuffixes, tree: tree, window: window) ? true : nil
        case .safari:
            // QA P3-16: the title first (one AX call, and it can't match a normal window's toolbar), then the shield.
            if try titleEnds(with: safariTitleSuffixes, tree: tree, window: window) { return true }
            return try hasIdentifier(safariShieldIdentifier, tree: tree, window: window) ? true : nil
        case .arc, .gecko, .none:
            return nil   // no AX call: Arc → Apple Event only; Gecko → the pending Zen signal goes here
        }
    }

    /// Reads the window title, compares its end, and drops it. Trailing spaces and bidi marks are ignored (a Hebrew
    /// title may end with one).
    static func titleEnds<T: AXNodeReading>(with suffixes: [String], tree: T,
                                            window: T.Node) throws(AXReadError) -> Bool {
        guard let title = try tree.string(.title, of: window) else { return false }
        return endsWithAny(title, suffixes)
    }

    /// Pure helper for `titleEnds`: no AX, no copy kept.
    static func endsWithAny(_ text: String, _ suffixes: [String]) -> Bool {
        var end = text.unicodeScalars.endIndex
        let scalars = text.unicodeScalars
        while end > scalars.startIndex {
            let prev = scalars.index(before: end)
            guard ignorableTrailing(scalars[prev]) else { break }
            end = prev
        }
        let trimmed = String(scalars[scalars.startIndex..<end])
        return suffixes.contains { trimmed.hasSuffix($0) }
    }

    private static func ignorableTrailing(_ s: Unicode.Scalar) -> Bool {
        switch s.value {
        case 0x20, 0x09, 0xA0, 0x200E, 0x200F, 0x202A...0x202E, 0x2066...0x2069: true
        default: false
        }
    }

    /// A bounded breadth-first look for an element with this AXIdentifier (≤ `shieldScanDepth`, ≤ `shieldScanNodes`).
    /// Reads only identifiers and children; never descends below the depth limit, so it never walks into the page.
    static func hasIdentifier<T: AXNodeReading>(_ identifier: String, tree: T,
                                                window: T.Node) throws(AXReadError) -> Bool {
        var queue: [(node: T.Node, depth: Int)] = [(window, 0)]
        var head = 0
        while head < queue.count, head < shieldScanNodes {
            let (node, depth) = queue[head]
            head += 1
            if depth > 0, try tree.string(.identifier, of: node) == identifier { return true }
            if depth < shieldScanDepth {
                queue.append(contentsOf: try tree.children(of: node).map { ($0, depth + 1) })
            }
        }
        return false
    }
}
