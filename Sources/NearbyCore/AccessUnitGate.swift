import Foundation

// AB5 (Design HC): the receiver's fail-closed access-unit gate for codecs 4 (H.264) and 5 (HEVC), the sender's
// packetiser and the keyframe-request rule (PROTOCOL "Draft: HEVC and H.264 video codecs", "Sender rules" and
// "Access-unit validation"). Android: `AccessUnitGate`, `HevcAccessUnitValidator`, `AvcAccessUnitValidator`,
// `AnnexBPacketiser`. The parsers read only the fields PROTOCOL names, within the parse budget; everything else in the
// codec syntax is left to the platform decoder (a gate, not a sanitizer).

public extension AnnexBCodec {
    var vpsType: Int { self == .hevc ? 32 : -1 }
    var spsType: Int { self == .hevc ? 33 : 7 }
    var ppsType: Int { self == .hevc ? 34 : 8 }

    /// Rule 2: HEVC `forbidden_zero_bit` 0, `nuh_layer_id` 0, `nuh_temporal_id_plus1` 1; H.264 `forbidden_zero_bit` 0.
    func headerValid(_ nal: Data) -> Bool {
        let b = [UInt8](nal.prefix(2))
        switch self {
        case .hevc:
            guard b.count == 2 else { return false }
            let layerId = Int(b[0] & 1) << 5 | Int(b[1] >> 3)
            return b[0] >> 7 == 0 && layerId == 0 && b[1] & 7 == 1
        case .h264:
            return !b.isEmpty && b[0] & 0x80 == 0
        }
    }

    /// Rule 3. HEVC: 0 and 1 (trailing), 19 and 20 (IDR), 32 VPS, 33 SPS, 34 PPS, 35 AUD, 38 filler, 39 and 40 SEI.
    /// H.264: 1, 5, 6 SEI, 7 SPS, 8 PPS, 9 AUD, 12 filler. CRA (21) is deferred and rejected.
    func isAllowed(_ type: Int) -> Bool {
        self == .hevc ? [0, 1, 19, 20, 32, 33, 34, 35, 38, 39, 40].contains(type) : [1, 5, 6, 7, 8, 9, 12].contains(type)
    }

    func isSlice(_ type: Int) -> Bool { self == .hevc ? [0, 1, 19, 20].contains(type) : type == 1 || type == 5 }
    func isIdr(_ type: Int) -> Bool { self == .hevc ? type == 19 || type == 20 : type == 5 }
    /// SEI, AUD and filler: removed before decoding (rule 11), never parsed.
    func isStripped(_ type: Int) -> Bool { self == .hevc ? [35, 38, 39, 40].contains(type) : [6, 9, 12].contains(type) }
    /// Types that must follow the slice (filler; HEVC suffix SEI).
    func isTrailing(_ type: Int) -> Bool { self == .hevc ? type == 38 || type == 40 : type == 12 }
    func isParameterSet(_ type: Int) -> Bool { type == vpsType || type == spsType || type == ppsType }
    /// Video coding layer types (HEVC 0...31, H.264 1...5): any that is not an allowed slice is refused by the sender.
    func isVcl(_ type: Int) -> Bool { self == .hevc ? type <= 31 : (1...5).contains(type) }
}

/// The session envelope of rule 6: per axis, either orientation (the larger side against the larger header side).
struct SizeEnvelope {
    let big: Int, small: Int, headerBig: Int, headerSmall: Int

    init(headerMaxWidth: Int, headerMaxHeight: Int) {
        func roundUp16(_ v: Int) -> Int { v <= 0 ? 0 : (v + 15) / 16 * 16 }
        let w = roundUp16(headerMaxWidth), h = roundUp16(headerMaxHeight)
        big = max(w, h); small = min(w, h)
        headerBig = max(headerMaxWidth, headerMaxHeight); headerSmall = min(headerMaxWidth, headerMaxHeight)
    }

    /// The sender's own sets are parsed without a session size.
    static let unbounded = SizeEnvelope(headerMaxWidth: Int(Int32.max), headerMaxHeight: Int(Int32.max))

    /// Visible size after cropping (crop units of `unit` samples); it must stay at least 16.
    func visible(_ coded: Int, _ cropA: Int, _ cropB: Int, unit: Int, _ what: String) throws -> Int {
        let v = coded - unit * (cropA + cropB)
        guard v >= 16 else { throw RuleViolation(rule: 6, reason: "\(what) visible size \(v) below 16") }
        return v
    }

    /// H.264: each coded side at most the header side rounded up to 16 (macroblocks).
    func requireCoded(_ width: Int, _ height: Int) throws {
        guard width > 0, height > 0, max(width, height) <= big, min(width, height) <= small else {
            throw RuleViolation(rule: 6, reason: "coded size \(width)x\(height) outside the session envelope")
        }
    }

    /// HEVC: coded sides multiples of 8, padding below 64 per axis, cropped size within the header.
    func requireHevc(codedWidth: Int, codedHeight: Int, visibleWidth: Int, visibleHeight: Int) throws {
        guard codedWidth % 8 == 0, codedHeight % 8 == 0 else {
            throw RuleViolation(rule: 6, reason: "HEVC coded size \(codedWidth)x\(codedHeight) not a multiple of 8")
        }
        guard codedWidth - visibleWidth < 64, codedHeight - visibleHeight < 64 else {
            throw RuleViolation(rule: 6, reason: "HEVC coded size \(codedWidth)x\(codedHeight) pads by 64 or more")
        }
        guard max(visibleWidth, visibleHeight) <= headerBig, min(visibleWidth, visibleHeight) <= headerSmall else {
            throw RuleViolation(rule: 6, reason: "cropped size \(visibleWidth)x\(visibleHeight) outside the header size")
        }
    }
}

struct SpsInfo {
    let id: Int
    /// HEVC VPS ID; -1 for H.264.
    let vpsId: Int
    let visibleWidth: Int
    let visibleHeight: Int
    let unusual: [String]
}

struct PpsInfo {
    let id: Int
    let spsId: Int
    let numExtraSliceHeaderBits: Int
}

private func parameterSetReader(_ nal: Data, _ codec: AnnexBCodec, rule: Int, type: Int) -> AnnexBBitReader {
    AnnexBBitReader(AnnexB.unescape(nal, from: codec.headerBytes, budget: AnnexB.parameterSetBudget), rule: rule, nalType: type)
}

private func sliceReader(_ nal: Data, _ codec: AnnexBCodec, type: Int) -> AnnexBBitReader {
    AnnexBBitReader(AnnexB.unescape(nal, from: codec.headerBytes, budget: AnnexB.sliceHeaderBudget), rule: 4, nalType: type)
}

/// HEVC VPS (7), SPS (8), PPS (10) and slice-header prefix (4).
enum HevcSyntax {
    static func parseVps(_ nal: Data) throws -> Int {
        var r = parameterSetReader(nal, .hevc, rule: 7, type: 32)
        let id = try r.u(4)
        try r.skip(2) // vps_base_layer_internal_flag, vps_base_layer_available_flag
        guard try r.u(6) == 0 else { throw RuleViolation(rule: 7, reason: "vps_max_layers_minus1 not 0", nalType: 32) }
        guard try r.u(3) == 0 else { throw RuleViolation(rule: 7, reason: "vps_max_sub_layers_minus1 not 0", nalType: 32) }
        return id
    }

    static func parseSps(_ nal: Data, envelope: SizeEnvelope) throws -> SpsInfo {
        var r = parameterSetReader(nal, .hevc, rule: 8, type: 33)
        var unusual: [String] = []
        let vpsId = try r.u(4)
        guard try r.u(3) == 0 else { throw RuleViolation(rule: 8, reason: "sps_max_sub_layers_minus1 not 0", nalType: 33) }
        try r.skip(1) // sps_temporal_id_nesting_flag
        // profile_tier_level without sub-layers: the fixed 12-byte general part.
        guard try r.u(2) == 0 else { throw RuleViolation(rule: 8, reason: "general_profile_space not 0", nalType: 33) }
        try r.skip(1) // general_tier_flag
        let profileIdc = try r.u(5)
        let compatibility = try r.bits(32)
        let compatibleWithMain = (compatibility >> 30) & 1 == 1 // general_profile_compatibility_flag[1]
        guard profileIdc == 1 || compatibleWithMain else { throw RuleViolation(rule: 8, reason: "not Main profile (idc \(profileIdc))", nalType: 33) }
        try r.skip(48) // progressive, interlaced, non-packed and frame-only flags, 43 reserved bits, one more bit
        let level = try r.u(8)
        guard level <= 186 else { throw RuleViolation(rule: 8, reason: "general_level_idc \(level) above 186", nalType: 33) }
        if level > 123 { unusual.append("general_level_idc=\(level)") }
        let spsId = try r.ue(max: 15)
        guard try r.ue() == 1 else { throw RuleViolation(rule: 8, reason: "chroma_format_idc not 1", nalType: 33) }
        let width = Int(try r.ue())
        let height = Int(try r.ue())
        var crop = (left: 0, right: 0, top: 0, bottom: 0)
        if try r.flag() {
            crop = (Int(try r.ue()), Int(try r.ue()), Int(try r.ue()), Int(try r.ue()))
        }
        guard try r.ue() == 0 else { throw RuleViolation(rule: 8, reason: "bit_depth_luma not 8", nalType: 33) }
        guard try r.ue() == 0 else { throw RuleViolation(rule: 8, reason: "bit_depth_chroma not 8", nalType: 33) }
        _ = try r.ue(max: 12) // log2_max_pic_order_cnt_lsb_minus4
        _ = try r.flag() // sps_sub_layer_ordering_info_present_flag: one entry either way
        let maxDecodingMinus1 = try r.ue(max: 15)
        if maxDecodingMinus1 > 5 { unusual.append("sps_max_dec_pic_buffering_minus1=\(maxDecodingMinus1)") }
        guard try r.ue() == 0 else { throw RuleViolation(rule: 8, reason: "sps_max_num_reorder_pics not 0", nalType: 33) }
        let visibleWidth = try envelope.visible(width, crop.left, crop.right, unit: 2, "width")
        let visibleHeight = try envelope.visible(height, crop.top, crop.bottom, unit: 2, "height")
        try envelope.requireHevc(codedWidth: width, codedHeight: height, visibleWidth: visibleWidth, visibleHeight: visibleHeight)
        return SpsInfo(id: spsId, vpsId: vpsId, visibleWidth: visibleWidth, visibleHeight: visibleHeight, unusual: unusual)
    }

    static func parsePps(_ nal: Data) throws -> PpsInfo {
        var r = parameterSetReader(nal, .hevc, rule: 10, type: 34)
        let id = try r.ue(max: 63)
        let spsId = try r.ue(max: 15)
        try r.skip(2) // dependent_slice_segments_enabled_flag, output_flag_present_flag
        let extraBits = try r.u(3) // num_extra_slice_header_bits
        return PpsInfo(id: id, spsId: spsId, numExtraSliceHeaderBits: extraBits)
    }

    /// Returns the slice's PPS ID.
    static func parseSlice(_ nal: Data, type: Int, numExtraSliceHeaderBits: Int) throws -> Int {
        var r = sliceReader(nal, .hevc, type: type)
        guard try r.flag() else { throw RuleViolation(rule: 4, reason: "first_slice_segment_in_pic_flag not 1", nalType: type) }
        if (16...23).contains(type) { try r.skip(1) } // no_output_of_prior_pics_flag
        let ppsId = try r.ue(max: 63)
        try r.skip(numExtraSliceHeaderBits)
        let sliceType = try r.ue()
        guard sliceType == 1 || sliceType == 2 else { throw RuleViolation(rule: 4, reason: "slice_type \(sliceType) not P or I", nalType: type) }
        if AnnexBCodec.hevc.isIdr(type) && sliceType != 2 { throw RuleViolation(rule: 4, reason: "IDR slice_type not I", nalType: type) }
        return ppsId
    }
}

/// H.264 SPS (9), PPS (10) and slice-header prefix (4).
enum AvcSyntax {
    static func parseSps(_ nal: Data, envelope: SizeEnvelope) throws -> SpsInfo {
        var r = parameterSetReader(nal, .h264, rule: 9, type: 7)
        var unusual: [String] = []
        let profile = try r.u(8)
        guard [66, 77, 100].contains(profile) else { throw RuleViolation(rule: 9, reason: "profile_idc \(profile) not 66, 77 or 100", nalType: 7) }
        try r.skip(8) // constraint_set flags and reserved bits
        let level = try r.u(8)
        guard level <= 62 else { throw RuleViolation(rule: 9, reason: "level_idc \(level) above 62", nalType: 7) }
        if level > 41 { unusual.append("level_idc=\(level)") }
        let spsId = try r.ue(max: 31)
        if profile == 100 {
            guard try r.ue() == 1 else { throw RuleViolation(rule: 9, reason: "chroma_format_idc not 1", nalType: 7) }
            guard try r.ue() == 0 else { throw RuleViolation(rule: 9, reason: "bit_depth_luma not 8", nalType: 7) }
            guard try r.ue() == 0 else { throw RuleViolation(rule: 9, reason: "bit_depth_chroma not 8", nalType: 7) }
            try r.skip(1) // qpprime_y_zero_transform_bypass_flag
            if try r.flag() { // seq_scaling_matrix_present_flag
                for i in 0..<8 {
                    if try r.flag() { try skipScalingList(&r, size: i < 6 ? 16 : 64) }
                }
            }
        }
        _ = try r.ue(max: 12) // log2_max_frame_num_minus4
        let pocType = try r.ue(max: 2)
        if pocType == 0 {
            _ = try r.ue(max: 12) // log2_max_pic_order_cnt_lsb_minus4
        } else if pocType == 1 {
            try r.skip(1) // delta_pic_order_always_zero_flag
            _ = try r.se() // offset_for_non_ref_pic
            _ = try r.se() // offset_for_top_to_bottom_field
            let cycle = try r.ue(max: 255)
            for _ in 0..<cycle { _ = try r.se() }
        }
        let maxRefFrames = try r.ue(max: 16)
        if maxRefFrames > 4 { unusual.append("max_num_ref_frames=\(maxRefFrames)") }
        try r.skip(1) // gaps_in_frame_num_value_allowed_flag
        let widthMbs = Int(try r.ue()) + 1
        let heightMbs = Int(try r.ue()) + 1
        guard try r.flag() else { throw RuleViolation(rule: 9, reason: "frame_mbs_only_flag not 1", nalType: 7) }
        try r.skip(1) // direct_8x8_inference_flag
        let width = widthMbs * 16, height = heightMbs * 16
        try envelope.requireCoded(width, height)
        var crop = (left: 0, right: 0, top: 0, bottom: 0)
        if try r.flag() {
            crop = (Int(try r.ue()), Int(try r.ue()), Int(try r.ue()), Int(try r.ue()))
        }
        if pocType != 2 {
            guard try r.flag() else { throw RuleViolation(rule: 9, reason: "poc type \(pocType) without VUI", nalType: 7) }
            guard try vuiReorderZero(&r) else { throw RuleViolation(rule: 9, reason: "poc type \(pocType) without max_num_reorder_frames 0", nalType: 7) }
        }
        let visibleWidth = try envelope.visible(width, crop.left, crop.right, unit: 2, "width")
        let visibleHeight = try envelope.visible(height, crop.top, crop.bottom, unit: 2, "height")
        return SpsInfo(id: spsId, vpsId: -1, visibleWidth: visibleWidth, visibleHeight: visibleHeight, unusual: unusual)
    }

    /// scaling_list(): at most 64 se(v) entries.
    private static func skipScalingList(_ r: inout AnnexBBitReader, size: Int) throws {
        var last = 8, next = 8
        for _ in 0..<size {
            if next != 0 {
                let delta = try r.se()
                guard (-128...127).contains(delta) else { throw RuleViolation(rule: 9, reason: "delta_scale \(delta) out of range", nalType: 7) }
                next = (last + Int(delta) + 256) % 256
            }
            last = next == 0 ? last : next
        }
    }

    private static func skipHrd(_ r: inout AnnexBBitReader) throws {
        let count = try r.ue(max: 31) + 1 // cpb_cnt_minus1 + 1, at most 32
        try r.skip(8) // bit_rate_scale, cpb_size_scale
        for _ in 0..<count {
            _ = try r.ue() // bit_rate_value_minus1
            _ = try r.ue() // cpb_size_value_minus1
            try r.skip(1) // cbr_flag
        }
        try r.skip(20) // four 5-bit length fields
    }

    /// The VUI up to `bitstream_restriction`: true when the flag is 1 and `max_num_reorder_frames` is 0.
    private static func vuiReorderZero(_ r: inout AnnexBBitReader) throws -> Bool {
        if try r.flag() { // aspect_ratio_info_present_flag
            if try r.u(8) == 255 { try r.skip(32) } // Extended_SAR
        }
        if try r.flag() { try r.skip(1) } // overscan_info_present_flag, overscan_appropriate_flag
        if try r.flag() { // video_signal_type_present_flag
            try r.skip(4) // video_format, video_full_range_flag
            if try r.flag() { try r.skip(24) } // colour_description_present_flag
        }
        if try r.flag() { // chroma_loc_info_present_flag
            _ = try r.ue()
            _ = try r.ue()
        }
        if try r.flag() { try r.skip(65) } // timing_info_present_flag: 32 + 32 + fixed_frame_rate_flag
        let nalHrd = try r.flag()
        if nalHrd { try skipHrd(&r) }
        let vclHrd = try r.flag()
        if vclHrd { try skipHrd(&r) }
        if nalHrd || vclHrd { try r.skip(1) } // low_delay_hrd_flag
        try r.skip(1) // pic_struct_present_flag
        guard try r.flag() else { return false } // bitstream_restriction_flag
        try r.skip(1) // motion_vectors_over_pic_boundaries_flag
        _ = try r.ue() // max_bytes_per_pic_denom
        _ = try r.ue() // max_bits_per_mb_denom
        _ = try r.ue() // log2_max_mv_length_horizontal
        _ = try r.ue() // log2_max_mv_length_vertical
        return try r.ue() == 0 // max_num_reorder_frames
    }

    static func parsePps(_ nal: Data) throws -> PpsInfo {
        var r = parameterSetReader(nal, .h264, rule: 10, type: 8)
        let id = try r.ue(max: 255)
        let spsId = try r.ue(max: 31)
        try r.skip(2) // entropy_coding_mode_flag, bottom_field_pic_order_in_frame_present_flag
        guard try r.ue() == 0 else { throw RuleViolation(rule: 10, reason: "num_slice_groups_minus1 not 0", nalType: 8) }
        _ = try r.ue() // num_ref_idx_l0_default_active_minus1
        _ = try r.ue() // num_ref_idx_l1_default_active_minus1
        try r.skip(3) // weighted_pred_flag, weighted_bipred_idc
        _ = try r.se() // pic_init_qp_minus26
        _ = try r.se() // pic_init_qs_minus26
        _ = try r.se() // chroma_qp_index_offset
        try r.skip(2) // deblocking_filter_control_present_flag, constrained_intra_pred_flag
        guard try !r.flag() else { throw RuleViolation(rule: 10, reason: "redundant_pic_cnt_present_flag not 0", nalType: 8) }
        return PpsInfo(id: id, spsId: spsId, numExtraSliceHeaderBits: 0)
    }

    /// Returns the slice's PPS ID. P or I slices only; I exactly in an IDR.
    static func parseSlice(_ nal: Data, type: Int) throws -> Int {
        var r = sliceReader(nal, .h264, type: type)
        guard try r.ue() == 0 else { throw RuleViolation(rule: 4, reason: "first_mb_in_slice not 0", nalType: type) }
        let sliceType = try r.ue()
        let intra: Bool
        switch sliceType {
        case 0, 5: intra = false
        case 2, 7: intra = true
        default: throw RuleViolation(rule: 4, reason: "slice_type \(sliceType) not P or I", nalType: type)
        }
        guard AnnexBCodec.h264.isIdr(type) == intra else {
            throw RuleViolation(rule: 4, reason: "slice_type \(sliceType) does not fit NAL type \(type)", nalType: type)
        }
        return try r.ue(max: 255)
    }
}

/// One validated parameter-set group.
public struct ParameterSets: Equatable {
    public let codec: AnnexBCodec
    /// Escaped NAL bytes without start codes (`vps` nil for H.264).
    public let vps: Data?
    public let sps: Data
    public let pps: Data
    /// Visible (cropped) size.
    public let visibleWidth: Int
    public let visibleHeight: Int
    public let ppsId: Int
    public let numExtraSliceHeaderBits: Int
    /// Values above the usual range, accepted and logged as `au_unusual` ("field=value").
    public let unusual: [String]

    func matches(vps otherVps: Data?, sps otherSps: Data, pps otherPps: Data) -> Bool {
        vps == otherVps && sps == otherSps && pps == otherPps
    }
}

/// Builds and validates one parameter-set group (rule 5 sizes and chain, rules 6 to 10).
public enum ParameterSetParser {
    static func build(codec: AnnexBCodec, vps: Data?, sps: Data, pps: Data, envelope: SizeEnvelope) throws -> ParameterSets {
        for nal in [vps, sps, pps].compactMap({ $0 }) where nal.count > AnnexB.maxParameterSetNalBytes {
            throw RuleViolation(rule: 5, reason: "parameter set of \(nal.count) bytes above \(AnnexB.maxParameterSetNalBytes)")
        }
        var vpsId = -1
        if codec == .hevc {
            guard let vps else { throw RuleViolation(rule: 5, reason: "missing VPS") }
            vpsId = try HevcSyntax.parseVps(vps)
        }
        let spsInfo = try codec == .hevc ? HevcSyntax.parseSps(sps, envelope: envelope) : AvcSyntax.parseSps(sps, envelope: envelope)
        let ppsInfo = try codec == .hevc ? HevcSyntax.parsePps(pps) : AvcSyntax.parsePps(pps)
        if codec == .hevc && spsInfo.vpsId != vpsId {
            throw RuleViolation(rule: 5, reason: "SPS VPS ID \(spsInfo.vpsId) does not name the VPS (\(vpsId))")
        }
        guard ppsInfo.spsId == spsInfo.id else {
            throw RuleViolation(rule: 5, reason: "PPS SPS ID \(ppsInfo.spsId) does not name the SPS (\(spsInfo.id))")
        }
        return ParameterSets(codec: codec, vps: vps, sps: sps, pps: pps, visibleWidth: spsInfo.visibleWidth, visibleHeight: spsInfo.visibleHeight,
                             ppsId: ppsInfo.id, numExtraSliceHeaderBits: ppsInfo.numExtraSliceHeaderBits, unusual: spsInfo.unusual)
    }

    /// The sender's own sets, parsed without a session size (the receiver applies its header's envelope).
    public static func buildUnbounded(codec: AnnexBCodec, vps: Data?, sps: Data, pps: Data) throws -> ParameterSets {
        try build(codec: codec, vps: vps, sps: sps, pps: pps, envelope: .unbounded)
    }
}

public enum AuVerdict: Equatable {
    /// `accessUnit`: SEI, AUD and filler removed, 4-byte start codes. `activated`: the sets this IDR made active (only
    /// when they changed, including the first).
    case accept(accessUnit: Data, keyFrame: Bool, activated: ParameterSets?)
    /// Dropped as corrupt video (the receiver asks for a keyframe). `keyFrame`: the keyframe flag was set or an IDR NAL
    /// unit was present.
    case reject(rule: Int, nalType: Int, bytes: Int, reason: String, keyFrame: Bool)
    /// Unsupported stream: end the session. `codec_config`, `discardable` or `rejected_keyframes`.
    case close(String)
}

/// One per receive session (call or stream); not thread-safe (call it from the packet-handling thread).
public final class AccessUnitGate {
    public static let rejectedKeyframeWindowMs: Int64 = 10_000
    public let codec: AnnexBCodec
    private let envelope: SizeEnvelope
    /// The active configuration; it changes only inside a fully valid IDR access unit.
    public private(set) var active: ParameterSets?
    /// After a rejected keyframe, until the next valid IDR: non-IDR access units are dropped (rule 5).
    public private(set) var waitingForIdr = false
    private var closedReason: String?
    private var rejectedKeyframeTimes: [Int64] = []
    private var candidateKeyFrame = false

    public init(codec: AnnexBCodec, headerMaxWidth: Int, headerMaxHeight: Int) {
        self.codec = codec
        envelope = SizeEnvelope(headerMaxWidth: headerMaxWidth, headerMaxHeight: headerMaxHeight)
    }

    public func check(_ payload: Data, flags: UInt8, nowMs: Int64) -> AuVerdict {
        if let closedReason { return .close(closedReason) }
        if flags & StreamProtocol.flagCodecConfig != 0 { return close("codec_config") }
        if flags & StreamProtocol.flagDiscardable != 0 { return close("discardable") }
        candidateKeyFrame = flags & StreamProtocol.flagKeyFrame != 0
        do {
            let verdict = try evaluate(payload, flags: flags)
            if case .accept(_, true, _) = verdict {
                rejectedKeyframeTimes.removeAll()
                waitingForIdr = false
            }
            return verdict
        } catch let violation as RuleViolation {
            return rejected(violation, bytes: payload.count, nowMs: nowMs)
        } catch {
            return rejected(RuleViolation(rule: 1, reason: "\(error)"), bytes: payload.count, nowMs: nowMs)
        }
    }

    private func close(_ reason: String) -> AuVerdict {
        closedReason = reason
        return .close(reason)
    }

    private func rejected(_ violation: RuleViolation, bytes: Int, nowMs: Int64) -> AuVerdict {
        if candidateKeyFrame {
            waitingForIdr = true
            rejectedKeyframeTimes.append(nowMs)
            if rejectedKeyframeTimes.count > 3 { rejectedKeyframeTimes.removeFirst() }
            if rejectedKeyframeTimes.count == 3, rejectedKeyframeTimes[2] - rejectedKeyframeTimes[0] <= Self.rejectedKeyframeWindowMs {
                return close("rejected_keyframes")
            }
        }
        return .reject(rule: violation.rule, nalType: violation.nalType, bytes: bytes, reason: violation.reason, keyFrame: candidateKeyFrame)
    }

    private func evaluate(_ payload: Data, flags: UInt8) throws -> AuVerdict {
        guard !payload.isEmpty, payload.count <= StreamProtocol.maxPayloadBytes else {
            throw RuleViolation(rule: 1, reason: "payload size \(payload.count) outside 1...\(StreamProtocol.maxPayloadBytes)")
        }
        // Rule 1: framing and escapes.
        let nals: [NalUnit]
        switch AnnexB.scan(payload, codec: codec) {
        case .ok(let found):
            nals = found
        case .fail(let reason, let partial):
            if partial.contains(where: { codec.isIdr($0.type) }) { candidateKeyFrame = true }
            throw RuleViolation(rule: 1, reason: reason)
        }
        if nals.contains(where: { codec.isIdr($0.type) }) { candidateKeyFrame = true }
        // Rules 2 and 3: NAL headers and allowed types.
        for nal in nals where !codec.headerValid(nal.bytes) {
            throw RuleViolation(rule: 2, reason: "NAL header not valid", nalType: nal.type)
        }
        for nal in nals where !codec.isAllowed(nal.type) {
            throw RuleViolation(rule: 3, reason: "NAL type \(nal.type) not allowed", nalType: nal.type)
        }
        // Rule 4: exactly one slice; parameter sets, AUD and prefix SEI before it, filler and suffix SEI after it.
        guard let sliceIndex = nals.firstIndex(where: { codec.isSlice($0.type) }) else {
            throw RuleViolation(rule: 4, reason: "no slice NAL unit")
        }
        guard nals.filter({ codec.isSlice($0.type) }).count == 1 else {
            throw RuleViolation(rule: 4, reason: "more than one slice NAL unit", nalType: nals[sliceIndex].type)
        }
        for (i, nal) in nals.enumerated() {
            if i < sliceIndex && codec.isTrailing(nal.type) { throw RuleViolation(rule: 4, reason: "NAL type \(nal.type) before the slice", nalType: nal.type) }
            if i > sliceIndex && !codec.isTrailing(nal.type) { throw RuleViolation(rule: 4, reason: "NAL type \(nal.type) after the slice", nalType: nal.type) }
        }
        let slice = nals[sliceIndex]
        let idr = codec.isIdr(slice.type)
        let vpsIndexes = nals.indices.filter { nals[$0].type == codec.vpsType }
        let spsIndexes = nals.indices.filter { nals[$0].type == codec.spsType }
        let ppsIndexes = nals.indices.filter { nals[$0].type == codec.ppsType }
        // Rule 5: the keyframe flag is set if and only if the slice is an IDR.
        guard (flags & StreamProtocol.flagKeyFrame != 0) == idr else {
            throw RuleViolation(rule: 5, reason: idr ? "IDR without the keyframe flag" : "keyframe flag without an IDR", nalType: slice.type)
        }
        var activated: ParameterSets?
        if idr {
            let wantVps = codec == .hevc ? 1 : 0
            guard vpsIndexes.count == wantVps, spsIndexes.count == 1, ppsIndexes.count == 1 else {
                throw RuleViolation(rule: 5, reason: "an IDR needs exactly one \(codec == .hevc ? "VPS, " : "")SPS and PPS")
            }
            guard (vpsIndexes.first ?? -1) < spsIndexes[0], spsIndexes[0] < ppsIndexes[0] else {
                throw RuleViolation(rule: 5, reason: "parameter sets out of order")
            }
            let vps = vpsIndexes.first.map { nals[$0].bytes }
            let sps = nals[spsIndexes[0]].bytes, pps = nals[ppsIndexes[0]].bytes
            let sets: ParameterSets
            if let current = active, current.matches(vps: vps, sps: sps, pps: pps) {
                sets = current // identical bytes were already validated against this session's envelope
            } else {
                sets = try ParameterSetParser.build(codec: codec, vps: vps, sps: sps, pps: pps, envelope: envelope)
            }
            let ppsId = try codec == .hevc
                ? HevcSyntax.parseSlice(slice.bytes, type: slice.type, numExtraSliceHeaderBits: sets.numExtraSliceHeaderBits)
                : AvcSyntax.parseSlice(slice.bytes, type: slice.type)
            guard ppsId == sets.ppsId else {
                throw RuleViolation(rule: 5, reason: "slice PPS ID \(ppsId) does not name the PPS (\(sets.ppsId))", nalType: slice.type)
            }
            if sets != active { activated = sets }
            active = sets // atomic: reached only when the whole access unit passed
        } else {
            if let first = (vpsIndexes + spsIndexes + ppsIndexes).first {
                throw RuleViolation(rule: 5, reason: "a non-IDR access unit carries a parameter set", nalType: nals[first].type)
            }
            guard let current = active else { throw RuleViolation(rule: 5, reason: "no active configuration before the first IDR", nalType: slice.type) }
            if waitingForIdr { throw RuleViolation(rule: 5, reason: "dropped until the next valid IDR", nalType: slice.type) }
            let ppsId = try codec == .hevc
                ? HevcSyntax.parseSlice(slice.bytes, type: slice.type, numExtraSliceHeaderBits: current.numExtraSliceHeaderBits)
                : AvcSyntax.parseSlice(slice.bytes, type: slice.type)
            guard ppsId == current.ppsId else {
                throw RuleViolation(rule: 5, reason: "slice PPS ID \(ppsId) is not the active PPS (\(current.ppsId))", nalType: slice.type)
            }
        }
        // Rule 11: SEI, AUD and filler are removed; the rest goes on behind 4-byte start codes.
        let kept = nals.filter { !codec.isStripped($0.type) }.map(\.bytes)
        return .accept(accessUnit: AnnexB.annexB(kept), keyFrame: idr, activated: activated)
    }
}

/// Sender side of codecs 4 and 5 (PROTOCOL "Sender rules"; Android `AnnexBPacketiser`): one Annex B access unit per
/// `BTV3` video packet from an encoder's NAL units. The encoder's parameter sets are cached (newest wins), stripped from
/// every access unit and prepended to every IDR; SEI, AUD and filler are removed; the keyframe flag comes from the NAL
/// type, never from the encoder's own flag; presentation timestamps must strictly increase. Not thread-safe.
public struct HardwareAccessUnitPacketiser {
    public enum Output: Equatable {
        /// `visibleWidth`/`visibleHeight`: the SPS size after cropping, on keyframes only.
        case packet(payload: Data, keyFrame: Bool, visibleWidth: Int?, visibleHeight: Int?)
        /// `reorder`, `no_parameter_sets`, `no_slice`, `multi_slice`, `unsupported_nal` or `malformed`.
        case error(String)
    }

    public let codec: AnnexBCodec
    private var vps: Data?, sps: Data?, pps: Data?
    private var parsed: ParameterSets?
    private var dirty = false
    private var lastPresentationTimeUs: Int64?
    /// Why the cached sets do not parse (nil when they do or when none are cached).
    public private(set) var parameterSetProblem: String?

    public init(codec: AnnexBCodec) { self.codec = codec }

    /// The encoder's parameter sets (VideoToolbox: its format description's sets, in any order); newest wins.
    public mutating func updateParameterSets(_ nals: [Data]) {
        for nal in nals { absorb(nal) }
    }

    /// The cached, parsed sets, or nil until a complete set is cached and parses.
    public mutating func cachedSets() -> ParameterSets? {
        if dirty { reparse() }
        return parsed
    }

    public mutating func packetise(_ nals: [Data], presentationTimeUs: Int64) -> Output {
        guard !nals.contains(where: { $0.isEmpty }) else { return .error("malformed") }
        let typed = nals.map { NalUnit(type: codec.nalType($0[$0.startIndex]), bytes: $0) }
        if let odd = typed.first(where: { codec.isVcl($0.type) && !codec.isSlice($0.type) }) {
            return .error("unsupported_nal \(odd.type)")
        }
        let slices = typed.filter { codec.isSlice($0.type) }
        if slices.isEmpty {
            for nal in typed where codec.isParameterSet(nal.type) { absorb(nal.bytes) }
            return .error("no_slice")
        }
        if slices.count > 1 { return .error("multi_slice") }
        if let odd = typed.first(where: { !codec.isSlice($0.type) && !codec.isParameterSet($0.type) && !codec.isStripped($0.type) }) {
            return .error("unsupported_nal \(odd.type)")
        }
        // In-band sets update the cache whether or not this access unit is accepted below.
        for nal in typed where codec.isParameterSet(nal.type) { absorb(nal.bytes) }
        if let last = lastPresentationTimeUs, presentationTimeUs <= last { return .error("reorder") }
        let slice = slices[0]
        let keyFrame = codec.isIdr(slice.type)
        let output: Output
        if keyFrame {
            guard let sets = cachedSets() else { return .error(parameterSetProblem.map { "no_parameter_sets \($0)" } ?? "no_parameter_sets") }
            output = .packet(payload: AnnexB.annexB([sets.vps, sets.sps, sets.pps, slice.bytes].compactMap { $0 }), keyFrame: true,
                             visibleWidth: sets.visibleWidth, visibleHeight: sets.visibleHeight)
        } else {
            output = .packet(payload: AnnexB.annexB([slice.bytes]), keyFrame: false, visibleWidth: nil, visibleHeight: nil)
        }
        lastPresentationTimeUs = presentationTimeUs
        return output
    }

    private mutating func absorb(_ nal: Data) {
        guard let first = nal.first else { return }
        let type = codec.nalType(first)
        if type == codec.vpsType, vps != nal { vps = nal; dirty = true }
        if type == codec.spsType, sps != nal { sps = nal; dirty = true }
        if type == codec.ppsType, pps != nal { pps = nal; dirty = true }
    }

    private mutating func reparse() {
        dirty = false
        parsed = nil
        parameterSetProblem = nil
        guard let sps, let pps, codec == .h264 || vps != nil else { return }
        do {
            parsed = try ParameterSetParser.buildUnbounded(codec: codec, vps: vps, sps: sps, pps: pps)
        } catch {
            parameterSetProblem = "\(error)"
        }
    }
}

/// PROTOCOL "Sender rules", keyframe requests (codecs 4 and 5): a request must be answered by an IDR, judged from the
/// emitted NAL types. Without one within 1 s the request is repeated; after 3 misses the sender ends video with
/// `no_idr` and the encoder is ineligible for this process.
public struct IdrRequestTracker {
    public enum Action: Equatable { case none, repeatRequest, giveUp }
    public static let answerWindow: TimeInterval = 1
    public static let maxMisses = 3
    private var pendingSince: TimeInterval?
    private var misses = 0

    public init() {}

    public var waiting: Bool { pendingSince != nil }

    /// A keyframe request arrived (a second request while one is pending keeps the first deadline).
    public mutating func requested(now: TimeInterval) {
        if pendingSince == nil { pendingSince = now }
    }

    /// The encoder emitted an access unit; an IDR answers every pending request.
    public mutating func emitted(idr: Bool) {
        if idr {
            pendingSince = nil
            misses = 0
        }
    }

    /// Called before each frame: repeat the request after each missed second, give up after the third.
    public mutating func tick(now: TimeInterval) -> Action {
        guard let since = pendingSince, now - since >= Self.answerWindow else { return .none }
        misses += 1
        if misses >= Self.maxMisses {
            pendingSince = nil
            return .giveUp
        }
        pendingSince = now
        return .repeatRequest
    }
}
