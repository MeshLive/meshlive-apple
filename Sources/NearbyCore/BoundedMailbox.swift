import Foundation

/// Bounded cross-queue handoff; only one drain notification is necessary per batch.
public final class BoundedMailbox<Value> {
    private let lock = NSLock()
    private let capacity: Int
    private var values: [Value] = []
    private var scheduled = false
    public init(capacity: Int) { self.capacity = capacity }
    /// nil rejects admission; true schedules a drain; false uses the already scheduled drain.
    public func offer(_ value: Value) -> Bool? {
        lock.lock(); defer { lock.unlock() }
        guard values.count < capacity else { return nil }
        values.append(value); let notify = !scheduled; scheduled = true; return notify
    }
    public func takeAll() -> [Value] {
        lock.lock(); defer { lock.unlock() }
        let result = values; values.removeAll(keepingCapacity: true); scheduled = false; return result
    }
    /// Diagnostics coalesce to the latest value instead of dropping the final summary.
    public func offerLatest(_ value: Value) -> Bool? {
        lock.lock(); defer { lock.unlock() }
        guard capacity > 0 else { return nil }
        values.removeAll(keepingCapacity: true); values.append(value)
        let notify = !scheduled; scheduled = true; return notify
    }
}
