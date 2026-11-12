import Foundation

/// The power state when a call starts, as the codec choice reads it (`power=` in `encoder_choice`; Android
/// `CodecPowerState`). Apple: Low Power Mode is `saver`, a thermal state of fair or worse is `warm`.
public enum CodecPowerState: String, Equatable {
    case normal, saver, warm
}

/// The masters and control arms one call codec choice reads (Android `CodecChoiceSwitches`; the Android design record "Design HC" and
/// "Automatic codec order after the 2026-10-28 phone measurements"). The bundled libvpx VP9 encoder is always in
/// Automatic, as Android's shipped `prefer_libvpx`.
public struct CodecChoiceSwitches: Equatable {
    public var hevc: Bool
    public var h264: Bool
    /// Control arm `-NearbyPreferHEVC NO` (Android `test_prefer_hevc=false`): HEVC stays advertised, Automatic never picks it.
    public var preferHevc: Bool
    /// Control arm `-NearbyPreferAVC NO` (Android `test_prefer_hw_avc=false`).
    public var preferAvc: Bool
    /// Peer bit 7 keeps a hardware HEVC encoder (that the peer decodes) ahead of VP9; control arm `-NearbyBit7HwHevc NO`.
    public var bit7AllowsHwHevc: Bool
    /// `codec_power_aware`; control arm `-NearbyCodecPowerAware NO`.
    public var powerAware: Bool
    /// The power state read once at call start.
    public var power: CodecPowerState

    public init(hevc: Bool, h264: Bool, preferHevc: Bool = true, preferAvc: Bool = true, bit7AllowsHwHevc: Bool = true,
                powerAware: Bool = true, power: CodecPowerState = .normal) {
        self.hevc = hevc; self.h264 = h264; self.preferHevc = preferHevc; self.preferAvc = preferAvc
        self.bit7AllowsHwHevc = bit7AllowsHwHevc; self.powerAware = powerAware; self.power = power
    }

    /// Either master on: the Design HC rules; both off: exactly the two-codec rule (`CallEngine.codecForPeer`).
    public var anyNew: Bool { hevc || h264 }
}

/// One encoder this device could send a call with.
public struct VideoEncoderCandidate: Equatable {
    public enum Backend: Equatable {
        /// A hardware encoder (VideoToolbox with a hardware encoder, MediaCodec `isHardwareAccelerated`).
        case hardware
        /// The bundled libvpx VP9 encoder (Design VX).
        case libvpx
        /// Any other software encoder (Android's libaom and platform software encoders; none on Apple).
        case software
    }

    public let name: String
    public let codecId: UInt8
    public let backend: Backend
    public var hardware: Bool { backend == .hardware }

    public init(name: String, codecId: UInt8, backend: Backend) { self.name = name; self.codecId = codecId; self.backend = backend }
}

/// What the app gives a call engine for its codec choice: its encoders and switches, and the encoders this process
/// stopped trusting (`no_idr`).
public struct CallCodecInputs: Equatable {
    public var encoders: [VideoEncoderCandidate]
    public var switches: CodecChoiceSwitches
    public var ineligible: Set<String>

    public init(encoders: [VideoEncoderCandidate], switches: CodecChoiceSwitches, ineligible: Set<String> = []) {
        self.encoders = encoders; self.switches = switches; self.ineligible = ineligible
    }
}

/// AB5: the one call codec choice per direction (Android `VideoCodecChoice.forCall`, Design HC review 2 F12), from the
/// peer's authenticated end-to-end decode mask. Automatic order: hardware AV1, hardware HEVC, hardware VP9, the bundled
/// libvpx VP9, hardware H.264, then the other software encoders; only codecs the peer decodes count. Precedence: peer
/// bit 7 (counted only with peer VP9 bit 0) puts VP9 first, below only a hardware HEVC encoder the peer decodes; peer
/// bit 4 moves AV1 below the hardware HEVC and VP9 encoders the peer decodes; `codec_power_aware` (Low Power Mode or a
/// warm device at call start) moves the hardware encoders ahead of a software first choice, never over bit 7. A prefer
/// arm that is off removes its codec from Automatic. Apple has no manual codec picker and no family VP9 policy, so
/// Android's user-choice and `CallVp9Compatibility` branches are not part of this port.
public struct CallCodecChoice: Equatable {
    /// What this device sends, or nil (`no_common_codec`).
    public let sent: VideoEncoderCandidate?
    /// The ordered, filtered list; a fallback walks only this list.
    public let ordered: [VideoEncoderCandidate]
    /// Android's `encoder_choice` reason label.
    public let reason: String
    /// Extra log notes, e.g. `bit7_hw_hevc_first`, `bit7_without_vp9_ignored`.
    public let notes: [String]
    /// `codec_power_aware` changed the order of this call.
    public let powerApplied: Bool
    public let peerDecodeMask: UInt8
    public let switches: CodecChoiceSwitches

    private static func callRank(_ codecId: UInt8) -> Int {
        switch codecId {
        case StreamProtocol.codecAV1: return 0
        case StreamProtocol.codecHEVC: return 1
        case StreamProtocol.codecVP9: return 2
        case StreamProtocol.codecH264: return 3
        default: return 4
        }
    }

    private static func isHc(_ codecId: UInt8) -> Bool { VideoCodecMap.isInBandParameterSetCodec(codecId) }

    /// Why `candidate` is not in the Automatic list, or nil when it is.
    private static func exclusion(_ candidate: VideoEncoderCandidate, switches: CodecChoiceSwitches, ineligible: Set<String>) -> String? {
        guard isHc(candidate.codecId) else { return nil }
        let preferred = candidate.codecId == StreamProtocol.codecHEVC ? switches.hevc && switches.preferHevc : switches.h264 && switches.preferAvc
        if !preferred { return candidate.codecId == StreamProtocol.codecHEVC ? "hevc_not_preferred" : "avc_not_preferred" }
        if !candidate.hardware { return "ineligible:software" }
        if ineligible.contains(candidate.name) { return "ineligible:policy" }
        return nil
    }

    /// The Automatic call order before any peer filter.
    public static func automatic(_ available: [VideoEncoderCandidate], switches: CodecChoiceSwitches,
                                 ineligible: Set<String> = []) -> [VideoEncoderCandidate] {
        let usable = available.filter { exclusion($0, switches: switches, ineligible: ineligible) == nil }
        // A stable sort by rank (Swift's sort is not guaranteed stable, so ties keep the input order explicitly).
        let hardware = usable.enumerated().filter { $0.element.hardware }
            .sorted { (callRank($0.element.codecId), $0.offset) < (callRank($1.element.codecId), $1.offset) }.map(\.element)
        let libvpx = usable.filter { $0.backend == .libvpx }
        let otherSoftware = usable.filter { $0.backend == .software }
        let avcAt = hardware.firstIndex { $0.codecId == StreamProtocol.codecH264 } ?? hardware.count
        return Array(hardware[..<avcAt]) + libvpx + Array(hardware[avcAt...]) + otherSoftware
    }

    /// The codec this device sends to a call peer whose authenticated end-to-end decode mask is `peerDecodeMask`.
    public static func forCall(available: [VideoEncoderCandidate], peerDecodeMask: UInt8, switches: CodecChoiceSwitches,
                               ineligible: Set<String> = []) -> CallCodecChoice {
        func decodes(_ c: VideoEncoderCandidate) -> Bool { peerDecodeMask & VideoCodecMap.helloBit(codecId: c.codecId) != 0 }
        var notes: [String] = []
        let bit7 = peerDecodeMask & NodeCapabilities.decodePrefersVP9 != 0
        let bit7Counts = bit7 && peerDecodeMask & NodeCapabilities.codecVP9 != 0
        if bit7 && !bit7Counts { notes.append("bit7_without_vp9_ignored") }
        let bit4 = peerDecodeMask & NodeCapabilities.decodeAV1Software != 0
        let vp9 = available.filter { $0.codecId == StreamProtocol.codecVP9 }
            .min { rank($0.backend) < rank($1.backend) }
        let auto = automatic(available, switches: switches, ineligible: ineligible)
        var ordered = auto.filter(decodes)
        if bit4 { ordered = demoteAv1(ordered) }
        var forced: String?
        if bit7Counts, let vp9 {
            // Bit 7 exists for the legacy Qualcomm call profile; a hardware HEVC encoder the peer decodes stays ahead
            // (the Android design record "Design HC", "Bit 7 and hardware HEVC").
            let hwHevc = switches.bit7AllowsHwHevc ? ordered.filter { $0.hardware && $0.codecId == StreamProtocol.codecHEVC } : []
            if !hwHevc.isEmpty { notes.append("bit7_hw_hevc_first") }
            ordered = hwHevc + [vp9] + ordered.filter { $0 != vp9 && !hwHevc.contains($0) }
            forced = "peer_prefers_vp9"
        }
        // codec_power_aware: decided once, at call start (the caller passes the session-start power state).
        let powered = forced == nil ? powerReorder(ordered, switches: switches, ineligible: ineligible) : nil
        if let powered { ordered = powered }
        let sent = ordered.first
        let reason: String
        if sent == nil {
            reason = "no_common_codec"
        } else if let forced, sent == vp9 {
            reason = forced
        } else if powered != nil, let sent {
            reason = sent.codecId == StreamProtocol.codecH264 ? "power_prefers_hw_avc" : "power_prefers_hw"
        } else {
            reason = automaticReason(sent!, available: available, switches: switches, ineligible: ineligible, peerDecodeMask: peerDecodeMask)
        }
        return CallCodecChoice(sent: sent, ordered: ordered, reason: reason, notes: notes, powerApplied: powered != nil,
                               peerDecodeMask: peerDecodeMask, switches: switches)
    }

    private static func rank(_ backend: VideoEncoderCandidate.Backend) -> Int {
        switch backend {
        case .hardware: return 0
        case .libvpx: return 1
        case .software: return 2
        }
    }

    /// Peer bit 4: AV1 entries move below this device's hardware HEVC and hardware VP9 entries (those the peer decodes).
    private static func demoteAv1(_ list: [VideoEncoderCandidate]) -> [VideoEncoderCandidate] {
        let av1 = list.filter { $0.codecId == StreamProtocol.codecAV1 }
        guard !av1.isEmpty, let lastPreferred = list.lastIndex(where: {
            $0.hardware && ($0.codecId == StreamProtocol.codecHEVC || $0.codecId == StreamProtocol.codecVP9)
        }) else { return list }
        let before = list[...lastPreferred].filter { $0.codecId != StreamProtocol.codecAV1 }
        let movedAv1 = av1.filter { list.firstIndex(of: $0)! <= lastPreferred }
        return before + movedAv1 + list[(lastPreferred + 1)...]
    }

    /// `codec_power_aware` (Android `CodecPowerAware.reorder`): when the state is not normal and the first entry is a
    /// software encoder, the usable hardware encoders move ahead, each group keeping its order. Nil: unchanged.
    private static func powerReorder(_ list: [VideoEncoderCandidate], switches: CodecChoiceSwitches,
                                     ineligible: Set<String>) -> [VideoEncoderCandidate]? {
        guard switches.powerAware, switches.power != .normal, let first = list.first, !first.hardware else { return nil }
        let hardware = list.filter { $0.hardware && !ineligible.contains($0.name) }
        guard !hardware.isEmpty else { return nil }
        return hardware + list.filter { !hardware.contains($0) }
    }

    private static func peerSkip(_ codecId: UInt8) -> String {
        switch codecId {
        case StreamProtocol.codecAV1: return "peer_no_av1_decode"
        case StreamProtocol.codecHEVC: return "peer_no_hevc_decode"
        case StreamProtocol.codecH264: return "peer_no_avc_decode"
        default: return "peer_no_vp9_decode"
        }
    }

    /// Why Automatic sent `sent` (Android `VideoCodecChoice.automaticReason`): the first better-ranked hardware codec that
    /// was skipped names the reason; with none, `hw_av1_preferred`, `hw_hevc_preferred`, `hw_avc_preferred`, or
    /// `no_hw_av1` for VP9 and software.
    static func automaticReason(_ sent: VideoEncoderCandidate, available: [VideoEncoderCandidate], switches: CodecChoiceSwitches,
                                ineligible: Set<String>, peerDecodeMask: UInt8) -> String {
        var codecs = [StreamProtocol.codecAV1, StreamProtocol.codecHEVC, StreamProtocol.codecVP9, StreamProtocol.codecH264]
        codecs.removeAll { ($0 == StreamProtocol.codecHEVC && !switches.hevc) || ($0 == StreamProtocol.codecH264 && !switches.h264) }
        for codecId in codecs {
            if sent.hardware && codecId == sent.codecId { break }
            guard let component = available.first(where: { $0.hardware && $0.codecId == codecId }) else { continue }
            if codecId == StreamProtocol.codecAV1 {
                if ineligible.contains(component.name) { continue }
            } else if let excluded = exclusion(component, switches: switches, ineligible: ineligible) {
                return excluded
            }
            if peerDecodeMask & VideoCodecMap.helloBit(codecId: codecId) == 0 { return peerSkip(codecId) }
            if codecId == StreamProtocol.codecAV1 && peerDecodeMask & NodeCapabilities.decodeAV1Software != 0 { return "peer_av1_software" }
        }
        if sent.hardware {
            switch sent.codecId {
            case StreamProtocol.codecAV1: return "hw_av1_preferred"
            case StreamProtocol.codecHEVC: return "hw_hevc_preferred"
            case StreamProtocol.codecH264: return "hw_avc_preferred"
            default: break
            }
        }
        return "no_hw_av1"
    }

    /// The fields of one `encoder_choice` log line (Android `BENCHMARK encoder_choice`, Design HC format).
    public func logFields(role: String) -> [String: String] {
        var fields = [
            "role": role,
            "encoder": sent?.name ?? "none",
            "codec": sent.map { VideoCodecMap.label(codecId: $0.codecId) } ?? "none",
            "hardware": "\(sent?.hardware ?? false)",
            "peer_decode_mask": "\(peerDecodeMask)",
            "reason": reason,
            "hevc": "\(switches.hevc)",
            "h264": "\(switches.h264)",
            "prefer_hevc": "\(switches.preferHevc)",
            "prefer_hw_avc": "\(switches.preferAvc)",
            "list": ordered.isEmpty ? "none" : ordered.map(\.name).joined(separator: ","),
            "power": switches.power.rawValue,
            "codec_power_aware": "\(switches.powerAware)",
        ]
        if !notes.isEmpty { fields["notes"] = notes.joined(separator: ",") }
        return fields
    }
}
