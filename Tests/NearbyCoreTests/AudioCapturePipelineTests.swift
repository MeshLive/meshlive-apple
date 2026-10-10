import XCTest
import AVFoundation
@testable import NearbyCore

/// Microphone formats -> PCMResampler (48 kHz mono) -> AudioCaptureFramer (960-sample Opus frames, us timestamps).
final class AudioCapturePipelineTests: XCTestCase {
    private func run(inputRate: Double, chunk: Int, seconds: Double = 1, tone: Double = 1_000) throws -> [(presentationTimeUs: Int64, samples: [Float])] {
        let input = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: inputRate, channels: 1, interleaved: false)!
        let output = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 48_000, channels: 1, interleaved: false)!
        let resampler = try PCMResampler(input: input, output: output)
        var framer = AudioCaptureFramer()
        var frames: [(presentationTimeUs: Int64, samples: [Float])] = []
        let total = Int(inputRate * seconds)
        var n = 0
        while n < total {
            let count = min(chunk, total - n)
            let buffer = AVAudioPCMBuffer(pcmFormat: input, frameCapacity: AVAudioFrameCount(count))!
            buffer.frameLength = AVAudioFrameCount(count)
            for i in 0..<count { buffer.floatChannelData![0][i] = Float(0.5 * sin(2 * .pi * tone * Double(n + i) / inputRate)) }
            n += count
            frames += framer.append(try resampler.convert(buffer), captureTimeUs: { 5_000_000 })
        }
        return frames
    }

    func testCommonMicrophoneRatesBecomeTwentyMillisecondFramesOnTheSampleClock() throws {
        // 48 kHz (iPhone 14 with voice processing), 44.1 kHz, 16 kHz and 24 kHz, in tap-sized chunks.
        for (rate, chunk) in [(48_000.0, 480), (44_100.0, 441), (16_000.0, 160), (24_000.0, 1_024)] {
            let frames = try run(inputRate: rate, chunk: chunk)
            XCTAssertTrue((48...50).contains(frames.count), "\(rate) Hz gave \(frames.count) frames")
            XCTAssertTrue(frames.allSatisfy { $0.samples.count == 960 })
            XCTAssertEqual(frames.first?.presentationTimeUs, 5_000_000)
            XCTAssertEqual(Set(zip(frames.dropFirst(), frames).map { $0.0.presentationTimeUs - $0.1.presentationTimeUs }), [20_000], "\(rate) Hz")
            // The tone survives resampling: ~1 kHz by zero crossings over the steady part.
            let samples = frames.dropFirst(2).flatMap(\.samples)
            let crossings = zip(samples, samples.dropFirst()).filter { $0.0 < 0 && $0.1 >= 0 }.count
            let hz = Double(crossings) / (Double(samples.count) / 48_000)
            XCTAssertEqual(hz, 1_000, accuracy: 20, "\(rate) Hz input")
            XCTAssertGreaterThan(samples.map { abs($0) }.max() ?? 0, 0.4)
        }
    }

    func testFramerKeepsRemaindersAndResets() {
        var framer = AudioCaptureFramer()
        XCTAssertTrue(framer.append([Float](repeating: 0, count: 959), captureTimeUs: { 1 }).isEmpty)
        let one = framer.append([0, 0], captureTimeUs: { 7 })
        XCTAssertEqual(one.count, 1); XCTAssertEqual(one[0].presentationTimeUs, 7); XCTAssertEqual(framer.bufferedSamples, 1)
        framer.reset(); XCTAssertEqual(framer.bufferedSamples, 0)
    }
}
