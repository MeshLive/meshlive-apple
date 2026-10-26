import Foundation
import CoreBluetooth
import CryptoKit
import NearbyCore

// MeshPeer: a macOS command-line MeshLive peer built from the iPhone protocol core (NearbyCore) and the app's
// CoreBluetooth radio (App/Transport/MeshRadio.swift, MeshLinks.swift), for interop runs against Android phones
// before an iPhone is available. Media is stubbed: no camera, no microphone, no Opus encoder; calls carry the
// signalling, the BTV3 header and the Opus configuration packet only (voice calls with no audio frames).
// See Peer/README.md for the one-time Bluetooth permission and the Android switches.

struct Options {
    var command = "help"
    var target = "first"
    var seconds: TimeInterval = 30
    var transport: MeshTransport = .gatt
    var rotating = false, bmh3 = false, pseudonyms = false
    /// Test tool only: sign VP9 and AV1 as encodable and decodable so a call reaches ACTIVE with any Android codec;
    /// MeshPeer still drops all media (it has no decoder or encoder). Never in the app.
    var claimCodecs = false
    var identityFile = (NSHomeDirectory() as NSString).appendingPathComponent("MeshLive/peer-identity.key")

    init(_ args: [String]) {
        var rest = Array(args.dropFirst())
        if let first = rest.first, !first.hasPrefix("-") { command = first; rest.removeFirst() }
        var i = 0
        while i < rest.count {
            let a = rest[i], value = i + 1 < rest.count ? rest[i + 1] : ""
            switch a {
            case "--seconds": seconds = TimeInterval(value) ?? seconds; i += 1
            case "--to": target = value; i += 1
            case "--transport": transport = MeshTransport(rawValue: value) ?? transport; i += 1
            case "--identity": identityFile = value; i += 1
            case "--rotating": rotating = true
            case "--bmh3": bmh3 = true
            case "--pseudonyms": pseudonyms = true; bmh3 = true; rotating = true
            case "--android-defaults": rotating = true; bmh3 = true; pseudonyms = true
            case "--claim-codecs": claimCodecs = true
            default: break
            }
            i += 1
        }
    }
}

let usage = """
MeshPeer (macOS, experimental test tool). Commands:
  scan [--seconds N]                         list nearby MeshLive phones (Android and iPhone adverts)
  listen [--seconds N]                       advertise call availability, answer the first call (voice), hang up after N s
  call --to first|<prefix12hex> [--seconds N]  call a nearby phone (voice), hang up N s after it is active
Options: --transport gatt|l2cap (default gatt)  --rotating  --bmh3  --pseudonyms  --android-defaults (all three)
         --claim-codecs (sign VP9+AV1 encode/decode so any Android codec reaches ACTIVE; media is still dropped)
         --identity <file> (default ~/MeshLive/peer-identity.key; a software P-256 key, created on first run)
Output: one line per event; every engine event as `peer: ...`, radio events as the app's `BENCHMARK ...` lines.
"""

func log(_ line: String) {
    let stamp = String(format: "%.3f", ProcessInfo.processInfo.systemUptime)
    print("\(stamp) peer: \(line)"); fflush(stdout)
}

/// A persistent software identity, so the peer keeps its node prefix across runs (Android pins and contacts).
func loadIdentity(_ path: String) -> SoftwareSigningIdentity {
    if let raw = FileManager.default.contents(atPath: path), raw.count == 32, let id = try? SoftwareSigningIdentity(rawScalar: raw) { return id }
    let id = SoftwareSigningIdentity()
    try? FileManager.default.createDirectory(atPath: (path as NSString).deletingLastPathComponent, withIntermediateDirectories: true)
    FileManager.default.createFile(atPath: path, contents: id.privateKey.rawRepresentation, attributes: [.posixPermissions: 0o600])
    return id
}

final class Peer {
    let options: Options
    let identity: SoftwareSigningIdentity
    let radio = MeshRadio()
    var engine: CallEngine?
    var driver: ConnectionDriver?
    var activeAt: Date?
    let started = Date()
    let pins = Bmh3Pins()
    let entryKey = SymmetricKey(size: .bits256).withUnsafeBytes { Data($0) }
    /// Listen with --rotating: the role-0 ID rotates every epoch and a connection opens only the IDs pinned when it
    /// was accepted, as the app does.
    lazy var presence = RotatingCallPresence { [unowned self] epoch in
        RotatingDiscoveryIds.ownEntry(presenceKey: self.entryKey, nodeId: self.identity.nodeId.bytes, epoch: epoch, role: 0)
    }
    static var elapsedMs: Int64 { Int64(ProcessInfo.processInfo.systemUptime * 1000) }

    init(_ options: Options) {
        self.options = options
        identity = loadIdentity(options.identityFile)
        log("node \(identity.nodeId.hex) prefix \(identity.nodeId.prefix.hex) handle \(IdentityHandle.handle(prefix: identity.nodeId.prefix) ?? "?")")
        radio.acceptRotating = options.rotating
        radio.onState = { log("bluetooth: \($0)") }
        radio.onPeersChanged = { [weak self] in self?.peersChanged() }
        radio.onIncomingLink = { [weak self] link in self?.incoming(link) }
        radio.onReady = { [weak self] in self?.ready() }
    }

    var codecs: (encode: UInt8, decode: UInt8) {
        options.claimCodecs ? (NodeCapabilities.codecVP9 | NodeCapabilities.codecAV1, NodeCapabilities.codecVP9 | NodeCapabilities.codecAV1)
                            : (NodeCapabilities.codecVP9, NodeCapabilities.codecVP9)
    }
    private var seen = Set<String>()

    func bmh3(selected: DiscoveryAnnouncement?) -> Bmh3CallOptions? {
        options.bmh3 ? Bmh3CallOptions(pseudonyms: options.pseudonyms && options.rotating, selected: selected, pins: pins) : nil
    }

    private var radioReady = false

    func ready() {
        log("radio ready (\(options.command))")
        radioReady = true
        // The radio scans only when asked (the app turns it on from its model): scan and call need it.
        if options.command != "listen" { radio.setScanning(true); return }
        if options.rotating { rotate(); return }
        advertise(prefix: identity.nodeId.prefix, rotating: false)
    }

    private func advertise(prefix: Data, rotating: Bool) {
        var offer = DiscoveryAnnouncement(nodeIdPrefix: prefix,
                                          flags: DiscoveryAnnouncement.flagAcceptingConnections | DiscoveryAnnouncement.flagPrivateCallAvailable
                                              | (options.transport == .gatt ? DiscoveryAnnouncement.flagGattTransport : 0),
                                          capabilitySummary: codecs.encode & codecs.decode, streamToken: 0, routeCost: 0)
        offer.rotating = rotating
        radio.advertise(offer, name: "MeshPeer")
        log("advertising a call offer (\(rotating ? "rotating ID " + prefix.hex : "fixed prefix"))")
    }

    /// Rotating listener: a new ID at each epoch boundary after a 1-8 s silence (until a call is accepted).
    private func rotate() {
        switch presence.step(epoch: RotatingDiscoveryIds.currentWallEpoch(), elapsedMs: Self.elapsedMs) {
        case .none: break
        case .stop: radio.advertise(nil, name: ""); log("epoch boundary: advertising paused")
        case .advertise(let entry): advertise(prefix: entry.rdi, rotating: true)
        }
    }

    func peersChanged() {
        for peer in radio.peers.values {
            let a = peer.announcement
            let kind = a.isStreamOffer ? "stream" : a.isPrivateCallOffer ? "call" : "request"
            let line = "seen \(kind) \(a.rotating ? "rotating" : "fixed") \(a.prefixHex) cost \(a.routeCost) \(a.transport?.rawValue ?? "classic") iPhone \(peer.isIPhone) summary \(String(format: "%02x", a.capabilitySummary))"
            if seen.insert(line).inserted { log(line + " rssi \(peer.rssi)") }
        }
        guard options.command == "call", engine == nil else { return }
        guard let row = radio.peers.values.first(where: { $0.announcement.isPrivateCallOffer && !$0.announcement.usesClassic
                && (options.target == "first" || $0.prefixHex == options.target.lowercased()) }) else { return }
        let offer = row.announcement
        let transport = offer.transport ?? .gatt
        let call = CallEngine(role: .caller, transport: transport, identity: identity, requestedType: .voice, encodeMask: codecs.encode, decodeMask: codecs.decode,
                              expectedPeerPrefix: offer.rotating ? nil : offer.nodeIdPrefix, relayHops: offer.routeCost,
                              rotating: options.rotating ? RotatingCallOptions(selected: offer) : nil, bmh3: bmh3(selected: offer))
        engine = call
        log("calling \(offer.prefixHex) over \(transport.rawValue)")
        radio.connect(to: row.id, transport: transport) { [weak self] result in
            switch result {
            case .success(let link): self?.attach(call, link)
            case .failure(let error): log("connect failed: \(error)"); exit(2)
            }
        }
    }

    func incoming(_ link: MeshLink) {
        guard options.command == "listen", engine == nil else { link.close(); return }
        // The IDs this connection may open are pinned now, at accept (on air, or off air for less than 60 s).
        let pinned = presence.acceptedEntries(elapsedMs: Self.elapsedMs)
        let entries: () -> [OpeningEntry] = { pinned }
        let call = CallEngine(role: .callee, transport: link.transport, identity: identity, requestedType: .voice, encodeMask: codecs.encode,
                              decodeMask: codecs.decode, rotating: options.rotating ? RotatingCallOptions(entries: entries) : nil, bmh3: bmh3(selected: nil))
        engine = call
        attach(call, link)
    }

    func attach(_ call: CallEngine, _ link: MeshLink) {
        call.onEvent = { [weak self, weak call] event in
            log("\(event)")
            if case .incomingCall = event { try? call?.accept(as: .voice); self?.driver?.pump() }
            if case .phase(let p) = event, p == .active { self?.activeAt = Date() }
            if case .ended = event { DispatchQueue.main.asyncAfter(deadline: .now() + 1) { exit(0) } }
        }
        let driver = ConnectionDriver(engine: call, link: link)
        driver.onFinished = { reason in log("finished: \(reason)") }
        self.driver = driver
        driver.start()
    }

    func tick() {
        if options.command == "listen", options.rotating, engine == nil, radioReady { rotate() }
        if let activeAt, Date().timeIntervalSince(activeAt) >= options.seconds { log("hanging up"); engine?.end(); driver?.pump(); self.activeAt = nil }
        let limit = options.command == "scan" ? options.seconds : max(options.seconds * 3, 120)
        if Date().timeIntervalSince(started) > limit { log("time limit"); exit(engine == nil && options.command != "scan" ? 3 : 0) }
    }
}

let options = Options(CommandLine.arguments)
guard ["scan", "listen", "call"].contains(options.command) else { print(usage); exit(options.command == "help" ? 0 : 64) }
let peer = Peer(options)
peer.radio.start()
Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { _ in peer.tick() }
RunLoop.main.run()
