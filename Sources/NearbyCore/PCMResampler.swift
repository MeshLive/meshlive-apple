import Foundation
import AVFoundation

/// Stateful converter shared by capture and executable generated-signal checks.
/// Call on a media worker, never on a render callback.
public final class PCMResampler {
    private let converter: AVAudioConverter
    private let output: AVAudioPCMBuffer
    public var leadingFrames: UInt32 { converter.primeInfo.leadingFrames }
    public init(input: AVAudioFormat, output: AVAudioFormat) throws {
        guard let converter = AVAudioConverter(from: input, to: output),
              let buffer = AVAudioPCMBuffer(pcmFormat: output, frameCapacity: 4096),
              input.channelCount == 1, output.channelCount == 1,
              input.commonFormat == .pcmFormatFloat32, output.commonFormat == .pcmFormatFloat32 else {
            throw ProtocolError.incompatible("Resampler requires mono Float32 formats")
        }
        self.converter = converter; self.output = buffer
    }
    public func reset() { converter.reset() }
    public func convert(_ source: AVAudioPCMBuffer?, ending: Bool = false) throws -> [Float] {
        var supplied = false, iterations = 0; var result: [Float] = []
        while true {
            iterations += 1; guard iterations <= 8 else { throw ProtocolError.limit("Converter output backlog") }
            var error: NSError?
            let status = converter.convert(to: output, error: &error) { _, inputStatus in
                if let source, !supplied { supplied = true; inputStatus.pointee = .haveData; return source }
                inputStatus.pointee = ending ? .endOfStream : .noDataNow; return nil
            }
            if status == .error { throw error ?? ProtocolError.state("Sample conversion error") as NSError }
            if output.frameLength > 0 { result.append(contentsOf: UnsafeBufferPointer(start: output.floatChannelData![0], count: Int(output.frameLength))) }
            if status == .inputRanDry || status == .endOfStream || output.frameLength == 0 { return result }
        }
    }
}
