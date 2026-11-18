// P4-5b (owner live test 2026-11-18, Slack just launched with no other helper app): after `AXManualAccessibility` the
// tree is there, but Slack names no focused element (`AXFocusedUIElement` nil, app and system-wide) for the composer
// that already had focus when the tree was built, until focus moves. A read-only probe on the owner's Slack found it by
// a breadth-first walk of the app's `AXFocusedWindow`: one `AXTextArea` with `AXFocused = true` at depth 23 among
// 660 nodes (58 ms, out of process).
//
// The walk, pure over a node seam (the live node is `System/Text/AXChatFocusNode`): breadth first from the focused
// window, reading each node's role and children (one call), and `AXFocused` only on text-box roles. It stops at the
// first text box that says it is focused, after `maxNodes` nodes, at the first read that timed out, or when
// `budgetNanos` of wall time is spent. Read only: nothing is ever set on any element. Chat apps only (the caller).
// Reads no text: roles, children and one boolean per text box. Nothing is kept after the convert.

import Foundation

/// One node of the walked tree.
protocol ChatFocusWalkNode: AnyObject {
    /// The node's role and children in one read, each read bounded by `timeout` seconds.
    func roleAndChildren(timeout: Double) -> ChatFocusNodeRead<Self>
    /// `AXFocused`: true / false; nil = unreadable. `timedOut` = the app didn't answer.
    func isFocused(timeout: Double) -> (focused: Bool?, timedOut: Bool)
}

enum ChatFocusNodeRead<Node> {
    case read(role: String?, children: [Node])
    /// The node can't be read (gone, unsupported): skipped.
    case failed
    /// The app didn't answer in time: the walk stops (it would only time out again).
    case timedOut
}

enum ChatFocusWalk {
    /// What the walk saw (counts only, for the DEBUG trace).
    struct Stats: Sendable, Equatable {
        var nodes = 0
        /// Depth of the found box (0 = the window itself), or the deepest level reached.
        var depth = 0
        var nanos: UInt64 = 0
    }

    enum Outcome<Node> {
        case found(Node, Stats)
        case notFound(Stats)
        /// Out of nodes, time, or the app stopped answering.
        case budget(Stats)
    }

    /// The text-box roles the walk looks for (a chat composer is an `AXTextArea`; a one-line box an `AXTextField`).
    static let boxRoles: Set<String> = ["AXTextArea", "AXTextField"]
    static let defaultMaxNodes = 2_000
    /// Each read's messaging timeout: never more than this, nor more than what is left.
    static let maxReadTimeout: Double = 0.25
    static let minReadTimeout: Double = 0.01

    static func find<Node: ChatFocusWalkNode>(from root: Node, maxNodes: Int = defaultMaxNodes, budgetNanos: UInt64,
                                              clock: any Clock) -> Outcome<Node> {
        let start = clock.nowNanos
        var stats = Stats()
        var queue: [(node: Node, depth: Int)] = [(root, 0)]
        var head = 0
        func left() -> UInt64? {
            let used = clock.nowNanos &- start
            return used < budgetNanos ? budgetNanos - used : nil
        }
        func timeout(_ nanos: UInt64) -> Double {
            min(maxReadTimeout, max(minReadTimeout, Double(nanos) / 1e9))
        }
        func done(_ make: (Stats) -> Outcome<Node>) -> Outcome<Node> {
            stats.nanos = clock.nowNanos &- start
            return make(stats)
        }
        while head < queue.count {
            guard stats.nodes < maxNodes, let budget = left() else { return done { .budget($0) } }
            let (node, depth) = queue[head]
            head += 1
            stats.nodes += 1
            stats.depth = max(stats.depth, depth)
            switch node.roleAndChildren(timeout: timeout(budget)) {
            case .timedOut:
                return done { .budget($0) }
            case .failed:
                continue
            case .read(let role, let children):
                if let role, boxRoles.contains(role) {
                    guard let budget = left() else { return done { .budget($0) } }
                    let answer = node.isFocused(timeout: timeout(budget))
                    if answer.timedOut { return done { .budget($0) } }
                    if answer.focused == true {
                        stats.depth = depth
                        return done { .found(node, $0) }
                    }
                }
                for child in children { queue.append((child, depth + 1)) }
            }
        }
        return done { .notFound($0) }
    }
}

/// P4-5b: what `TextReplacing.pinChatFocus` did, for the caller and the DEBUG trace (counts only).
enum ChatFocusWalkReport: Equatable, Sendable {
    case found(ChatFocusWalk.Stats)
    case notFound(ChatFocusWalk.Stats)
    case budget(ChatFocusWalk.Stats)
    /// No focused window, no grant, or a replacer that can't walk.
    case unavailable

    var isFound: Bool { if case .found = self { true } else { false } }

    var traceName: String {
        func counts(_ s: ChatFocusWalk.Stats) -> String { "nodes=\(s.nodes) ms=\(s.nanos / 1_000_000) depth=\(s.depth)" }
        switch self {
        case .found(let s): return "found " + counts(s)
        case .notFound(let s): return "notFound " + counts(s)
        case .budget(let s): return "budget " + counts(s)
        case .unavailable: return "unavailable"
        }
    }
}
