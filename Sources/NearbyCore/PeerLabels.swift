import Foundation
import CryptoKit

// Experimental peer labels (naming phase 1, Android `test_peer_labels`): signed names, call subjects and
// stream titles (BNL1 in a BLB1 container, BME1 content type 10, end-to-end hello bit 5), the label text
// rules, and public title pages. Mirrors Android LabelText.kt / SignedLabel.kt / TitlePage.kt exactly.
// Off by default: with the switch off no hello bit, no type 10, nothing on the wire changes.

public enum PeerLabelFeature {
    /// End-to-end hello transport-mask bit 5: "accepts and sends LABELS". Never in link or BGK1 hellos.
    public static let capabilityBit: UInt8 = 1 << 5
    public static func advertise(_ caps: NodeCapabilities, enabled: Bool) -> NodeCapabilities {
        var c = caps; if enabled { c.transportMask |= capabilityBit }; return c
    }
    public static func negotiated(localEnabled: Bool, peer: NodeCapabilities) -> Bool {
        localEnabled && peer.transportMask & capabilityBit != 0
    }
    /// Streams additionally need the link peer to be the endpoint peer (no opaque stream relay between).
    public static func streamHopNegotiated(localEnabled: Bool, linkPeer: NodeId, endpointPeer: NodeId, peer: NodeCapabilities) -> Bool {
        negotiated(localEnabled: localEnabled, peer: peer) && linkPeer == endpointPeer
    }
}

public enum LabelKind: UInt8, CaseIterable {
    case personName = 1, streamTitle = 2, callSubject = 3
    public var maxBytes: Int { switch self { case .personName: return 32; case .streamTitle: return 48; case .callSubject: return 64 } }
}

public enum LabelText {
    public static let maxCombiningRun = 3
    static let checkMarks: Set<UInt32> = [0x2713, 0x2714, 0x2705, 0x2611, 0x1F5F8]

    /// Java `Character.isWhitespace || Character.isSpaceChar`.
    static func isSpace(_ s: Unicode.Scalar) -> Bool {
        switch s.properties.generalCategory {
        case .spaceSeparator, .lineSeparator, .paragraphSeparator: return true
        default: return (0x09...0x0D).contains(s.value) || (0x1C...0x1F).contains(s.value)
        }
    }

    static func collapseWhitespace(_ text: String) -> String {
        var out = String.UnicodeScalarView()
        var pending = false, started = false
        for s in text.unicodeScalars {
            if isSpace(s) { if started { pending = true } }
            else { if pending { out.append(" ") }; pending = false; started = true; out.append(s) }
        }
        return String(out)
    }

    /// Sender side: the canonical text, or a short reason (never containing the text).
    public static func normalize(_ kind: LabelKind, _ text: String) -> Result<String, LabelRejected> {
        let normalized = collapseWhitespace(text).precomposedStringWithCanonicalMapping
        guard !normalized.isEmpty else { return .failure(LabelRejected("empty")) }
        guard normalized.utf8.count <= kind.maxBytes else { return .failure(LabelRejected("too long")) }
        var run = 0
        for s in normalized.unicodeScalars {
            switch s.properties.generalCategory {
            case .control, .format, .privateUse, .surrogate, .unassigned, .lineSeparator, .paragraphSeparator:
                return .failure(LabelRejected("control, format or unassigned character"))
            default: break
            }
            if checkMarks.contains(s.value) { return .failure(LabelRejected("check mark")) }
            switch s.properties.generalCategory {
            case .nonspacingMark, .enclosingMark:
                run += 1
                if run > maxCombiningRun { return .failure(LabelRejected("stacked combining marks")) }
            default: run = 0
            }
        }
        guard scriptsAllowed(normalized) else { return .failure(LabelRejected("mixed scripts")) }
        guard !looksLikeHandle(normalized) else { return .failure(LabelRejected("looks like a handle")) }
        return .success(normalized)
    }

    /// Byte comparison: Swift `==` on String uses canonical equivalence, which would accept decomposed text.
    public static func isCanonical(_ kind: LabelKind, _ text: String) -> Bool {
        if case .success(let n) = normalize(kind, text) { return n.utf8.elementsEqual(text.utf8) }
        return false
    }

    public static func rejection(_ kind: LabelKind, _ text: String) -> String? {
        switch normalize(kind, text) {
        case .success(let n): return n.utf8.elementsEqual(text.utf8) ? nil : "not canonical"
        case .failure(let e): return e.reason
        }
    }

    /// UTS #39 Moderately Restrictive (Common/Inherited/Unknown ignored).
    public static func scriptsAllowed(_ text: String) -> Bool {
        var scripts = Set<Int>()
        for s in text.unicodeScalars {
            let script = UnicodeScripts.script(of: s)
            if script != UnicodeScripts.common && script != UnicodeScripts.inherited && script != UnicodeScripts.unknown { scripts.insert(script) }
        }
        if scripts.count <= 1 { return true }
        let latin = UnicodeScripts.index("Latin"), han = UnicodeScripts.index("Han")
        let cjk: [Set<Int>] = [[latin, han, UnicodeScripts.index("Hiragana"), UnicodeScripts.index("Katakana")],
                               [latin, han, UnicodeScripts.index("Bopomofo")], [latin, han, UnicodeScripts.index("Hangul")]]
        if cjk.contains(where: { scripts.isSubset(of: $0) }) { return true }
        if scripts.contains(latin) && scripts.count == 2 {
            let other = scripts.first { $0 != latin }!
            return other != UnicodeScripts.index("Cyrillic") && other != UnicodeScripts.index("Greek")
        }
        return false
    }

    /// R6: handle-shaped text only ("Brave Tiger" stays valid: no digit).
    public static func looksLikeHandle(_ text: String) -> Bool {
        let folded = text.precomposedStringWithCompatibilityMapping.lowercased()
        let chars = Array(folded.unicodeScalars)
        let alnum: (Unicode.Scalar) -> Bool = { ("0"..."9").contains($0) || ("a"..."z").contains($0) }
        if chars.count == 11, chars[5] == "-", chars.enumerated().allSatisfy({ $0.offset == 5 || alnum($0.element) }) { return true }
        guard folded.unicodeScalars.contains(where: { ("0"..."9").contains($0) }) else { return false }
        return IdentityHandle.parse(folded) != nil || IdentityHandle.parseShort(folded) != nil
    }
}

public struct LabelRejected: Error, Equatable, CustomStringConvertible {
    public let reason: String
    public init(_ reason: String) { self.reason = reason }
    public var description: String { reason }
}

/// What a label is bound to: a BMC2 call ID (1) or a stream ID (2).
public struct LabelBinding: Equatable {
    public static let call: UInt8 = 1, stream: UInt8 = 2
    public let type: UInt8
    public let id: UUID
    public init(type: UInt8, id: UUID) { self.type = type; self.id = id }
    public static func call(_ id: UUID) -> LabelBinding { LabelBinding(type: call, id: id) }
    /// A direct stream without a mesh stream ID binds to the all-zero ID.
    public static func stream(_ id: UUID?) -> LabelBinding { LabelBinding(type: stream, id: id ?? UUID(rawBytes: Data(count: 16))) }
    public static let directStream = stream(nil)
}

public struct SignedLabel {
    public let kindValue: UInt8
    public let spki: Data
    public let sequence: UInt32
    public let binding: LabelBinding
    public let text: String
    public let signature: Data
    public let encoded: Data
    let signedBytes: Data
    public var kind: LabelKind? { LabelKind(rawValue: kindValue) }
}

public enum SignedLabelCodec {
    static let magic = Data("BNL1".utf8), containerMagic = Data("BLB1".utf8)
    public static let version: UInt8 = 1
    public static let maxLabels = 3
    /// R8: terminated domain.
    public static let domain = Data("BluetoothVideoMesh/Label/1".utf8) + Data([0])

    public static func signedPart(kind: UInt8, spki: Data, sequence: UInt32, binding: LabelBinding, text: String) throws -> Data {
        let t = Data(text.utf8)
        guard (1...512).contains(spki.count), (1...64).contains(t.count), binding.type == 1 || binding.type == 2 else {
            throw LabelRejected("field length")
        }
        var w = BinaryWriter()
        w.bytes(magic); w.byte(version); w.byte(kind); w.u16(UInt16(spki.count)); w.bytes(spki); w.u32(sequence)
        w.byte(binding.type); w.bytes(binding.id.rawBytes); w.byte(UInt8(t.count)); w.bytes(t)
        return w.data
    }

    public static func sign(identity: SigningIdentity, kind: LabelKind, binding: LabelBinding, text: String, sequence: UInt32 = 0) throws -> Data {
        let canonical = try LabelText.normalize(kind, text).get()
        let unsigned = try signedPart(kind: kind.rawValue, spki: identity.publicKeyEncoded, sequence: sequence, binding: binding, text: canonical)
        let signature = try identity.sign(domain + unsigned) // DER ECDSA (Android rejects raw signatures)
        guard (1...256).contains(signature.count) else { throw LabelRejected("signature length") }
        var w = BinaryWriter(); w.bytes(unsigned); w.u16(UInt16(signature.count)); w.bytes(signature); return w.data
    }

    public static func decode(_ encoded: Data) throws -> SignedLabel {
        var r = BinaryReader(encoded)
        do {
            guard try r.bytes(4) == magic else { throw LabelRejected("magic") }
            guard try r.byte() == version else { throw LabelRejected("version") }
            let kind = try r.byte()
            let spkiLength = Int(try r.u16())
            guard (1...512).contains(spkiLength) else { throw LabelRejected("spki length") }
            let spki = try r.bytes(spkiLength)
            let sequence = try r.u32()
            let bindingType = try r.byte()
            guard bindingType == 1 || bindingType == 2 else { throw LabelRejected("binding type") }
            let binding = LabelBinding(type: bindingType, id: UUID(rawBytes: try r.bytes(16)))
            let textLength = Int(try r.byte())
            guard (1...64).contains(textLength) else { throw LabelRejected("text length") }
            let textBytes = try r.bytes(textLength)
            let signedLength = r.offset
            let signatureLength = Int(try r.u16())
            guard (1...256).contains(signatureLength) else { throw LabelRejected("signature length") }
            let signature = try r.bytes(signatureLength)
            guard r.remaining == 0 else { throw LabelRejected("trailing bytes") }
            guard let text = String(data: textBytes, encoding: .utf8), Data(text.utf8) == textBytes else { throw LabelRejected("utf8") }
            let e = encoded.rebased
            return SignedLabel(kindValue: kind, spki: spki, sequence: sequence, binding: binding, text: text, signature: signature,
                               encoded: e, signedBytes: e.prefix(signedLength).rebased)
        } catch let error as LabelRejected { throw error }
        catch { throw LabelRejected("truncated") }
    }

    /// Receiver checks in PROTOCOL order; returns the kind or throws with a reason.
    @discardableResult
    public static func verify(_ label: SignedLabel, expectedSigner: NodeId, expectedBinding: LabelBinding) throws -> LabelKind {
        guard let kind = label.kind else { throw LabelRejected("unknown kind") }
        guard NodeId.fromPublicKey(label.spki) == expectedSigner else { throw LabelRejected("signer") }
        guard let key = try? P256.Signing.PublicKey(derRepresentation: label.spki) else { throw LabelRejected("key") }
        guard let signature = try? P256.Signing.ECDSASignature(derRepresentation: label.signature),
              key.isValidSignature(signature, for: domain + label.signedBytes) else { throw LabelRejected("signature") }
        guard label.binding == expectedBinding else { throw LabelRejected("binding") }
        if let reason = LabelText.rejection(kind, label.text) { throw LabelRejected("text \(reason)") }
        return kind
    }

    public static func encodeContainer(_ labels: [Data]) throws -> Data {
        guard labels.count <= maxLabels else { throw LabelRejected("too many labels") }
        var w = BinaryWriter(); w.bytes(containerMagic); w.byte(UInt8(labels.count))
        for l in labels { guard (1...0xffff).contains(l.count) else { throw LabelRejected("label length") }; w.u16(UInt16(l.count)); w.bytes(l) }
        return w.data
    }

    public static func decodeContainer(_ payload: Data) throws -> [Data] {
        var r = BinaryReader(payload)
        guard let m = try? r.bytes(4) else { throw LabelRejected("container") }
        guard m == containerMagic else { throw LabelRejected("container magic") }
        guard let count = try? r.byte() else { throw LabelRejected("container") }
        guard count <= maxLabels else { throw LabelRejected("container count") }
        var out: [Data] = []
        for _ in 0..<count {
            guard let length = try? r.u16(), let bytes = try? r.bytes(Int(length)) else { throw LabelRejected("container truncated") }
            out.append(bytes)
        }
        guard r.remaining == 0 else { throw LabelRejected("container trailing bytes") }
        return out
    }
}

/// Labels verified in one session (call or stream hop); nothing outlives the session.
public final class LabelInbox {
    private var accepted: [LabelKind: SignedLabel] = [:]
    private var arrivals: [TimeInterval] = []
    private let now: () -> TimeInterval
    public var onRejected: ((LabelKind?, String) -> Void)?
    public init(now: @escaping () -> TimeInterval = { ProcessInfo.processInfo.systemUptime }) { self.now = now }

    public func text(_ kind: LabelKind) -> String? { accepted[kind]?.text }
    /// Exact verified bytes for forwarding unchanged.
    public func verifiedEncoded() -> [Data] { LabelKind.allCases.compactMap { accepted[$0]?.encoded } }

    /// Applies one LABELS payload; failures are dropped (never thrown). Returns the kinds that changed.
    @discardableResult
    public func accept(_ payload: Data, expectedSigner: NodeId, expectedBinding: LabelBinding) -> Set<LabelKind> {
        let t = now()
        arrivals.removeAll { t - $0 > 60 }
        if let last = arrivals.last, t - last < 2 { onRejected?(nil, "rate"); return [] }
        if arrivals.count >= 8 { onRejected?(nil, "rate"); return [] }
        arrivals.append(t)
        let raw: [Data]
        do { raw = try SignedLabelCodec.decodeContainer(payload) } catch { onRejected?(nil, "\(error)"); return [] }
        var changed = Set<LabelKind>()
        for bytes in raw {
            guard let label = try? SignedLabelCodec.decode(bytes) else { onRejected?(nil, "decode"); continue }
            guard label.kind != nil else { continue } // unknown kinds are skipped for later versions
            let kind: LabelKind
            do { kind = try SignedLabelCodec.verify(label, expectedSigner: expectedSigner, expectedBinding: expectedBinding) }
            catch { onRejected?(label.kind, "\(error)"); continue }
            if let previous = accepted[kind], label.sequence <= previous.sequence { continue }
            accepted[kind] = label; changed.insert(kind)
        }
        return changed
    }
}

// MARK: - Public title pages (read only on iPhone: iOS cannot advertise manufacturer data)

public struct TitlePage: Equatable {
    public let routeToken: UInt32, digest: UInt16, index: Int, count: Int, fragment: Data
    public init(routeToken: UInt32, digest: UInt16, index: Int, count: Int, fragment: Data) {
        self.routeToken = routeToken; self.digest = digest; self.index = index; self.count = count; self.fragment = fragment.rebased
    }
}

public enum TitlePageCodec {
    public static let version: UInt8 = 3
    public static let headerBytes = 8, maxFragmentBytes = 19, maxPages = 3
    public static func digest(_ bytes: Data) -> UInt16 { let h = Array(SHA256.hash(data: bytes)); return UInt16(h[0]) << 8 | UInt16(h[1]) }

    /// Splits a canonical title (<= 48 bytes) at code-point boundaries into scan-response payloads.
    public static func pages(routeToken: UInt32, title: String) throws -> [Data] {
        let bytes = [UInt8](title.utf8)
        guard !bytes.isEmpty, bytes.count <= LabelKind.streamTitle.maxBytes else { throw LabelRejected("title length") }
        var fragments: [[UInt8]] = [], offset = 0
        while offset < bytes.count {
            var end = min(bytes.count, offset + maxFragmentBytes)
            while end < bytes.count && end > offset && bytes[end] & 0xc0 == 0x80 { end -= 1 }
            fragments.append(Array(bytes[offset..<end])); offset = end
        }
        guard fragments.count <= maxPages else { throw LabelRejected("too many pages") }
        let d = digest(Data(bytes))
        return fragments.enumerated().map { i, f in
            var w = BinaryWriter(); w.byte(version); w.u32(routeToken); w.u16(d); w.byte(UInt8(i << 4 | fragments.count)); w.bytes(f); return w.data
        }
    }

    public static func isTitlePage(_ payload: Data) -> Bool { payload.first == version }

    public static func decode(_ payload: Data) throws -> TitlePage {
        let p = payload.rebased
        guard (headerBytes + 1...headerBytes + maxFragmentBytes).contains(p.count), p[0] == version else { throw LabelRejected("title page") }
        var r = BinaryReader(p); _ = try r.byte()
        let token = try r.u32(), d = try r.u16(), page = try r.byte()
        let index = Int(page >> 4), count = Int(page & 0x0f)
        guard (1...maxPages).contains(count), index < count else { throw LabelRejected("title page index") }
        return TitlePage(routeToken: token, digest: d, index: index, count: count, fragment: try r.rest())
    }
}

/// Reassembles advertised titles by (token, digest, count) within 30 s; conflicting digests for one token
/// within 60 s show no title. Advertised titles are always "unconfirmed".
public final class TitleBoard {
    struct Key: Hashable { let token: UInt32, digest: UInt16, count: Int }
    private var partials: [Key: (first: TimeInterval, pages: [Data?])] = [:]
    private var titles: [UInt32: (String, TimeInterval)] = [:]
    private var digests: [UInt32: [(UInt16, TimeInterval)]] = [:]
    private var conflicted: [UInt32: TimeInterval] = [:]
    private let now: () -> TimeInterval
    public init(now: @escaping () -> TimeInterval = { ProcessInfo.processInfo.systemUptime }) { self.now = now }

    @discardableResult
    public func add(_ page: TitlePage) -> String? {
        let t = now(); prune(t)
        var seen = digests[page.routeToken] ?? []
        seen.removeAll { t - $0.1 > 60 || $0.0 == page.digest }
        if !seen.isEmpty { conflicted[page.routeToken] = t; titles[page.routeToken] = nil }
        seen.append((page.digest, t)); digests[page.routeToken] = seen
        let key = Key(token: page.routeToken, digest: page.digest, count: page.count)
        var partial = partials[key] ?? (t, Array(repeating: nil, count: page.count))
        partial.pages[page.index] = page.fragment
        partials[key] = partial
        guard partial.pages.allSatisfy({ $0 != nil }) else { return nil }
        partials[key] = nil
        let bytes = partial.pages.reduce(Data()) { $0 + $1! }
        guard TitlePageCodec.digest(bytes) == page.digest, let text = String(data: bytes, encoding: .utf8), Data(text.utf8) == bytes,
              LabelText.isCanonical(.streamTitle, text) else { return nil }
        if let c = conflicted[page.routeToken], t - c <= 60 { return nil }
        titles[page.routeToken] = (text, t)
        return text
    }

    public func title(routeToken: UInt32) -> String? {
        prune(now())
        if conflicted[routeToken] != nil { return nil }
        return titles[routeToken]?.0
    }

    private func prune(_ t: TimeInterval) {
        partials = partials.filter { t - $0.value.first <= 30 }
        titles = titles.filter { t - $0.value.1 <= 30 }
        conflicted = conflicted.filter { t - $0.value <= 60 }
    }
}
