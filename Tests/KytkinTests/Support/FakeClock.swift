// P2-4: A manually driven `Clock` for timing tests. Time only moves when a test calls `advance`/`set`.

import Foundation

final class FakeClock: Clock, @unchecked Sendable { // @unchecked: all state is guarded by `lock`
    private let lock = NSLock()
    private var now: UInt64

    init(nowNanos: UInt64 = 0) { now = nowNanos }

    var nowNanos: UInt64 { lock.withLock { now } }

    func advance(byNanos nanos: UInt64) { lock.withLock { now += nanos } }
    func advance(byMilliseconds ms: UInt64) { advance(byNanos: ms * 1_000_000) }
    func advance(bySeconds s: UInt64) { advance(byNanos: s * 1_000_000_000) }

    /// Jumps to an absolute time. Monotonic clocks never go back, so moving backwards is a test bug.
    func set(nowNanos: UInt64) {
        lock.withLock {
            precondition(nowNanos >= now, "FakeClock can't go back in time")
            now = nowNanos
        }
    }
}
