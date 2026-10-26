import Foundation

// BMC2 private-call signalling and state machine (Android PrivateCallSession.kt, IntercomCall.kt).

public enum PrivateCallSignal: UInt8 {
    case invite = 1, ringing = 2, accept = 3, decline = 4, cancel = 5, hangUp = 6
    case cameraOff = 7, cameraOn = 8, microphoneMuted = 9, microphoneUnmuted = 10
}

public enum PrivateCallReason: UInt8 {
    case none = 0, rejected = 1, busy = 2, unsupported = 3, normal = 4, error = 5
}

public struct PrivateCallSignalMessage: Equatable {
    public static let magic = Data("BMC2".utf8)
    public static let encodedBytes = 23
    public static let maxRelayHops: UInt8 = 15
    public let callId: UUID
    public let signal: PrivateCallSignal
    public let reason: PrivateCallReason
    public let relayHops: UInt8

    public init(callId: UUID, signal: PrivateCallSignal, reason: PrivateCallReason = .none, relayHops: UInt8 = 0) throws {
        guard callId != UUID(uuid: (0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0)) else { throw ProtocolError.malformed("A private call needs a non-zero call ID") }
        guard relayHops <= PrivateCallSignalMessage.maxRelayHops else { throw ProtocolError.malformed("Invalid private-call relay count") }
        guard signal == .invite || relayHops == 0 else { throw ProtocolError.malformed("Only a private-call invitation can carry its relay count") }
        switch signal {
        case .decline: guard [.rejected, .busy, .unsupported].contains(reason) else { throw ProtocolError.malformed("A declined call needs a decline reason") }
        case .hangUp: guard [.normal, .error].contains(reason) else { throw ProtocolError.malformed("A hang-up needs a terminal reason") }
        default: guard reason == .none else { throw ProtocolError.malformed("\(signal) cannot carry a reason") }
        }
        self.callId = callId; self.signal = signal; self.reason = reason; self.relayHops = relayHops
    }

    public var encoded: Data {
        var w = BinaryWriter(capacity: PrivateCallSignalMessage.encodedBytes)
        w.bytes(PrivateCallSignalMessage.magic); w.byte(signal.rawValue); w.bytes(callId.rawBytes)
        w.byte(reason.rawValue); w.byte(relayHops); return w.data
    }

    public init(decoding data: Data) throws {
        guard data.count == PrivateCallSignalMessage.encodedBytes else { throw ProtocolError.malformed("Invalid private-call signal length") }
        var r = BinaryReader(data)
        guard try r.bytes(4) == PrivateCallSignalMessage.magic else { throw ProtocolError.malformed("Invalid private-call signal") }
        let signalValue = try r.byte()
        guard let signal = PrivateCallSignal(rawValue: signalValue) else { throw ProtocolError.malformed("Unknown private-call signal \(signalValue)") }
        let id = UUID(rawBytes: try r.bytes(16))
        let reasonValue = try r.byte()
        guard let reason = PrivateCallReason(rawValue: reasonValue) else { throw ProtocolError.malformed("Unknown private-call reason \(reasonValue)") }
        try self.init(callId: id, signal: signal, reason: reason, relayHops: try r.byte())
    }
}

public extension UUID {
    /// The 16 bytes in Java `mostSignificantBits`, `leastSignificantBits` order (canonical string order).
    var rawBytes: Data { withUnsafeBytes(of: uuid) { Data($0) } }
    init(rawBytes: Data) {
        var tuple: uuid_t = (0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0)
        withUnsafeMutableBytes(of: &tuple) { raw in for (i, b) in rawBytes.prefix(16).enumerated() { raw[i] = b } }
        self.init(uuid: tuple)
    }
}

public enum PrivateCallRole { case caller, callee }
public enum PrivateCallPhase { case outgoingInvite, outgoingRinging, incomingRinging, negotiatingMedia, active, ended }
public enum PrivateCallEvent { case remoteRinging, localAccept, remoteAccept, localDecline, remoteDecline, localCancel, remoteCancel, mediaReady, localHangUp, remoteHangUp, linkLost }

public struct PrivateCallState: Equatable {
    public let callId: UUID
    public let role: PrivateCallRole
    public private(set) var phase: PrivateCallPhase

    public static func outgoing(callId: UUID = UUID()) -> PrivateCallState { PrivateCallState(callId: callId, role: .caller, phase: .outgoingInvite) }
    public static func incoming(callId: UUID) -> PrivateCallState { PrivateCallState(callId: callId, role: .callee, phase: .incomingRinging) }

    /// Exactly Android's transition table; anything else is a protocol error.
    public func transition(_ event: PrivateCallEvent) throws -> PrivateCallState {
        let next: PrivateCallPhase?
        switch (phase, event) {
        case (.outgoingInvite, .remoteRinging): next = .outgoingRinging
        case (.outgoingInvite, .remoteAccept), (.outgoingRinging, .remoteAccept): next = .negotiatingMedia
        case (.outgoingInvite, .remoteDecline), (.outgoingInvite, .localCancel), (.outgoingInvite, .linkLost),
             (.outgoingRinging, .remoteDecline), (.outgoingRinging, .localCancel), (.outgoingRinging, .linkLost): next = .ended
        case (.incomingRinging, .localAccept): next = .negotiatingMedia
        case (.incomingRinging, .localDecline), (.incomingRinging, .remoteCancel), (.incomingRinging, .linkLost): next = .ended
        case (.negotiatingMedia, .mediaReady): next = .active
        case (.negotiatingMedia, .localHangUp), (.negotiatingMedia, .remoteHangUp), (.negotiatingMedia, .linkLost),
             (.active, .localHangUp), (.active, .remoteHangUp), (.active, .linkLost): next = .ended
        default: next = nil
        }
        guard let next else { throw ProtocolError.state("Invalid private-call transition \(phase) + \(event)") }
        var copy = self; copy.phase = next; return copy
    }
}

public enum CallType: String { case voice, video }

/// Voice calls use only existing signals: Invite then Camera off (caller), Accept then Camera off (callee).
public final class VoiceCallNegotiation {
    public let role: PrivateCallRole
    public let requested: CallType
    public private(set) var peerOfferedVoice = false
    public init(role: PrivateCallRole, requested: CallType) { self.role = role; self.requested = requested }
    /// iOS always supports the voice experiment (it is the default way to call from an iPhone).
    public var localType: CallType { role == .caller ? requested : (peerOfferedVoice ? .voice : requested) }
    public func inviteSignals() -> [PrivateCallSignal] { localType == .voice ? [.invite, .cameraOff] : [.invite] }
    /// Camera off/on while ringing changes the offered type (callee). Returns true when it changed.
    @discardableResult
    public func onRemoteCameraSignal(phase: PrivateCallPhase, enabled: Bool) -> Bool {
        guard role == .callee, phase == .incomingRinging else { return false }
        let voice = !enabled
        defer { peerOfferedVoice = voice }
        return voice != peerOfferedVoice
    }
}
