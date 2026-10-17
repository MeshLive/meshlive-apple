import Foundation
import CryptoKit

// Experimental audio-only live streams ("radio"): Android AudioLiveProtocol.kt. Wire rules: PROTOCOL.md
// "Experimental audio-only live streams" in the Android project; design and reasons: DECISIONS "Design AL".
// The offer marker, the BTL1 header with its signer block, source-signed records and the receiver's guard
// (Opus profile, ingress budgets, clock rules). Nothing here touches video streams.

public enum AudioLive {
    public static let headerMagic = Data("BTL1".utf8)
    public static let fixedHeaderBytes = 11
    public static let frameMs: UInt8 = 20
    public static let frameUs: Int64 = 20_000
    public static let frameSamples = 960
    public static let zeroStreamId = UUID(uuid: (0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0))
    public static let maxOpusUnitBytes = 1275
    public static let presetLowData: UInt8 = 1
    public static let presetVoice: UInt8 = 2
    public static let presetMusic: UInt8 = 3
    public static let defaultBatchFrames = 10
    public static let minBatchFrames = 1
    public static let maxBatchFrames = 20
    /// `capabilitySummary` of a stream offer that carries audio only (exactly this value, zero geometry).
    public static let summaryAudioOnly: UInt8 = 0x40
    public static let signatureBytes = 64
    public static let seqBytes = 4
    public static let maxSpkiBytes = 128
    public static let maxCertSignatureBytes = 80
    /// Largest signed record payload: sequence + a 20-unit batch of maximum units + signature.
    public static let maxRecordPayloadBytes = seqBytes + 5 + maxBatchFrames * (6 + maxOpusUnitBytes) + signatureBytes
    static let certDomain = Data("BluetoothVideoMesh/AudioLive/Cert/1".utf8) + Data([0])
    static let recordDomain = Data("BluetoothVideoMesh/AudioLive/Rec/1".utf8) + Data([0])

    public static func isValidPreset(_ preset: UInt8) -> Bool { (presetLowData...presetMusic).contains(preset) }

    /// Nominal Opus rate of a preset in kbps (display and encoder configuration).
    public static func presetKbps(_ preset: UInt8) -> Int {
        switch preset { case presetLowData: return 16; case presetMusic: return 48; default: return 24 }
    }

    /// The 11 fixed header bytes: `BTL1`, Opus, 48000, mono, 20 ms, preset, reserved 0.
    public static func fixedHeader(preset: UInt8) -> Data {
        var w = BinaryWriter(capacity: fixedHeaderBytes)
        w.bytes(headerMagic); w.byte(StreamProtocol.audioCodecOpus); w.u16(UInt16(StreamProtocol.audioSampleRate))
        w.byte(UInt8(StreamProtocol.audioChannelCount)); w.byte(frameMs); w.byte(preset); w.byte(0)
        return w.data
    }

    static func certMessage(streamId: UUID, preset: UInt8, streamKeySpki: Data) -> Data {
        certDomain + streamId.rawBytes + fixedHeader(preset: preset) + streamKeySpki
    }

    static func recordMessage(streamId: UUID, flags: UInt8, presentationTimeUs: Int64, seq: UInt32, body: Data) -> Data {
        var w = BinaryWriter(capacity: recordDomain.count + 29 + body.count)
        w.bytes(recordDomain); w.bytes(streamId.rawBytes); w.byte(flags); w.i64(presentationTimeUs); w.u32(seq); w.bytes(body)
        return w.data
    }

    /// True when the payload starts with the audio-only header magic (dispatch before a strict decode).
    public static func isAudioLiveHeader(_ payload: Data) -> Bool { payload.rebased.prefix(4) == headerMagic }
}

public enum StreamOfferKind: Equatable { case video, audioOnly, malformed }

public extension DiscoveryAnnouncement {
    /// Bit 6 of `capabilitySummary` is the audio-only marker only as exactly `0x40` on a stream offer with zero
    /// geometry; any other use of the bit is malformed (ignored by the Live list). Without bit 6: a video offer.
    var streamOfferKind: StreamOfferKind {
        guard capabilitySummary & AudioLive.summaryAudioOnly != 0 else { return .video }
        guard isStreamOffer, capabilitySummary == AudioLive.summaryAudioOnly,
              streamWidth == 0, streamHeight == 0, streamFps == 0 else { return .malformed }
        return .audioOnly
    }
    var isAudioOnlyOffer: Bool { streamOfferKind == .audioOnly }
}

/// The parsed `BTL1` header: fixed part plus the signer block (stream key, identity key, certificate).
public struct AudioLiveHeader: Equatable {
    public let preset: UInt8
    public let streamKeySpki: Data
    public let identitySpki: Data
    /// DER ECDSA signature by the identity key over `certMessage`.
    public let certificate: Data

    public init(preset: UInt8, streamKeySpki: Data, identitySpki: Data, certificate: Data) {
        self.preset = preset; self.streamKeySpki = streamKeySpki; self.identitySpki = identitySpki; self.certificate = certificate
    }

    public var encoded: Data {
        var w = BinaryWriter()
        w.bytes(AudioLive.fixedHeader(preset: preset))
        for block in [streamKeySpki, identitySpki, certificate] { w.u16(UInt16(block.count)); w.bytes(block) }
        return w.data
    }

    /// Strict decode: any other codec, rate, channel count, frame size, preset, a non-zero reserved byte, a bad
    /// block length or trailing bytes fail the stream closed.
    public init(decoding data: Data) throws {
        var r = BinaryReader(data)
        guard try r.bytes(4) == AudioLive.headerMagic else { throw ProtocolError.incompatible("Unsupported stream header") }
        guard try r.byte() == StreamProtocol.audioCodecOpus else { throw ProtocolError.incompatible("Unsupported audio live codec") }
        guard Int(try r.u16()) == StreamProtocol.audioSampleRate else { throw ProtocolError.incompatible("Unsupported audio live sample rate") }
        guard Int(try r.byte()) == StreamProtocol.audioChannelCount else { throw ProtocolError.incompatible("Unsupported audio live channel count") }
        guard try r.byte() == AudioLive.frameMs else { throw ProtocolError.incompatible("Unsupported audio live frame duration") }
        let preset = try r.byte()
        guard AudioLive.isValidPreset(preset) else { throw ProtocolError.malformed("Invalid audio live preset \(preset)") }
        guard try r.byte() == 0 else { throw ProtocolError.malformed("Invalid audio live reserved byte") }
        func block(_ max: Int, _ what: String) throws -> Data {
            let size = Int(try r.u16())
            guard (1...max).contains(size) else { throw ProtocolError.malformed("Invalid audio live \(what) length \(size)") }
            return try r.bytes(size)
        }
        self.preset = preset
        streamKeySpki = try block(AudioLive.maxSpkiBytes, "stream key")
        identitySpki = try block(AudioLive.maxSpkiBytes, "identity key")
        certificate = try block(AudioLive.maxCertSignatureBytes, "certificate")
        try r.end()
    }
}

/// Source side: a fresh per-stream P-256 key certified once by the identity key; every record is
/// `seq(4) || body || signature(64)`, signed once and shared by every listener.
public final class AudioLiveSigner {
    public let streamId: UUID
    public let preset: UInt8
    public let header: AudioLiveHeader
    private let streamKey: P256.Signing.PrivateKey
    private var nextSeq: UInt64 = 0
    private let lock = NSLock()

    public init(identity: SigningIdentity, streamId: UUID, preset: UInt8, streamKey: P256.Signing.PrivateKey = .init()) throws {
        guard AudioLive.isValidPreset(preset) else { throw ProtocolError.malformed("Invalid audio live preset \(preset)") }
        self.streamId = streamId; self.preset = preset; self.streamKey = streamKey
        let spki = streamKey.publicKey.derRepresentation
        let certificate = try identity.sign(AudioLive.certMessage(streamId: streamId, preset: preset, streamKeySpki: spki))
        header = AudioLiveHeader(preset: preset, streamKeySpki: spki, identitySpki: identity.publicKeyEncoded, certificate: certificate)
    }

    /// Signs one record; `body` is what an unsigned audio record carries (OpusHead, one unit, BTA1 or BTA2).
    public func sign(flags: UInt8, presentationTimeUs: Int64, body: Data) throws -> MediaPacket {
        lock.lock(); defer { lock.unlock() }
        guard nextSeq <= UInt64(UInt32.max) else { throw ProtocolError.state("Audio signing sequence exhausted") }
        let seq = UInt32(nextSeq); nextSeq += 1
        let message = AudioLive.recordMessage(streamId: streamId, flags: flags, presentationTimeUs: presentationTimeUs, seq: seq, body: body)
        let signature = try streamKey.signature(for: message).rawRepresentation
        var w = BinaryWriter(capacity: AudioLive.seqBytes + body.count + AudioLive.signatureBytes)
        w.u32(seq); w.bytes(body); w.bytes(signature)
        return MediaPacket(flags: flags, presentationTimeUs: presentationTimeUs, payload: w.data)
    }
}

/// Listener side: the certifying identity key must hash to the source node ID the reader already authenticated,
/// the certificate must verify, then every record's signature and the strictly increasing sequence.
public final class AudioLiveVerifier {
    private let streamId: UUID
    private let streamKey: P256.Signing.PublicKey
    private var lastAudioSeq: Int64 = -1

    public init(header: AudioLiveHeader, streamId: UUID, expectedSource: NodeId) throws {
        guard NodeId.fromPublicKey(header.identitySpki) == expectedSource else {
            throw ProtocolError.authentication
        }
        guard let identityKey = try? P256.Signing.PublicKey(derRepresentation: header.identitySpki),
              let streamKey = try? P256.Signing.PublicKey(derRepresentation: header.streamKeySpki) else {
            throw ProtocolError.malformed("Audio stream keys must be P-256")
        }
        // Canonical SPKI only (the keys are hashed and signed as sent).
        guard identityKey.derRepresentation == header.identitySpki, streamKey.derRepresentation == header.streamKeySpki else {
            throw ProtocolError.malformed("Audio stream keys must be P-256")
        }
        guard let certificate = try? P256.Signing.ECDSASignature(derRepresentation: header.certificate),
              identityKey.isValidSignature(certificate, for: AudioLive.certMessage(streamId: streamId, preset: header.preset, streamKeySpki: header.streamKeySpki)) else {
            throw ProtocolError.authentication
        }
        self.streamId = streamId; self.streamKey = streamKey
    }

    /// Checks the signature and the sequence rule and strips the envelope; returns the unsigned packet and seq.
    public func open(_ packet: MediaPacket) throws -> (packet: MediaPacket, seq: Int64) {
        let payload = packet.payload
        guard payload.count >= AudioLive.seqBytes + AudioLive.signatureBytes + 1 else { throw ProtocolError.malformed("Unsigned or truncated audio record") }
        var r = BinaryReader(payload)
        let seq = Int64(try r.u32())
        let body = payload.subdata(in: AudioLive.seqBytes..<(payload.count - AudioLive.signatureBytes)).rebased
        let raw = payload.suffix(AudioLive.signatureBytes).rebased
        let message = AudioLive.recordMessage(streamId: streamId, flags: packet.flags, presentationTimeUs: packet.presentationTimeUs,
                                              seq: UInt32(seq), body: body)
        guard let signature = try? Bmh3Crypto.rawSignature(raw), streamKey.isValidSignature(signature, for: message) else {
            throw ProtocolError.authentication
        }
        if packet.flags & StreamProtocol.flagCodecConfig == 0 {
            // Strictly increasing (gaps are legitimate after age shedding); replayed or reordered records fail.
            guard seq > lastAudioSeq else { throw ProtocolError.replay }
            lastAudioSeq = seq
        }
        return (MediaPacket(flags: packet.flags, presentationTimeUs: packet.presentationTimeUs, payload: body), seq)
    }
}

/// The Opus packet rules of this profile (RFC 6716 section 3.1 table-of-contents byte).
public enum AudioLiveOpus {
    static let twentyMsConfigs: Set<Int> = [1, 5, 9, 13, 15, 19, 23, 27, 31]

    /// Exactly one 20 ms mono frame: TOC code 0, stereo bit clear, a 20 ms configuration, 1 to 1275 bytes.
    public static func isSingle20msMonoFrame(_ unit: Data) -> Bool {
        let u = unit.rebased
        guard !u.isEmpty, u.count <= AudioLive.maxOpusUnitBytes else { return false }
        let toc = Int(u[0])
        return toc & 0x3 == 0 && toc & 0x4 == 0 && twentyMsConfigs.contains(toc >> 3)
    }

    /// The configuration must be an OpusHead (directly, or in Android MediaCodec's AOPUSHDR marker block) for
    /// version 1, one channel, mapping family 0.
    public static func isMonoConfig(_ payload: Data) -> Bool {
        guard let head = opusHead(payload.rebased) else { return false }
        return head.count >= 19 && head[8] == 1 && head[9] == 1 && head[18] == 0
    }

    static func opusHead(_ data: Data) -> Data? {
        if data.prefix(8) == Data("AOPUSHDR".utf8) {
            var offset = 0
            while data.count - offset >= 16 {
                let marker = data.subdata(in: offset..<offset + 8)
                var length: UInt64 = 0
                for i in 0..<8 { length |= UInt64(data[offset + 8 + i]) << (8 * UInt64(i)) } // little endian
                offset += 16
                guard length <= UInt64(data.count - offset) else { return nil }
                let value = data.subdata(in: offset..<offset + Int(length))
                offset += Int(length)
                if marker == Data("AOPUSHDR".utf8) { return opusHead(value.rebased) }
            }
            return nil
        }
        guard data.prefix(8) == Data("OpusHead".utf8), data.count >= 19 else { return nil }
        return data
    }
}

/// A refilling budget: `capacity` units, `refillPerSecond` units per second.
struct TokenBudget {
    let capacity: Double, refillPerSecond: Double
    private var tokens: Double
    private var lastMs: Int64
    init(capacity: Double, refillPerSecond: Double, nowMs: Int64) {
        self.capacity = capacity; self.refillPerSecond = refillPerSecond; tokens = capacity; lastMs = nowMs
    }
    mutating func tryTake(_ amount: Double, nowMs: Int64) -> Bool {
        tokens = min(capacity, tokens + Double(max(0, nowMs - lastMs)) * refillPerSecond / 1_000)
        lastMs = nowMs
        guard tokens >= amount else { return false }
        tokens -= amount
        return true
    }
}

/// Receiver-side rules for a `BTL1` stream, applied to every record after the header (Android
/// AudioLiveStreamGuard): flags, size, ingress budgets, signature and sequence, one fixed OpusHead, the 20 ms
/// mono unit rule, contiguous units, and the gap and burst clock rules. Every violation throws: the stream fails closed.
public final class AudioLiveStreamGuard {
    public static let maxConfigRecords = 4
    static let recordsPerSecond = 60.0, recordBurst = 600.0
    static let bytesPerSecond = 16_000.0, byteBurst = 512.0 * 1024
    static let controlPerSecond = 4.0, controlBurst = 40.0
    static let gapSlackUs: Int64 = 100_000
    static let maxRecordSpanUs: Int64 = Int64(AudioLive.maxBatchFrames) * AudioLive.frameUs
    static let maxGapUs: Int64 = 60_000_000
    static let burstAllowanceMs: Int64 = 32_000
    static let disallowedFlags: UInt8 = StreamProtocol.flagKeyFrame | StreamProtocol.flagDisplayRotation | StreamProtocol.flagDebugIntegrity
        | StreamProtocol.flagDiscontinuity | StreamProtocol.flagDiscardable

    private let verifier: AudioLiveVerifier
    private let clockMs: () -> Int64
    private var codecConfig: Data?
    private var configRecords = 0
    private var previousEndUs: Int64?
    private var previousSeq: Int64 = -1
    private var maxOffsetMs: Int64?
    private var recordBudget: TokenBudget, byteBudget: TokenBudget, controlBudget: TokenBudget
    public private(set) var verifiedRecords = 0
    public private(set) var lastSeq: Int64 = -1

    public init(verifier: AudioLiveVerifier, clockMs: @escaping () -> Int64 = { Int64(ProcessInfo.processInfo.systemUptime * 1_000) }) {
        self.verifier = verifier; self.clockMs = clockMs
        let now = clockMs()
        recordBudget = TokenBudget(capacity: Self.recordBurst, refillPerSecond: Self.recordsPerSecond, nowMs: now)
        byteBudget = TokenBudget(capacity: Self.byteBurst, refillPerSecond: Self.bytesPerSecond, nowMs: now)
        controlBudget = TokenBudget(capacity: Self.controlBurst, refillPerSecond: Self.controlPerSecond, nowMs: now)
    }

    /// The OpusHead of the stream, once its configuration record verified.
    public var opusHead: Data? { codecConfig.flatMap { AudioLiveOpus.opusHead($0) } }

    /// A lifecycle record (pause, resume, end) is rate limited and restarts the media-clock baseline (not `seq`).
    public func onLifecycleRecord() throws {
        guard controlBudget.tryTake(1, nowMs: clockMs()) else { throw ProtocolError.malformed("Lifecycle records arrive too fast") }
        previousEndUs = nil; maxOffsetMs = nil; previousSeq = -1
    }

    /// Checked on the decrypted record before it is parsed.
    public func checkSealedSize(_ plaintextBytes: Int) throws {
        guard plaintextBytes <= AudioLive.maxRecordPayloadBytes + StreamProtocol.packetHeaderBytes else {
            throw ProtocolError.malformed("Audio record of \(plaintextBytes) bytes exceeds the stream limit")
        }
    }

    /// Verifies and checks one record; returns the unsigned packet (same flags and timestamp) for the pipeline.
    public func open(_ packet: MediaPacket) throws -> MediaPacket {
        let flags = packet.flags
        guard flags & StreamProtocol.flagAudio != 0 else { throw ProtocolError.malformed("Video packet on an audio-only stream") }
        guard flags & Self.disallowedFlags == 0 else { throw ProtocolError.malformed("Flag \(flags) is not valid on an audio-only stream") }
        guard packet.payload.count <= AudioLive.maxRecordPayloadBytes else { throw ProtocolError.malformed("Audio record exceeds the stream limit") }
        let now = clockMs()
        guard recordBudget.tryTake(1, nowMs: now) else { throw ProtocolError.malformed("Audio records arrive too fast") }
        guard byteBudget.tryTake(Double(packet.payload.count), nowMs: now) else { throw ProtocolError.malformed("Audio bytes arrive too fast") }
        let opened = try verifier.open(packet)
        let body = opened.packet
        if flags & StreamProtocol.flagCodecConfig != 0 {
            guard flags == StreamProtocol.flagAudio | StreamProtocol.flagCodecConfig else { throw ProtocolError.malformed("An Opus configuration cannot be batched") }
            configRecords += 1
            guard configRecords <= Self.maxConfigRecords else { throw ProtocolError.malformed("Too many Opus configuration records") }
            guard AudioLiveOpus.isMonoConfig(body.payload) else { throw ProtocolError.incompatible("Opus configuration is not mono") }
            if let known = codecConfig {
                guard known == body.payload else { throw ProtocolError.malformed("Opus configuration changed on an audio-only stream") }
            } else {
                codecConfig = body.payload
            }
            verifiedRecords += 1
            return body
        }
        let units = flags & StreamProtocol.flagAudioPair != 0 ? try body.splitAudio() : [body]
        guard (AudioLive.minBatchFrames...AudioLive.maxBatchFrames).contains(units.count) else { throw ProtocolError.malformed("Invalid audio unit count") }
        let firstUs = units[0].presentationTimeUs
        for (index, unit) in units.enumerated() {
            guard AudioLiveOpus.isSingle20msMonoFrame(unit.payload) else { throw ProtocolError.incompatible("Not a single 20 ms mono Opus frame") }
            guard unit.presentationTimeUs == firstUs + Int64(index) * AudioLive.frameUs else { throw ProtocolError.malformed("Audio units are not contiguous 20 ms steps") }
        }
        try checkGap(firstUs: firstUs, seq: opened.seq)
        previousEndUs = firstUs + Int64(units.count) * AudioLive.frameUs
        previousSeq = opened.seq
        try checkBurst(firstUs: firstUs, nowMs: now)
        verifiedRecords += 1
        lastSeq = opened.seq
        return body
    }

    private func checkGap(firstUs: Int64, seq: Int64) throws {
        guard let end = previousEndUs else { return }
        let step = firstUs - end
        guard step >= 0 else { throw ProtocolError.malformed("Audio timestamps overlap") }
        let dropped = max(0, seq - previousSeq - 1)
        let allowed = min(Self.gapSlackUs + dropped * Self.maxRecordSpanUs, Self.maxGapUs)
        guard step <= allowed else { throw ProtocolError.malformed("Audio timestamp gap \(step) us is not explained by \(dropped) dropped records") }
    }

    private func checkBurst(firstUs: Int64, nowMs: Int64) throws {
        let offset = nowMs - firstUs / 1_000
        let peak = max(maxOffsetMs ?? offset, offset)
        maxOffsetMs = peak
        guard peak - offset <= Self.burstAllowanceMs else { throw ProtocolError.malformed("Audio clock runs \(peak - offset) ms ahead of arrival") }
    }
}
