// P2-17: Turns a `CGEvent.timestamp` into uptime nanoseconds, the base the Core expects (KeyEvent.timestampNanos).
// Apple documents the field as nanoseconds, but on Apple Silicon it has been reported to carry mach_absolute_time
// ticks (24 MHz, timebase 125/3 here). Double-Shift timing (300 ms window) would then be ~42× too loose.
// Created-but-not-posted events have timestamp 0, so an agent can't check this headlessly. Instead, the first real
// event decides the unit once: its timestamp is "just before now" in exactly one of the two clocks.
// Tap-thread confined; no allocation, O(1).

import Foundation

struct EventTimestampNormalizer: Sendable, Equatable {
    enum Unit: Sendable, Equatable { case undecided, nanoseconds, machTicks }

    let numer: UInt32
    let denom: UInt32
    private(set) var unit: Unit

    /// `numer`/`denom`: the mach timebase. Equal values (Intel) mean ticks are nanoseconds, so nothing to decide.
    init(numer: UInt32, denom: UInt32) {
        self.numer = max(1, numer)
        self.denom = max(1, denom)
        unit = self.numer == self.denom ? .nanoseconds : .undecided
    }

    /// The real machine's timebase.
    static func system() -> EventTimestampNormalizer {
        var info = mach_timebase_info_data_t()
        mach_timebase_info(&info)
        return EventTimestampNormalizer(numer: info.numer, denom: info.denom)
    }

    /// `machNow` / `uptimeNanosNow`: read right now (`mach_absolute_time`, `CLOCK_UPTIME_RAW`). Both are needed only
    /// until the unit is decided. A zero timestamp (a synthetic event without one) becomes "now".
    mutating func nanos(fromEventTimestamp ts: UInt64, machNow: @autoclosure () -> UInt64,
                        uptimeNanosNow: @autoclosure () -> UInt64) -> UInt64 {
        if ts == 0 { return uptimeNanosNow() }
        if unit == .undecided {
            let mach = machNow(), up = uptimeNanosNow()
            let toTicks = mach > ts ? mach - ts : ts - mach
            let toNanos = up > ts ? up - ts : ts - up
            unit = toTicks < toNanos ? .machTicks : .nanoseconds
        }
        guard unit == .machTicks else { return ts }
        return ticksToNanos(ts)
    }

    /// Forget the decision (a new tap was installed).
    mutating func reset() {
        unit = numer == denom ? .nanoseconds : .undecided
    }

    private func ticksToNanos(_ ticks: UInt64) -> UInt64 {
        let product = ticks.multipliedFullWidth(by: UInt64(numer))
        let d = UInt64(denom)
        // The quotient overflows only after ~centuries of uptime; saturate instead of trapping.
        guard product.high < d else { return .max }
        return d.dividingFullWidth(product).quotient
    }
}
