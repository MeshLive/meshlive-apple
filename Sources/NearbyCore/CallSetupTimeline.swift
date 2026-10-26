import Foundation

/// One call's setup stages in order, timed from its origin: the caller's tap, or the callee's link arriving. Each stage
/// is recorded once (the first time it happens); `summary` lists them as `stage:ms` and names the largest step, the
/// stage that waited longest after the one before it. Same stages as Android's setup breakdown (tap, connect,
/// services, link and endpoint handshakes, invite, ring, accept, active, first media).
public struct CallSetupTimeline {
    public let origin: TimeInterval
    public private(set) var stages: [(name: String, at: TimeInterval)] = []

    public init(origin: TimeInterval) { self.origin = origin }

    /// Records `name` at `at` unless it was already recorded; returns the step (ms since the previous stage) when new.
    @discardableResult
    public mutating func mark(_ name: String, at: TimeInterval) -> (ms: Int, stepMs: Int)? {
        guard !stages.contains(where: { $0.name == name }) else { return nil }
        let previous = stages.last?.at ?? origin
        stages.append((name, at))
        return (Self.ms(at - origin), Self.ms(at - previous))
    }

    public func has(_ name: String) -> Bool { stages.contains { $0.name == name } }

    /// `stage:ms` in order, e.g. `connect:3 services:420 link_auth:910`.
    public var summary: String { stages.map { "\($0.name):\(Self.ms($0.at - origin))" }.joined(separator: " ") }

    /// The stage that waited longest after the previous one, and that wait.
    public var largestStep: (name: String, ms: Int)? {
        var previous = origin
        var best: (String, Int)?
        for stage in stages {
            let step = Self.ms(stage.at - previous)
            if best == nil || step > best!.1 { best = (stage.name, step) }
            previous = stage.at
        }
        return best.map { (name: $0.0, ms: $0.1) }
    }

    public var totalMs: Int { stages.last.map { Self.ms($0.at - origin) } ?? 0 }

    static func ms(_ seconds: TimeInterval) -> Int { Int((seconds * 1000).rounded()) }
}
