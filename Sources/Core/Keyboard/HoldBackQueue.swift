// P2-12: The hold-back FIFO (001 §7 B2, R5): user events swallowed while a replacement runs, replayed in order.
// Hard cap 32 events (design.md). Storage is reserved once, so holding never allocates; draining does (rare).

import Foundation

struct HoldBackQueue: Sendable, Equatable {
    static let maxCapacity = 32

    let capacity: Int
    private var items: [HeldEvent] = []

    /// The capacity is clamped to 1...32, so no configuration can break the design cap.
    init(capacity: Int = HoldBackQueue.maxCapacity) {
        self.capacity = min(max(1, capacity), Self.maxCapacity)
        items.reserveCapacity(self.capacity)
    }

    var count: Int { items.count }
    var isEmpty: Bool { items.isEmpty }
    var isFull: Bool { items.count >= capacity }

    /// Returns false (and drops nothing already held) when the queue is full.
    @discardableResult
    mutating func append(_ e: HeldEvent) -> Bool {
        guard !isFull else { return false }
        items.append(e)
        return true
    }

    /// Everything held, oldest first; the queue is empty afterwards.
    mutating func drain() -> [HeldEvent] {
        let out = items
        items = []
        items.reserveCapacity(capacity)
        return out
    }
}
