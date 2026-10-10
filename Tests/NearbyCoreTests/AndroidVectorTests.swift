import XCTest
import CryptoKit
@testable import NearbyCore

/// Vectors produced by the Android app's own protocol classes (MeshSecurity.kt, SecureBluetoothLink.kt,
/// EndToEndVideoSecurity.kt, PrivateCallSession.kt, StreamProtocol.kt, MeshCore.kt, IdentityVerification.kt,
/// MeshControlMessages.kt, StreamDiscovery.kt, CallVideoFragments.kt) compiled unchanged with kotlinc.
/// See Interop/android-vectors/README.md for regeneration.
final class AndroidVectorTests: XCTestCase {
    private var json: [String: Any] = [:]

    override func setUpWithError() throws {
        let url = try XCTUnwrap(Bundle.module.url(forResource: "android-vectors", withExtension: "json", subdirectory: "Fixtures"))
        json = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any])
    }
    private func obj(_ key: String, in dict: [String: Any]? = nil) throws -> [String: Any] { try XCTUnwrap((dict ?? json)[key] as? [String: Any]) }
    private func hex(_ key: String, in dict: [String: Any]? = nil) throws -> Data { try XCTUnwrap(Data(hex: try XCTUnwrap((dict ?? json)[key] as? String))) }
    private func str(_ key: String, in dict: [String: Any]? = nil) throws -> String { try XCTUnwrap((dict ?? json)[key] as? String) }
    private func key(_ data: Data) -> SymmetricKey { SymmetricKey(data: data) }

    func testAesGcmMatchesAndroidAndWindowsVector() throws {
        let key = SymmetricKey(data: Data((0..<32).map { UInt8($0) }))
        let out = try MeshAead.encrypt(key: key, sequence: 7, plaintext: Data("cross-platform".utf8), associatedData: Data("BMS1-test-aad".utf8))
        XCTAssertEqual(out, try hex("aesGcm"))
        XCTAssertEqual(out.hex, "831f7c6c643a2e96a52b8940413960b7e55624a70b6b69866e3df1d44810")
    }

    private func checkHandshake(_ name: String, purpose: HandshakePurpose) throws -> (i2r: Data, r2i: Data) {
        let v = try obj(name)
        let initiatorHello = try SignedHandshakeHello(decoding: try hex("encoded", in: try obj("initiatorHello", in: v)))
        let responderHello = try SignedHandshakeHello(decoding: try hex("encoded", in: try obj("responderHello", in: v)))
        // Byte-exact re-encoding, Android signatures verify in the right domain only.
        XCTAssertEqual(try initiatorHello.encoded(), try hex("encoded", in: try obj("initiatorHello", in: v)))
        XCTAssertEqual(initiatorHello.unsignedEncoding, try hex("unsigned", in: try obj("initiatorHello", in: v)))
        try MeshHandshake.verify(initiatorHello, purpose: purpose)
        try MeshHandshake.verify(responderHello, purpose: purpose)
        XCTAssertThrowsError(try MeshHandshake.verify(initiatorHello, purpose: purpose == .link ? .endToEnd : .link))
        XCTAssertEqual(initiatorHello.role, .initiator); XCTAssertEqual(responderHello.role, .responder)
        // Identity keys: CryptoKit's SPKI is byte-identical to Java's PublicKey.encoded, so node IDs match.
        let initiatorIdentity = try SoftwareSigningIdentity(rawScalar: try hex("initiatorIdentityPrivate", in: v))
        XCTAssertEqual(initiatorIdentity.publicKeyEncoded, initiatorHello.identityPublicKey)
        XCTAssertEqual(initiatorIdentity.nodeId, initiatorHello.nodeId)
        XCTAssertEqual(initiatorHello.nodeId.hex, try str("nodeId", in: try obj("initiatorHello", in: v)))
        let ephemeral = try P256.KeyAgreement.PrivateKey(rawRepresentation: try hex("initiatorEphemeralPrivate", in: v))
        XCTAssertEqual(ephemeral.publicKey.derRepresentation, initiatorHello.ephemeralPublicKey)
        // Swift finishes as the initiator with Android's ephemeral secret and derives Android's keys.
        let pending = PendingHandshake(hello: initiatorHello, ephemeral: ephemeral, purpose: purpose)
        let keys = try MeshHandshake.finish(pending, remote: responderHello)
        let send = keys.sendKey.withUnsafeBytes { Data($0) }, receive = keys.receiveKey.withUnsafeBytes { Data($0) }
        XCTAssertEqual(send, try hex("initiatorToResponderKey", in: v))
        XCTAssertEqual(receive, try hex("responderToInitiatorKey", in: v))
        // And as the responder.
        let responderEphemeral = try P256.KeyAgreement.PrivateKey(rawRepresentation: try hex("responderEphemeralPrivate", in: v))
        let rKeys = try MeshHandshake.finish(PendingHandshake(hello: responderHello, ephemeral: responderEphemeral, purpose: purpose), remote: initiatorHello)
        XCTAssertEqual(rKeys.sendKey.withUnsafeBytes { Data($0) }, try hex("responderToInitiatorKey", in: v))
        // A tampered capability byte breaks the signature.
        var tampered = initiatorHello; tampered.capabilities.maxChildren = 9
        XCTAssertThrowsError(try MeshHandshake.verify(tampered, purpose: purpose))
        return (send, receive)
    }

    func testLinkAndEndpointHandshakesDeriveAndroidKeys() throws {
        _ = try checkHandshake("link", purpose: .link)
        _ = try checkHandshake("endpoint", purpose: .endToEnd)
        let ep = try SignedHandshakeHello(decoding: try hex("encoded", in: try obj("initiatorHello", in: try obj("endpoint"))))
        XCTAssertEqual(ep.capabilities.decodeCodecMask, 3 | NodeCapabilities.decodePrefersVP9)
        XCTAssertEqual(ep.capabilities.maxBitrateKbps, 1200)
        XCTAssertEqual(ep.capabilities.transportMask, NodeCapabilities.transportL2CAP)
    }

    func testFramedHelloMatchesAndroidSocketBytes() throws {
        let framed = try hex("framedHelloExample")
        let link = SecureLink(role: .responder, identity: SoftwareSigningIdentity(), capabilities: NodeCapabilities(transportMask: 2, encodeCodecMask: 1, decodeCodecMask: 1, maxBitrateKbps: 1200, maxChildren: 0))
        // Fed one byte at a time: the responder answers with its own framed hello once complete.
        var outputs: [SecureLink.Output] = []
        for byte in framed { outputs += try link.receive(Data([byte])) }
        XCTAssertEqual(outputs.count, 2)
        guard case .send(let reply) = outputs[0] else { return XCTFail("no reply") }
        XCTAssertEqual(outputs[1], .established)
        XCTAssertEqual(Int(reply.prefix(4).reduce(0) { $0 << 8 | Int($1) }), reply.count - 4)
        XCTAssertEqual(link.peerCapabilities?.transportMask, NodeCapabilities.transportL2CAP)
    }

    func testBms1StreamAndBme1ContentsOpenWithAndroidKeys() throws {
        let link = try checkHandshake("link", purpose: .link)
        let endpoint = try checkHandshake("endpoint", purpose: .endToEnd)
        let stream = try hex("bms1Stream")
        let opener = SecureRecordOpener(key: key(link.i2r))
        // Arbitrary fragmentation of the byte stream.
        var records: [SecureRecord] = []
        var index = 0; var step = 1
        while index < stream.count { let end = min(stream.count, index + step); records += try opener.feed(stream.subdata(in: index..<end)); index = end; step = step % 97 + 13 }
        let expected = try XCTUnwrap(json["bms1Records"] as? [[String: Any]])
        XCTAssertEqual(records.count, expected.count)
        for (record, e) in zip(records, expected) {
            XCTAssertEqual(Int(record.type.rawValue), e["type"] as? Int)
            XCTAssertEqual(record.payload.hex, e["payload"] as? String, e["label"] as? String ?? "")
        }
        // Swift reproduces the identical BMS1 byte stream (AES-GCM is deterministic for key/nonce).
        let sealer = SecureRecordSealer(key: key(link.i2r))
        var rebuilt = Data()
        for r in records { rebuilt += try sealer.seal(r.type, r.payload) }
        XCTAssertEqual(rebuilt, stream)

        // BME1: open every Android-sealed content record, check flags/types, and re-seal identically.
        let contents = try XCTUnwrap(json["bme1Contents"] as? [[String: Any]])
        let contentOpener = EndToEndContentOpener(key: key(endpoint.i2r))
        let contentSealer = EndToEndContentSealer(key: key(endpoint.i2r))
        for c in contents {
            let sealed = try XCTUnwrap(Data(hex: try XCTUnwrap(c["sealed"] as? String)))
            let opened = try contentOpener.open(sealed)
            XCTAssertEqual(Int(opened.type.rawValue), c["type"] as? Int)
            XCTAssertEqual(Int(opened.flags), c["flags"] as? Int)
            XCTAssertEqual(opened.payload.hex, c["plaintext"] as? String)
            XCTAssertEqual(try contentSealer.seal(opened.type, flags: opened.flags, opened.payload), sealed)
        }
        // Replay is rejected; tampering is rejected.
        let first = try XCTUnwrap(Data(hex: try XCTUnwrap(contents[0]["sealed"] as? String)))
        XCTAssertThrowsError(try contentOpener.open(first))
        var bad = first; bad[bad.count - 1] ^= 1
        XCTAssertThrowsError(try EndToEndContentOpener(key: key(endpoint.i2r)).open(bad))
        // A BMS1 record with a skipped sequence is rejected (exact-next ordering).
        let skipping = SecureRecordSealer(key: key(link.i2r)); _ = try skipping.seal(.linkHeartbeat, Data([1]))
        XCTAssertThrowsError(try SecureRecordOpener(key: key(link.i2r)).feed(try skipping.seal(.linkHeartbeat, Data([1]))))
    }

    func testDecodedMediaSignalsAndHeartbeats() throws {
        let contents = try XCTUnwrap(json["bme1Contents"] as? [[String: Any]])
        func plaintext(_ label: String) throws -> (Data, UInt8) {
            let c = try XCTUnwrap(contents.first { $0["label"] as? String == label })
            return (try XCTUnwrap(Data(hex: try XCTUnwrap(c["plaintext"] as? String))), UInt8(try XCTUnwrap(c["flags"] as? Int)))
        }
        let invite = try PrivateCallSignalMessage(decoding: try plaintext("invite").0)
        XCTAssertEqual(invite.signal, .invite)
        XCTAssertEqual(invite.callId.uuidString.lowercased(), "0f1e2d3c-4b5a-6978-8796-a5b4c3d2e1f0")
        XCTAssertEqual(invite.encoded, try plaintext("invite").0)
        XCTAssertEqual(try PrivateCallSignalMessage(decoding: try plaintext("cameraOff").0).signal, .cameraOff)
        let hangUp = try PrivateCallSignalMessage(decoding: try plaintext("hangUp").0)
        XCTAssertEqual(hangUp.reason, .normal)
        let relayed = try PrivateCallSignalMessage(decoding: try hex("bmc2RelayedInvite"))
        XCTAssertEqual(relayed.relayHops, 3)
        XCTAssertEqual(try PrivateCallSignalMessage(decoding: try hex("bmc2Decline")).reason, .busy)

        let header = try StreamHeader(decoding: try plaintext("header").0)
        XCTAssertEqual(header, StreamHeader(width: 426, height: 240, fps: 15, codecId: StreamProtocol.codecVP9, rotationDegrees: 90, includeAudio: true))
        XCTAssertEqual(try header.encoded(), try hex("btv3Header"))
        XCTAssertEqual(header.displayWidth, 240)

        let (configBytes, configFlags) = try plaintext("audioConfig")
        let config = try MediaPacket(decoding: configBytes, authenticatedFlags: configFlags)
        XCTAssertTrue(config.isAudio && config.isCodecConfig)
        XCTAssertEqual(try OpusHead.parse(config.payload).channels, 1)
        XCTAssertEqual(OpusHead.make(channels: 1, preSkip: 312), config.payload)
        let (audioBytes, audioFlags) = try plaintext("audio")
        let audio = try MediaPacket(decoding: audioBytes, authenticatedFlags: audioFlags)
        XCTAssertEqual(audio.presentationTimeUs, 20_000)
        XCTAssertThrowsError(try MediaPacket(decoding: audioBytes, authenticatedFlags: audioFlags | 2))
        let (pairBytes, pairFlags) = try plaintext("audioPair")
        let pair = try MediaPacket(decoding: pairBytes, authenticatedFlags: pairFlags).splitAudio()
        XCTAssertEqual(pair.map(\.presentationTimeUs), [40_000, 60_000]); XCTAssertEqual(pair[1].payload.hex, "fc2222")
        XCTAssertEqual(try MediaPacket.combineAudio(pair).encoded, pairBytes)
        let (batchBytes, batchFlags) = try plaintext("audioBatch")
        let batch = try MediaPacket(decoding: batchBytes, authenticatedFlags: batchFlags).splitAudio()
        XCTAssertEqual(batch.map(\.presentationTimeUs), [80_000, 100_000, 120_000])
        XCTAssertEqual(try MediaPacket.combineAudio(batch).encoded, batchBytes)
        let (rotationBytes, rotationFlags) = try plaintext("rotation")
        XCTAssertEqual(try MediaPacket(decoding: rotationBytes, authenticatedFlags: rotationFlags).decodeDisplayRotation(), 270)
        XCTAssertEqual(try StreamLifecycleState(decoding: try plaintext("paused").0), .paused)

        let records = try XCTUnwrap(json["bms1Records"] as? [[String: Any]])
        func heartbeat(_ label: String) throws -> Data { try XCTUnwrap(Data(hex: try XCTUnwrap(records.first { $0["label"] as? String == label }?["payload"] as? String))) }
        XCTAssertNil(try LinkHeartbeat.decode(try heartbeat("heartbeatV1")))
        let v2 = try XCTUnwrap(try LinkHeartbeat.decode(try heartbeat("heartbeatV2")))
        XCTAssertEqual(v2, LinkCapacityReport(arrivalKbps: 512, linkLate: true, addedDelayMs: 300))
        XCTAssertEqual(LinkHeartbeat.encode(v2), try heartbeat("heartbeatV2"))
        let v3 = try XCTUnwrap(try LinkHeartbeat.decode(try heartbeat("heartbeatV3")))
        XCTAssertEqual(v3.receivedBytes, 123_456_789); XCTAssertEqual(v3.clockMs, UInt32(4_000_000_000 as UInt64)); XCTAssertTrue(v3.deliveryOnly)
        XCTAssertEqual(LinkHeartbeat.encode(v3), try heartbeat("heartbeatV3"))
        XCTAssertThrowsError(try LinkHeartbeat.decode(Data([2, 0, 0, 4, 0, 0])))
        XCTAssertEqual(try RouteWithdrawal(decoding: try heartbeat("routeWithdrawal")), .localCapacity)
    }

    func testMeshEnvelopeGrantAndForwardedStream() throws {
        let mesh = try obj("mesh")
        let grant = try ForwardedStreamGrant(decoding: try hex("grant", in: mesh))
        XCTAssertEqual(grant.key, try hex("grantKey", in: mesh))
        XCTAssertEqual(grant.sourceNodeId.hex, try str("sourceNodeId", in: mesh))
        XCTAssertEqual(grant.streamId.uuidString.lowercased(), try str("streamId", in: mesh))
        XCTAssertEqual(grant.encoded, try hex("grant", in: mesh))
        let opener = SecureRecordOpener(key: key(try hex("linkKey", in: mesh)))
        let records = try opener.feed(try hex("stream", in: mesh))
        XCTAssertEqual(records.count, 4)
        let content = EndToEndContentOpener(key: key(grant.key))
        var window = DuplicateWindow()
        var lastSequence: UInt64?
        for (index, record) in records.enumerated() {
            XCTAssertEqual(record.type, .meshEnvelope)
            let envelope = try MeshEnvelope(decoding: record.payload)
            XCTAssertEqual(envelope.encoded, record.payload)
            XCTAssertEqual(envelope.sourceNodeId, grant.sourceNodeId)
            XCTAssertEqual(envelope.streamId, grant.streamId)
            XCTAssertEqual(envelope.ttl, MeshEnvelope.defaultTtl)
            XCTAssertTrue(window.markIfNew(envelope)); XCTAssertFalse(window.markIfNew(envelope))
            if let lastSequence { XCTAssertGreaterThan(envelope.sequence, lastSequence) }
            lastSequence = envelope.sequence
            let opened = try content.open(envelope.payload)
            switch index {
            case 0: XCTAssertEqual(opened.type, .streamHeader); XCTAssertEqual(envelope.flags, 0)
            case 1: XCTAssertEqual(opened.type, .mediaPacket); XCTAssertEqual(envelope.flags, MeshEnvelope.flagAudio)
            case 2: XCTAssertEqual(envelope.flags & MeshEnvelope.flagKeyFrame, MeshEnvelope.flagKeyFrame)
            default:
                XCTAssertEqual(opened.type, .streamState)
                XCTAssertEqual(try StreamLifecycleState(decoding: opened.payload), .ended)
                XCTAssertEqual(envelope.flags, MeshEnvelope.flagControl | MeshEnvelope.flagTerminal)
            }
        }
    }

    func testIdentityFingerprintSafetyCodeAndQr() throws {
        let id = try obj("identity")
        let link = try obj("link")
        let callerIdentity = try SoftwareSigningIdentity(rawScalar: try hex("initiatorIdentityPrivate", in: link))
        let calleeIdentity = try SoftwareSigningIdentity(rawScalar: try hex("responderIdentityPrivate", in: link))
        XCTAssertEqual(callerIdentity.fingerprint.hex, try str("callerFingerprint", in: id))
        XCTAssertEqual(calleeIdentity.fingerprint.hex, try str("calleeFingerprint", in: id))
        XCTAssertEqual(SafetyCode.half(callerIdentity.fingerprint), try str("callerHalf", in: id))
        XCTAssertEqual(SafetyCode.derive(callerIdentity.fingerprint, calleeIdentity.fingerprint), try str("pairCode", in: id))
        XCTAssertEqual(SafetyCode.derive(calleeIdentity.fingerprint, callerIdentity.fingerprint), try str("pairCode", in: id))
        // Android's fixed release vector.
        let x = try IdentityFingerprint(bytes: Data((0..<32).map { UInt8($0) }))
        let y = try IdentityFingerprint(bytes: Data((0..<32).map { UInt8(0xff - $0) }))
        XCTAssertEqual(SafetyCode.half(x), "91662 04557 05960 21671 25144 22586")
        XCTAssertEqual(SafetyCode.half(y), "71883 11788 79268 78261 54534 68020")
        XCTAssertEqual(SafetyCode.derive(x, y), "71883 11788 79268 78261 54534 68020 91662 04557 05960 21671 25144 22586")
        XCTAssertEqual(SafetyCode.half(x), try str("fixedHalfX", in: id))
        XCTAssertEqual(IdentityFingerprint(publicKey: Data("abc".utf8)).hex, "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad")
        // QR: Swift encodes Android's exact text and parses it back.
        XCTAssertEqual(try IdentityQrCodec.encode(IdentityQrPayload(fingerprint: callerIdentity.fingerprint, displayName: "Asha · फ़ोन")), try str("qr", in: id))
        let parsed = try IdentityQrCodec.parse(try str("qrJose", in: id))
        XCTAssertEqual(parsed.displayName, "José"); XCTAssertEqual(parsed.fingerprint, calleeIdentity.fingerprint)
        let qr = try str("qr", in: id), name = String(qr.split(separator: ".")[2]), hexFp = callerIdentity.fingerprint.hex
        for bad in ["", "BVMID2.\(hexFp).\(name)", "bvmid1.\(hexFp).\(name)", "BVMID1.\(hexFp)", "BVMID1.\(hexFp).\(name).extra",
                    "BVMID1.\(hexFp.prefix(10).uppercased())\(hexFp.dropFirst(10)).\(name)", "BVMID1.\(String(repeating: "g", count: 64)).\(name)",
                    "BVMID1.\(hexFp).\(name)=", "BVMID1.\(hexFp).", " \(qr)",
                    "BVMID1.\(hexFp).\(IdentityQrCodec.base64url(Data("a\u{0}b".utf8)))",
                    "BVMID1.\(hexFp).\(IdentityQrCodec.base64url(Data([0xc3, 0x28])))",
                    "BVMID1.\(hexFp).\(IdentityQrCodec.base64url(Data("   ".utf8)))",
                    "BVMID1.\(hexFp).\(IdentityQrCodec.base64url(Data("Bob\u{202E}evil".utf8)))",
                    "BVMID1.\(hexFp).\(IdentityQrCodec.base64url(Data("Bo\u{200B}b".utf8)))",
                    "BVMID1.\(hexFp).\(IdentityQrCodec.base64url(Data(repeating: 0x61, count: 65)))"] {
            XCTAssertThrowsError(try IdentityQrCodec.parse(bad), bad)
        }
    }

    func testDiscoveryAnnouncementsAndRouteTokens() throws {
        let d = try obj("discovery")
        let prefix = try XCTUnwrap(Data(hex: "a1b2c3d4e5f6"))
        let route = try StreamRouteToken.forAdvertiser(logical: 0x1234abcd, prefix: prefix)
        XCTAssertEqual(Int(route), d["routeToken"] as? Int)
        XCTAssertEqual(StreamRouteToken.logical(routeToken: route, prefix: prefix), 0x1234abcd)
        let offer = try DiscoveryAnnouncement(decoding: try hex("offer", in: d))
        XCTAssertTrue(offer.isStreamOffer); XCTAssertTrue(offer.isFullStreamOffer); XCTAssertEqual(offer.transport, .gatt)
        XCTAssertEqual(offer.streamWidth, 640); XCTAssertEqual(offer.streamFps, 15); XCTAssertEqual(offer.streamBitrateKbps, 300)
        XCTAssertEqual(offer.logicalStreamToken, 0x1234abcd)
        XCTAssertEqual(try offer.encoded(), try hex("offer", in: d))
        let viewer = try DiscoveryAnnouncement(decoding: try hex("viewerRecovery", in: d))
        XCTAssertEqual(viewer.recoveryFromNodeIdPrefix, prefix); XCTAssertTrue(viewer.isViewerRequest(routeToken: route))
        XCTAssertEqual(try viewer.encoded(), try hex("viewerRecovery", in: d))
        let call = try DiscoveryAnnouncement(decoding: try hex("call", in: d))
        XCTAssertTrue(call.isPrivateCallOffer); XCTAssertEqual(call.transport, .l2cap)
        XCTAssertEqual(try DiscoveryAnnouncement(manufacturerData: Data([0xff, 0xff]) + (try hex("call", in: d))), call)
    }

    /// Writes a Swift-produced transcript for the reverse check with Android's classes
    /// (`java -jar android-vectors.jar verify <file>`; see Interop/android-vectors/README.md).
    func testSwiftTranscriptForAndroidVerification() throws {
        let identity = SoftwareSigningIdentity()
        let caps = NodeCapabilities(transportMask: NodeCapabilities.transportL2CAP, encodeCodecMask: NodeCapabilities.codecVP9,
                                    decodeCodecMask: NodeCapabilities.codecVP9 | NodeCapabilities.decodePrefersVP9, maxBitrateKbps: 1200, maxChildren: 0)
        let linkHello = try MeshHandshake.start(identity: identity, role: .initiator, capabilities: caps, purpose: .link).hello
        let endpointHello = try MeshHandshake.start(identity: identity, role: .initiator, capabilities: caps, purpose: .endToEnd).hello
        let linkKey = SymmetricKey(size: .bits256), contentKey = SymmetricKey(size: .bits256)
        let sealer = SecureRecordSealer(key: linkKey), content = EndToEndContentSealer(key: contentKey)
        var stream = try sealer.seal(.linkHeartbeat, LinkHeartbeat.version1)
        let invite = try PrivateCallSignalMessage(callId: UUID(), signal: .invite)
        stream += try sealer.seal(.endToEndContent, try content.seal(.privateCallSignal, invite.encoded))
        stream += try sealer.seal(.endToEndContent, try content.seal(.streamHeader, try StreamHeader(width: 640, height: 360, fps: 15, codecId: StreamProtocol.codecVP9, includeAudio: true).encoded()))
        let config = MediaPacket(flags: StreamProtocol.flagAudio | StreamProtocol.flagCodecConfig, presentationTimeUs: 0, payload: OpusHead.make())
        stream += try sealer.seal(.endToEndContent, try content.seal(.mediaPacket, flags: config.flags, config.encoded))
        let audio = MediaPacket(flags: StreamProtocol.flagAudio, presentationTimeUs: 20_000, payload: Data([0xfc, 1, 2, 3]))
        stream += try sealer.seal(.endToEndContent, try content.seal(.mediaPacket, flags: audio.flags, audio.encoded))
        let out: [String: String] = [
            "swiftLinkHello": try linkHello.encoded().hex, "swiftEndpointHello": try endpointHello.encoded().hex,
            "swiftBms1Stream": stream.hex, "swiftBms1Key": linkKey.withUnsafeBytes { Data($0) }.hex,
            "swiftBme1Key": contentKey.withUnsafeBytes { Data($0) }.hex,
        ]
        guard let path = ProcessInfo.processInfo.environment["NEARBY_TRANSCRIPT_OUT"] else { return }
        try JSONSerialization.data(withJSONObject: out, options: [.prettyPrinted, .sortedKeys]).write(to: URL(fileURLWithPath: path))
    }

    func testCallVideoFragmentsMatchAndroid() throws {
        let packet = try hex("fragmentedPacket")
        let fragments = try XCTUnwrap(json["fragments"] as? [String]).map { Data(hex: $0)! }
        XCTAssertEqual(try CallVideoFragments.split(packet), fragments)
        var reassembler = CallVideoReassembler()
        var result: Data?
        for f in fragments { result = try reassembler.accept(flags: StreamProtocol.flagKeyFrame, fragment: f) }
        XCTAssertEqual(result, packet)
        var fresh = CallVideoReassembler()
        XCTAssertThrowsError(try fresh.accept(flags: StreamProtocol.flagKeyFrame, fragment: fragments[1]))
    }
}
