import Foundation

/// A link measures what it delivers from the media it already carries (as Android `ArrivalTrainMeter`).
/// A sealed record is written back to back, so a large record crosses the link as a packet train: its bytes over its
/// arrival time is the rate the link delivered then. The median train of the last 10 s is the estimate.
///
/// Apple sees the link as chunks (GATT values, L2CAP reads) delivered on the main queue, so a chunk's time is when it
/// was handed over. As on Android, a train starts only with a record whose first chunk arrived while nothing was
/// buffered and the reader had been waiting (here: an idle gap since the previous chunk, which a backlog of chunks
/// delivered back to back after a main-thread stall does not have), and the first chunk's bytes are not counted.
public final class ArrivalTrainMeter {
    /// Enough chunks to average out L2CAP chunking and GATT notification batching (Android `MIN_TRAIN_BYTES`).
    public static let minTrainBytes = 8_000
    /// Several BLE connection events (Android `MIN_TRAIN_NS`).
    public static let minTrainSeconds: TimeInterval = 0.06
    public static let window: TimeInterval = 10
    /// A first chunk delivered sooner than this after the previous one was waiting in a backlog.
    public static let minIdleBeforeTrain: TimeInterval = 0.003

    private var samples: [(at: TimeInterval, kbps: Int)] = []
    private var inTrain = false
    private var startAt: TimeInterval = 0, lastAt: TimeInterval = 0
    private var trainBytes = 0
    private var lastChunkAt = -TimeInterval.infinity
    /// Measured trains so far (Android `genuineTrains`).
    public private(set) var trains = 0

    public init() {}

    /// One chunk handed to the record parser. `pendingBefore`/`pendingAfter`: bytes of an incomplete record buffered
    /// before and after it; `completedRecords`: records it completed.
    /// Returns a new train's kbps when this chunk ended one.
    @discardableResult
    public func noteChunk(bytes: Int, at now: TimeInterval, pendingBefore: Int, completedRecords: Int, pendingAfter: Int) -> Int? {
        let waited = now - lastChunkAt >= Self.minIdleBeforeTrain
        lastChunkAt = now
        if inTrain {
            trainBytes += bytes; lastAt = now
        } else if pendingBefore == 0 && waited {
            inTrain = true; startAt = now; lastAt = now; trainBytes = 0
        }
        guard inTrain, completedRecords > 0 else { return nil }
        inTrain = false
        // Bytes of a following record that began in the completing chunk are not part of this train.
        let bytes = trainBytes - (trainBytes > 0 ? pendingAfter : 0)
        let duration = lastAt - startAt
        guard bytes >= Self.minTrainBytes, duration >= Self.minTrainSeconds else { return nil }
        let kbps = Int((Double(bytes) * 8 / duration / 1000).rounded())
        samples.append((lastAt, kbps)); trains += 1
        return kbps
    }

    /// The median train in the window, or nil when none is recent.
    public func estimateKbps(now: TimeInterval) -> Int? {
        samples.removeAll { now - $0.at > Self.window }
        let sorted = samples.map(\.kbps).sorted()
        return sorted.isEmpty ? nil : sorted[(sorted.count - 1) / 2]
    }
}
