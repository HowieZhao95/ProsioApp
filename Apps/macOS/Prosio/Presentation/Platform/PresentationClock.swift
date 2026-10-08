import Foundation

import Darwin

nonisolated enum PresentationClock {
    /// Continuous monotonic time includes sleep and is unaffected by wall-clock edits.
    static func now() -> TimeInterval {
        var info = mach_timebase_info_data_t()
        mach_timebase_info(&info)
        return Double(mach_continuous_time()) * Double(info.numer) / Double(info.denom) / 1_000_000_000
    }
}
