import Foundation

/// Capture side of call audio after resampling: collects 48 kHz mono samples into 20 ms (960-sample) Opus
/// frames and stamps each with a BTV3 presentation time in microseconds on the sample clock (the first
/// frame takes the capture time; later frames advance exactly 20 000 us), like Android's MediaCodec path.
public struct AudioCaptureFramer {
    public static let sampleRate = 48_000
    public static let frameSamples = 960
    private var pending: [Float] = []
    private var emittedSamples: Int64 = 0
    private var baseUs: Int64?

    public init() {}

    /// Appends resampled samples; returns the complete frames with their presentation times.
    public mutating func append(_ samples: [Float], captureTimeUs: () -> Int64) -> [(presentationTimeUs: Int64, samples: [Float])] {
        pending.append(contentsOf: samples)
        var frames: [(Int64, [Float])] = []
        while pending.count >= Self.frameSamples {
            let frame = Array(pending.prefix(Self.frameSamples)); pending.removeFirst(Self.frameSamples)
            if baseUs == nil { baseUs = captureTimeUs() }
            frames.append((baseUs! + emittedSamples * 1_000_000 / Int64(Self.sampleRate), frame))
            emittedSamples += Int64(Self.frameSamples)
        }
        return frames
    }

    public var bufferedSamples: Int { pending.count }
    public mutating func reset() { pending.removeAll(); emittedSamples = 0; baseUs = nil }
}
