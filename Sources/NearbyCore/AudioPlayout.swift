import Foundation

/// Receive-side playout for 20 ms Opus access units keyed by BTV3 presentation time (microseconds).
/// The sender's audio clock defines frame slots; the receiver plays one slot per 20 ms of its own
/// output clock. Missing slots are concealed (Opus PLC); a drained buffer re-buffers to the target.
/// The target depth adapts upward when bursts arrive (Android batches up to 400 ms on constrained
/// links) and is bounded, so latency stays bounded.
public struct AudioPlayout {
    public enum Output: Equatable {
        case packet(Data), conceal, silence
        /// Experimental FEC: the missing frame just before this packet; decode it with decode_fec = 1.
        case recover(fromNext: Data)
    }
    /// Experimental call FEC (off by default): recover a single missing frame from the next packet's in-band FEC.
    public var fecRecovery = false
    public private(set) var recovered = 0
    public let frameUs: Int64
    public private(set) var targetFrames: Int
    public let minTargetFrames: Int
    public let maxTargetFrames: Int
    public let capacityFrames: Int
    private var slots: [Int64: Data] = [:]
    private var baseUs: Int64?
    private var next: Int64 = 0
    private var playing = false
    private var concealRun = 0
    public private(set) var underruns = 0
    public private(set) var concealed = 0
    public private(set) var late = 0
    public private(set) var overflows = 0
    public private(set) var played = 0
    public var bufferedFrames: Int { slots.count }
    public var bufferedMilliseconds: Int { Int(Int64(slots.count) * frameUs / 1000) }

    public init(frameUs: Int64 = 20_000, targetFrames: Int = 4, maxTargetFrames: Int = 25, capacityFrames: Int = 75) {
        self.frameUs = frameUs; self.targetFrames = targetFrames; minTargetFrames = targetFrames
        self.maxTargetFrames = maxTargetFrames; self.capacityFrames = capacityFrames
    }

    private func slot(_ pts: Int64) -> Int64 {
        let delta = pts - (baseUs ?? pts)
        return delta >= 0 ? (delta + frameUs / 2) / frameUs : -((-delta + frameUs / 2) / frameUs)
    }

    public mutating func push(presentationTimeUs pts: Int64, payload: Data) {
        if baseUs == nil { baseUs = pts; next = 0 }
        var index = slot(pts)
        // A sender restart (clock jump) resets the timeline instead of starving or flooding.
        if index < next - 250 || index > next + 3_000 { reset(); baseUs = pts; index = 0 }
        // Before playback starts, an earlier packet (reordered or batched arrival) re-bases the timeline
        // instead of being discarded as late.
        if !playing, index < next, index >= next - Int64(capacityFrames) {
            let shift = next - index
            slots = Dictionary(uniqueKeysWithValues: slots.map { ($0.key + shift, $0.value) })
            baseUs = baseUs! - shift * frameUs
            index = next
        }
        guard index >= next else { late += 1; return }
        guard slots[index] == nil else { return }
        slots[index] = payload
        if slots.count > capacityFrames, let oldest = slots.keys.min() {
            slots[oldest] = nil; overflows += 1; next = max(next, oldest + 1)
        }
    }

    /// One 20 ms output slot.
    public mutating func pop() -> Output {
        if !playing {
            guard slots.count >= targetFrames, let first = slots.keys.min() else { return .silence }
            playing = true; next = max(next, first)
        }
        if let payload = slots.removeValue(forKey: next) {
            next += 1; concealRun = 0; played += 1
            return .packet(payload)
        }
        if slots.isEmpty {
            // Drained: stop, count an underrun and grow the target for bursty links.
            playing = false; underruns += 1; concealRun = 0
            targetFrames = min(maxTargetFrames, targetFrames + 2)
            return .silence
        }
        if fecRecovery, let following = slots[next + 1] {
            // The next packet carries this frame's LBRR copy when the sender enabled in-band FEC.
            next += 1; concealRun = 0; recovered += 1
            return .recover(fromNext: following)
        }
        next += 1; concealRun += 1; concealed += 1
        if concealRun > 10, let first = slots.keys.min() { next = first; concealRun = 0 }
        return .conceal
    }

    public mutating func reset() {
        slots.removeAll(); baseUs = nil; next = 0; playing = false; concealRun = 0; targetFrames = minTargetFrames
    }
}
