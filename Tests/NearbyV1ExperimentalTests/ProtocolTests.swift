import XCTest
import CryptoKit
@testable import NearbyCore
@testable import NearbyV1Experimental

final class ProtocolTests: XCTestCase {
    func testEveryFrameSplitAndCoalescedInput() throws {
        let records = [Data([1]) + Data(repeating: 7, count: 128), Data([2, 4, 8]), Data([3])]
        let all = try records.reduce(Data()) { try $0 + Wire.frame($1) }
        for split in 0...all.count {
            var decoder = FrameDecoder()
            let a = try decoder.feed(Data(all.prefix(split)))
            let b = try decoder.feed(Data(all.dropFirst(split)))
            XCTAssertEqual(a + b, records); XCTAssertEqual(decoder.bufferedBytes, 0)
        }
        var decoder = FrameDecoder(); var output: [Data] = []
        for byte in all { output += try decoder.feed(Data([byte])) }; XCTAssertEqual(output, records)
    }
    func testMalformedLengthsAndBounds() throws {
        for length: UInt32 in [0, 32769, .max] {
            var w = BinaryWriter(); w.u32(length); var d = FrameDecoder()
            XCTAssertThrowsError(try d.feed(w.data))
        }
        var d = FrameDecoder(); XCTAssertThrowsError(try d.feed(Data(repeating: 0, count: 65536)))
    }
    func testGATTActualLimitsFragmentationAndReplay() throws {
        let frame = try Wire.frame(Data(repeating: 0xBC, count: 2017))
        for limit in [20, 64, 185, 244, 512] {
            var assembler = GATTAssembler(); var frames: [Data] = []
            let chunks = try GATTFragmenter.chunks(frame, id: 0, maximum: limit)
            for chunk in chunks { XCTAssertLessThanOrEqual(chunk.count, limit); if let complete = try assembler.feed(chunk) { frames.append(complete) } }
            XCTAssertEqual(frames, [frame]); XCTAssertThrowsError(try assembler.feed(chunks[0]))
        }
        var a = GATTAssembler(); let chunks = try GATTFragmenter.chunks(frame, id: 0, maximum: 20)
        _ = try a.feed(chunks[0]); XCTAssertThrowsError(try a.feed(chunks[2]))
        XCTAssertThrowsError(try GATTFragmenter.chunks(frame, id: 0, maximum: 9))
    }
    func testOrderedPartialWritesAndBackpressure() throws {
        let writer = OrderedWriter(limit: 64)
        var completed: [UInt64] = []; writer.onComplete = { completed.append($0) }
        try writer.enqueue(Data("abcdef".utf8), tag: 1, now: 0); try writer.enqueue(Data("ghijkl".utf8), tag: 2, now: 1)
        var delivered = Data(); var budget = 5
        try writer.drain { data in let n = min(2, data.count, budget); budget -= n; delivered.append(data.prefix(n)); return n }
        XCTAssertEqual(delivered, Data("abcde".utf8)); XCTAssertEqual(completed, []); XCTAssertEqual(writer.queuedBytes, 7)
        try writer.drain { data in delivered.append(data.prefix(1)); return 1 }
        XCTAssertEqual(delivered, Data("abcdefghijkl".utf8)); XCTAssertEqual(completed, [1, 2]); XCTAssertEqual(writer.queuedBytes, 0)
        try writer.enqueue(Data([1, 2]), now: 2); writer.cancel()
        try writer.drain { _ in XCTFail("Cancelled work wrote bytes"); return 0 }
        XCTAssertThrowsError(try writer.enqueue(Data(repeating: 0, count: 65), now: 3))
    }
    func testWriterErrorsAndGenerationGate() throws {
        let writer = OrderedWriter(); try writer.enqueue(Data([1,2]), now: 0)
        XCTAssertThrowsError(try writer.drain { _ in -1 }); XCTAssertThrowsError(try writer.drain { _ in 3 })
        var gate = AttemptGate(); let old = gate.current; let new = gate.renew()
        XCTAssertFalse(gate.accepts(old)); XCTAssertTrue(gate.accepts(new))
    }
    func testNegotiationRejectsMismatchAndCodec() throws {
        let a = Capabilities(transport: .gatt, opus: true, pcm: false, name: "A")
        let b = Capabilities(transport: .l2cap, opus: true, name: "B")
        XCTAssertThrowsError(try a.negotiate(with: b))
        let pcm = Capabilities(transport: .gatt, name: "C")
        XCTAssertThrowsError(try a.negotiate(with: pcm))
        XCTAssertEqual(try pcm.negotiate(with: pcm).sampleRate, 8000)
        let unicode = Capabilities(transport: .gatt, name: String(repeating: "🔐", count: 20))
        XCTAssertEqual(try Capabilities(decoding: unicode.encoded).name, String(repeating: "🔐", count: 12))
        for malformed in [Data([2,1,2,0,0]), Data([1,1,128,0,0]), Data([1,9,2,0,0]), Data([1,1,2,0,49])] {
            XCTAssertThrowsError(try Capabilities(decoding: malformed))
        }
    }
    func testAudioValidationAndFinalPacket() throws {
        let profile = MediaProfile(codec: .pcmDiagnostic, video: false)
        let packet = AudioPacket(stream: 1, timestamp: 160, final: true, discontinuity: false, validSamples: 43, payload: Data(repeating: 0, count: 320))
        XCTAssertEqual(try AudioPacket(decoding: packet.encoded, profile: profile), packet)
        let invalid = AudioPacket(stream: 1, timestamp: 159, final: false, discontinuity: false, validSamples: 160, payload: packet.payload)
        XCTAssertThrowsError(try AudioPacket(decoding: invalid.encoded, profile: profile))
        let invalidPartial = AudioPacket(stream: 1, timestamp: 160, final: false, discontinuity: false, validSamples: 43, payload: packet.payload)
        XCTAssertThrowsError(try AudioPacket(decoding: invalidPartial.encoded, profile: profile))
        let final = AudioPacket(stream: 1, timestamp: 320, final: true, discontinuity: false, validSamples: 0, payload: Data())
        XCTAssertEqual(try AudioPacket(decoding: final.encoded, profile: profile), final)
    }
    func testJitterClockLimitsUnderrunsAndInterruption() throws {
        var jitter = JitterBuffer(sampleRate: 8000)
        func packet(_ index: UInt64, final: Bool = false, stream: UInt32 = 1) -> AudioPacket {
            AudioPacket(stream: stream, timestamp: index * 160, final: final, discontinuity: index == 0, validSamples: 160, payload: Data(repeating: 0, count: 320))
        }
        try jitter.push(packet(0)); XCTAssertNil(jitter.pop())
        try jitter.push(packet(1)); try jitter.push(packet(2)); XCTAssertEqual(jitter.pop()?.timestamp, 0)
        XCTAssertEqual(jitter.pop()?.timestamp, 160); XCTAssertEqual(jitter.pop()?.timestamp, 320)
        XCTAssertNil(jitter.pop()); XCTAssertEqual(jitter.underruns, 1)
        try jitter.push(packet(3)); XCTAssertEqual(jitter.late, 1)
        jitter.interrupt(); XCTAssertFalse(jitter.running); XCTAssertEqual(jitter.packets.count, 0)
        for index in 0..<14 { try jitter.push(packet(UInt64(index), stream: 2)) }
        XCTAssertEqual(jitter.packets.count, 10); XCTAssertEqual(jitter.overflows, 4); XCTAssertEqual(jitter.pop()?.timestamp, 640)
        XCTAssertThrowsError(try jitter.push(packet(5, stream: 1)))
    }
}

final class SessionTests: XCTestCase {
    private let token = Data(repeating: 0xAF, count: 16)
    private func key(_ value: UInt8) throws -> Curve25519.KeyAgreement.PrivateKey { try .init(rawRepresentation: Data(repeating: value, count: 32)) }
    private func pair(expectedPeer: Data? = nil) throws -> (SecureSession, SecureSession, Exchange) {
        let cap = Capabilities(transport: .gatt, name: "Fixture")
        let a = SecureSession(role: .initiator, identity: try key(1), capabilities: cap, hostToken: token, now: 0, expectedPeer: expectedPeer, ephemeral: try key(3))
        let b = SecureSession(role: .responder, identity: try key(2), capabilities: cap, hostToken: token, now: 0, ephemeral: try key(4))
        let exchange = Exchange(a, b); try a.start(now: 0); try exchange.pump()
        return (a,b,exchange)
    }
    func testHandshakeVerificationAndAcknowledgementsBothDirections() throws {
        let (a,b,e) = try pair(); var codes: [String] = []
        // Deterministic fixture covers identity/ephemeral inputs and transcript.
        XCTAssertEqual(a.state, .verification); XCTAssertEqual(a.sessionID, b.sessionID)
        var events: [SessionEvent] = []; a.onEvent = { events.append($0); if case .verification(let code, _) = $0 { codes.append(code) } }
        XCTAssertThrowsError(try a.sendText("unverified", now: 1))
        try a.verify(now: 1); try e.pump(); XCTAssertEqual(a.state, .verification)
        try b.verify(now: 1); try e.pump(); XCTAssertEqual(a.state, .ready); XCTAssertEqual(b.state, .ready)
        var text = ""; b.onEvent = { if case .text(_, let s) = $0 { text = s } }
        let id = try a.sendText("Hello, independent iPhone", now: 2)
        XCTAssertEqual(a.pendingCount, 1); XCTAssertEqual(a.applicationBytesAcknowledged, 0)
        try e.pump(); XCTAssertEqual(text, "Hello, independent iPhone"); XCTAssertEqual(a.pendingCount, 0)
        XCTAssertTrue(events.contains { if case .acknowledged(let n) = $0 { return n == id }; return false })
        _ = try b.sendText("Reply", now: 3); try e.pump(); XCTAssertEqual(b.applicationBytesAcknowledged, 5)
    }
    func testReplayTamperAndSequenceAreFatal() throws {
        for mode in 0..<3 {
            let (a,b,e) = try pair(); try a.verify(now: 1); try b.verify(now: 1); try e.pump()
            _ = try a.sendText("secret", now: 2); let record = e.queue.removeFirst().1
            if mode == 0 { try b.receive(record, now: 2); XCTAssertThrowsError(try b.receive(record, now: 3)) }
            else {
                var damaged = record; damaged[mode == 1 ? damaged.count - 1 : 26] ^= 1
                XCTAssertThrowsError(try b.receive(damaged, now: 2))
            }
            XCTAssertEqual(b.state, .closed)
        }
    }
    func testWrongPinnedIdentityAndPrologueRejected() throws {
        XCTAssertThrowsError(try pair(expectedPeer: key(9).publicKey.rawRepresentation))
        let cap = Capabilities(transport: .gatt, name: "A")
        let a = SecureSession(role: .initiator, identity: try key(1), capabilities: cap, hostToken: token, now: 0)
        let b = SecureSession(role: .responder, identity: try key(2), capabilities: cap, hostToken: Data(repeating: 0, count: 16), now: 0)
        let e = Exchange(a,b); try a.start(now: 0); XCTAssertThrowsError(try e.pump())
    }
    func testKeepaliveCloseCancellationAndTimeouts() throws {
        let (a,b,e) = try pair(); try a.verify(now: 1); try b.verify(now: 1); try e.pump()
        let id = try a.sendText("Cancel advisory", now: 2); try a.cancelMessage(id, now: 2); try e.pump()
        XCTAssertEqual(a.pendingCount, 0)
        try a.tick(now: 6); try e.pump(now: 6); XCTAssertEqual(a.state, .ready)
        try a.close(reason: "Stop", now: 7); try e.pump(now: 7); XCTAssertEqual(a.state, .closed); XCTAssertEqual(b.state, .closed)
        let (c,_,_) = try pair(); try c.tick(now: 121); XCTAssertEqual(c.state, .closed)
    }
    func testSendFailureAndUnacknowledgedTimeout() throws {
        let (a,b,e) = try pair(); try a.verify(now: 1); try b.verify(now: 1); try e.pump()
        _ = try a.sendText("No remote ACK", now: 2); try a.tick(now: 13); XCTAssertEqual(a.state, .closed)
        let (c,d,f) = try pair(); try c.verify(now: 1); try d.verify(now: 1); try f.pump()
        c.onSend = { _ in throw ProtocolError.limit("Queue full") }
        XCTAssertThrowsError(try c.sendText("Never delivered", now: 2)); XCTAssertEqual(c.state, .closed)
    }
    func testFreshReconnectHasDifferentSessionAndRejectsOldRecord() throws {
        let (a,b,e) = try pair(); try a.verify(now: 1); try b.verify(now: 1); try e.pump(); _ = try a.sendText("Old", now: 2)
        let old = e.queue[0].1
        let cap = Capabilities(transport: .gatt, name: "New")
        let c = SecureSession(role: .initiator, identity: try key(1), capabilities: cap, hostToken: token, now: 3)
        let d = SecureSession(role: .responder, identity: try key(2), capabilities: cap, hostToken: token, now: 3)
        let f = Exchange(c,d); try c.start(now: 3); try f.pump(now: 3); try c.verify(now: 4); try d.verify(now: 4); try f.pump(now: 4)
        XCTAssertNotEqual(c.sessionID, a.sessionID); XCTAssertThrowsError(try d.receive(old, now: 5))
    }
}

private final class Exchange {
    var queue: [(SecureSession, Data)] = []
    init(_ a: SecureSession, _ b: SecureSession) {
        a.onSend = { [weak self, weak b] in if let b { self?.queue.append((b,$0)) } }
        b.onSend = { [weak self, weak a] in if let a { self?.queue.append((a,$0)) } }
    }
    func pump(now: TimeInterval = 2) throws {
        var count = 0
        while !queue.isEmpty { count += 1; guard count < 200 else { throw ProtocolError.state("Fixture loop") }; let next = queue.removeFirst(); try next.0.receive(next.1, now: now) }
    }
}
