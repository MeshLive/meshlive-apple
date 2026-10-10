import Foundation

/// An ordered, bounded writer. Zero means backpressure; negative means failure.
/// Transport owners call drain only from readiness callbacks or on enqueue.
public final class OrderedWriter {
    private struct Item { var data: Data; var offset: Int; let submitted: TimeInterval; let tag: UInt64 }
    private var items: [Item] = []
    private let limit: Int
    public private(set) var queuedBytes = 0
    public private(set) var completedBytes: UInt64 = 0
    public var pendingCount: Int { items.count }
    public var oldestSubmission: TimeInterval? { items.first?.submitted }
    public var onComplete: ((UInt64) -> Void)?
    public init(limit: Int = 131_072) { self.limit = limit }
    public func enqueue(_ data: Data, tag: UInt64 = 0, now: TimeInterval) throws {
        guard !data.isEmpty, items.count < 1024, queuedBytes + data.count <= limit else { throw ProtocolError.limit("Transport send queue full") }
        items.append(Item(data: data, offset: 0, submitted: now, tag: tag)); queuedBytes += data.count
    }
    public func drain(write: (Data) throws -> Int) throws {
        while let item = items.first {
            let remaining = Data(item.data.dropFirst(item.offset))
            let count = try write(remaining)
            guard count >= 0, count <= remaining.count else { throw ProtocolError.state("Output stream error") }
            if count == 0 { return }
            items[0].offset += count; queuedBytes -= count; completedBytes += UInt64(count)
            if items[0].offset == item.data.count {
                items.removeFirst(); onComplete?(item.tag)
            }
        }
    }
    public func cancel() { items.removeAll(keepingCapacity: false); queuedBytes = 0 }
}

/// Attempt tokens gate timers and media completions across reconnects.
public struct AttemptGate {
    public private(set) var current = UUID()
    public init() {}
    @discardableResult public mutating func renew() -> UUID { current = UUID(); return current }
    public func accepts(_ token: UUID) -> Bool { token == current }
}
