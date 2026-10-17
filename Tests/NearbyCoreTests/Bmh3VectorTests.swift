import XCTest
import CryptoKit
@testable import NearbyCore

/// Replays the byte-exact BMH3 vectors of Android's tools/bmh3_reference.py in both roles (Android Bmh3VectorTest).
final class Bmh3VectorTests: XCTestCase {
    private func bytes(_ hex: String) -> Data { Data(hex: hex)! }

    private func scalar(_ hex: String) -> Data {
        var digits = hex.hasPrefix("0x") ? String(hex.dropFirst(2)) : hex
        while digits.count < 64 { digits = "0" + digits }
        return bytes(digits)
    }

    private final class VectorEntropy: Bmh3Entropy {
        let key: P256.KeyAgreement.PrivateKey, nonceBytes: Data, tag: Data
        var drawn = 0
        init(key: P256.KeyAgreement.PrivateKey, nonce: Data, tag: Data) { self.key = key; nonceBytes = nonce; self.tag = tag }
        func ephemeral() -> P256.KeyAgreement.PrivateKey { drawn += 1; return key }
        func nonce() -> Data { nonceBytes }
        func randomTag() -> Data { tag }
    }

    /// Checks the exact signing input and returns the vector's RFC 6979 signature as DER (a phone signs with a random k).
    private final class VectorIdentity: SigningIdentity {
        let publicKeyEncoded: Data
        let expected: Data, raw: Data
        var signed = 0
        init(spki: Data, expected: Data, raw: Data) { publicKeyEncoded = spki; self.expected = expected; self.raw = raw }
        func sign(_ message: Data) throws -> Data {
            XCTAssertEqual(message.hex, expected.hex, "signing input")
            signed += 1
            return try Bmh3Crypto.rawToDer(raw)
        }
    }

    func testEveryVectorReplaysInBothRolesByteForByte() throws {
        XCTAssertEqual(Bmh3Vectors.all.count, 5)
        for vector in Bmh3Vectors.all {
            let purpose: Bmh3Purpose = vector.purpose == "Link" ? .link : .endToEnd
            let inputs = vector.inputs, trace = vector.trace, m = vector.messages
            let m1 = bytes(m["m1"]!), m2 = bytes(m["m2"]!), m3 = bytes(m["m3"]!)
            let ephI = try P256.KeyAgreement.PrivateKey(rawRepresentation: scalar(inputs["ephemeral_I_scalar"]!))
            let ephR = try P256.KeyAgreement.PrivateKey(rawRepresentation: scalar(inputs["ephemeral_R_scalar"]!))
            XCTAssertEqual(ephI.publicKey.x963Representation, m1.subdata(in: 9..<74), vector.name)
            XCTAssertEqual(ephR.publicKey.x963Representation, m2.subdata(in: 8..<73), vector.name)
            let entropyI = VectorEntropy(key: ephI, nonce: bytes(inputs["nonce_I"]!), tag: bytes(inputs["random_tag_I"]!))
            let entropyR = VectorEntropy(key: ephR, nonce: bytes(inputs["nonce_R"]!), tag: Data(count: 16))
            let identityI = VectorIdentity(spki: bytes(inputs["identity_I_spki"]!),
                                           expected: Bmh3Crypto.signatureContext(purpose, role: "Initiator", transcriptHash: bytes(trace["i_th_sig_I"]!)),
                                           raw: bytes(trace["i_sig_I"]!))
            let identityR = VectorIdentity(spki: bytes(inputs["identity_R_spki"]!),
                                           expected: Bmh3Crypto.signatureContext(purpose, role: "Responder", transcriptHash: bytes(trace["r_th_sig_R"]!)),
                                           raw: bytes(trace["r_sig_R"]!))
            let extI = try Bmh3Extensions.parse(bytes(inputs["extensions_I"]!))
            let extR = try Bmh3Extensions.parse(bytes(inputs["extensions_R"]!))
            XCTAssertEqual(try extI.encodeArea().hex, inputs["extensions_I"]!, vector.name)
            XCTAssertEqual(try extR.encodeArea().hex, inputs["extensions_R"]!, vector.name)
            let capsI = try NodeCapabilities(decoding: bytes(inputs["caps_I"]!))
            let capsR = try NodeCapabilities(decoding: bytes(inputs["caps_R"]!))
            // A pseudonymous vector signs with the throwaway keys: the stranger presentation of a phone whose real key never signs.
            let untouched = SoftwareSigningIdentity()
            let configI = extI.pseudonym
                ? try Bmh3Config(purpose: purpose, identity: untouched, capabilities: capsI, entropy: entropyI, buildTag: extI.buildTag,
                                 stranger: try Bmh3Presentation(identity: identityI, capabilities: capsI, pseudonym: true))
                : try Bmh3Config(purpose: purpose, identity: identityI, capabilities: capsI, entropy: entropyI, buildTag: extI.buildTag)
            let configR = extR.pseudonym
                ? try Bmh3Config(purpose: purpose, identity: untouched, capabilities: capsR, entropy: entropyR, buildTag: extR.buildTag,
                                 stranger: try Bmh3Presentation(identity: identityR, capabilities: capsR, pseudonym: true))
                : try Bmh3Config(purpose: purpose, identity: identityR, capabilities: capsR, entropy: entropyR, buildTag: extR.buildTag)
            let tagKey = inputs["tag_key_I"]!
            let initiator = Bmh3Initiator(config: configI, mayRevealFirst: inputs["may_reveal_first_I"] == "true",
                                          contactTag: tagKey.isEmpty ? nil : try Bmh3ContactTag(key: bytes(tagKey), binding: bytes(inputs["tag_binding_I"]!)),
                                          intent: extI.intent)
            let checks = try inputs["tag_checks_R"]!.split(separator: ",").map { pair -> Bmh3ContactTag in
                let parts = pair.split(separator: ":")
                return try Bmh3ContactTag(key: bytes(String(parts[0])), binding: bytes(String(parts[1])))
            }
            let responder = Bmh3Responder(config: configR, mode: inputs["mode_R"] == "CONTACTS_ONLY" ? .contactsOnly : .everyone,
                                          tagChecks: checks, opening: extR.opening)

            XCTAssertEqual(try initiator.message1().hex, m["m1"], vector.name)
            XCTAssertEqual(try responder.onMessage1(m1).hex, m["m2"], vector.name)
            XCTAssertEqual(try initiator.onMessage2(m2).hex, m["m3"], vector.name)
            let rFirst = vector.order == "R_FIRST"
            XCTAssertEqual(initiator.chosenOrder, rFirst ? .rFirst : .iFirst, vector.name)
            let m4 = try responder.onMessage3(m3)
            if rFirst { XCTAssertNil(m4) } else {
                XCTAssertEqual(m4?.hex, m["m4"], vector.name)
                try initiator.onMessage4(m4!)
            }
            XCTAssertTrue(initiator.isComplete && responder.isComplete, vector.name)
            XCTAssertEqual(entropyI.drawn, 1); XCTAssertEqual(entropyR.drawn, 1)
            let ini = try initiator.finalResult(), res = try responder.finalResult()
            XCTAssertEqual(ini.sendKey.hex, trace["i_app_i2r"], vector.name)
            XCTAssertEqual(ini.receiveKey.hex, trace["i_app_r2i"], vector.name)
            XCTAssertEqual(ini.exporter.hex, trace["i_exporter"], vector.name)
            XCTAssertEqual(ini.sendKey, res.receiveKey); XCTAssertEqual(ini.receiveKey, res.sendKey); XCTAssertEqual(ini.exporter, res.exporter)
            XCTAssertEqual(ini.peer.nodeId.hex, inputs["node_id_R"], vector.name)
            XCTAssertEqual(res.peer.nodeId.hex, inputs["node_id_I"], vector.name)
            XCTAssertEqual(identityI.signed, 1); XCTAssertEqual(identityR.signed, 1)
            XCTAssertEqual(responder.contactTagMatched, !checks.isEmpty && !tagKey.isEmpty, vector.name)
            XCTAssertEqual(ini.peer.buildTag, extR.buildTag, vector.name)
            XCTAssertEqual(res.peer.buildTag, extI.buildTag, vector.name)
            XCTAssertEqual(res.peer.pseudonymous, extI.pseudonym, vector.name)
            XCTAssertEqual(ini.peer.pseudonymous, extR.pseudonym, vector.name)
            XCTAssertEqual(ini.ownPseudonymous, extI.pseudonym, vector.name)
            if !vector.reveal.isEmpty { try replayReveals(vector, ini, res) }

            // The first BMS1 record in each direction (sequence 0 under its own direction key).
            XCTAssertEqual(try SecureRecordSealer(key: SymmetricKey(data: ini.sendKey)).seal(.linkHeartbeat, Data([1])).hex, vector.bms1FirstRecordI2r, vector.name)
            XCTAssertEqual(try SecureRecordSealer(key: SymmetricKey(data: ini.receiveKey)).seal(.linkHeartbeat, Data([1])).hex, vector.bms1FirstRecordR2i, vector.name)
        }
    }

    private func replayReveals(_ vector: Bmh3Vectors.Vector, _ ini: Bmh3Result, _ res: Bmh3Result) throws {
        let reveal = vector.reveal
        XCTAssertEqual(ini.exporter.hex, reveal["exporter"], vector.name)
        let entry = try DiscoveryOpeningCodec.decode(DiscoveryOpeningCodec.magic + Data([1, 1]) + bytes(Bmh3Vectors.OPENING_ENTRY))[0]
        let calleeIdentity = VectorIdentity(spki: bytes(reveal["real_R_spki"]!), expected: bytes(reveal["callee_input"]!), raw: bytes(reveal["callee_sig"]!))
        let callerIdentity = VectorIdentity(spki: bytes(reveal["real_I_spki"]!), expected: bytes(reveal["caller_input"]!), raw: bytes(reveal["caller_sig"]!))
        let callee = try Bmh3Reveal.build(role: 2, real: calleeIdentity, exporter: ini.exporter, ownPseudonymSpki: res.ownSpki,
                                          peerPseudonymSpki: ini.ownSpki, entries: [entry], prior: Data())
        XCTAssertEqual(try DiscoveryExchange.encode(.identityReveal(callee)).hex, reveal["callee"])
        XCTAssertEqual(Bmh3Crypto.sha256(try DiscoveryExchange.encode(.identityReveal(callee))).hex, reveal["callee_record_hash"])
        let caller = try Bmh3Reveal.build(role: 1, real: callerIdentity, exporter: ini.exporter, ownPseudonymSpki: ini.ownSpki,
                                          peerPseudonymSpki: res.ownSpki, entries: [], prior: bytes(reveal["callee_record_hash"]!))
        XCTAssertEqual(try DiscoveryExchange.encode(.identityReveal(caller)).hex, reveal["caller"])
        guard case .identityReveal(let decodedCallee) = try DiscoveryExchange.decode(bytes(reveal["callee"]!)),
              case .identityReveal(let decodedCaller) = try DiscoveryExchange.decode(bytes(reveal["caller"]!)) else {
            return XCTFail("reveal records did not decode")
        }
        let verifiedCallee = try Bmh3Reveal.verify(decodedCallee, expectedRole: 2, exporter: ini.exporter, peerPseudonymSpki: res.ownSpki,
                                                   ownPseudonymSpki: ini.ownSpki, ownSpkis: [ini.ownSpki], prior: Data())
        XCTAssertEqual(verifiedCallee.nodeId.hex, reveal["node_id_real_R"])
        let verifiedCaller = try Bmh3Reveal.verify(decodedCaller, expectedRole: 1, exporter: ini.exporter, peerPseudonymSpki: ini.ownSpki,
                                                   ownPseudonymSpki: res.ownSpki, ownSpkis: [res.ownSpki], prior: bytes(reveal["callee_record_hash"]!))
        XCTAssertEqual(verifiedCaller.nodeId.hex, reveal["node_id_real_I"])
        XCTAssertEqual(calleeIdentity.signed, 1); XCTAssertEqual(callerIdentity.signed, 1)

        // The session state machine in both roles with real keys: order, binding of the callee record, one per direction.
        let realCaller = SoftwareSigningIdentity(), realCallee = SoftwareSigningIdentity()
        let calleeSession = Bmh3RevealSession(localRole: 2, exporter: ini.exporter, ownPseudonymSpki: res.ownSpki, peerPseudonymSpki: ini.ownSpki,
                                              ownPseudonymous: true, peerPseudonymous: true)
        let callerSession = Bmh3RevealSession(localRole: 1, exporter: ini.exporter, ownPseudonymSpki: ini.ownSpki, peerPseudonymSpki: res.ownSpki,
                                              ownPseudonymous: true, peerPseudonymous: true)
        XCTAssertThrowsError(try callerSession.sendOwn(real: realCaller, entries: []))
        XCTAssertTrue(callerSession.peerRevealRequired)
        let calleeRecord = try calleeSession.sendOwn(real: realCallee, entries: [entry])
        guard case .identityReveal(let calleeReveal) = try DiscoveryExchange.decode(calleeRecord) else { return XCTFail() }
        XCTAssertEqual(try callerSession.onPeerReveal(calleeReveal).nodeId, realCallee.nodeId)
        XCTAssertTrue(callerSession.callerMayReveal)
        let callerRecord = try callerSession.sendOwn(real: realCaller, entries: [])
        guard case .identityReveal(let callerReveal) = try DiscoveryExchange.decode(callerRecord) else { return XCTFail() }
        XCTAssertEqual(try calleeSession.onPeerReveal(callerReveal).nodeId, realCaller.nodeId)
        XCTAssertThrowsError(try calleeSession.onPeerReveal(callerReveal), "second reveal")
    }

    func testTheContactTagKeyAndTheDomainsMatchTheReference() throws {
        XCTAssertEqual(try Bmh3Crypto.contactTagKey(leaseKey: bytes(Bmh3Vectors.LEASE_KEY)).hex, Bmh3Vectors.K_TAG)
        XCTAssertEqual(Bmh3Crypto.advertBinding(selected6: bytes(Bmh3Vectors.OPENING_ENTRY).prefix(6), role: 0, wallEpoch: nil).hex, Bmh3Vectors.BINDING)
        XCTAssertEqual(Bmh3Purpose.link.domain.hex, "426c7565746f6f7468566964656f4d6573682f424d48332f4c696e6b")
        XCTAssertEqual(String(decoding: Bmh3Purpose.endToEnd.domain, as: UTF8.self), "BluetoothVideoMesh/BMH3/EndToEnd")
    }

    func testTheWireSizesAreTheSpecifiedOnes() {
        XCTAssertEqual(Bmh3Wire.msg1Bytes, 122)
        XCTAssertEqual(Bmh3Wire.msg2ClearBytes, 105)
        XCTAssertEqual(Bmh3Wire.blockBytes, 310)
        XCTAssertEqual(Bmh3Wire.msg2RFirstBytes, 431)
        XCTAssertEqual(Bmh3Wire.msg3Bytes, 334)
    }

    /// Negative cases of the reference (a subset; each must fail closed).
    func testTamperedMessagesFailClosed() throws {
        func run(mutateM2: ((inout Data) -> Void)? = nil, mutateM3: ((inout Data) -> Void)? = nil, mutateM1: ((inout Data) -> Void)? = nil) throws {
            let caps = NodeCapabilities(transportMask: 4, encodeCodecMask: 1, decodeCodecMask: 1, maxBitrateKbps: 1100, maxChildren: 0)
            let initiator = Bmh3Initiator(config: try Bmh3Config(purpose: .link, identity: SoftwareSigningIdentity(), capabilities: caps))
            let responder = Bmh3Responder(config: try Bmh3Config(purpose: .link, identity: SoftwareSigningIdentity(), capabilities: caps))
            var m1 = try initiator.message1(); mutateM1?(&m1)
            var m2 = try responder.onMessage1(m1); mutateM2?(&m2)
            var m3 = try initiator.onMessage2(m2); mutateM3?(&m3)
            _ = try responder.onMessage3(m3)
        }
        XCTAssertNoThrow(try run())
        XCTAssertThrowsError(try run(mutateM1: { $0[7] ^= 0x02 }), "reserved msg1 flag")
        XCTAssertThrowsError(try run(mutateM1: { $0[5] = 2 }), "link message in the endpoint domain")
        XCTAssertThrowsError(try run(mutateM2: { $0[200] ^= 1 }), "ciphertext bit flip")
        XCTAssertThrowsError(try run(mutateM2: { $0[7] = 0 }), "I_FIRST demanded from an initiator that refuses it")
        XCTAssertThrowsError(try run(mutateM3: { $0[300] ^= 1 }), "msg3 bit flip")
        // Every bit of msg2 flipped once fails.
        for index in stride(from: 0, to: Bmh3Wire.msg2RFirstBytes, by: 37) {
            XCTAssertThrowsError(try run(mutateM2: { $0[index] ^= 0x10 }), "msg2 byte \(index)")
        }
    }

    func testAReplayedMsg1IsRefusedByTheCache() throws {
        let caps = NodeCapabilities(transportMask: 4, encodeCodecMask: 1, decodeCodecMask: 1, maxBitrateKbps: 1100, maxChildren: 0)
        let cache = Bmh3ReplayCache()
        let m1 = try Bmh3Initiator(config: try Bmh3Config(purpose: .link, identity: SoftwareSigningIdentity(), capabilities: caps)).message1()
        let identity = SoftwareSigningIdentity()
        XCTAssertNoThrow(try Bmh3Responder(config: try Bmh3Config(purpose: .link, identity: identity, capabilities: caps), replayCache: cache).onMessage1(m1))
        XCTAssertThrowsError(try Bmh3Responder(config: try Bmh3Config(purpose: .link, identity: identity, capabilities: caps), replayCache: cache).onMessage1(m1))
    }
}
