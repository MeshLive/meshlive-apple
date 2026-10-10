import Foundation
#if canImport(NearbyCore)
import NearbyCore
#endif
import CryptoKit

public enum MessageKind: UInt8 {
    case verify = 1, text = 2, acknowledgement = 3, cancel = 4, ping = 5, pong = 6
    case close = 7, closeAcknowledgement = 8, audio = 9, videoConfig = 10, video = 11
    case audioCancel = 12
}

public enum SessionEvent {
    case verification(code: String, fingerprint: String)
    case ready(MediaProfile)
    case submitted(UInt32), acknowledged(UInt32), cancelled(UInt32)
    case text(UInt32, String), audio(AudioPacket)
    case audioCancelled(UInt32)
    case videoConfig(Data), video(Data)
    case closed(String)
}

/// Owner confines this class to one serial queue. Sending failure is fatal: no nonce may be reused or skipped.
public final class SecureSession {
    public enum State: String { case handshake, verification, ready, closing, closed }
    public private(set) var state: State = .handshake
    public private(set) var profile: MediaProfile?
    public private(set) var sessionID = Data()
    public private(set) var peerName = ""
    public private(set) var lastReceived: TimeInterval
    public private(set) var applicationBytesAcknowledged: UInt64 = 0
    public private(set) var receivedOrderlyClose = false
    public var pendingCount: Int { pending.count }
    public var onEvent: ((SessionEvent) -> Void)?
    public var onSend: ((Data) throws -> Void)?
    private let local: Capabilities
    private let role: NoiseXX.Role
    private let noise: NoiseXX
    private let expectedPeer: Data?
    private var sendCipher: NoiseCipher?
    private var receiveCipher: NoiseCipher?
    private var localVerified = false, remoteVerified = false
    private var peerCapabilities: Capabilities?
    private var pending: [UInt32: (time: TimeInterval, bytes: Int)] = [:]
    private var nextMessageID: UInt32 = 1
    private var lastPeerMessageID: UInt32 = 0
    private var lastSent: TimeInterval
    private let created: TimeInterval
    private var closeTime: TimeInterval?

    public init(role: NoiseXX.Role, identity: Curve25519.KeyAgreement.PrivateKey, capabilities: Capabilities,
                hostToken: Data, now: TimeInterval, expectedPeer: Data? = nil,
                ephemeral: Curve25519.KeyAgreement.PrivateKey? = nil) {
        self.role = role; local = capabilities; self.expectedPeer = expectedPeer
        var prologue = Data("NearbyIntercom/v1".utf8); prologue.append(capabilities.transport.rawValue); prologue.append(hostToken)
        noise = NoiseXX(role: role, identity: identity, prologue: prologue, ephemeral: ephemeral)
        created = now; lastReceived = now; lastSent = now
    }

    public func start(now: TimeInterval) throws {
        guard role == .initiator, state == .handshake else { return }
        try emit(Data([1]) + noise.write(payload: local.encoded), now: now)
    }

    public func receive(_ record: Data, now: TimeInterval) throws {
        guard state != .closed else { return }
        do {
            guard let type = record.first else { throw ProtocolError.malformed("Empty record") }
            if state == .handshake {
                let expected: UInt8 = role == .initiator ? 2 : (peerCapabilities == nil ? 1 : 3)
                guard type == expected else { throw ProtocolError.state("Unexpected handshake record") }
                let payload = try noise.read(Data(record.dropFirst()))
                if type == 1 || type == 2 {
                    let peer = try Capabilities(decoding: payload); peerCapabilities = peer; peerName = peer.name
                    let negotiated = try local.negotiate(with: peer); profile = negotiated
                    if type == 1 { try emit(Data([2]) + noise.write(payload: local.encoded), now: now) }
                    else { try emit(Data([3]) + noise.write(payload: negotiated.encoded), now: now); try establish() }
                } else {
                    guard payload == profile?.encoded else { throw ProtocolError.incompatible("Media selection mismatch") }
                    try establish()
                }
            } else {
                guard type == 4 else { throw ProtocolError.state("Unexpected record after handshake") }
                try receiveEncrypted(record, now: now)
            }
            lastReceived = now
        } catch { fail(String(describing: error)); throw error }
    }

    private func establish() throws {
        let keys = try noise.split(expectedPeer: expectedPeer)
        sendCipher = keys.send; receiveCipher = keys.receive
        sessionID = Data(noise.hash.prefix(16)); state = .verification
        let codeBytes = SHA256.hash(data: Data("NearbyIntercom SAS v1".utf8) + noise.hash)
        let code = codeBytes.prefix(5).map { String(format: "%02X", $0) }.joined()
        let fingerprint = SHA256.hash(data: noise.remoteIdentity!).prefix(8).map { String(format: "%02X", $0) }.joined()
        onEvent?(.verification(code: String(code.prefix(5)) + " " + String(code.suffix(5)), fingerprint: fingerprint))
    }

    public func verify(now: TimeInterval) throws {
        guard state == .verification, !localVerified else { throw ProtocolError.state("Verification is not pending") }
        try send(.verify, payload: noise.hash, now: now); localVerified = true; becomeReady()
    }
    private func becomeReady() {
        if localVerified && remoteVerified { state = .ready; onEvent?(.ready(profile!)) }
    }

    @discardableResult public func sendText(_ text: String, now: TimeInterval) throws -> UInt32 {
        let bytes = Data(text.utf8)
        guard state == .ready, !bytes.isEmpty, bytes.count <= Wire.maxText else { throw ProtocolError.limit("Text must be 1–4096 UTF-8 bytes in a verified session") }
        guard pending.count < 16, nextMessageID < UInt32.max else { throw ProtocolError.limit("Too many messages awaiting acknowledgement") }
        let id = nextMessageID; nextMessageID += 1
        var w = BinaryWriter(); w.u32(id); w.bytes(bytes)
        pending[id] = (now, bytes.count)
        try send(.text, payload: w.data, now: now); onEvent?(.submitted(id)); return id
    }
    public func cancelMessage(_ id: UInt32, now: TimeInterval) throws {
        guard pending.removeValue(forKey: id) != nil else { return }
        var w = BinaryWriter(); w.u32(id); try send(.cancel, payload: w.data, now: now); onEvent?(.cancelled(id))
    }
    public func sendAudio(_ packet: AudioPacket, now: TimeInterval) throws {
        guard let profile else { throw ProtocolError.state("No audio profile") }
        _ = try AudioPacket(decoding: packet.encoded, profile: profile)
        try send(.audio, payload: packet.encoded, now: now)
    }
    public func cancelAudio(stream: UInt32, now: TimeInterval) throws {
        guard stream > 0 else { return }; var w = BinaryWriter(); w.u32(stream); try send(.audioCancel, payload: w.data, now: now)
    }
    public func sendVideo(kind: MessageKind, payload: Data, now: TimeInterval) throws {
        guard profile?.video == true, kind == .video || kind == .videoConfig, payload.count <= 24_576 else {
            throw ProtocolError.incompatible("Video was not negotiated or frame exceeds limit")
        }
        try send(kind, payload: payload, now: now)
    }
    public func close(reason: String, now: TimeInterval) throws {
        guard state != .closed, state != .closing else { return }
        if sendCipher == nil { fail(reason); return }
        try send(.close, payload: Wire.utf8Prefix(reason, maximum: 128), now: now)
        state = .closing; closeTime = now
    }
    public func tick(now: TimeInterval) throws {
        guard state != .closed else { return }
        if state == .closing {
            if now - (closeTime ?? now) >= 2 { fail("Local close completed without remote confirmation") }; return
        }
        if state == .handshake && now - created > 20 { fail("Handshake timeout"); return }
        if state == .verification && now - created > 120 { fail("Peer verification timeout"); return }
        if state == .ready {
            if now - lastReceived > 15 { fail("Peer keepalive timeout"); return }
            if pending.values.contains(where: { now - $0.time > 10 }) { fail("Remote application acknowledgement timeout"); return }
            if now - lastSent >= 5 { var w = BinaryWriter(); w.u64(UInt64(max(0, (now - created) * 1000))); try send(.ping, payload: w.data, now: now) }
        }
    }
    public func fail(_ reason: String) {
        guard state != .closed else { return }
        state = .closed; sendCipher = nil; receiveCipher = nil; pending.removeAll(); onEvent?(.closed(reason))
    }
    private func send(_ kind: MessageKind, payload: Data, now: TimeInterval) throws {
        guard let cipher = sendCipher, payload.count <= Wire.maxRecord - 47 else { throw ProtocolError.state("No secure writer or payload too large") }
        guard state == .ready || kind == .verify || kind == .close || kind == .closeAcknowledgement else { throw ProtocolError.state("Both peers must verify before data or media") }
        var w = BinaryWriter(); w.byte(4); w.byte(1); w.byte(kind.rawValue); w.bytes(sessionID)
        w.u64(cipher.counter); w.u32(UInt32(payload.count))
        let header = w.data; let encrypted = try cipher.encrypt(payload, ad: noise.hash + header)
        try emit(header + encrypted, now: now)
    }
    private func emit(_ record: Data, now: TimeInterval) throws {
        guard let onSend else { throw ProtocolError.state("No transport") }
        do { try onSend(record); lastSent = now } catch { fail("Transport submission failed: \(error)"); throw error }
    }
    private func receiveEncrypted(_ record: Data, now: TimeInterval) throws {
        guard let cipher = receiveCipher, record.count >= 47 else { throw ProtocolError.malformed("Short encrypted record") }
        var r = BinaryReader(record); _ = try r.byte()
        guard try r.byte() == 1, let kind = MessageKind(rawValue: try r.byte()), try r.bytes(16) == sessionID else { throw ProtocolError.authentication }
        guard try r.u64() == cipher.counter else { throw ProtocolError.replay }
        let length = Int(try r.u32())
        guard length <= Wire.maxRecord - 47, r.remaining == length + 16 else { throw ProtocolError.malformed("Encrypted length mismatch") }
        let payload = try cipher.decrypt(r.bytes(r.remaining), ad: noise.hash + Data(record.prefix(31)))
        guard state == .ready || kind == .verify || kind == .close || kind == .closeAcknowledgement else { throw ProtocolError.state("Unverified peer sent application data") }
        var p = BinaryReader(payload)
        switch kind {
        case .verify:
            guard state == .verification, !remoteVerified, payload == noise.hash else { throw ProtocolError.authentication }
            remoteVerified = true; becomeReady()
        case .text:
            let id = try p.u32()
            guard id > lastPeerMessageID, p.remaining > 0, p.remaining <= Wire.maxText,
                  let text = String(data: try p.bytes(p.remaining), encoding: .utf8) else { throw ProtocolError.malformed("Invalid text message") }
            lastPeerMessageID = id; onEvent?(.text(id, text))
            var w = BinaryWriter(); w.u32(id); try send(.acknowledgement, payload: w.data, now: now)
        case .acknowledgement:
            let id = try p.u32(); try p.end()
            guard id > 0, id < nextMessageID else { throw ProtocolError.malformed("Unknown acknowledgement") }
            if let message = pending.removeValue(forKey: id) { applicationBytesAcknowledged += UInt64(message.bytes); onEvent?(.acknowledged(id)) }
        case .cancel: let id = try p.u32(); try p.end(); guard id > 0 else { throw ProtocolError.malformed("Invalid cancellation") }; onEvent?(.cancelled(id))
        case .ping: _ = try p.u64(); try p.end(); try send(.pong, payload: payload, now: now)
        case .pong: _ = try p.u64(); try p.end()
        case .close:
            guard payload.count <= 128, let reason = String(data: payload, encoding: .utf8) else { throw ProtocolError.malformed("Invalid close") }
            try send(.closeAcknowledgement, payload: Data(), now: now); receivedOrderlyClose = true; fail("Peer closed: \(reason)")
        case .closeAcknowledgement: try p.end(); guard state == .closing else { throw ProtocolError.state("Unexpected close acknowledgement") }; fail("Orderly close acknowledged")
        case .audio: onEvent?(.audio(try AudioPacket(decoding: payload, profile: profile!)))
        case .audioCancel:
            let stream = try p.u32(); try p.end(); guard stream > 0 else { throw ProtocolError.malformed("Invalid audio cancellation") }
            onEvent?(.audioCancelled(stream))
        case .videoConfig, .video:
            guard profile?.video == true, payload.count <= 24_576 else { throw ProtocolError.incompatible("Unnegotiated video") }
            if kind == .videoConfig { onEvent?(.videoConfig(payload)) } else { onEvent?(.video(payload)) }
        }
    }
}
