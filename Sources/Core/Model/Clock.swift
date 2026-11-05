// P2-4: Injected time source (design.md: "Inject time through `Clock`").
// Monotonic nanoseconds, so timing logic (deadlines, debounce, learning windows) is testable with a fake.

import Foundation

protocol Clock: Sendable {
    /// Monotonic time in nanoseconds. Only differences are meaningful; never a wall-clock date.
    var nowNanos: UInt64 { get }
}
