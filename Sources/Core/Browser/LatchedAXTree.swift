// P3-6: A read stops at the first timeout (001 §14.3.3, B13), as the convert path does with `AXTimeoutLatch`
// (Text/, P2-49). A hung browser answers every AX call with a 0.25 s messaging timeout; without the latch one read
// could chain dozens of them. After the first `.timedOut`, every further call of that read fails at once without
// asking the browser, even if a strategy catches the error and tries another route. So one read can't take much
// more than ~0.5 s wall even against a hung browser.

/// One read's timeout state. AX thread only.
final class AXReadLatch {
    private(set) var tripped = false

    init() {}

    func reset() { tripped = false }

    /// Runs `call` unless the latch has tripped; trips it when `call` times out.
    func guarded<T>(_ call: () throws(AXReadError) -> T) throws(AXReadError) -> T {
        if tripped { throw .timedOut }
        do {
            return try call()
        } catch {
            if error == .timedOut { tripped = true }
            throw error
        }
    }
}

/// Wraps a tree so every call goes through the latch. `isSame` asks nothing of the browser and isn't latched.
struct LatchedAXTree<Base: AXNodeReading>: AXNodeReading {
    typealias Node = Base.Node
    let base: Base
    let latch: AXReadLatch

    init(_ base: Base, latch: AXReadLatch) {
        self.base = base
        self.latch = latch
    }

    func focusedElement() throws(AXReadError) -> Node? {
        try latch.guarded { () throws(AXReadError) in try base.focusedElement() }
    }

    func mainWindow() throws(AXReadError) -> Node? {
        try latch.guarded { () throws(AXReadError) in try base.mainWindow() }
    }

    func focusedWindow() throws(AXReadError) -> Node? {
        try latch.guarded { () throws(AXReadError) in try base.focusedWindow() }
    }

    func parent(of n: Node) throws(AXReadError) -> Node? {
        try latch.guarded { () throws(AXReadError) in try base.parent(of: n) }
    }

    func children(of n: Node) throws(AXReadError) -> [Node] {
        try latch.guarded { () throws(AXReadError) in try base.children(of: n) }
    }

    func string(_ a: AXStringAttribute, of n: Node) throws(AXReadError) -> String? {
        try latch.guarded { () throws(AXReadError) in try base.string(a, of: n) }
    }

    func url(of n: Node) throws(AXReadError) -> String? {
        try latch.guarded { () throws(AXReadError) in try base.url(of: n) }
    }

    func isFocused(_ n: Node) throws(AXReadError) -> Bool? {
        try latch.guarded { () throws(AXReadError) in try base.isFocused(n) }
    }

    func area(of n: Node) throws(AXReadError) -> Double? {
        try latch.guarded { () throws(AXReadError) in try base.area(of: n) }
    }

    func isSame(_ a: Node, _ b: Node) -> Bool {
        base.isSame(a, b)
    }
}
