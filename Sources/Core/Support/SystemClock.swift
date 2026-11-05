// P2-4: The real `Clock`. Uses the uptime clock, which is monotonic and doesn't run while the Mac sleeps,
// the same time base as CGEvent/NSEvent timestamps (mach_absolute_time).

import Foundation

struct SystemClock: Clock {
    var nowNanos: UInt64 { clock_gettime_nsec_np(CLOCK_UPTIME_RAW) }
}
