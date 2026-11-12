import Foundation

// BVMID2 in-person verification (Android Bvmid2.kt; PROTOCOL "Verification code BVMID2"). Sans-I/O: the code format, the
// displaying phone's single-use state machine, the verify-only session scope, the scanner's checks, the mutual outcome and
// the BVMID1 and lease rules. The app binds it to the Add contact screen and the call endpoint.
//
// What a scan proves: the scanner reached a phone that holds the private key whose fingerprint is in the code, through a
// secret that was on the displaying screen. It does NOT prove physical presence (a current photograph or a live relay of the
// screen works within the code's life): the scanner confirms "Is this Rahul's screen?" before the shield is set, and the
// wording is "scanned", never "was here".
//
// Single use: the code is RESERVED atomically for one logical attempt when the link handshake's tag matches
// (`QrCodeDisplay.reserve`); the end-to-end handshake of the SAME connection continues under that reservation; a failure
// releases it (counted against a per-code attempt cap); only a completed end-to-end handshake commits it (CONSUMED). The
// first messages seen for a code are pinned until it expires, so cache eviction cannot manufacture a reuse alert.

/// Why a text is not a BVMID2 code; `reason` is Android's `Bvmid2FormatException.reason`.
public struct Bvmid2FormatError: Error, Equatable, CustomStringConvertible {
    public let reason: String
    public init(_ reason: String) { self.reason = reason }
    public var description: String { "Not a verification code: \(reason)" }
}

/// `BVMID2.<64 hex fingerprint>.<64 hex K_qr>.<12 hex RDI>`: the displaying phone's full fingerprint, the code's secret and
/// the role-0 rotating ID it advertises while the code is on screen.
public struct Bvmid2Payload: Equatable {
    public let fingerprint: IdentityFingerprint
    public let kQr: Data
    public let rdi: Data

    public init(fingerprint: IdentityFingerprint, kQr: Data, rdi: Data) throws {
        guard kQr.count == 32, rdi.count == RotatingDiscoveryIds.idBytes else { throw Bvmid2FormatError("length") }
        self.fingerprint = fingerprint; self.kQr = kQr.rebased; self.rdi = rdi.rebased
    }

    public static func == (a: Self, b: Self) -> Bool {
        a.fingerprint == b.fingerprint && constantTimeEqual(a.kQr, b.kQr) && a.rdi == b.rdi
    }
}

public enum Bvmid2 {
    public static let magic = "BVMID2"
    /// "BVMID2." + 64 + "." + 64 + "." + 12 characters.
    public static let textLength = 149

    /// Uppercase hex and `.` only (QR alphanumeric mode).
    public static func encode(_ payload: Bvmid2Payload) -> String {
        [magic, payload.fingerprint.hex.uppercased(), payload.kQr.hex.uppercased(), payload.rdi.hex.uppercased()].joined(separator: ".")
    }

    /// Strict parse: magic and version, four fields, lengths, hex alphabet, one case only, a nonzero secret.
    public static func parse(_ text: String) throws -> Bvmid2Payload {
        let parts = text.trimmingCharacters(in: .whitespacesAndNewlines).split(separator: ".", omittingEmptySubsequences: false).map(String.init)
        guard parts.first == magic else {
            throw Bvmid2FormatError(parts.first?.hasPrefix("BVMID") == true ? "other version" : "other magic")
        }
        guard parts.count == 4 else { throw Bvmid2FormatError("field count") }
        let fingerprintHex = parts[1], secretHex = parts[2], rdiHex = parts[3]
        guard fingerprintHex.count == 64, secretHex.count == 64, rdiHex.count == 12 else { throw Bvmid2FormatError("length") }
        let all = fingerprintHex + secretHex + rdiHex
        guard all.unicodeScalars.allSatisfy({ ("0"..."9").contains($0) || ("A"..."F").contains($0) || ("a"..."f").contains($0) }) else {
            throw Bvmid2FormatError("alphabet")
        }
        let upper = all.unicodeScalars.contains { ("A"..."F").contains($0) }
        let lower = all.unicodeScalars.contains { ("a"..."f").contains($0) }
        guard !(upper && lower) else { throw Bvmid2FormatError("mixed case") }
        guard let secret = Data(hex: secretHex), let rdi = Data(hex: rdiHex) else { throw Bvmid2FormatError("alphabet") }
        guard secret.contains(where: { $0 != 0 }) else { throw Bvmid2FormatError("zero secret") }
        guard let fingerprint = try? IdentityFingerprint(hex: fingerprintHex.lowercased()) else { throw Bvmid2FormatError("alphabet") }
        return try Bvmid2Payload(fingerprint: fingerprint, kQr: secret, rdi: rdi)
    }

    public static func tryParse(_ text: String) -> Bvmid2Payload? { try? parse(text) }

    /// True for text that begins with the version 2 magic (so a screen can say "unreadable" instead of "not a code").
    public static func looksLikeBvmid2(_ text: String) -> Bool {
        text.trimmingCharacters(in: .whitespacesAndNewlines).hasPrefix(magic + ".")
    }
}

public extension Bmh3Crypto {
    static let qrTagInfo = Data("BluetoothVideoMesh/BMH3/QrTag/1".utf8)

    /// BVMID2: `K_tag = HKDF-Expand(K_qr, "BluetoothVideoMesh/BMH3/QrTag/1", 32)` (never `K_qr` itself).
    static func qrTagKey(kQr: Data) throws -> Data {
        guard kQr.count == 32 else { throw Bmh3Failure("K_qr is 32 bytes") }
        return expand(kQr, qrTagInfo)
    }
}

/// The responder-side hook of a verification code (`QrCodeDisplay`). It runs at msg1, after the tag matched and before any
/// key is drawn or signature made. It atomically reserves the code for the connection's attempt (link layer first, then the
/// end-to-end layer of the SAME connection), spends the Meet screen's signing budget, enforces the per-code attempt cap and
/// the replay pins. It throws `Bmh3Failure` to close silently.
public protocol QrTagGate: AnyObject {
    func onTagMatch(purpose: Bmh3Purpose, msg1Ephemeral: Data) throws
}

/// What happened to the code on the displaying phone's screen (all on the thread that drives the connection).
public protocol QrDisplayEvents: AnyObject {
    /// A phone completed a scan of the live code (the code is consumed): "Rahul scanned your code".
    func onScanCompleted(_ peer: IdentityFingerprint)
    /// A genuinely new attempt used a consumed code: "Two phones used your code ...".
    func onReuseAlert()
    /// The code is no longer valid (expired, screen left, ID changed, attempt cap): the screen draws a new one.
    func onCodeEnded(_ reason: String)
}

/// The displaying phone's live code: at most one at a time, 300 s of monotonic time, single use.
public final class QrCodeDisplay {
    public enum Phase: Equatable { case live, reserved, consumed }

    public static let lifetime: TimeInterval = 300
    /// An attempt that neither commits nor releases within this time loses its reservation.
    public static let reservation: TimeInterval = 45
    /// Reserved attempts per code (a photographed code cannot drive unlimited real-key signatures).
    public static let maxAttempts = 3
    /// Distinct first messages pinned per code until it expires (bounded).
    public static let maxSeen = 32
    /// The Meet screen's own signing bucket (Android `Bmh3Policy.meetBudget`): 3 tokens, one more every 10 s.
    public static func meetBudget() -> Bmh3SigningBudget { Bmh3SigningBudget(capacity: maxAttempts, refill: 10) }

    private final class Code {
        let payload: Bvmid2Payload
        let id: UInt64
        let createdAt: TimeInterval
        var phase: Phase = .live
        weak var owner: QrConnectionGate?
        var reservedAt: TimeInterval = 0
        var attempts = 0
        var seenEphemerals = Set<Data>()
        let tagKey: Data
        let binding: Data
        init(payload: Bvmid2Payload, id: UInt64, createdAt: TimeInterval) throws {
            self.payload = payload; self.id = id; self.createdAt = createdAt
            tagKey = try Bmh3Crypto.qrTagKey(kQr: payload.kQr)
            binding = Bmh3Crypto.advertBinding(selected6: payload.rdi, role: RotatingDiscoveryIds.roleCallOffer, wallEpoch: nil)
        }
    }

    private let clock: () -> TimeInterval
    private let random: (Int) -> Data
    private let budget: Bmh3SigningBudget
    private let lock = NSRecursiveLock()
    private var current: Code?
    private var nextId: UInt64 = 1
    public weak var events: QrDisplayEvents?
    /// Called on a reuse alert before `events` (the visit withholds every lease not yet sent, Design QL review).
    public var onReuse: (() -> Void)?

    /// Screen-only reachability: the device is call-ready only because this screen shows a code. Its responder then
    /// accepts nothing but a connection whose tag matches the code.
    public var screenOnlyReachable: Bool {
        get { lock.lock(); defer { lock.unlock() }; return screenOnly }
        set { lock.lock(); screenOnly = newValue; lock.unlock() }
    }
    private var screenOnly = false

    public init(clock: @escaping () -> TimeInterval = { ProcessInfo.processInfo.systemUptime },
                random: @escaping (Int) -> Data = { randomBytes($0) }, budget: Bmh3SigningBudget = QrCodeDisplay.meetBudget()) {
        self.clock = clock; self.random = random; self.budget = budget
    }

    /// A new live code for `fingerprint` on the device's current role-0 `rdi`; any earlier code ends.
    @discardableResult
    public func show(fingerprint: IdentityFingerprint, rdi: Data) throws -> Bvmid2Payload {
        lock.lock(); defer { lock.unlock() }
        end("replaced")
        var secret = random(32)
        while !secret.contains(where: { $0 != 0 }) { secret = random(32) }
        let payload = try Bvmid2Payload(fingerprint: fingerprint, kQr: secret, rdi: rdi)
        current = try Code(payload: payload, id: nextId, createdAt: clock())
        nextId += 1
        return payload
    }

    /// The screen was left (app in the background, page closed, code hidden).
    public func leave() { lock.lock(); end("left"); lock.unlock() }

    /// The device's role-0 ID changed: the code is dead and the screen draws a new one.
    public func onRdiChanged(_ rdi: Data?) {
        lock.lock(); defer { lock.unlock() }
        guard let code = current else { return }
        if rdi != code.payload.rdi { end("id_changed") }
    }

    /// The live (or reserved) code, or nil; an expired code is ended on the way.
    public func livePayload() -> Bvmid2Payload? {
        lock.lock(); defer { lock.unlock() }
        expireIfDue()
        guard let code = current, code.phase != .consumed else { return nil }
        return code.payload
    }

    /// True while a code can still be matched (live, reserved, or consumed and pinned for the reuse alert).
    public func hasCode() -> Bool { lock.lock(); defer { lock.unlock() }; expireIfDue(); return current != nil }

    public func phase() -> Phase? { lock.lock(); defer { lock.unlock() }; expireIfDue(); return current?.phase }

    /// One incoming connection's view of the displayed code (its link and end-to-end handshakes share it).
    public func newGate() -> QrConnectionGate { QrConnectionGate(display: self) }

    /// The tag check the responder of `gate`'s connection adds, or nil without a code.
    public func tagCheck(_ gate: QrConnectionGate) -> Bmh3ContactTag? {
        lock.lock(); defer { lock.unlock() }
        expireIfDue()
        guard let code = current else { return nil }
        gate.bind(codeId: code.id)
        return try? Bmh3ContactTag(key: code.tagKey, binding: code.binding, qrGate: gate)
    }

    func reserve(_ gate: QrConnectionGate, codeId: UInt64, purpose: Bmh3Purpose, ephemeral: Data) throws {
        lock.lock(); defer { lock.unlock() }
        expireIfDue()
        guard let code = current, code.id == codeId else { throw Bmh3Failure("qr expired") }
        // A repeated msg1 (a replay of a sniffed first message) is closed silently and never raises the reuse alert.
        guard code.seenEphemerals.insert(Bmh3Crypto.sha256(ephemeral)).inserted else { throw Bmh3Failure("replay") }
        if code.seenEphemerals.count > Self.maxSeen { throw Bmh3Failure("qr attempts") }
        switch code.phase {
        case .consumed:
            // A genuinely new attempt on a consumed code: someone else holds it. Cancel the pending scan, alert.
            onReuse?()
            events?.onReuseAlert()
            throw Bmh3Failure("qr consumed")
        case .reserved:
            if code.owner === gate, purpose == .endToEnd, gate.linkReserved { return }
            if clock() - code.reservedAt < Self.reservation { throw Bmh3Failure("qr busy") }
            // The earlier reservation timed out: fall through as a new attempt.
            code.owner = nil
            code.phase = .live
        case .live:
            break
        }
        guard purpose == .link else { throw Bmh3Failure("qr end-to-end without link") }
        if code.attempts >= Self.maxAttempts {
            end("attempt_cap")
            throw Bmh3Failure("qr attempts")
        }
        // The Meet screen's signing budget applies to every reserved attempt (it throws "budget" when empty).
        try budget.spend()
        code.attempts += 1
        code.phase = .reserved
        code.owner = gate
        code.reservedAt = clock()
        gate.linkReserved = true
    }

    /// The attempt of `gate` completed its end-to-end handshake with `peer`: commit (CONSUMED).
    func commit(_ gate: QrConnectionGate, codeId: UInt64, peer: IdentityFingerprint) -> Bool {
        lock.lock(); defer { lock.unlock() }
        guard let code = current, code.id == codeId, code.phase == .reserved, code.owner === gate else { return false }
        code.phase = .consumed
        code.owner = nil
        events?.onScanCompleted(peer)
        return true
    }

    /// The attempt of `gate` failed or its connection ended before commit: the reservation is released (attempt counted).
    func release(_ gate: QrConnectionGate, codeId: UInt64) {
        lock.lock(); defer { lock.unlock() }
        guard let code = current, code.id == codeId, code.phase == .reserved, code.owner === gate else { return }
        code.phase = .live
        code.owner = nil
    }

    private func expireIfDue() {
        guard let code = current else { return }
        if clock() - code.createdAt >= Self.lifetime { end("expired") }
    }

    private func end(_ reason: String) {
        guard current != nil else { return }
        current = nil
        events?.onCodeEnded(reason)
    }
}

/// One incoming connection's view of the displayed code (the link and the end-to-end handshake share it).
public final class QrConnectionGate: QrTagGate {
    private let display: QrCodeDisplay
    /// The link handshake of this connection reserved the code.
    public internal(set) var linkReserved = false
    private var boundCodeId: UInt64 = 0
    private var committed = false

    init(display: QrCodeDisplay) { self.display = display }

    func bind(codeId: UInt64) { boundCodeId = codeId }

    public func onTagMatch(purpose: Bmh3Purpose, msg1Ephemeral: Data) throws {
        try display.reserve(self, codeId: boundCodeId, purpose: purpose, ephemeral: msg1Ephemeral)
    }

    /// The end-to-end handshake finished: the verification is committed and the code consumed. True only once.
    public func complete(_ peer: IdentityFingerprint) -> Bool {
        guard !committed else { return false }
        committed = display.commit(self, codeId: boundCodeId, peer: peer)
        return committed
    }

    /// The connection ended or failed before `complete`.
    public func fail() { if !committed { display.release(self, codeId: boundCodeId) } }
}

/// The exact scope of a session opened with a verification code. It exists only to verify:
///
/// - link records: the end-to-end handshake, end-to-end content, link heartbeats and the link opening `BDO1`; everything
///   else closes it (the call endpoint already refuses every other hop record);
/// - content: `LABELS` (the scanner's optional name) and, when both endpoint hellos carry bit 3, one `BDX1`
///   `RECOGNITION_OFFER` and one `PRESENCE_LEASE` per direction (Design QL); `INVITE` and every call signal, other discovery
///   records (`OPENING`, `IDENTITY_REVEAL`, a second OFFER or LEASE), streams, media, key frames and group keys close it;
/// - completion: the successful end-to-end handshake IS the verification event; no extra control message exists;
/// - no ordinary contact side effect: no ring, recent-call entry, label persistence or message exchange;
/// - at most `maxSession` after the handshake, then it closes. A violation closes it and is counted.
public final class QrSessionScope {
    public static let maxSession: TimeInterval = 60
    /// After the verification event the session lingers briefly (the scanner's name label may still be in flight).
    public static let closeGrace: TimeInterval = 2
    /// How long a session waits for the scanner's confirmation (scanner) or its OFFER (displayer) before it ends without a lease.
    public static let confirmWait: TimeInterval = 20
    public static let linkRecords: Set<SecureRecordType> = [.endToEndHandshake, .endToEndContent, .linkHeartbeat, .discoveryOpening]
    public static let leaseKinds: Set<UInt8> = [DiscoveryExchange.kindRecognitionOffer, DiscoveryExchange.kindPresenceLease]

    public let startedAt: TimeInterval
    public private(set) var violations = 0
    private var discoveryKindsSeen = Set<UInt8>()

    public init(startedAt: TimeInterval) { self.startedAt = startedAt }

    public static func allowsLinkRecord(_ type: SecureRecordType) -> Bool { linkRecords.contains(type) }
    public static func allowsContent(_ type: EndToEndContentType) -> Bool { type == .labels }

    /// True when `type` is refused; counts the violation.
    public func refuseLinkRecord(_ type: SecureRecordType) -> Bool {
        let refused = !Self.allowsLinkRecord(type)
        if refused { violations += 1 }
        return refused
    }

    public func refuseContent(_ type: EndToEndContentType) -> Bool {
        let refused = !Self.allowsContent(type)
        if refused { violations += 1 }
        return refused
    }

    /// Design QL: a `BDX1` record is allowed only as the first OFFER or the first LEASE from the peer, and only when both
    /// endpoint hellos carried bit 3 (`negotiated`). True when refused; counts the violation.
    public func refuseDiscovery(_ payload: Data, negotiated: Bool) -> Bool {
        let magic = DiscoveryExchange.magic
        let bytes = payload.rebased
        let kind: UInt8? = bytes.count > magic.count && bytes.prefix(magic.count) == magic ? bytes[magic.count] : nil
        let allowed = negotiated && kind.map { Self.leaseKinds.contains($0) && discoveryKindsSeen.insert($0).inserted } == true
        if !allowed { violations += 1 }
        return !allowed
    }

    public func expired(now: TimeInterval) -> Bool { now - startedAt >= Self.maxSession }
}

/// The scanner side: how a parsed code becomes handshake options and which answers are refused.
public enum QrScanPolicy {
    /// Search window for the code's advert; every advertising address that carries it is tried within it.
    public static let search: TimeInterval = 10

    /// The tag toward the displayer: `K_tag` of the code bound to its RDI, and the full node ID the answerer must have.
    public static func tag(_ payload: Bvmid2Payload) throws -> Bmh3ContactTag {
        try Bmh3ContactTag(key: try Bmh3Crypto.qrTagKey(kQr: payload.kQr),
                           binding: Bmh3Crypto.advertBinding(selected6: payload.rdi, role: RotatingDiscoveryIds.roleCallOffer, wallEpoch: nil),
                           expectedPeer: payload.fingerprint.nodeId)
    }

    /// The checks before this device presents its real key: a `PSEUDONYM` answer is refused (a real answer was expected),
    /// and the handshake key's fingerprint must equal the code's.
    public static func checkResponder(_ payload: Bvmid2Payload, _ peer: Bmh3Peer) throws {
        if peer.pseudonymous { throw Bmh3Failure("pseudonym answer to a verification code") }
        guard peer.fingerprint == payload.fingerprint else { throw Bmh3Failure("not the code's key") }
    }

    /// Only call offers carrying the code's RDI as a rotating ID, at route cost 0, are tried.
    public static func matches(_ payload: Bvmid2Payload, _ offer: DiscoveryAnnouncement) -> Bool {
        offer.rotating && offer.routeCost == 0 && offer.isPrivateCallOffer && offer.nodeIdPrefix == payload.rdi
    }

    /// The addresses to try, in the order they were seen, each once.
    public static func addressesToTry<Address: Hashable>(_ payload: Bvmid2Payload, _ seen: [(Address, DiscoveryAnnouncement)]) -> [Address] {
        var out: [Address] = []
        for (address, offer) in seen where matches(payload, offer) && !out.contains(address) { out.append(address) }
        return out
    }
}

/// A code matched at one layer only is neither a verification session nor a call.
public enum QrLayerBinding {
    public static func consistent(linkMatched: Bool, endpointMatched: Bool) -> Bool { linkMatched == endpointMatched }
}

/// While the device is call-ready only because the Add contact screen shows a code, it accepts nothing but the code,
/// whatever handshake the peer spoke.
public enum MeetScreenGate {
    public static func refuses(screenOnlyReachable: Bool, linkMatchedCode: Bool) -> Bool { screenOnlyReachable && !linkMatchedCode }
}

/// The Add contact screen model. Each scan is its own tagged session, so each phone learns of the other's scan from a real
/// authenticated event. "Scanned each other" needs both events for the same fingerprint during one visit; the shield
/// ("I scanned them") is set only after the user confirmed whose screen was scanned.
public final class MeetSession {
    public enum Outcome: Equatable { case none, youScanned, theyScannedYou, scannedEachOther }
    /// Design QL revision 2's plain result: (a) callable from Contacts, (b) this device declined, (c) not finished (no
    /// reason guessed: a peer that declined, a late answer, an older build and a lost link look the same), (d) one scan.
    public enum QlResult: Equatable { case recognised, declined, notFinished, oneScan }
    /// Call now shows for this long after a lease was stored in this visit (Android `MeetSession.CALL_NOW_MS`).
    public static let callNowSeconds: TimeInterval = 60

    private var scannedByMe = Set<IdentityFingerprint>()
    private var pendingConfirm: [IdentityFingerprint: String] = [:]
    private var scannedMe = Set<IdentityFingerprint>()
    private var recognised = Set<IdentityFingerprint>()
    /// The people this device's user unchecked "Let <name>'s phone recognise yours nearby" for, in this visit.
    private var declined = Set<IdentityFingerprint>()
    /// When a lease from each person was stored in this visit (uptime seconds), for Call now.
    private var storedAt: [IdentityFingerprint: TimeInterval] = [:]
    public private(set) var reuseAlert = false

    public init() {}

    /// A scan reached `peer`: the screen asks "Is this <name>'s screen?" before anything is marked.
    public func scanReached(_ peer: IdentityFingerprint, name: String) { pendingConfirm[peer] = name }

    /// The name the confirmation asks about, or nil when nothing is pending for `peer`.
    public func pendingName(_ peer: IdentityFingerprint) -> String? { pendingConfirm[peer] }

    /// The user answered. True: the shield may be set. False: nothing is marked.
    @discardableResult
    public func confirmScreen(_ peer: IdentityFingerprint, yes: Bool) -> Bool {
        guard pendingConfirm.removeValue(forKey: peer) != nil else { return false }
        if yes { scannedByMe.insert(peer) }
        return yes
    }

    /// An inbound verification session on the displayed code completed with `peer`'s real key.
    public func scannedByPeer(_ peer: IdentityFingerprint) { scannedMe.insert(peer) }

    /// Design QL: a verification session in this visit stored `peer`'s presence lease (`at`: uptime seconds).
    public func leaseStored(_ peer: IdentityFingerprint, at: TimeInterval = 0) { recognised.insert(peer); storedAt[peer] = at }

    public func recognises(_ peer: IdentityFingerprint) -> Bool { recognised.contains(peer) }

    /// Design QL revision 2: this device's user unchecked recognition for `peer` at the scan confirmation.
    public func declinedRecognition(_ peer: IdentityFingerprint) { declined.insert(peer) }

    /// Revision 2's result for `peer`; nil before any scan.
    public func qlResult(_ peer: IdentityFingerprint) -> QlResult? {
        switch outcome(peer) {
        case .none: return nil
        case .youScanned, .theyScannedYou: return .oneScan
        case .scannedEachOther:
            if recognised.contains(peer) { return .recognised }
            return declined.contains(peer) ? .declined : .notFinished
        }
    }

    /// Call now: only with result (a), for `callNowSeconds` after the lease was stored in this visit.
    public func callNowVisible(_ peer: IdentityFingerprint, now: TimeInterval) -> Bool {
        guard qlResult(peer) == .recognised, let at = storedAt[peer] else { return false }
        return now >= at && now - at < Self.callNowSeconds
    }

    /// The one person Call now is for right now, if any (the latest stored lease still inside its window).
    public func callNowPeer(now: TimeInterval) -> IdentityFingerprint? {
        storedAt.filter { callNowVisible($0.key, now: now) }.max { $0.value < $1.value }?.key
    }

    public func onReuseAlert() { reuseAlert = true; pendingConfirm.removeAll() }

    public func outcome(_ peer: IdentityFingerprint) -> Outcome {
        switch (scannedByMe.contains(peer), scannedMe.contains(peer)) {
        case (true, true): return .scannedEachOther
        case (true, false): return .youScanned
        case (false, true): return .theyScannedYou
        default: return .none
        }
    }

    /// Android's Add contact status line for `peer` (shown with `name`), or nil before any scan.
    public func message(_ peer: IdentityFingerprint, name: String) -> String? {
        switch outcome(peer) {
        case .none: return nil
        case .youScanned: return "You scanned \(name). \(name) has not scanned your code yet."
        case .theyScannedYou: return "\(name) scanned your code. Now scan their code."
        case .scannedEachOther:
            return recognised.contains(peer)
                ? "You and \(name) scanned each other. Your phones now recognise each other, so you can call from Contacts."
                : "You and \(name) scanned each other. Scan each other's codes again, or call once from Nearby, so your phones recognise each other."
        }
    }

    /// Design QL revision 2's status line for `peer` (Android `ql_result_*`), or nil before any scan.
    public func qlMessage(_ peer: IdentityFingerprint, name: String) -> String? {
        switch qlResult(peer) {
        case nil: return nil
        case .recognised?: return "\(name) added. You can call them from Contacts when they're nearby."
        case .declined?: return "\(name) added. Nearby recognition is off. To call, find each other in Nearby."
        case .notFinished?: return "\(name) added, but your phones didn't finish recognising each other. Scan each other's codes again, or call once from Nearby."
        case .oneScan?: return (message(peer, name: name) ?? "") + " Show them your code so you can call each other from Contacts."
        }
    }
}

/// Design QL (review) and its revision 2 consent: whom this device's own user confirmed ("Is this X's screen?" answered
/// yes, shield stored) during the current visit of the Add contact screen, with the answer to "Let <name>'s phone recognise
/// yours nearby", and whether a reuse alert fired in it. This is the lease gate of a verification session on both roles: a
/// side sends an OFFER or a LEASE only to a person its user confirmed AND let recognise this device in this visit, never
/// after a reuse alert. So a race winner that happens to be an older contact gets nothing, and no lease leaves without
/// this device's consent. The vault's "Can see when I'm nearby" switch and the eligibility checks still apply on top.
public final class MeetVisit {
    /// Confirmed people and their recognition answer (true: may recognise this device).
    private var confirmed: [IdentityFingerprint: Bool] = [:]
    private var reuse = false
    /// The screen left (or the app went to the background): nothing leases until the next visit begins.
    private var closed = false
    private let lock = NSLock()

    public init() {}

    public func begin() { lock.lock(); confirmed.removeAll(); reuse = false; closed = false; lock.unlock() }

    /// The visit ended: every answer is forgotten and any verification session still open (a displayer's, up to 60 s)
    /// sends nothing more, so the per-visit rule is the CURRENT visit only.
    public func end() { lock.lock(); confirmed.removeAll(); closed = true; lock.unlock() }

    /// The user confirmed `peer`'s screen (the shield is stored) and answered the recognition choice: `recognise` is true
    /// only when the answer was yes AND it was stored. A later answer for the same person replaces the earlier one.
    public func confirm(_ peer: IdentityFingerprint, recognise: Bool) { lock.lock(); confirmed[peer] = recognise; lock.unlock() }
    public func onReuseAlert() { lock.lock(); reuse = true; lock.unlock() }

    /// Either side of a verification session may offer and lease to `peer` now.
    public func mayLease(_ peer: IdentityFingerprint) -> Bool { lock.lock(); defer { lock.unlock() }; return !closed && !reuse && confirmed[peer] == true }

    /// Any lease of a verification session is withheld after a reuse alert in this visit.
    public func reuseAlerted() -> Bool { lock.lock(); defer { lock.unlock() }; return reuse }
}

/// Design QL revision 2 (Android `QlConsent`): the recognition choice at the scan confirmation, "Let <name>'s phone
/// recognise yours nearby" (on by default, Q-QL2a). The answer is written to that person's "Can see when I'm nearby" after
/// the shield is stored and before the scanning session may offer.
public enum QlConsent {
    /// Whether the session may go on to the lease exchange: only when the answer is yes and was stored (`write` returns
    /// whether the switch now reads as written). A refusal, or a write that fails, withholds the lease (fails closed).
    /// Without a persistent presence store there is nothing to record: a yes goes on (eligibility then refuses anyway,
    /// since leases need a persistent store), a no withholds.
    public static func applyAnswer(recognise: Bool, vaultUsable: Bool, write: (Bool) -> Bool) -> Bool {
        guard vaultUsable else { return recognise }
        let stored = write(recognise)
        return stored && recognise
    }
}

/// How a scan is recorded. A BVMID2 scan the user confirmed is always the scanned method (shield). A static BVMID1 code has
/// no freshness, so it records only "Checked by code" unless the DEBUG compat arm `bvmid1Compat` is on (Android
/// `bvmid1_compat`, off, no Settings switch).
public enum Bvmid1Policy {
    public static let scanned = "qr"
    public static let checkedByCode = "safety-code"

    public static func methodForBvmid1Scan(compat: Bool) -> String { compat ? scanned : checkedByCode }
}

/// Presence-lease eligibility for a contact that was only checked by code: it neither receives nor offers NEW leases until
/// both phones scanned each other; one that already holds a lease keeps it until the next generation change.
public enum CodeOnlyLeaseRule {
    public static func blocked(method: String?, scannedBothWays: Bool, holdsLease: Bool) -> Bool {
        method == Bvmid1Policy.checkedByCode && !scannedBothWays && !holdsLease
    }
}
