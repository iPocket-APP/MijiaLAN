import Foundation
import MijiaSupport
import Combine

/// View-owned edit intent, separate from the controller's confirmed device readings.
/// Sends immediately, limits the send rate, and keeps just the newest unsent value.
@MainActor
public final class ContinuousValueWriter: ObservableObject {
    @Published public private(set) var pendingValue: Double?
    @Published public private(set) var error: String?
    public var isSending: Bool { pendingValue != nil }
    private let minimumInterval: TimeSpan
    private let apply: @MainActor @Sendable (Double) async throws -> Void
    private var queued: Double?
    private var active: Double?
    private var worker: Task<Void, Never>?
    private var lastStart: MonotonicClock.Instant?

    public init(minimumInterval: TimeSpan = .milliseconds(100),
                apply: @escaping @MainActor @Sendable (Double) async throws -> Void) {
        self.minimumInterval = max(.zero, minimumInterval)
        self.apply = apply
    }

    public func submit(_ value: Double) {
        guard pendingValue != value else { return }
        pendingValue = value
        queued = value
        error = nil
        guard worker == nil else { return }
        // The synchronous prefix owns UI edit state, so it stays on the main actor.
        worker = Task { await drain() }
    }

    /// Navigation drops old, unsent intent. A packet already sent still gets its honest readback.
    public func cancelPending() {
        queued = nil
        pendingValue = active
    }

    private func drain() async {
        while queued != nil {
            if let lastStart {
                do { try await MonotonicClock.sleep(until: lastStart.advanced(by: minimumInterval)) }
                catch { break }
            }
            guard !Task.isCancelled, let value = queued else { break }
            queued = nil
            active = value
            lastStart = MonotonicClock.now
            do {
                try await apply(value)
                // A gesture may return to the value already being confirmed.
                if queued == value { queued = nil }
            } catch {
                if queued == nil { self.error = error.localizedDescription }
            }
            active = nil
        }
        pendingValue = nil
        worker = nil
    }

    // Await the worker rather than a timing guess in concurrency regression tests.
    func waitUntilIdle() async { while let worker { await worker.value } }
}
