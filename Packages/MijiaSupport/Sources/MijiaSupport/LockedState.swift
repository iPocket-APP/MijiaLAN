import Foundation

/// NSLock-backed storage for deployment targets before OSAllocatedUnfairLock.
/// All access to the stored Sendable value stays inside the synchronous lock.
public final class LockedState<Value: Sendable>: @unchecked Sendable {
    private let lock = NSLock()
    private var value: Value

    public init(initialState: Value) { value = initialState }

    public func withLock<Result>(_ body: (inout Value) throws -> Result) rethrows -> Result {
        try lock.withLock { try body(&value) }
    }
}
