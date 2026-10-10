import Foundation
import CryptoKit

@main enum Fixture {
    static func main() throws {
        func key(_ v: UInt8) throws -> Curve25519.KeyAgreement.PrivateKey { try .init(rawRepresentation: Data(repeating: v, count: 32)) }
        let cap = Capabilities(transport: .gatt, name: "Fixture")
        let token = Data(repeating: 0xAF, count: 16)
        let a = SecureSession(role: .initiator, identity: try key(1), capabilities: cap, hostToken: token, now: 0, ephemeral: try key(3))
        let b = SecureSession(role: .responder, identity: try key(2), capabilities: cap, hostToken: token, now: 0, ephemeral: try key(4))
        var queue: [(SecureSession, Data)] = []; var records: [[String: String]] = []; var codes: [String] = []
        func hex(_ data: Data) -> String { data.map { String(format: "%02x", $0) }.joined() }
        a.onSend = { records.append(["from":"initiator", "hex":hex($0)]); queue.append((b,$0)) }
        b.onSend = { records.append(["from":"responder", "hex":hex($0)]); queue.append((a,$0)) }
        a.onEvent = { if case .verification(let code, _) = $0 { codes.append(code) } }
        b.onEvent = { if case .verification(let code, _) = $0 { codes.append(code) } }
        func pump() throws { while !queue.isEmpty { let (session, record) = queue.removeFirst(); try session.receive(record, now: 2) } }
        try a.start(now: 0); try pump(); try a.verify(now: 1); try b.verify(now: 1); try pump()
        _ = try a.sendText("Fixture hello", now: 2); try pump()
        let fixture: [String: Any] = ["purpose":"Generated interoperability fixture; test keys only, not a published independent Noise vector", "protocol":"NearbyIntercom/v1", "initiatorStaticPrivate":String(repeating:"01",count:32), "responderStaticPrivate":String(repeating:"02",count:32), "initiatorEphemeralPrivate":String(repeating:"03",count:32), "responderEphemeralPrivate":String(repeating:"04",count:32), "hostToken":hex(token), "sessionID":hex(a.sessionID), "verificationCodes":codes, "records":records]
        let data = try JSONSerialization.data(withJSONObject: fixture, options: [.prettyPrinted,.sortedKeys])
        print(String(decoding: data, as: UTF8.self))
    }
}
