// P3-31 (owner decision 2026-11-08, plan.md P3-31): "Is the focused text field outside the page the real address
// bar?" Only the real bar gets the browser's language (P3-29); the Find box (⌘F) and other toolbar fields keep the
// site's language (`BrowserPageState.editingBrowserField`). Pure Core over `AXNodeReading`, one classifier per
// browser (`AddressBarSignal`, catalog data like `PrivateWindowSignal`).
//
// Answers: `.addressBar`, `.otherField`, or `.unknown`. Unknown keeps the P3-29 behaviour (the field counts as the
// bar), so a browser whose bar can't be told apart behaves exactly as before.
//
// Cost (B13): the reader asks only when a read finds focus in a text field outside the page, and caches the answer
// per window for that focused element (`isSame`, no AX call), so it costs at most one attribute read on the focused
// element per focus change, never a scan, and nothing at all while the user keeps typing in the same field.
// Privacy: only ids are read (AXDOMIdentifier, AXIdentifier, AXDOMClassList), never AXValue, a title or a description.
//
// Per browser:
// - Gecko (Zen, Firefox): the window's cached `urlbar-input` (`BrowserWindowState.addressBar`) compared with the focused
//   element (`isSame`, no AX call) → `.addressBar`. Otherwise one AXDOMIdentifier read on the focused element:
//   `urlbar-input` → `.addressBar` (and the bar is cached for the window); another id → `.otherField`; no id →
//   `.otherField` when the window's bar is known (it isn't this field) or the field isn't an AXComboBox (QA: the
//   Gecko bar is a combo box, by id (R3b §1) and by the description fallback alike, so an id-less text field such as
//   Firefox's find bar can't be it; the role comes from the focus walk, no extra AX call), else `.unknown` (an
//   id-less combo box before the bar is known: a Firefox fork's bar found only by description keeps P3-29).
// - Chromium (Chrome, Edge, Brave, …): the omnibox's AXDOMIdentifier is a dynamic `view_NNNN` (R3b D16), so the
//   only candidate is AXDOMClassList containing `OmniboxViewViews` (Chromium's omnibox view class). Wired, but OFF
//   (`chromiumOmniboxClassEnabled = false` → `.unknown`) until the owner's §P3-31 focus probe shows Chrome exposes it.
// - Safari: candidate AXIdentifier `WEB_BROWSER_ADDRESS_AND_SEARCH_FIELD` (the shape in the test fixtures). Wired,
//   but OFF (`safariAddressFieldIDEnabled = false` → `.unknown`) until the probe confirms it and shows the Find box
//   differs.
// - Arc, Orion, unknown browsers: `.none` → `.unknown` (Arc's command bar may not be told apart: plan.md P3-31).

/// Which "is this the address bar?" check a browser gets (P3-31). Catalog data, not a user setting.
enum AddressBarSignal: Sendable, Equatable {
    case geckoURLBar            // AXDOMIdentifier `urlbar-input` (cached by GeckoReadStrategy)
    case chromiumOmniboxClass   // AXDOMClassList contains `OmniboxViewViews` (gated, see below)
    case safariAddressField     // AXIdentifier `WEB_BROWSER_ADDRESS_AND_SEARCH_FIELD` (gated, see below)
    case none                   // can't tell: every field outside the page counts as the bar (P3-29)
}

/// What the classifier says about the focused text field outside the page.
enum AddressBarVerdict: Sendable, Equatable {
    case addressBar
    case otherField
    case unknown
}

struct AddressBarClassifier: Sendable, Equatable {
    /// P3-31: Chromium's omnibox view class (`OmniboxViewViews`), exposed by Chromium's views AX as AXDOMClassList.
    static let chromiumOmniboxClass = "OmniboxViewViews"
    /// P3-31: Safari's address field AXIdentifier (fixture shape; unverified on a real Safari).
    static let safariAddressFieldID = "WEB_BROWSER_ADDRESS_AND_SEARCH_FIELD"
    /// P3-31: OFF until the owner's §P3-31 focus probe confirms Chrome's omnibox has `OmniboxViewViews` in
    /// AXDOMClassList and its Find box doesn't. Off = `.unknown` with no AX call (P3-29 behaviour).
    static let chromiumOmniboxClassEnabled = false
    /// P3-31: OFF until the probe confirms Safari's address field id and that the Find box has another one.
    static let safariAddressFieldIDEnabled = false

    let signal: AddressBarSignal
    /// The gates, per instance so tests can exercise the wired path.
    let chromiumEnabled: Bool
    let safariEnabled: Bool

    init(signal: AddressBarSignal, chromiumEnabled: Bool = Self.chromiumOmniboxClassEnabled,
         safariEnabled: Bool = Self.safariAddressFieldIDEnabled) {
        self.signal = signal
        self.chromiumEnabled = chromiumEnabled
        self.safariEnabled = safariEnabled
    }

    /// Would `classify` ask the browser anything? False = always `.unknown` (no cache entry needed).
    var isActive: Bool {
        switch signal {
        case .geckoURLBar: true
        case .chromiumOmniboxClass: chromiumEnabled
        case .safariAddressField: safariEnabled
        case .none: false
        }
    }

    /// `focused` is a text field outside the page; `role` its AXRole as the focus walk read it (nil = not known).
    /// `window.addressBar` is the window's cached Gecko bar (nil if not found yet); a Gecko `urlbar-input` found here
    /// is cached into it. At most one AX call.
    func classify<T: AXNodeReading>(_ focused: T.Node, role: String? = nil, window: inout BrowserWindowState<T.Node>,
                                    tree: T) throws(AXReadError) -> AddressBarVerdict {
        switch signal {
        case .geckoURLBar:
            if let bar = window.addressBar, tree.isSame(focused, bar) { return .addressBar }
            switch try tree.string(.domIdentifier, of: focused) {
            case GeckoReadLimits.urlbarID?:
                window.addressBar = focused   // the real bar: cached for the window (a stale handle is replaced)
                return .addressBar
            case .some:
                return .otherField
            case nil:
                if window.addressBar != nil { return .otherField }
                return role == AXRoleName.comboBox || role == nil ? .unknown : .otherField
            }
        case .chromiumOmniboxClass:
            guard chromiumEnabled, let classes = try tree.strings(.domClassList, of: focused), !classes.isEmpty else {
                return .unknown
            }
            return classes.contains(Self.chromiumOmniboxClass) ? .addressBar : .otherField
        case .safariAddressField:
            guard safariEnabled, let id = try tree.string(.identifier, of: focused) else { return .unknown }
            return id == Self.safariAddressFieldID ? .addressBar : .otherField
        case .none:
            return .unknown
        }
    }
}
