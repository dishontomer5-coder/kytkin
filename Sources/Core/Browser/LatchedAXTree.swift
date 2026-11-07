// P3-6: A read stops at the first timeout (001 §14.3.3, B13), as the convert path does with `AXTimeoutLatch`
// (Text/, P2-49). A hung browser answers every AX call with a 0.25 s messaging timeout; without the latch one read
// could chain dozens of them. After the first `.timedOut`, every further call of that read fails at once without
// asking the browser, even if a strategy catches the error and tries another route. So one read can't take much
// more than ~0.5 s wall even against a hung browser.
//
// P3-10: plus a wall-clock deadline. A slow (not hung) browser can answer each call in just under 0.25 s, so the
// first-timeout rule alone would let a 400-node scan run for minutes. With a clock, the latch also trips once the
// read has run for `readBudgetNanos` (0.5 s): the call in progress finishes (≤ 0.25 s more), every later one fails
// at once. So one read stays under ~0.75 s wall whatever the browser does (B13). The live tree maps
// `kAXErrorCannotComplete` (what a messaging timeout returns) to `.timedOut`, so the first-timeout rule fires too.

/// One read's timeout state. AX thread only.
final class AXReadLatch {
    /// P3-10: a read's wall-clock budget (B13).
    static let readBudgetNanos: UInt64 = 500_000_000

    private(set) var tripped = false
    private let clock: (any Clock)?
    private let budgetNanos: UInt64
    private var deadline: UInt64?

    /// No deadline: only the first timeout trips it.
    init() {
        clock = nil
        budgetNanos = 0
        deadline = nil
    }

    /// P3-10: also trips once `clock` reaches `startedAt + budgetNanos`.
    init(clock: any Clock, startedAt: UInt64, budgetNanos: UInt64 = AXReadLatch.readBudgetNanos) {
        self.clock = clock
        self.budgetNanos = budgetNanos
        deadline = startedAt &+ budgetNanos
    }

    /// Clears the trip and, with a clock, starts a new budget from now.
    func reset() {
        tripped = false
        if let clock { deadline = clock.nowNanos &+ budgetNanos }
    }

    /// Runs `call` unless the latch has tripped or the read is over budget; trips it when `call` times out.
    func guarded<T>(_ call: () throws(AXReadError) -> T) throws(AXReadError) -> T {
        if tripped { throw .timedOut }
        if let clock, let deadline, clock.nowNanos >= deadline {
            tripped = true
            throw .timedOut
        }
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
