import Foundation
import CryptoKit

/// AW1 (Experimental): the Wi-Fi Direct guest of one direct call (Design WF revision 3; Android WifiHopAgent,
/// WifiAttempt and DirectBearerDriver as guest). Single-threaded and sans-I/O: CallEngine feeds it hop records, socket
/// bytes and ticks; the app's WifiDirectGuest performs its requests. Apple is never the host.
public final class WifiCallAgent {
    public struct Config: Equatable {
        /// `wifiCarrier` and `wifiDirect` on and the platform can join now (iPhone: a Hotspot-entitled build; Mac:
        /// Location allowed and Wi-Fi powered on).
        public var directClient: Bool
        public init(directClient: Bool) { self.directClient = directClient }
    }

    public enum Request: Equatable {
        case join(ssid: String, passphrase: String, hostFreqMhz: Int, ticket: Data)
        case connect(host: UInt32, port: UInt16, local: IPv4Interface, ticket: Data)
        case closeSocket(ticket: Data)
        case leave(ticket: Data)
        case keyFrame
    }

    public static let attemptSeconds: TimeInterval = 25
    public static let credsSeconds: TimeInterval = 8
    public static let connectSeconds: TimeInterval = 12
    public static let frameSeconds: TimeInterval = 2
    public static let bindSeconds: TimeInterval = 5
    public static let heartbeatSeconds: TimeInterval = 0.5
    public static let silenceSeconds: TimeInterval = 2.5
    /// Design WF liveness: a write stalled this long kills the carrier even while the peer's records arrive.
    public static let writeStallSeconds: TimeInterval = 2.5

    public let linkInitiator: Bool
    public var config: Config
    public var onRequest: ((Request) -> Void)?
    public var log: ((String, [String: String]) -> Void)?
    /// iPhone: the app is in the foreground (Android: the screen is on); otherwise a HOST gets DECLINE 1.
    public var foreground: () -> Bool = { true }
    /// Test seams; production uses the real WifiKeys and Bwu1Guest.
    public var directNames: (Data, Data) throws -> (ssid: String, passphrase: String) = { uw, ticket in
        (try WifiKeys.directSsid(uw: uw, ticket: ticket), try WifiKeys.directPsk(uw: uw, ticket: ticket))
    }
    public var makeGuest: (Data, Data) -> Bwu1GuestSession = { uw, ticket in Bwu1Guest(uw: uw, ticket: ticket) }

    private let uw: Data?
    /// R-1: the peer is proven to read BWF1 (a responder saw the initiator's WIFI marker; anyone received a BWF1).
    private var peerReads: Bool
    public private(set) var capsSent = false
    public private(set) var peerBearers: UInt8?
    private var peerFree: (host: UInt8, guest: UInt8) = (0, 0)
    /// A violation or the call's end: no more BWF1 on this call.
    public private(set) var wifiOver = false
    private var bluetoothOut: [Bwf1] = []

    private enum Stage: Equatable { case awaitingCreds, joining, connecting, frame1, frame3, hostBind, hostReady, up }
    private struct Attempt {
        let ticket: Data
        let hostFreqMhz: Int
        let names: (ssid: String, passphrase: String)
        let startedAt: TimeInterval
        var stage: Stage
        var stageSince: TimeInterval
        var creds: (host: UInt32, port: UInt16)?
        var guest: Bwu1GuestSession?
        var connectedAt: TimeInterval?
        var input = Data()
        var sealer: SecureRecordSealer?
        var opener: SecureRecordOpener?
    }
    private var attempt: Attempt?
    private var usedTickets = Set<Data>()
    private var hostsAccepted = 0
    private var lastAttemptEnd: TimeInterval?
    private var socketOut: [Data] = []
    private var lastWifiReceiveAt: TimeInterval = 0
    private var lastWifiSendAt: TimeInterval = 0
    private var unsentSince: TimeInterval?
    public private(set) var cutover = WifiCallCutover()

    /// AW2: the child of a stream parent-to-child hop (Android HopCapsPlan STREAM_CHILD) instead of a call endpoint.
    public let streamChild: Bool
    /// AW2: this hop may offer Wi-Fi Direct now (a stream child: a direct video stream); otherwise CAPS goes out all clear.
    public var hopEligible = true
    /// The bearer bits this side's CAPS carried; the role choice uses them, never a later value.
    public private(set) var sentBearers: UInt8 = 0

    /// - Parameter streamChild: AW2. The child counts as the link initiator of the role choice whichever side dialled
    ///   (Android HopCapsPlan.localIsInitiator) and sends CAPS first once its first stream header arrived; `peerSentMarker`
    ///   is then the BMH2 build-tag gate, which proves the parent reads BWF1.
    public init(linkInitiator: Bool, uw: Data?, peerSentMarker: Bool, config: Config, streamChild: Bool = false) {
        self.linkInitiator = linkInitiator || streamChild; self.uw = uw; self.config = config; self.streamChild = streamChild
        peerReads = streamChild ? peerSentMarker : !linkInitiator && peerSentMarker
    }

    public var carrierUp: Bool { attempt?.stage == .up }
    public var binding: Bool { attempt != nil && !carrierUp }
    public var sendingOnWifi: Bool { carrierUp && cutover.sendOnWifi }
    private var ownBearers: UInt8 { uw != nil && config.directClient && hopEligible ? WifiWire.bitDirectClient : 0 }

    /// BWF1 records due on Bluetooth (carrier 0), in order.
    public func takeBluetoothRecords() -> [Bwf1] { defer { bluetoothOut = [] }; return bluetoothOut }
    /// Bytes due on the Wi-Fi socket (BWU1 frame 2 and sealed records), in order.
    public func takeSocketBytes() -> Data? { socketOut.isEmpty ? nil : socketOut.removeFirst() }

    // MARK: Engine hooks

    /// Every engine tick while the call is open. `ready`: the call is ACTIVE and every reveal is verified.
    public func tick(now: TimeInterval, ready: Bool, heartbeat: Data) {
        guard !wifiOver else { return }
        if !capsSent, ready, peerReads, streamChild || !linkInitiator || peerBearers != nil {
            capsSent = true
            sentBearers = ownBearers
            bluetoothOut.append(.caps(bearers: sentBearers, freeHost: 0, freeGuest: 0))
            log?("wifi_caps", ["event": "sent", "bearers": "\(sentBearers)", "role": linkInitiator ? "initiator" : "responder",
                               "hop": streamChild ? "stream" : "call"])
        }
        guard let a = attempt else { return }
        if a.stage != .up, now - a.startedAt > Self.attemptSeconds { fail(.setupFailed, "attempt_timeout", now: now); return }
        switch a.stage {
        case .awaitingCreds:
            if now - a.stageSince > Self.credsSeconds { fail(.setupFailed, "creds_timeout", now: now) }
        case .joining, .connecting:
            if now - a.startedAt > Self.connectSeconds { fail(.setupFailed, a.stage == .joining ? "join_timeout" : "connect_timeout", now: now) }
        case .frame1, .frame3:
            if now - a.stageSince > Self.frameSeconds { fail(.setupFailed, "bind_timeout", now: now) }
        case .hostBind, .hostReady:
            if now - (a.connectedAt ?? now) > Self.bindSeconds { fail(.setupFailed, "bind_timeout", now: now) }
        case .up:
            if now - lastWifiReceiveAt > Self.silenceSeconds { carrierLost("silent", now: now); return }
            if let since = unsentSince, now - since > Self.writeStallSeconds { carrierLost("write_stall", now: now); return }
            if now - lastWifiSendAt >= Self.heartbeatSeconds { sealOnWifi(.linkHeartbeat, heartbeat, now: now) }
        }
    }

    /// A hop type-16 record from carrier 0. Violations end Wi-Fi for this call, never the call.
    public func receivedOnBluetooth(_ payload: Data, now: TimeInterval) {
        guard !wifiOver else { return }
        let record: Bwf1
        do { record = try Bwf1.decode(payload) } catch WifiWireError.kind {
            log?("wifi_upgrade", ["event": "bwf1_unknown_kind"]); return
        } catch { violation("malformed", now: now); return }
        peerReads = true
        if case .caps(let bearers, let freeHost, let freeGuest) = record {
            guard peerBearers == nil else { violation("repeated_caps", now: now); return }
            peerBearers = bearers; peerFree = (freeHost, freeGuest)
            log?("wifi_caps", ["event": "received", "bearers": "\(bearers)"])
            return
        }
        guard capsSent, peerBearers != nil else { violation("record_before_caps", now: now); return }
        switch record {
        case .host(let status, let bearer, let ticket, let validMs, let freqMhz):
            onHost(status: status, bearer: bearer, ticket: ticket, validMs: validMs, freqMhz: freqMhz, now: now)
        case .creds(let ticket, let port, let ipv4):
            onCreds(ticket: ticket, port: port, ipv4: ipv4, now: now)
        case .decline(let ticket, let reason):
            // Android: a DECLINE ends only an attempt still being set up. Once its carrier is up the attempt was handed
            // over, so the DECLINE is stale (logged, ignored) and the cutover stays as it is.
            if let a = attempt, a.ticket == ticket, a.stage != .up { end("peer_decline_\(reason)", now: now) }
            else { log?("wifi_upgrade", ["event": "decline_stale"]) }
        case .switchTo(let gen, let ticket, let boundary, _):
            let result = cutover.receivedSwitch(gen: gen, ticket: ticket, boundary: boundary)
            log?("wifi_cutover", ["event": "switch_received", "carrier": "bluetooth", "result": "\(result)"])
        case .resume(let gen, let ticket, let next, _):
            if cutover.receivedResume(gen: gen, ticket: ticket, next: next) == .closeWifi {
                if carrierUp { carrierLost("peer_resume", now: now) } else { end("peer_resume", now: now) }
            }
        case .close:
            log?("wifi_upgrade", ["event": "close_ignored"])
        default:
            violation("unexpected_kind_\(record.kind)", now: now)
        }
    }

    // MARK: App hooks (WifiDirectGuest, through CallEngine)

    /// The platform joined the group. `local`: the pinned Wi-Fi interface; `all`: every IPv4 interface now; `band`: what
    /// this device read of the joined network (the iPhone reads nothing).
    public func joined(ticket: Data, local: IPv4Interface, all: [IPv4Interface], band: DirectGuestRules.Band, now: TimeInterval) {
        guard let a = attempt, a.ticket == ticket, a.stage == .joining, let creds = a.creds else { return }
        guard DirectGuestRules.bandOk(read: band, hostFreqMhz: a.hostFreqMhz) else { fail(.band, "band_24", now: now); return }
        if let refusal = DirectGuestRules.credsRefusal(joined: local, all: all, host: creds.host) {
            fail(refusal, refusal == .wifiUnavailable ? "subnet_overlap" : "creds_off_link", now: now); return
        }
        attempt?.stage = .connecting; attempt?.stageSince = now
        log?("wifi_upgrade", ["event": "joined", "band": band.rawValue])
        onRequest?(.connect(host: creds.host, port: creds.port, local: local, ticket: ticket))
    }

    public func joinFailed(ticket: Data, reason: DeclineReason, detail: String, now: TimeInterval) {
        guard let a = attempt, a.ticket == ticket, a.stage == .joining else { return }
        fail(reason, detail, now: now)
    }

    public func connected(ticket: Data, now: TimeInterval) {
        guard let a = attempt, a.ticket == ticket, a.stage == .connecting, let uw else { return }
        attempt?.stage = .frame1; attempt?.stageSince = now; attempt?.connectedAt = now
        attempt?.guest = makeGuest(uw, ticket)
    }

    public func connectFailed(ticket: Data, detail: String, now: TimeInterval) {
        guard let a = attempt, a.ticket == ticket, a.stage == .connecting else { return }
        fail(.setupFailed, detail, now: now)
    }

    public func socketClosed(ticket: Data, detail: String, now: TimeInterval) {
        guard let a = attempt, a.ticket == ticket else { return }
        if a.stage == .up { carrierLost(detail, now: now) } else if a.connectedAt != nil { fail(.setupFailed, detail, now: now) }
    }

    /// Bytes from the Wi-Fi socket. Returns the BME1 content records that arrived on the carrier, in order; the engine
    /// runs them through the cutover.
    public func receivedOnSocket(_ data: Data, ticket: Data, now: TimeInterval) -> [Data] {
        guard let a = attempt, a.ticket == ticket, a.connectedAt != nil else { return [] }
        attempt?.input.append(data)
        do {
            if attempt?.stage == .frame1 {
                guard let input = attempt?.input, input.count >= Bwu1Wire.frame1Bytes, let guest = attempt?.guest else { return [] }
                let frame2 = try guest.respond(toFrame1: Data(input.prefix(Bwu1Wire.frame1Bytes)))
                attempt?.input = Data(input.dropFirst(Bwu1Wire.frame1Bytes))
                socketOut.append(frame2)
                attempt?.stage = .frame3; attempt?.stageSince = now
            }
            if attempt?.stage == .frame3 {
                guard let input = attempt?.input, input.count >= Bwu1Wire.frame3Bytes, let guest = attempt?.guest else { return [] }
                let keys = try guest.finish(frame3: Data(input.prefix(Bwu1Wire.frame3Bytes)))
                let opener = SecureRecordOpener(key: SymmetricKey(data: keys.receive))
                opener.acceptWifi = true
                attempt?.input = Data(input.dropFirst(Bwu1Wire.frame3Bytes))
                attempt?.guest = nil
                attempt?.sealer = SecureRecordSealer(key: SymmetricKey(data: keys.send))
                attempt?.opener = opener
                attempt?.stage = .hostBind
                // Android: each side writes its BIND at once, before reading the other's.
                sealOnWifi(.wifi, Bwf1.bind(role: 1, ticket: ticket).encoded(), now: now)
            }
            guard let opener = attempt?.opener, let pending = attempt?.input else { return [] }
            attempt?.input = Data()
            var content: [Data] = []
            for record in try opener.feed(pending) {
                guard attempt?.ticket == ticket else { break }
                if let bme1 = try onWifiRecord(record, ticket: ticket, now: now) { content.append(bme1) }
            }
            return content
        } catch {
            if carrierUp { carrierLost("record_error", now: now) } else { fail(.setupFailed, "bind_failed", now: now) }
            return []
        }
    }

    /// The app's socket: when its oldest write still waiting for the network was handed over, or nil when every write
    /// completed. Another attempt's report changes nothing.
    public func socketSendState(oldestPendingSince: TimeInterval?, ticket: Data) {
        guard attempt?.ticket == ticket else { return }
        unsentSince = oldestPendingSince
    }

    /// A BME1 record the engine sealed while this side's direction travels on Wi-Fi: the carrier's BMS1 bytes.
    public func sealContent(_ bme1: Data, now: TimeInterval) -> Data? {
        guard carrierUp, let sealer = attempt?.sealer, let bytes = try? sealer.seal(.endToEndContent, bme1) else { return nil }
        lastWifiSendAt = now
        return bytes
    }

    /// The call ended (hang-up, failure, wipe): close and leave; nothing is sent (Android sends no CLOSE).
    public func callEnded(now: TimeInterval) {
        if let a = attempt { release(a, now: now) }
        wifiOver = true; bluetoothOut = []
    }

    // MARK: Cutover pass-through for the engine

    public func requestSwitch(now: TimeInterval, activeSince: TimeInterval?, oldestQueuedAge: TimeInterval) {
        guard carrierUp, !wifiOver else { return }
        if cutover.requestSwitch(now: now, activeSince: activeSince, oldestQueuedAge: oldestQueuedAge) {
            log?("wifi_cutover", ["event": "switch_due"])
        }
    }
    /// A pending RESUME leaves even after Wi-Fi ended for this call; a SWITCH needs a live carrier, so none follows.
    public func takeMarker(nextSequence: UInt64) -> Bwf1? { cutover.takeMarker(nextSequence: nextSequence) }
    public func bluetoothVerdict(sequence: UInt64) -> WifiCallCutover.Verdict { cutover.bluetoothVerdict(sequence: sequence) }
    public func wifiVerdict(sequence: UInt64, record: Data, now: TimeInterval) -> WifiCallCutover.Verdict {
        cutover.wifiVerdict(sequence: sequence, record: record, now: now)
    }
    public func delivered(sequence: UInt64) { cutover.delivered(sequence: sequence) }
    public func takeFragmentActions() -> (suppressReceive: Bool, resetSend: Bool) { cutover.takeFragmentActions() }
    public func takeReleased(now: TimeInterval) -> [(sequence: UInt64, record: Data)] { cutover.takeReleased(now: now) }

    // MARK: Private

    private var guestTuple: Bool {
        guard let peer = peerBearers else { return false }
        return WifiRoles.choose(local: (sentBearers, 0, 0), peer: (peer, peerFree.host, peerFree.guest), localIsLinkInitiator: linkInitiator)
            == WifiRoles.Tuple(bearer: WifiWire.bearerDirect, localIsHost: false)
    }

    private func onHost(status: UInt8, bearer: UInt8, ticket: Data, validMs: Int, freqMhz: Int, now: TimeInterval) {
        let verdict = DirectGuestRules.hostVerdict(
            hasKey: uw != nil, guestTuple: guestTuple, status: status, bearer: bearer, validMs: validMs,
            ticketFresh: ticket != Data(count: 8) && !usedTickets.contains(ticket), attemptRunning: attempt != nil,
            hostsAccepted: hostsAccepted, sinceLastAttempt: lastAttemptEnd.map { now - $0 }, foreground: foreground(),
            eligible: config.directClient && hopEligible)
        switch verdict {
        case .ignore:
            log?("wifi_upgrade", ["event": "host_nothing_offered"])
        case .decline(let reason):
            bluetoothOut.append(.decline(ticket: ticket, reason: reason.rawValue))
            log?("wifi_upgrade", ["event": "host_declined", "decline": "\(reason.rawValue)"])
        case .accept:
            hostsAccepted += 1; usedTickets.insert(ticket)
            guard let uw, let names = try? directNames(uw, ticket) else {
                bluetoothOut.append(.decline(ticket: ticket, reason: DeclineReason.setupFailed.rawValue))
                lastAttemptEnd = now
                log?("wifi_upgrade", ["event": "fail", "reason": "names"])
                return
            }
            attempt = Attempt(ticket: ticket, hostFreqMhz: freqMhz, names: names, startedAt: now, stage: .awaitingCreds, stageSince: now)
            cutover.expect(ticket: ticket)
            log?("wifi_upgrade", ["event": "host_accepted", "freqMhz": "\(freqMhz)"])
        }
    }

    private func onCreds(ticket: Data, port: UInt16, ipv4: UInt32, now: TimeInterval) {
        // A CREDS for another or an ended attempt changes nothing.
        guard let a = attempt, a.ticket == ticket, a.stage == .awaitingCreds else { return }
        attempt?.creds = (ipv4, port); attempt?.stage = .joining; attempt?.stageSince = now
        onRequest?(.join(ssid: a.names.ssid, passphrase: a.names.passphrase, hostFreqMhz: a.hostFreqMhz, ticket: ticket))
    }

    private func onWifiRecord(_ record: SecureRecord, ticket: Data, now: TimeInterval) throws -> Data? {
        switch attempt?.stage {
        case .hostBind:
            guard record.type == .wifi, case .bind(2, let t) = try Bwf1.decode(record.payload), t == ticket else { throw WifiKeyError.badFrame }
            attempt?.stage = .hostReady
            sealOnWifi(.wifi, Bwf1.ready(recvCeilingKbps: 0xFFFF, familyCapKbps: 0, transportBudgetKbps: 0xFFFF).encoded(), now: now)
            return nil
        case .hostReady:
            guard record.type == .wifi, case .ready = try Bwf1.decode(record.payload) else { throw WifiKeyError.badFrame }
            attempt?.stage = .up
            lastWifiReceiveAt = now
            cutover.carrierUp(ticket: ticket)
            log?("wifi_upgrade", ["event": "carrier_up", "setupMs": "\(Int((now - (attempt?.startedAt ?? now)) * 1000))"])
            return nil
        case .up:
            lastWifiReceiveAt = now
            switch record.type {
            case .endToEndContent: return record.payload
            case .linkHeartbeat: return nil
            case .wifi:
                switch try Bwf1.decode(record.payload) {
                case .switchTo(let gen, let t, let b, _):
                    let result = cutover.receivedSwitch(gen: gen, ticket: t, boundary: b)
                    log?("wifi_cutover", ["event": "switch_received", "carrier": "wifi", "result": "\(result)"])
                case .resume(let gen, let t, let next, _):
                    if cutover.receivedResume(gen: gen, ticket: t, next: next) == .closeWifi { carrierLost("peer_resume", now: now) }
                default:
                    throw WifiKeyError.badFrame
                }
                return nil
            default:
                throw WifiKeyError.badFrame
            }
        default:
            return nil
        }
    }

    private func sealOnWifi(_ type: SecureRecordType, _ payload: Data, now: TimeInterval) {
        guard let sealer = attempt?.sealer else { return }
        do { socketOut.append(try sealer.seal(type, payload)); lastWifiSendAt = now }
        catch { carrierLost("seal_failed", now: now) }
    }

    private func fail(_ reason: DeclineReason, _ detail: String, now: TimeInterval) {
        guard let a = attempt else { return }
        bluetoothOut.append(.decline(ticket: a.ticket, reason: reason.rawValue))
        log?("wifi_upgrade", ["event": "fail", "reason": detail, "decline": "\(reason.rawValue)"])
        release(a, now: now)
    }

    private func end(_ detail: String, now: TimeInterval) {
        guard let a = attempt else { return }
        log?("wifi_upgrade", ["event": "end", "reason": detail])
        release(a, now: now)
    }

    private func carrierLost(_ detail: String, now: TimeInterval, announce: Bool = true) {
        guard let a = attempt else { return }
        let wasSending = cutover.sendOnWifi
        cutover.wifiLost(now: now, announce: announce)
        log?("wifi_cutover", ["event": "fallback", "reason": detail, "wasSending": "\(wasSending)"])
        release(a, now: now)
        onRequest?(.keyFrame)
    }

    private func release(_ a: Attempt, now: TimeInterval) {
        attempt = nil; lastAttemptEnd = now; socketOut = []; unsentSince = nil
        cutover.attemptEnded()
        if a.stage != .awaitingCreds && a.stage != .joining { onRequest?(.closeSocket(ticket: a.ticket)) }
        if a.stage != .awaitingCreds { onRequest?(.leave(ticket: a.ticket)) }
    }

    private func violation(_ detail: String, now: TimeInterval) {
        log?("wifi_upgrade", ["event": "bwf1_violation", "reason": detail])
        // The RESUME still goes out: the peer fences this side's Bluetooth content after our SWITCH until it sees one.
        if carrierUp { carrierLost(detail, now: now) } else if attempt != nil { end(detail, now: now) }
        wifiOver = true; bluetoothOut = []
    }
}

/// AW1/AW2: what WifiDirectGuest drives: the engine of one call or one stream hop that owns a WifiCallAgent.
public protocol WifiGuestEngine: AnyObject {
    func wifiJoined(ticket: Data, local: IPv4Interface, all: [IPv4Interface], band: DirectGuestRules.Band, now: TimeInterval)
    func wifiJoinFailed(ticket: Data, reason: DeclineReason, detail: String, now: TimeInterval)
    func wifiConnected(ticket: Data, now: TimeInterval)
    func wifiConnectFailed(ticket: Data, detail: String, now: TimeInterval)
    func wifiSocketClosed(ticket: Data, detail: String, now: TimeInterval)
    func wifiSendState(oldestPendingSince: TimeInterval?, ticket: Data, now: TimeInterval)
    func wifiReceive(_ data: Data, ticket: Data, now: TimeInterval)
    func nextWifiOutgoing(now: TimeInterval) -> Data?
}

extension CallEngine: WifiGuestEngine {}
extension StreamViewerEngine: WifiGuestEngine {}
