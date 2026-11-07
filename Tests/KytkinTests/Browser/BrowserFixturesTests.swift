// P3-6: The fixtures really have the R3b shapes, checked through the same `AXTreeScan` and prelude helpers the
// strategies use. If a fixture drifts, the strategy tests built on it (P3-11, P3-13) would prove nothing.

import XCTest

final class BrowserFixturesTests: XCTestCase {
    private typealias Reader = BrowserAddressReader<FakeAXTree>

    private func scan(_ tree: FakeAXTree, from root: Int,
                      limit: Int = BrowserReadLimits.scanNodes) throws -> (webAreas: [Int], visited: Int, roles: [Int: String]) {
        var webAreas: [Int] = []
        var roles: [Int: String] = [:]
        let visited = try AXTreeScan.breadthFirst(tree, from: root, limit: limit) { (n: Int) throws(AXReadError) in
            let role = try tree.string(.role, of: n) ?? ""
            roles[n] = role
            if role == AXRoleName.webArea {
                webAreas.append(n)
                return .skipChildren
            }
            return .descend
        }
        return (webAreas, visited, roles)
    }

    private func depth(of node: Int, below root: Int, in tree: FakeAXTree) throws -> Int {
        var d = 0
        var n: Int? = node
        while let current = n, current != root {
            n = try tree.parent(of: current)
            d += 1
        }
        return d
    }

    func testZenWebAreaIsUnreachableTopDownButFoundFromFocus() throws {
        let zen = BrowserFixtures.zen()
        let result = try scan(zen.tree, from: zen.window)
        XCTAssertEqual(result.webAreas, [], "R3b: a BFS from the Zen window finds no web area")
        XCTAssertNil(result.roles[zen.tabPanel], "the tab panel isn't in its parent's children")
        XCTAssertFalse(try zen.tree.children(of: zen.app).contains(zen.window), "AXWindows is empty in Zen")
        XCTAssertEqual(zen.tree.main, zen.window)

        let (focusClass, webArea) = try Reader.classifyFocus(zen.tree.focused, tree: zen.tree)
        XCTAssertEqual(focusClass, .inPage)
        XCTAssertEqual(webArea, zen.webArea)
    }

    func testZenURLBarIsAComboBoxAtDepthSix() throws {
        let zen = BrowserFixtures.zen()
        var found: Int?
        try AXTreeScan.breadthFirst(zen.tree, from: zen.window) { (n: Int) throws(AXReadError) in
            if try zen.tree.string(.domIdentifier, of: n) == "urlbar-input" {
                found = n
                return .stop
            }
            return .descend
        }
        XCTAssertEqual(found, zen.urlbar)
        XCTAssertEqual(try zen.tree.string(.role, of: zen.urlbar), AXRoleName.comboBox)
        XCTAssertEqual(try depth(of: zen.urlbar, below: zen.window, in: zen.tree), 6)
        XCTAssertEqual(try zen.tree.isFocused(zen.urlbar), false)
    }

    func testZenFocusVariants() throws {
        let urlbar = BrowserFixtures.zen(focus: .urlbar)
        XCTAssertEqual(try Reader.classifyFocus(urlbar.tree.focused, tree: urlbar.tree).0, .editing)
        XCTAssertEqual(try urlbar.tree.isFocused(urlbar.urlbar), true)
        let sidebar = BrowserFixtures.zen(focus: .sidebar)
        XCTAssertEqual(try Reader.classifyFocus(sidebar.tree.focused, tree: sidebar.tree).0, .other)
        let none = BrowserFixtures.zen(focus: .none)
        XCTAssertEqual(try Reader.classifyFocus(none.tree.focused, tree: none.tree).0, .other)
    }

    func testChromeFocusedWindowIsAPopupAndMainHasTwoWebAreas() throws {
        let chrome = BrowserFixtures.chrome()
        XCTAssertEqual(try chrome.tree.string(.subrole, of: chrome.tree.focusedWin!), "AXUnknown")
        XCTAssertEqual(try scan(chrome.tree, from: chrome.popup).webAreas, [])
        let result = try scan(chrome.tree, from: chrome.window)
        XCTAssertEqual(Set(result.webAreas), [chrome.bigWebArea, chrome.smallWebArea])
        XCTAssertNil(result.roles[chrome.pageButton], "the scan never descends into a web area")
        XCTAssertEqual(try depth(of: chrome.bigWebArea, below: chrome.window, in: chrome.tree), 8)
        XCTAssertEqual(try chrome.tree.area(of: chrome.bigWebArea), 1728 * 871)
        XCTAssertEqual(try chrome.tree.area(of: chrome.smallWebArea), 1728 * 56)
        XCTAssertEqual(try chrome.tree.string(.role, of: chrome.omnibox), AXRoleName.textField)
        XCTAssertEqual(try Reader.pickWindow(chrome.tree), chrome.window)
    }

    func testChromeWithoutAMainWindowHasNoUsableWindow() throws {
        let chrome = BrowserFixtures.chrome(reportsMainWindow: false)
        XCTAssertNil(try Reader.pickWindow(chrome.tree), "a popup focused window is never used")
    }

    func testArcWebAreaAtDepthThreeAndFocusInside() throws {
        let arc = BrowserFixtures.arc()
        let result = try scan(arc.tree, from: arc.window)
        XCTAssertEqual(result.webAreas, [arc.webArea])
        XCTAssertEqual(result.visited, 4, "R3b: 4 nodes")
        XCTAssertEqual(try depth(of: arc.webArea, below: arc.window, in: arc.tree), 3)
        let (focusClass, webArea) = try Reader.classifyFocus(arc.focusedButton, tree: arc.tree)
        XCTAssertEqual(focusClass, .inPage)
        XCTAssertEqual(webArea, arc.webArea)
    }

    func testSafariFieldAndWebArea() throws {
        let safari = BrowserFixtures.safari()
        XCTAssertEqual(try scan(safari.tree, from: safari.window).webAreas, [safari.webArea])
        XCTAssertEqual(try safari.tree.string(.identifier, of: safari.addressField), "WEB_BROWSER_ADDRESS_AND_SEARCH_FIELD")
        let focused = BrowserFixtures.safari(fieldFocused: true)
        XCTAssertEqual(try Reader.classifyFocus(focused.tree.focused, tree: focused.tree).0, .editing)
    }

    func testFixturesUseOnlyExampleOrInternalAddresses() throws {
        let trees = [BrowserFixtures.zen().tree, BrowserFixtures.chrome().tree, BrowserFixtures.arc().tree,
                     BrowserFixtures.safari().tree]
        for tree in trees {
            for (_, node) in tree.nodes {
                for text in [node.url, node.value].compactMap({ $0 }) where !text.isEmpty {
                    XCTAssertTrue(text.contains("example.") || text.hasPrefix("chrome://"), text)
                }
            }
        }
    }

    func testScanStopsAtTheNodeLimit() throws {
        let t = FakeAXTree()
        let window = t.add("AXWindow", subrole: "AXStandardWindow")
        for _ in 0..<500 { t.add("AXButton", under: window) }
        let visited = try AXTreeScan.breadthFirst(t, from: window) { (_: Int) throws(AXReadError) in .descend }
        XCTAssertEqual(visited, BrowserReadLimits.scanNodes)
    }
}
