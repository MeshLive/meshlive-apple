import Foundation
import AVFoundation
import VideoToolbox
import NearbyCore

struct VideoMetrics: Codable {
    var requested = "H.264 Baseline, 160×120, 5 FPS, 32 kbps; generated pattern"
    var effective = "Not configured"
    var hardwareEncoder: Bool?
    var encodedFrames = 0
    var decodedFrames = 0
    var shedFrames = 0
    var encodedBytes: UInt64 = 0
    var peakAccessUnit = 0
    var elapsed: Double = 0
}

/// Controlled generated live target. No camera access, file recording, or private scene capture.
final class PatternVideo {
    private let queue = DispatchQueue(label: "io.github.meshlive.app.video", qos: .utility)
    private var compression: VTCompressionSession?
    private var decompression: VTDecompressionSession?
    private var format: CMVideoFormatDescription?
    private var configuration: VideoConfiguration?
    private var dependency = VideoDependencyGate()
    private var timer: DispatchSourceTimer?
    private var index: Int64 = 0
    private var forceIDR = true
    private var running = false
    private var pending = 0
    private var pendingDecode = 0
    private var epoch: TimeInterval = 0
    private var finishing = false
    private var completion: (() -> Void)?
    private enum Ingress { case config(VideoConfiguration), frame(VideoFrame) }
    private let ingress = BoundedMailbox<Ingress>(capacity: 4)
    private let ingressLock = NSLock()
    private var ingressStopped = false
    private var metrics = VideoMetrics()
    var onConfig: ((VideoConfiguration) -> Void)?
    var onFrame: ((VideoFrame) -> Void)?
    var onImage: ((CVPixelBuffer) -> Void)?
    var onMetrics: ((VideoMetrics) -> Void)?
    var onFailure: ((String) -> Void)?
    var allowEncode: (() -> Bool)? // Must not inspect main-owned state from this queue.
    func requestKeyframe() { queue.async { [self] in forceIDR = true; metrics.shedFrames += 1 } }

    func start(loopback: Bool = false, frames: Int? = nil, completion: (() -> Void)? = nil) {
        queue.async { [self] in
            do {
                guard !running else { return }
                self.completion = completion; finishing = false; index = 0; metrics = VideoMetrics(); forceIDR = true
                try createEncoder(); running = true; epoch = ProcessInfo.processInfo.systemUptime
                let timer = DispatchSource.makeTimerSource(queue: queue); self.timer = timer
                timer.schedule(deadline: .now(), repeating: .milliseconds(200), leeway: .milliseconds(5))
                timer.setEventHandler { [weak self] in
                    guard let self, self.running else { return }
                    if let frames, self.index >= frames {
                        self.timer?.cancel(); self.timer = nil; self.finishing = true; self.finishEncoder(); self.maybeFinish(); return
                    }
                    do { try self.encode(loopback: loopback) } catch { self.onFailure?(String(describing: error)); self.stopOnQueue(); completion?() }
                }; timer.resume()
            } catch { onFailure?("VideoToolbox encoder unavailable: \(error)"); stopOnQueue(); completion?() }
        }
    }
    private func check(_ status: OSStatus, _ action: String) throws { if status != noErr { throw ProtocolError.state("\(action): OSStatus \(status)") } }
    private func createEncoder() throws {
        try check(VTCompressionSessionCreate(allocator: nil, width: 160, height: 120, codecType: kCMVideoCodecType_H264, encoderSpecification: nil, imageBufferAttributes: nil, compressedDataAllocator: nil,
            outputCallback: { refcon, source, status, _, sample in
                guard let refcon else { return }; let owner = Unmanaged<PatternVideo>.fromOpaque(refcon).takeUnretainedValue()
                let loopback = source != nil
                owner.queue.async { owner.encoded(status: status, sample: sample, loopback: loopback) }
            }, refcon: Unmanaged.passUnretained(self).toOpaque(), compressionSessionOut: &compression), "Create H.264 encoder")
        guard let compression else { throw ProtocolError.state("No encoder") }
        for (key, value) in [(kVTCompressionPropertyKey_RealTime, kCFBooleanTrue as CFTypeRef),
                             (kVTCompressionPropertyKey_AllowFrameReordering, kCFBooleanFalse as CFTypeRef),
                             (kVTCompressionPropertyKey_ProfileLevel, kVTProfileLevel_H264_Baseline_AutoLevel as CFTypeRef),
                             (kVTCompressionPropertyKey_AverageBitRate, 32_000 as CFNumber),
                             (kVTCompressionPropertyKey_ExpectedFrameRate, 5 as CFNumber),
                             (kVTCompressionPropertyKey_MaxKeyFrameInterval, 10 as CFNumber)] {
            try check(VTSessionSetProperty(compression, key: key, value: value), "Set \(key)")
        }
        try check(VTSessionSetProperty(compression, key: kVTCompressionPropertyKey_DataRateLimits, value: [8000,1] as CFArray), "Set video burst limit")
        try check(VTCompressionSessionPrepareToEncodeFrames(compression), "Prepare H.264 encoder")
        if #available(iOS 17.4, macOS 10.9, *) {
            let slot = UnsafeMutablePointer<Unmanaged<CFTypeRef>?>.allocate(capacity: 1)
            slot.initialize(to: nil)
            VTSessionCopyProperty(compression, key: kVTCompressionPropertyKey_UsingHardwareAcceleratedVideoEncoder, allocator: nil, valueOut: slot)
            metrics.hardwareEncoder = slot.pointee?.takeRetainedValue() as? Bool
            slot.deinitialize(count: 1); slot.deallocate()
        }
        metrics.effective = "Encoder created; effective output is measured from access units and format descriptions"
        onMetrics?(metrics)
    }
    private func encode(loopback: Bool) throws {
        guard let compression else { return }
        defer { index += 1 }
        guard pending < 2, allowEncode?() ?? true else { forceIDR = true; metrics.shedFrames += 1; return }
        var pixel: CVPixelBuffer?
        try check(CVPixelBufferCreate(nil, 160, 120, kCVPixelFormatType_32BGRA, [kCVPixelBufferIOSurfacePropertiesKey: [:]] as CFDictionary, &pixel), "Create generated pattern")
        guard let pixel else { throw ProtocolError.state("No pattern buffer") }
        CVPixelBufferLockBaseAddress(pixel, [])
        let base = CVPixelBufferGetBaseAddress(pixel)!.assumingMemoryBound(to: UInt8.self), stride = CVPixelBufferGetBytesPerRow(pixel)
        for y in 0..<120 { for x in 0..<160 {
            let p = base.advanced(by: y * stride + x * 4)
            let stripe = (x + Int(index) * 3) % 160 < 24
            p[0] = stripe ? 240 : 30; p[1] = UInt8(y * 2); p[2] = UInt8(x); p[3] = 255
        } }; CVPixelBufferUnlockBaseAddress(pixel, [])
        let properties = forceIDR ? [kVTEncodeFrameOptionKey_ForceKeyFrame: true] as CFDictionary : nil
        forceIDR = false; pending += 1
        try check(VTCompressionSessionEncodeFrame(compression, imageBuffer: pixel, presentationTimeStamp: CMTime(value: index, timescale: 5), duration: CMTime(value: 1, timescale: 5), frameProperties: properties,
            sourceFrameRefcon: loopback ? UnsafeMutableRawPointer(bitPattern: 1) : nil, infoFlagsOut: nil), "Encode pattern")
    }
    private func encoded(status: OSStatus, sample: CMSampleBuffer?, loopback: Bool) {
        defer { maybeFinish() }
        pending = max(0, pending - 1)
        guard running, status == noErr, let sample, CMSampleBufferDataIsReady(sample) else { if running { forceIDR = true; onFailure?("H.264 output failed: \(status)") }; return }
        do {
            guard let description = CMSampleBufferGetFormatDescription(sample), let block = CMSampleBufferGetDataBuffer(sample) else { throw ProtocolError.malformed("H.264 output has no format/data") }
            let dimensions = CMVideoFormatDescriptionGetDimensions(description)
            guard dimensions.width == 160, dimensions.height == 120 else { throw ProtocolError.incompatible("Effective video dimensions differ") }
            let config = try parameterSets(description)
            if config != configuration {
                configuration = config; onConfig?(config); if loopback { try configureDecoder(config) }
            }
            let length = CMBlockBufferGetDataLength(block)
            guard length <= 24_000 else { forceIDR = true; metrics.shedFrames += 1; return }
            var bytes = Data(count: length)
            try check(bytes.withUnsafeMutableBytes { CMBlockBufferCopyDataBytes(block, atOffset: 0, dataLength: length, destination: $0.baseAddress!) }, "Copy AVCC")
            let attachments = CMSampleBufferGetSampleAttachmentsArray(sample, createIfNecessary: false) as? [[CFString: Any]]
            let key = (attachments?.first?[kCMSampleAttachmentKey_NotSync] as? Bool) != true
            let timestamp = UInt64(CMTimeConvertScale(CMSampleBufferGetPresentationTimeStamp(sample), timescale: 1_000_000, method: .default).value)
            let frame = try VideoFrame(timestamp: timestamp, keyframe: key, discontinuity: key, avcc: bytes)
            metrics.encodedFrames += 1; metrics.encodedBytes += UInt64(length); metrics.peakAccessUnit = max(metrics.peakAccessUnit, length)
            metrics.effective = "H.264 \(dimensions.width)×\(dimensions.height); \(length) B latest access unit"
            onFrame?(frame); if loopback { try decode(frame) }
            if metrics.encodedFrames % 5 == 0 { metrics.elapsed = ProcessInfo.processInfo.systemUptime - epoch; onMetrics?(metrics) }
        } catch { forceIDR = true; onFailure?("H.264 output rejected: \(error)") }
    }
    private func parameterSets(_ description: CMVideoFormatDescription) throws -> VideoConfiguration {
        var sets: [Data] = []
        for i in 0..<2 {
            var pointer: UnsafePointer<UInt8>?, size = 0, count = 0; var header: Int32 = 0
            try check(CMVideoFormatDescriptionGetH264ParameterSetAtIndex(description, parameterSetIndex: i, parameterSetPointerOut: &pointer, parameterSetSizeOut: &size, parameterSetCountOut: &count, nalUnitHeaderLengthOut: &header), "Read SPS/PPS")
            guard let pointer, header == 4 else { throw ProtocolError.incompatible("H.264 NAL length is not 4 bytes") }
            sets.append(Data(bytes: pointer, count: size))
        }
        return try VideoConfiguration(sps: sets[0], pps: sets[1])
    }
    func receiveConfig(_ config: VideoConfiguration) { receive(.config(config)) }
    func receive(_ frame: VideoFrame) { receive(.frame(frame)) }
    private func receive(_ item: Ingress) {
        ingressLock.lock()
        guard !ingressStopped else { ingressLock.unlock(); return }
        guard let notify = ingress.offer(item) else {
            ingressStopped = true; ingressLock.unlock()
            queue.async { [self] in onFailure?("Video receive queue exceeded four records; experiment stopped"); stopOnQueue() }
            return
        }
        ingressLock.unlock()
        if notify { queue.async { [self] in
            for item in ingress.takeAll() {
                do {
                    switch item { case .config(let config): try configureDecoder(config); case .frame(let frame): try decode(frame) }
                } catch { dependency.decoderFailed(); onFailure?("H.264 receive failed: \(error)"); stopOnQueue(); break }
            }
        } }
    }
    private func configureDecoder(_ config: VideoConfiguration) throws {
        if let decompression { VTDecompressionSessionWaitForAsynchronousFrames(decompression); VTDecompressionSessionInvalidate(decompression) }
        decompression = nil; format = nil; dependency.configurationChanged()
        try config.sps.withUnsafeBytes { s in try config.pps.withUnsafeBytes { p in
            var pointers = [s.bindMemory(to: UInt8.self).baseAddress!, p.bindMemory(to: UInt8.self).baseAddress!]
            var sizes = [s.count,p.count]
            try check(CMVideoFormatDescriptionCreateFromH264ParameterSets(allocator: nil, parameterSetCount: 2, parameterSetPointers: &pointers, parameterSetSizes: &sizes, nalUnitHeaderLength: 4, formatDescriptionOut: &format), "Create H.264 format")
        } }
        let dimensions = CMVideoFormatDescriptionGetDimensions(format!)
        guard dimensions.width == 160, dimensions.height == 120 else { throw ProtocolError.incompatible("SPS dimensions differ from the negotiated 160×120 profile") }
        var callback = VTDecompressionOutputCallbackRecord(decompressionOutputCallback: { refcon, _, status, _, pixel, _, _ in
            guard let refcon else { return }; let owner = Unmanaged<PatternVideo>.fromOpaque(refcon).takeUnretainedValue()
            owner.queue.async {
                defer { owner.maybeFinish() }
                owner.pendingDecode = max(0, owner.pendingDecode - 1)
                guard status == noErr, let pixel else { owner.dependency.decoderFailed(); owner.onFailure?("H.264 decoder output: \(status)"); return }
                owner.metrics.decodedFrames += 1; owner.onImage?(pixel)
                if owner.metrics.decodedFrames % 5 == 0 { owner.onMetrics?(owner.metrics) }
            }
        }, decompressionOutputRefCon: Unmanaged.passUnretained(self).toOpaque())
        try check(VTDecompressionSessionCreate(allocator: nil, formatDescription: format!, decoderSpecification: nil, imageBufferAttributes: [kCVPixelBufferPixelFormatTypeKey: kCVPixelFormatType_32BGRA] as CFDictionary, outputCallback: &callback, decompressionSessionOut: &decompression), "Create H.264 decoder")
    }
    private func decode(_ frame: VideoFrame) throws {
        guard let decompression, let format else { throw ProtocolError.state("Video configuration missing") }
        guard try dependency.accept(frame) else { metrics.shedFrames += 1; return }
        guard pendingDecode < 3 else { dependency.decoderFailed(); metrics.shedFrames += 1; return }
        var block: CMBlockBuffer?
        try check(CMBlockBufferCreateWithMemoryBlock(allocator: nil, memoryBlock: nil, blockLength: frame.avcc.count, blockAllocator: nil, customBlockSource: nil, offsetToData: 0, dataLength: frame.avcc.count, flags: 0, blockBufferOut: &block), "Create decode block")
        try check(frame.avcc.withUnsafeBytes { CMBlockBufferReplaceDataBytes(with: $0.baseAddress!, blockBuffer: block!, offsetIntoDestination: 0, dataLength: $0.count) }, "Copy decode block")
        var timing = CMSampleTimingInfo(duration: CMTime(value: 1, timescale: 5), presentationTimeStamp: CMTime(value: Int64(frame.timestamp), timescale: 1_000_000), decodeTimeStamp: .invalid)
        var sample: CMSampleBuffer?, size = frame.avcc.count
        try check(CMSampleBufferCreateReady(allocator: nil, dataBuffer: block, formatDescription: format, sampleCount: 1, sampleTimingEntryCount: 1, sampleTimingArray: &timing, sampleSizeEntryCount: 1, sampleSizeArray: &size, sampleBufferOut: &sample), "Create decode sample")
        pendingDecode += 1
        let status = VTDecompressionSessionDecodeFrame(decompression, sampleBuffer: sample!, flags: [], frameRefcon: nil, infoFlagsOut: nil)
        if status != noErr { pendingDecode -= 1 }; try check(status, "Decode H.264")
    }
    private func finishEncoder() { if let compression { VTCompressionSessionCompleteFrames(compression, untilPresentationTimeStamp: .invalid) } }
    private func maybeFinish() {
        guard finishing, pending == 0, pendingDecode == 0 else { return }
        metrics.elapsed = ProcessInfo.processInfo.systemUptime - epoch; onMetrics?(metrics)
        let completion = self.completion; self.completion = nil; stopOnQueue(); completion?()
    }
    func stop() { queue.async { [self] in stopOnQueue() } }
    private func stopOnQueue() {
        ingressLock.lock(); ingressStopped = true; ingressLock.unlock(); _ = ingress.takeAll()
        running = false; timer?.setEventHandler {}; timer?.cancel(); timer = nil
        if let compression { VTCompressionSessionCompleteFrames(compression, untilPresentationTimeStamp: .invalid); VTCompressionSessionInvalidate(compression) }; compression = nil
        if let decompression { VTDecompressionSessionWaitForAsynchronousFrames(decompression); VTDecompressionSessionInvalidate(decompression) }; decompression = nil
    }
}
