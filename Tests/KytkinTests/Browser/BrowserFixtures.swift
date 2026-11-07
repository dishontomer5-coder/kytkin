// P3-6: Fake trees shaped like the R3b dumps (docs/research/browser-domain-r3b.md, 001 §14.3.2). Structure only:
// roles, subroles, ids, depths, sizes and which links are missing. Addresses are example domains or browser-internal
// pages, never anything real. P3-11 and P3-13 test their strategies against these; P3-17 updates them after the
// owner's P3-3 round.

enum BrowserFixtures {
    // MARK: Zen (Gecko) [V]

    struct Zen {
        let tree: FakeAXTree
        let app: Int
        let window: Int
        let urlbar: Int          // AXComboBox, AXDOMIdentifier "urlbar-input", depth 6
        let tabPanel: Int        // NOT in its parent's AXChildren
        let webArea: Int         // has AXURL; reachable only by AXParent from focus
        let sidebarTab: Int      // a tab button in the sidebar's AXTabGroup
    }

    enum ZenFocus { case page, urlbar, sidebar, none }

    /// Zen 1.24: `AXWindows` empty (the window isn't in the app's children), `AXMainWindow` and `AXFocusedWindow`
    /// both give the standard window; the content web area hangs under a tab panel its parent doesn't list.
    static func zen(focus: ZenFocus = .page, pageURL: String = "https://www.example.com/news/1",
                    urlbarValue: String = "www.example.com/news/1") -> Zen {
        let t = FakeAXTree()
        let app = t.add("AXApplication")
        let window = t.add("AXWindow", subrole: "AXStandardWindow", under: app, listed: false)
        // Toolbar route to the urlbar: window > toolbox > toolbar > group > group > group > combobox (depth 6).
        let toolbox = t.add("AXGroup", under: window)
        let toolbar = t.add("AXToolbar", under: toolbox)
        let g1 = t.add("AXGroup", under: toolbar)
        let g2 = t.add("AXGroup", under: g1)
        let g3 = t.add("AXGroup", under: g2)
        t.add("AXButton", under: g3, description: "back")
        let urlbar = t.add("AXComboBox", under: g3, domIdentifier: "urlbar-input", description: "Search or enter address",
                           value: urlbarValue, focused: focus == .urlbar)
        // Sidebar tab lists.
        let tabGroup = t.add("AXTabGroup", under: window)
        let sidebarTab = t.add("AXRadioButton", subrole: "AXTabButton", under: tabGroup)
        t.add("AXRadioButton", subrole: "AXTabButton", under: tabGroup)
        // Content: window > group > group > tab panel [unlisted] > scroll area > web area.
        let c1 = t.add("AXGroup", subrole: "AXUnknown", under: window)
        let c2 = t.add("AXGroup", subrole: "AXUnknown", under: c1)
        let tabPanel = t.add("AXGroup", subrole: "AXTabPanel", under: c2, listed: false)
        let scroll = t.add("AXScrollArea", subrole: "AXUnknown", under: tabPanel)
        let webArea = t.add("AXWebArea", under: scroll, domIdentifier: nil, url: pageURL, area: 1440 * 800)
        t.main = window
        t.focusedWin = window
        switch focus {
        case .page: t.focused = webArea
        case .urlbar: t.focused = urlbar
        case .sidebar: t.focused = sidebarTab
        case .none: t.focused = nil
        }
        return Zen(tree: t, app: app, window: window, urlbar: urlbar, tabPanel: tabPanel, webArea: webArea,
                   sidebarTab: sidebarTab)
    }

    // MARK: Chrome (Chromium) [V] structure

    struct Chrome {
        let tree: FakeAXTree
        let popup: Int           // AXWindow subrole AXUnknown: was AXFocusedWindow in R3b
        let window: Int          // the standard main window
        let omnibox: Int         // AXTextField, dynamic id "view_1012", localized description
        let bigWebArea: Int      // 1728×871, depth 8
        let smallWebArea: Int    // 1728×56, depth 8
        let pageButton: Int      // a button inside the big web area
    }

    /// Chrome 156 in R3b: two windows, the focused one a popup with no web area; the main window has two web areas
    /// at depth 8. Both showed `chrome://` pages that day; `pageURL` lets a test use an example domain (⏳ P3-3 item 2).
    static func chrome(pageURL: String = "chrome://newtab/", stripURL: String = "chrome://webui-toolbar/",
                       omniboxFocused: Bool = false, reportsMainWindow: Bool = true) -> Chrome {
        let t = FakeAXTree()
        let app = t.add("AXApplication")
        let popup = t.add("AXWindow", subrole: "AXUnknown", under: app)
        let dialog = t.add("AXGroup", subrole: "AXApplicationAlertDialog", under: popup)
        t.add("AXStaticText", under: dialog)
        let window = t.add("AXWindow", subrole: "AXStandardWindow", under: app)
        let root = t.add("AXGroup", under: window)
        let toolbar = t.add("AXToolbar", under: root)
        let omnibox = t.add("AXTextField", under: toolbar, domIdentifier: "view_1012",
                            description: "Address and search bar", value: "", focused: omniboxFocused)
        // window > g1 > g2 > g3 > g4 > g5 > g6 > g7 > web area (depth 8)
        var parent = root
        for _ in 0..<6 { parent = t.add("AXGroup", under: parent) }
        let big = t.add("AXWebArea", under: parent, url: pageURL, area: 1728 * 871)
        let pageButton = t.add("AXButton", under: t.add("AXGroup", under: big))
        let small = t.add("AXWebArea", under: parent, url: stripURL, area: 1728 * 56)
        t.main = reportsMainWindow ? window : nil
        t.focusedWin = popup
        t.focused = omniboxFocused ? omnibox : pageButton
        return Chrome(tree: t, popup: popup, window: window, omnibox: omnibox, bigWebArea: big, smallWebArea: small,
                      pageButton: pageButton)
    }

    // MARK: Arc (Chromium) [V]

    struct Arc {
        let tree: FakeAXTree
        let window: Int
        let webArea: Int         // depth 3, 1708×1063
        let focusedButton: Int   // AXButton < dialog group < group < group < web area
    }

    static func arc(pageURL: String = "https://example.org/docs") -> Arc {
        let t = FakeAXTree()
        let app = t.add("AXApplication")
        let window = t.add("AXWindow", subrole: "AXStandardWindow", under: app)
        let split = t.add("AXSplitGroup", under: window)
        let scroll = t.add("AXScrollArea", under: split)
        let webArea = t.add("AXWebArea", under: scroll, url: pageURL, area: 1708 * 1063)
        let g1 = t.add("AXGroup", under: webArea)
        let g2 = t.add("AXGroup", under: g1)
        let dialog = t.add("AXGroup", subrole: "AXApplicationDialog", under: g2)
        let button = t.add("AXButton", under: dialog)
        t.main = window
        t.focusedWin = window
        t.focused = button
        return Arc(tree: t, window: window, webArea: webArea, focusedButton: button)
    }

    // MARK: Safari (WebKit) [I], unverified until P3-3 item 3

    struct Safari {
        let tree: FakeAXTree
        let window: Int
        let addressField: Int    // AXTextField, AXIdentifier WEB_BROWSER_ADDRESS_AND_SEARCH_FIELD (shows the host)
        let webArea: Int
    }

    /// Presumed like Chromium (R3), plus the address field.
    static func safari(pageURL: String = "https://example.net/path", fieldValue: String = "example.net",
                       fieldFocused: Bool = false) -> Safari {
        let t = FakeAXTree()
        let app = t.add("AXApplication")
        let window = t.add("AXWindow", subrole: "AXStandardWindow", under: app)
        let toolbar = t.add("AXToolbar", under: window)
        let field = t.add("AXTextField", under: toolbar, identifier: "WEB_BROWSER_ADDRESS_AND_SEARCH_FIELD",
                          value: fieldValue, focused: fieldFocused)
        let tabs = t.add("AXGroup", under: window)
        let scroll = t.add("AXScrollArea", under: tabs)
        let webArea = t.add("AXWebArea", under: scroll, url: pageURL, area: 1280 * 720)
        t.main = window
        t.focusedWin = window
        t.focused = fieldFocused ? field : webArea
        return Safari(tree: t, window: window, addressField: field, webArea: webArea)
    }
}
