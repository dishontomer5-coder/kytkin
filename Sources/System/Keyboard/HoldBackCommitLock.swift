// P2-17: The B3 hold-back commit (001 §7 B3) behind its one tiny lock, shared by the tap thread and the
// replacement worker. 001 names `OSAllocatedUnfairLock`, but that needs `import os`, which the lint bans in any
// Keyboard/ folder (no logging there). An uncontended NSLock costs tens of nanoseconds and is taken only on a
// trigger, a due deadline, or a finish: never per key.
//
// Who calls what (001 §2.2 adapter contract):
// - tap thread: `arm` (a replacement started), `claimFlush` (deadline due), `finish` (after the finish/flush).
// - worker: `claimPosting` only, right before it posts. It never calls `finish`.

import Foundation

final class HoldBackCommitLock: @unchecked Sendable { // @unchecked: `commit` is only touched under `lock`
    private let lock = NSLock()
    private var commit = HoldBackCommit()

    init() {}

    var state: HoldBackCommit.State { lock.withLock { commit.state } }

    func arm(gen: UInt64) { lock.withLock { commit.arm(gen: gen) } }

    func claimPosting(gen: UInt64) -> Bool { lock.withLock { commit.claimPosting(gen: gen) } }

    func claimFlush(gen: UInt64) -> Bool { lock.withLock { commit.claimFlush(gen: gen) } }

    func finish(gen: UInt64) { lock.withLock { commit.finish(gen: gen) } }
}
