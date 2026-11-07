// P3-6: An in-memory AX tree for the browser read tests (001 §14.3.2, D8). Nodes are Ints. It reproduces the R3b
// quirks on demand: a child that reports its parent but isn't in that parent's `children` (Zen's web area and
// window), a main window that isn't reported, a focused window that is a popup. Every call is logged, so tests can
// assert what was (and wasn't) asked: "a focused address bar's value is never read", call and scan counts (B13),
// the latch stopping at the first timeout.


final class FakeAXTree: AXNodeReading {
    typealias Node = Int

    struct FakeNode {
        var role: String
        var subrole: String?
        var domIdentifier: String?
        var identifier: String?
        var description: String?
        var title: String?
        var value: String?
        var url: String?
        var focused: Bool?
        var area: Double?
        var parent: Int?
        var children: [Int] = []
    }

    enum Call: Equatable {
        case focusedElement, mainWindow, focusedWindow
        case parent(Int), children(Int), string(AXStringAttribute, Int), url(Int), isFocused(Int), area(Int)

        var node: Int? {
            switch self {
            case .focusedElement, .mainWindow, .focusedWindow: nil
            case .parent(let n), .children(let n), .string(_, let n), .url(let n), .isFocused(let n), .area(let n): n
            }
        }
    }

    private(set) var nodes: [Int: FakeNode] = [:]
    var focused: Int?
    var main: Int?
    var focusedWin: Int?

    /// Any call about one of these nodes throws this error.
    var errors: [Int: AXReadError] = [:]
    /// Every app-level call (focused element, windows) throws this.
    var appError: AXReadError?
    /// From the n-th call on (0-based), every call throws `.timedOut`: a browser that hangs mid-read.
    var hangAfterCalls: Int?

    private(set) var calls: [Call] = []

    init() {}

    // MARK: Building

    /// Adds a node. `listed: false` = it reports `parent` but isn't in the parent's children (Zen, R3b §1).
    @discardableResult
    func add(_ role: String, subrole: String? = nil, under parent: Int? = nil, listed: Bool = true,
             domIdentifier: String? = nil, identifier: String? = nil, description: String? = nil,
             title: String? = nil, value: String? = nil, url: String? = nil, focused: Bool? = nil,
             area: Double? = nil) -> Int {
        let id = nodes.count + 1
        nodes[id] = FakeNode(role: role, subrole: subrole, domIdentifier: domIdentifier, identifier: identifier,
                             description: description, title: title, value: value, url: url, focused: focused,
                             area: area, parent: parent)
        if let parent, listed { nodes[parent]?.children.append(id) }
        return id
    }

    func set(_ id: Int, _ change: (inout FakeNode) -> Void) {
        change(&nodes[id]!)
    }

    func resetCalls() { calls = [] }

    func calls(about node: Int) -> [Call] { calls.filter { $0.node == node } }

    /// How many nodes a scan expanded (children calls).
    var childrenCalls: Int { calls.filter { if case .children = $0 { true } else { false } }.count }

    // MARK: AXNodeReading

    private func log(_ call: Call) throws(AXReadError) {
        let index = calls.count
        calls.append(call)
        if let hang = hangAfterCalls, index >= hang { throw .timedOut }
        if let n = call.node {
            if let e = errors[n] { throw e }
            guard nodes[n] != nil else { throw .invalidElement }
        } else if let e = appError {
            throw e
        }
    }

    func focusedElement() throws(AXReadError) -> Int? { try log(.focusedElement); return focused }
    func mainWindow() throws(AXReadError) -> Int? { try log(.mainWindow); return main }
    func focusedWindow() throws(AXReadError) -> Int? { try log(.focusedWindow); return focusedWin }
    func parent(of n: Int) throws(AXReadError) -> Int? { try log(.parent(n)); return nodes[n]?.parent }
    func children(of n: Int) throws(AXReadError) -> [Int] { try log(.children(n)); return nodes[n]?.children ?? [] }

    func string(_ a: AXStringAttribute, of n: Int) throws(AXReadError) -> String? {
        try log(.string(a, n))
        guard let node = nodes[n] else { return nil }
        switch a {
        case .role: return node.role
        case .subrole: return node.subrole
        case .domIdentifier: return node.domIdentifier
        case .identifier: return node.identifier
        case .description: return node.description
        case .title: return node.title
        case .value: return node.value
        }
    }

    func url(of n: Int) throws(AXReadError) -> String? { try log(.url(n)); return nodes[n]?.url }
    func isFocused(_ n: Int) throws(AXReadError) -> Bool? { try log(.isFocused(n)); return nodes[n]?.focused }
    func area(of n: Int) throws(AXReadError) -> Double? { try log(.area(n)); return nodes[n]?.area }
    func isSame(_ a: Int, _ b: Int) -> Bool { a == b }
}
