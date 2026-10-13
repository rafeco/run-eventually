import Darwin
import Foundation

/// Continuous time includes sleep; absolute time measures time while awake.
public struct ExecutionClockSample: Sendable {
    public let continuous: TimeInterval
    public let awake: TimeInterval
    public init(continuous: TimeInterval, awake: TimeInterval) {
        self.continuous = continuous
        self.awake = awake
    }
    public static func now() -> ExecutionClockSample {
        var info = mach_timebase_info_data_t()
        mach_timebase_info(&info)
        let scale = Double(info.numer) / Double(info.denom) / 1_000_000_000
        return ExecutionClockSample(continuous: Double(mach_continuous_time()) * scale,
                                    awake: Double(mach_absolute_time()) * scale)
    }
}

struct ExecutionDeadline {
    let start: ExecutionClockSample
    let timeout: TimeInterval
    private(set) var previous: ExecutionClockSample
    private(set) var slept = false
    init(start: ExecutionClockSample, timeout: TimeInterval) {
        self.start = start
        self.previous = start
        self.timeout = timeout
    }
    mutating func observe(_ sample: ExecutionClockSample) -> Bool {
        let sleep = (sample.continuous - previous.continuous) - (sample.awake - previous.awake) > 5
        previous = sample
        slept = slept || sleep
        return sleep
    }
    func remaining(at sample: ExecutionClockSample) -> TimeInterval {
        timeout - (sample.continuous - start.continuous)
    }
}
