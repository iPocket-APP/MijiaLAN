#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#elseif canImport(Musl)
import Musl
#endif

/// A time interval in seconds with explicit units at call sites.
public struct TimeSpan: Comparable, Sendable, CustomStringConvertible {
    public let timeInterval: Double

    public static let zero = Self(timeInterval: 0)

    public static func seconds(_ value: Double) -> Self {
        precondition(value.isFinite, "A time interval must be finite")
        return Self(timeInterval: value)
    }

    public static func seconds<T: BinaryInteger>(_ value: T) -> Self {
        seconds(Double(value))
    }

    public static func milliseconds<T: BinaryInteger>(_ value: T) -> Self {
        seconds(Double(value) / 1_000)
    }

    public static func < (lhs: Self, rhs: Self) -> Bool {
        lhs.timeInterval < rhs.timeInterval
    }

    public static func * (interval: Self, multiplier: Int) -> Self {
        .seconds(interval.timeInterval * Double(multiplier))
    }

    public var description: String { "\(timeInterval) seconds" }
}

/// Uses elapsed time since boot, including time spent asleep. Wall-clock changes
/// must not change device timestamps, retries or optimistic write deadlines.
public enum MonotonicClock {
    public struct Instant: Comparable, Sendable {
        fileprivate let seconds: Double

        public static var now: Self { MonotonicClock.now }

        public func advanced(by interval: TimeSpan) -> Self {
            Self(seconds: seconds + interval.timeInterval)
        }

        public func duration(to other: Self) -> TimeSpan { other - self }

        public static func + (instant: Self, interval: TimeSpan) -> Self {
            instant.advanced(by: interval)
        }

        public static func - (lhs: Self, rhs: Self) -> TimeSpan {
            .seconds(lhs.seconds - rhs.seconds)
        }

        public static func < (lhs: Self, rhs: Self) -> Bool {
            lhs.seconds < rhs.seconds
        }
    }

    public static var now: Instant {
        #if canImport(Darwin)
        // CLOCK_MONOTONIC_RAW is mach_continuous_time converted to nanoseconds.
        Instant(seconds: Double(clock_gettime_nsec_np(CLOCK_MONOTONIC_RAW)) / 1_000_000_000)
        #else
        var time = timespec()
        clock_gettime(CLOCK_BOOTTIME, &time)
        return Instant(seconds: Double(time.tv_sec) + Double(time.tv_nsec) / 1_000_000_000)
        #endif
    }

    public static func sleep(for interval: TimeSpan, tolerance: TimeSpan? = nil) async throws {
        try Task.checkCancellation()
        guard interval > .zero else { return }

        if #available(macOS 13, iOS 16, tvOS 16, watchOS 9, *) {
            try await Task.sleep(for: .seconds(interval.timeInterval),
                                 tolerance: tolerance.map { .seconds($0.timeInterval) })
        } else {
            // Swift's nanosecond sleep uses a continuous clock on Darwin.
            let nanoseconds = (interval.timeInterval * 1_000_000_000).rounded(.up)
            try await Task.sleep(nanoseconds: UInt64(min(nanoseconds, Double(Int64.max).nextDown)))
        }
    }

    public static func sleep(until deadline: Instant) async throws {
        while true {
            let remaining = deadline - now
            try Task.checkCancellation()
            guard remaining > .zero else { return }
            try await sleep(for: remaining)
        }
    }
}
