import Foundation
import CryptoKit

// Design SI Phase 1, viewer side (PROTOCOL "Stream identities", A.1 "Join keys"; switch `stream_join_keys`,
// Experimental, off by default: the app reads it). A watch session presents a throwaway join key `J` instead of this
// phone's identity, and keys its own rotating discovery IDs with a throwaway salt key `Ks`:
// - the link and end-to-end BMH2 hellos of the stream hop are signed by `J`;
// - a version 5 (compact v2) viewer request carries `entry(Ks, nodeId(J), e, 2).rdi`, and its BDO1 role-2 entries;
// - a version 2 viewer request carries `nodeId(J)[0:6]` and capability summary 0;
// - a forwarding viewer uses the same `J` and `Ks` toward its children (role-1 entries).
// Rejoin, recovery and epoch boundaries keep the keys; leaving, the source's end, the 60 s lost-stream give-up,
// another stream, the process end and the wipe drop them. Nothing here is persisted or logged in a release build.
// Every current source (Android 0.4.4 and current, Windows, Apple) accepts a fresh key over BMH2: a source checks only
// the request's prefix or opening against the authenticated link peer, never which key it is.

/// A watch session's join key `J`: a fresh software P-256 signing key (never the Secure Enclave or Keychain identity).
/// It signs only while its session is open; after `StreamJoinKeys.close()` it refuses, so a link or engine that
/// outlived the session cannot present `J` again, and the private key's only reference is dropped. The public key and
/// node ID stay readable: they were public on the link anyway.
public final class StreamJoinIdentity: SigningIdentity {
    public let publicKeyEncoded: Data
    private var key: SoftwareSigningIdentity?

    init(key: SoftwareSigningIdentity) {
        self.key = key
        publicKeyEncoded = key.publicKeyEncoded
    }

    /// True once its session closed (the private key is gone).
    public var isClosed: Bool { key == nil }

    public func sign(_ message: Data) throws -> Data {
        guard let key else { throw ProtocolError.state("The watch session's join key was closed") }
        return try key.sign(message)
    }

    /// Drops the private key. CryptoKit keeps no other copy; its storage is released (best effort: Swift gives no
    /// guaranteed erasure of a CryptoKit private key, as JCA gives none on Android).
    fileprivate func drop() { key = nil }
}

/// The keys of one watch session: `J` (`identity`) and the salt key `Ks` (32 random bytes). Not thread-safe: the app
/// owns it on its main queue.
public final class StreamJoinKeys {
    public static let saltKeyBytes = 32

    /// Which side of a stream hop presents `J` (the DEBUG harness line).
    public enum Role: String {
        /// A child of a source or forwarder (the viewer request, the hop's responder).
        case viewer
        /// The same `J` toward this phone's own children (the forwarder offer, the hop's initiator).
        case forwarder
    }

    /// The process-local number of this watch session (1, 2, ...): the DEBUG harness tells sessions apart by it.
    public let session: Int
    /// `J`. Every stream hello of the session is signed by it.
    public let identity: StreamJoinIdentity
    /// `nodeId(J)`.
    public let nodeId: NodeId
    /// `Ks`, in memory this object owns (never a `Data` that could be copied): zeroed by `close()`, freed at deinit.
    private let saltKey: UnsafeMutableRawBufferPointer
    public private(set) var isClosed = false

    /// A new watch session: `J` and `Ks` from the CryptoKit CSPRNG.
    public convenience init(session: Int) {
        let ks = SymmetricKey(size: .bits256)
        self.init(session: session, key: SoftwareSigningIdentity(), saltKeySource: ks)
    }

    /// Fixed inputs: protocol vectors and tests only (`joinScalar` is J's raw P-256 scalar; internal, so the app cannot
    /// build a deterministic J). The caller keeps its own copies of the inputs; this object zeroes only the bytes it owns.
    convenience init(session: Int, joinScalar: Data, saltKey: Data) throws {
        guard saltKey.count == Self.saltKeyBytes else { throw ProtocolError.malformed("A join salt key is 32 bytes") }
        self.init(session: session, key: try SoftwareSigningIdentity(rawScalar: joinScalar), saltKeySource: saltKey)
    }

    private init<Bytes: ContiguousBytes>(session: Int, key: SoftwareSigningIdentity, saltKeySource: Bytes) {
        self.session = session
        identity = StreamJoinIdentity(key: key)
        nodeId = key.nodeId
        let buffer = UnsafeMutableRawBufferPointer.allocate(byteCount: Self.saltKeyBytes, alignment: 1)
        saltKeySource.withUnsafeBytes { source in
            precondition(source.count == Self.saltKeyBytes)
            buffer.copyMemory(from: source)
        }
        saltKey = buffer
    }

    deinit {
        close()
        saltKey.deallocate()
    }

    /// The version 2 viewer request's six ID bytes: `nodeId(J)[0:6]`.
    public var versionTwoPrefix: Data { nodeId.prefix }
    /// The 12-hex label of `nodeId(J)` (DEBUG lines only).
    public var prefixLabel: String { nodeId.shortLabel }

    /// `entry(Ks, nodeId(J), e, role)`, the existing `RotatingDiscoveryIds.entry` with `Ks` as the salt key. Only the
    /// stream roles: a join key never makes a call offer (role 0). Throws once the session closed.
    public func entry(epoch: Int64, role: UInt8) throws -> OpeningEntry {
        guard !isClosed else { throw ProtocolError.state("The watch session's join keys were closed") }
        guard role == RotatingDiscoveryIds.roleViewerRequest || role == RotatingDiscoveryIds.roleStreamOffer else {
            throw ProtocolError.malformed("A join key opens only stream roles 1 and 2")
        }
        let message = RotatingDiscoveryIds.saltDomain + RotatingDiscoveryIds.u32(epoch) + Data([role])
        let salt = Data(HMAC<SHA256>.authenticationCode(for: message, using: SymmetricKey(data: UnsafeRawBufferPointer(saltKey))))
        return OpeningEntry(rdi: RotatingDiscoveryIds.rdi(nodeId: nodeId.bytes, epoch: epoch, role: role, salt: salt),
                            epoch: epoch, role: role, salt: salt)
    }

    /// The waiting viewer's role-2 entry of `epoch` (its compact v2 request and its BDO1).
    public func viewerRequestEntry(epoch: Int64) throws -> OpeningEntry {
        try entry(epoch: epoch, role: RotatingDiscoveryIds.roleViewerRequest)
    }

    /// The forwarder's role-1 entry of `epoch`, for a rotating forwarder offer and its child-facing BDO1. Not used yet:
    /// this app does not build rotating forwarder offers (a rotating stream is not forwarded), and a version 2
    /// forwarder offer carries `versionTwoPrefix`.
    public func forwarderOfferEntry(epoch: Int64) throws -> OpeningEntry {
        try entry(epoch: epoch, role: RotatingDiscoveryIds.roleStreamOffer)
    }

    /// The role-2 entry function `RotatingViewerRequest.decide` asks (it gives each epoch its own entry), or nil once the
    /// session closed: nothing is advertised then. `epoch` is the epoch being decided; its entry is computed now.
    public func viewerRequestEntries(epoch: Int64) -> ((Int64) -> OpeningEntry)? {
        guard let current = try? viewerRequestEntry(epoch: epoch) else { return nil }
        return { [weak self] e in
            guard e != epoch, let other = try? self?.viewerRequestEntry(epoch: e) else { return current }
            return other
        }
    }

    /// The end of the watch session: `Ks` is overwritten with zeros and `J` stops signing and drops its private key.
    /// Idempotent. Entries already built (their salts went to the parent in BDO1, so they are not secrets) are dropped
    /// by their holders (`RotatingViewerRequest.startJoin`, the engines).
    public func close() {
        guard !isClosed else { return }
        isClosed = true
        if let base = saltKey.baseAddress { _ = memset_s(base, saltKey.count, 0, saltKey.count) }
        identity.drop()
    }

    /// A `stream_key` line (PROTOCOL A.9).
    public enum KeyEvent: String { case open, close }
    /// Why a join key is presented (opened, or presented again by a recovery rejoin).
    public enum OpenReason: String { case watch, rejoin, recovery }

    /// The values of `BENCHMARK stream_key: event=<open|close> | key=join | reason=<...> | role=<viewer|forwarder> |
    /// session=<n> | prefix=<12 hex>` (PROTOCOL A.9). Only a DEBUG build adds the session number and J's prefix; a
    /// release build's line carries no identifier.
    public func logLine(_ event: KeyEvent, reason: String, role: Role, debugBuild: Bool) -> KeyValuePairs<String, String> {
        guard debugBuild else { return ["event": event.rawValue, "key": "join", "reason": reason, "role": role.rawValue] }
        return ["event": event.rawValue, "key": "join", "reason": reason, "role": role.rawValue, "session": "\(session)", "prefix": prefixLabel]
    }

    /// Tests only: the bytes of `Ks` as this object holds them now.
    func saltKeySnapshot() -> Data { Data(UnsafeRawBufferPointer(saltKey)) }
}

/// The watch sessions of this phone: at most one at a time (PROTOCOL A.1 "A watch session"). A session begins when the
/// user selects a stream, or an automatic join retry targets a stream with no current session; rejoin, recovery and
/// epoch boundaries keep using `current`; any end closes it. Main queue.
public final class StreamJoinSessions {
    public enum EndReason: String {
        /// The user left, or the join gave up without the stream (a failed join).
        case left
        /// The source sent its end.
        case ended
        /// The 60 s lost-stream search gave up.
        case lost
        /// Another stream was selected while this one was open.
        case switched
        /// Something else stopped watching (critical heat, a block).
        case stopped
        /// The wipe.
        case wipe
    }

    public private(set) var current: StreamJoinKeys?
    private var opened = 0
    private let makeKeys: (Int) -> StreamJoinKeys
    /// Every close of a session, with its reason (the app's `stream_key` close line).
    private let onClose: ((StreamJoinKeys, EndReason) -> Void)?

    public init(makeKeys: @escaping (Int) -> StreamJoinKeys = { StreamJoinKeys(session: $0) },
                onClose: ((StreamJoinKeys, EndReason) -> Void)? = nil) {
        self.makeKeys = makeKeys; self.onClose = onClose
    }

    /// Why a watch ended, from its state when it finished: the source's end, the lost-stream give-up (the watch was
    /// still recovering), the user's Leave (or a stop the app made for the user, such as critical heat), else another
    /// stop (a join that gave up, a block).
    public static func endReason(sourceEnded: Bool, recovering: Bool, stoppedByUser: Bool) -> EndReason {
        if sourceEnded { return .ended }
        if recovering { return .lost }
        return stoppedByUser ? .left : .stopped
    }

    /// A new watch session with fresh keys; an open earlier session ends first (`switched`).
    public func begin() -> StreamJoinKeys {
        end(.switched)
        opened += 1
        let keys = makeKeys(opened)
        current = keys
        return keys
    }

    /// The open session's keys for a rejoin, a recovery or an epoch boundary of the same watch: `keys` itself while it
    /// is the open session, else nil (a closed session never resumes, and a rejoin never gets a fresh key).
    public func resume(_ keys: StreamJoinKeys) -> StreamJoinKeys? {
        guard let current, current === keys, !current.isClosed else { return nil }
        return current
    }

    /// Ends the open session (no-op without one) and returns the closed keys.
    @discardableResult
    public func end(_ reason: EndReason) -> StreamJoinKeys? {
        guard let keys = current else { return nil }
        current = nil
        keys.close()
        onClose?(keys, reason)
        return keys
    }

    /// Closes `keys` whether or not they are the open session (a watch that finished after another began); the open
    /// session's keys end through `end`.
    public func close(_ keys: StreamJoinKeys, reason: EndReason) {
        if current === keys { end(reason); return }
        guard !keys.isClosed else { return }
        keys.close()
        onClose?(keys, reason)
    }
}

/// S3: a watch's join key lives at most 60 s after the stream was first lost (PROTOCOL A.1: the lost-stream search gives
/// up after 60 s and the session ends). A recovered stream starts the count again at its next loss. Pure; the app runs
/// the timer.
public struct StreamJoinLostBound: Equatable {
    public static let seconds: TimeInterval = 60
    public private(set) var firstLossAt: TimeInterval?
    public init() {}

    /// The stream was lost (or a recovery rejoin failed): the count starts at the first loss only.
    public mutating func onLost(now: TimeInterval) { if firstLossAt == nil { firstLossAt = now } }
    /// The stream's header arrived again.
    public mutating func onRecovered() { firstLossAt = nil }
    /// Seconds left before the watch must end, nil while the stream is not lost.
    public func remaining(now: TimeInterval) -> TimeInterval? { firstLossAt.map { max(0, Self.seconds - (now - $0)) } }
    public func expired(now: TimeInterval) -> Bool { remaining(now: now) == 0 }
}

extension DiscoveryAnnouncement {
    /// S1/S2: the six ID bytes may be a stream participant's throwaway (a viewer request, or a relayed stream offer
    /// whose forwarder presents a join key), so logs never print them or a handle derived from them.
    public var idMayBeJoinKey: Bool {
        (flags & Self.flagAcceptingConnections != 0 && streamToken != 0) || (isStreamOffer && routeCost > 0)
    }
    /// Review finding 1: whether a log may print the six ID bytes. Never when they may be a join key; in a release
    /// build never for any stream advert either (a scanner cannot tell a source's fixed prefix from a forwarder's
    /// throwaway one, or a source's broadcast key later), so only call adverts keep their ID in release logs.
    public func idLoggable(debugBuild: Bool) -> Bool {
        guard !idMayBeJoinKey else { return false }
        return debugBuild || !isStreamOffer
    }
    /// The ID as a log may show it, else "hidden".
    public func loggablePrefix(debugBuild: Bool) -> String { idLoggable(debugBuild: debugBuild) ? prefixHex : "hidden" }
    /// The handle derived from the ID as a log may show it, else "hidden" (the handle is reversible to the prefix).
    public func loggableHandle(debugBuild: Bool) -> String {
        idLoggable(debugBuild: debugBuild) ? IdentityHandle.handle(prefix: nodeIdPrefix) ?? "?" : "hidden"
    }
}

/// The viewer requests of a watch session with join keys (the app advertises exactly these while it waits).
public enum StreamJoinRequest {
    /// A version 2 offer's request (also the request of a DEBUG run with rotating IDs off): `nodeId(J)`'s prefix and
    /// capability summary 0 (no source reads the summary; the per-model decode mask leaves the air; the link hello still
    /// carries it). Every other field as today's request: the accepting flag, the transport flag, the offer's route
    /// token, route cost and bitrate.
    public static func versionTwo(keys: StreamJoinKeys, offer: DiscoveryAnnouncement, transport: MeshTransport) throws -> DiscoveryAnnouncement {
        guard !keys.isClosed else { throw ProtocolError.state("The watch session's join keys were closed") }
        guard offer.isStreamOffer else { throw ProtocolError.malformed("A viewer request answers a stream offer") }
        return DiscoveryAnnouncement(nodeIdPrefix: keys.versionTwoPrefix,
                                     flags: DiscoveryAnnouncement.flagAcceptingConnections | (transport == .gatt ? DiscoveryAnnouncement.flagGattTransport : 0),
                                     capabilitySummary: 0, streamToken: offer.streamToken, routeCost: offer.routeCost,
                                     streamBitrateKbps: offer.streamBitrateKbps)
    }

    /// A rotating (version 5) offer's request for `epoch`: the compact v2 request with `J`'s role-2 RDI.
    public static func rotating(keys: StreamJoinKeys, epoch: Int64, offer: DiscoveryAnnouncement, transport: MeshTransport) throws -> DiscoveryAnnouncement {
        try RotatingViewerRequest.announcement(entry: keys.viewerRequestEntry(epoch: epoch), offer: offer, transport: transport)
    }
}
