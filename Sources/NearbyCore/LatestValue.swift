import Foundation

/// A value one thread publishes and any thread reads without ever waiting for the producer: the lock covers only the
/// assignment and the read, never the work that computes the value.
public final class LatestValue<Value> {
    private let lock = NSLock()
    private var value: Value

    public init(_ initial: Value) {
        value = initial
    }

    public func set(_ value: Value) {
        lock.withLock { self.value = value }
    }

    public func get() -> Value {
        lock.withLock { value }
    }
}
