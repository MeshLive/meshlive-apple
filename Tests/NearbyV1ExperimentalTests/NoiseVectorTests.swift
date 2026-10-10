import XCTest
import CryptoKit
@testable import NearbyCore
@testable import NearbyV1Experimental

final class NoiseVectorTests: XCTestCase {
    func testOversizedNoisePayloadIsRejectedBeforeAdvancingHandshake() throws {
        let peer = Curve25519.KeyAgreement.PrivateKey()
        let receiver = NoiseXX(role: .responder, identity: .init(), prologue: Data())
        let malformed = peer.publicKey.rawRepresentation + Data(repeating: 7, count: 257)
        XCTAssertThrowsError(try receiver.read(malformed))
        XCTAssertFalse(receiver.complete)
    }
    // Independent known-answer vector from rweather/noise-c (MIT); see Vendor/NOISE-C-COPYING.
    // https://github.com/rweather/noise-c/blob/master/tests/vector/noise-c-basic.txt
    func testPublishedNoiseXXKnownAnswerVector() throws {
        func bytes(_ hex: String) -> Data {
            var result = Data(); var cursor = hex.startIndex
            while cursor < hex.endIndex { let end = hex.index(cursor, offsetBy: 2); result.append(UInt8(hex[cursor..<end], radix: 16)!); cursor = end }; return result
        }
        func key(_ hex: String) throws -> Curve25519.KeyAgreement.PrivateKey { try .init(rawRepresentation: bytes(hex)) }
        let prologue = bytes("50726f6c6f677565313233")
        let a = NoiseXX(role: .initiator, identity: try key("e61ef9919cde45dd5f82166404bd08e38bceb5dfdfded0a34c8df7ed542214d1"), prologue: prologue, ephemeral: try key("893e28b9dc6ca8d611ab664754b8ceb7bac5117349a4439a6b0569da977c464a"))
        let b = NoiseXX(role: .responder, identity: try key("4a3acbfdb163dec651dfa3194dece676d437029c62a408b4c5ea9114246e4893"), prologue: prologue, ephemeral: try key("bbdb4cdbd309f1a1f2e1456967fe288cadd6f712d65dc7b7793d5e63da6b375b"))
        let payloads = ["4c756477696720766f6e204d69736573","4d757272617920526f746862617264","462e20412e20486179656b"]
        let ciphertexts = [
            "ca35def5ae56cec33dc2036731ab14896bc4c75dbb07a61f879f8e3afa4c79444c756477696720766f6e204d69736573",
            "95ebc60d2b1fa672c1f46a8aa265ef51bfe38e7ccb39ec5be34069f14480884381cbad1f276e038c48378ffce2b65285e08d6b68aaa3629a5a8639392490e5b94a6d8798832d5372f220f161d9c2df035528f8982ffe09be9b5c412f8a0db5d21351f20af1370d0bf8ef1a8c59a30e",
            "c7195ffacac1307ff99046f219750fc47693e23c3cb08b89c2af808b444850a8589981dfbd651e6ff4724a781cc2aa6158c9fea0d4ec82a286427484c5b8c8123a7a6002b1de9f9775fc97"
        ]
        for i in 0..<3 {
            let sender = i == 1 ? b : a, receiver = i == 1 ? a : b
            let result = try sender.write(payload: bytes(payloads[i])); XCTAssertEqual(result, bytes(ciphertexts[i]))
            XCTAssertEqual(try receiver.read(result), bytes(payloads[i]))
        }
        let hash = bytes("852a28d2146785c54bd8334f4e460c80d7fe4fd0cc5bc0abef2a24a3c4d44d5f")
        XCTAssertEqual(a.hash, hash); XCTAssertEqual(b.hash, hash)
        let aKeys = try a.split(), bKeys = try b.split()
        let transportPayloads = ["4361726c204d656e676572", "4a65616e2d426170746973746520536179", "457567656e2042f6686d20766f6e2042617765726b"]
        let transportCiphertexts = ["96763ed773f8e47bb3712f0e29b3060ffc956ffc146cee53d5e1df", "3e40f15f6f3a46ae446b253bf8b1d9ffb6ed9b174d272328ff91a7e2e5c79c07f5", "eb3f3515110702e047a6c9da4478b6ead94873c11c0f2d710ddb3f09fce024b3a58502ae3f"]
        for i in 0..<3 {
            let send = i % 2 == 0 ? bKeys.send : aKeys.send
            let receive = i % 2 == 0 ? aKeys.receive : bKeys.receive
            let result = try send.encrypt(bytes(transportPayloads[i]), ad: Data()); XCTAssertEqual(result, bytes(transportCiphertexts[i]))
            XCTAssertEqual(try receive.decrypt(result, ad: Data()), bytes(transportPayloads[i]))
        }
    }
    func testGeneratedFixtureIncludesMatchingCodesAndAuthenticatedSession() throws {
        let url = Bundle.module.url(forResource: "session-v1", withExtension: "json", subdirectory: "Fixtures")!
        let fixture = try JSONSerialization.jsonObject(with: Data(contentsOf: url)) as! [String: Any]
        let records = fixture["records"] as! [[String: String]]
        func bytes(_ hex: String) -> Data {
            var result = Data(); var cursor = hex.startIndex
            while cursor < hex.endIndex { let end = hex.index(cursor, offsetBy: 2); result.append(UInt8(hex[cursor..<end], radix: 16)!); cursor = end }; return result
        }
        func key(_ field: String) throws -> Curve25519.KeyAgreement.PrivateKey { try .init(rawRepresentation: bytes(fixture[field] as! String)) }
        let capabilities = Capabilities(transport: .gatt, name: "Fixture")
        let a = SecureSession(role: .initiator, identity: try key("initiatorStaticPrivate"), capabilities: capabilities, hostToken: bytes(fixture["hostToken"] as! String), now: 0, ephemeral: try key("initiatorEphemeralPrivate"))
        let b = SecureSession(role: .responder, identity: try key("responderStaticPrivate"), capabilities: capabilities, hostToken: bytes(fixture["hostToken"] as! String), now: 0, ephemeral: try key("responderEphemeralPrivate"))
        var generated: [Data] = []; var codes: [String] = []; var received = ""
        a.onSend = { generated.append($0) }; b.onSend = { generated.append($0) }
        a.onEvent = { if case .verification(let code, _) = $0 { codes.append(code) } }
        b.onEvent = { if case .verification(let code, _) = $0 { codes.append(code) }; if case .text(_, let text) = $0 { received = text } }
        try a.start(now: 0)
        for (i, record) in records.enumerated() {
            let incoming = bytes(record["hex"]!)
            if i == 3 { try a.verify(now: 1); try b.verify(now: 1) }
            if i == 5 { _ = try a.sendText("Fixture hello", now: 2) }
            XCTAssertEqual(generated[i], incoming)
            try (record["from"] == "initiator" ? b : a).receive(incoming, now: 2)
        }
        XCTAssertEqual(codes, fixture["verificationCodes"] as! [String])
        XCTAssertEqual(a.sessionID, bytes(fixture["sessionID"] as! String)); XCTAssertEqual(a.state, .ready); XCTAssertEqual(b.state, .ready)
        XCTAssertEqual(received, "Fixture hello"); XCTAssertEqual(a.applicationBytesAcknowledged, UInt64(received.utf8.count))
    }
}
