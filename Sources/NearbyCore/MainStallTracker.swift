import Foundation

/// B1.2 F4: the state behind the main-thread stall tracer. A watchdog on a utility queue pings the main queue; while
/// the ping is unanswered, `poll` reports the stall at 0.75 s, 2 s, 5 s, 10 s and every 10 s after that, naming the
/// innermost marked task. When main answers, `pingAnswered` reports the total and the longest marked task. Nothing is
/// logged or started here: this type is pure and testable.
public struct MainStallTracker {
    public struct Open: Equatable {
        public let stalledMs: Int
        public let running: [String]
        public let runningForMs: Int?
        public let lastFinished: String?
        public let lastFinishedAgoMs: Int?
    }

    public struct Ended: Equatable {
        public let totalMs: Int
        public let longestMarked: String?
        public let longestMarkedMs: Int
    }

    private struct Mark {
        let name: String
        let at: TimeInterval
    }

    private struct Finished {
        let name: String
        let at: TimeInterval
        let duration: TimeInterval
    }

    private static let maxDepth = 8
    private static let firstThreshold: TimeInterval = 0.75
    private var stack: [Mark] = []
    private var ignoredDepth = 0
    private var lastFinished: Finished?
    private var recentFinished: [Finished] = []
    private var pingAt: TimeInterval?
    private var nextPollAt: TimeInterval = 0
    private var reportedThisStall = false

    public init() {}

    public mutating func enter(_ name: String, at uptime: TimeInterval) {
        guard stack.count < Self.maxDepth else { ignoredDepth += 1; return }
        stack.append(Mark(name: name, at: uptime))
    }

    public mutating func exit(at uptime: TimeInterval) {
        if ignoredDepth > 0 { ignoredDepth -= 1; return }
        guard let mark = stack.popLast() else { return }
        let finished = Finished(name: mark.name, at: uptime, duration: max(0, uptime - mark.at))
        lastFinished = finished
        recentFinished.append(finished)
        if recentFinished.count > 32 { recentFinished.removeFirst(recentFinished.count - 32) }
    }

    public mutating func pingSent(at uptime: TimeInterval) {
        guard pingAt == nil else { return }
        pingAt = uptime
        nextPollAt = uptime + Self.firstThreshold
        reportedThisStall = false
    }

    public mutating func pingAnswered(at uptime: TimeInterval) -> Ended? {
        guard let start = pingAt else { return nil }
        pingAt = nil
        nextPollAt = 0
        let duration = max(0, uptime - start)
        let wasStall = reportedThisStall || duration >= Self.firstThreshold
        reportedThisStall = false
        guard wasStall else { return nil }
        let longest = longestMarked(since: start, until: uptime)
        return Ended(totalMs: Int(duration * 1000), longestMarked: longest?.name,
                     longestMarkedMs: Int((longest?.duration ?? 0) * 1000))
    }

    public mutating func poll(at uptime: TimeInterval) -> Open? {
        guard let start = pingAt else { return nil }
        guard uptime - start >= Self.firstThreshold, uptime >= nextPollAt else { return nil }
        reportedThisStall = true
        advanceNextPoll(after: uptime, start: start)
        let top = stack.last
        return Open(stalledMs: Int((uptime - start) * 1000),
                    running: stack.map(\.name),
                    runningForMs: top.map { Int(max(0, uptime - $0.at) * 1000) },
                    lastFinished: lastFinished?.name,
                    lastFinishedAgoMs: lastFinished.map { Int(max(0, uptime - $0.at) * 1000) })
    }

    /// The next report is the first of 0.75, 2, 5 and 10 s after the ping that is still ahead, then every 10 s.
    private mutating func advanceNextPoll(after uptime: TimeInterval, start: TimeInterval) {
        for threshold in [0.75, 2, 5, 10] where start + threshold > uptime {
            nextPollAt = start + threshold
            return
        }
        let elapsed = uptime - start
        nextPollAt = start + (floor(elapsed / 10) + 1) * 10
    }

    private func longestMarked(since start: TimeInterval, until end: TimeInterval) -> (name: String, duration: TimeInterval)? {
        var best: (name: String, duration: TimeInterval)?
        for mark in stack {
            let duration = max(0, end - mark.at)
            if duration > (best?.duration ?? 0) { best = (mark.name, duration) }
        }
        for finished in recentFinished where finished.at >= start {
            if finished.duration > (best?.duration ?? 0) { best = (finished.name, finished.duration) }
        }
        return best
    }
}
