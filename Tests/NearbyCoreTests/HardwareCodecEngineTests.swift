import XCTest
@testable import NearbyCore

/// Two engines joined by an in-memory byte pipe (the L2CAP form of `EngineTests`' pipe).
private final class HcPipe {
    let a: MeshConnection, b: MeshConnection
    var now: TimeInterval = 0
    init(_ a: MeshConnection, _ b: MeshConnection) { self.a = a; self.b = b }

    private func move(from: MeshConnection, to: MeshConnection) -> Bool {
        var moved = false
        while let bytes = from.nextOutgoing(now: now) {
            moved = true
            to.receive(bytes, now: now)
        }
        return moved
    }

    func pump(_ rounds: Int = 50) {
        for _ in 0..<rounds {
            let x = move(from: a, to: b)
            let y = move(from: b, to: a)
            if !x && !y { return }
        }
    }

}

/// AB5 step 5: calls and streams with codecs 4 and 5 through the real engines (handshakes, hellos, `BTV3` header, media
/// records): the sender chooses by the peer's signed decode mask, and the receiver's gate passes, drops (with a keyframe
/// request) or closes exactly as PROTOCOL "Access-unit validation" says. The HEVC access units are Android's M31 vectors.
final class HardwareCodecEngineTests: XCTestCase {
    private let vp9 = NodeCapabilities.codecVP9, hevc = NodeCapabilities.codecHEVC, h264 = NodeCapabilities.codecH264
    private let key = StreamProtocol.flagKeyFrame
    private let hevcP = Data(hex: "000000010201d0744e17370529df6a47e361c8a4b469bfbe9bcbd09f9dc77aea8fd571f4d430bf43964c243b")!
    private let settings = CallMediaSettings(width: 352, height: 288, fps: 15, videoBitrate: 300_000)
    private let appleEncoders = [VideoEncoderCandidate(name: "VideoToolbox HEVC", codecId: StreamProtocol.codecHEVC, backend: .hardware),
                                 VideoEncoderCandidate(name: "VideoToolbox H264", codecId: StreamProtocol.codecH264, backend: .hardware),
                                 VideoEncoderCandidate(name: "libvpx VP9", codecId: StreamProtocol.codecVP9, backend: .libvpx)]

    override func setUp() {
        super.setUp()
        StreamProtocol.hevcEnabled = true
        StreamProtocol.h264Enabled = true
    }

    override func tearDown() {
        StreamProtocol.hevcEnabled = false
        StreamProtocol.h264Enabled = false
        super.tearDown()
    }

    /// An Apple caller with both masters on (encode VP9, HEVC, H.264) and a callee that decodes `calleeDecode`.
    private func videoCall(calleeDecode: UInt8, inputs: Bool = true) throws -> (CallEngine, CallEngine, HcPipe) {
        let callerId = SoftwareSigningIdentity(), calleeId = SoftwareSigningIdentity()
        let caller = CallEngine(role: .caller, transport: .l2cap, identity: callerId, requestedType: .video, encodeMask: vp9 | hevc | h264,
                                decodeMask: vp9 | hevc | h264, settings: settings, expectedPeerPrefix: calleeId.nodeId.prefix)
        if inputs { caller.codecChoiceInputs = CallCodecInputs(encoders: appleEncoders, switches: CodecChoiceSwitches(hevc: true, h264: true)) }
        let callee = CallEngine(role: .callee, transport: .l2cap, identity: calleeId, requestedType: .video, encodeMask: vp9,
                                decodeMask: calleeDecode, settings: settings)
        let pipe = HcPipe(caller, callee)
        try caller.start(now: 0); try callee.start(now: 0); pipe.pump()
        try callee.accept(as: .video); pipe.pump()
        return (caller, callee, pipe)
    }

    func testAnHevcCalleeReceivesHevcAndAnOldCalleeReceivesVp9() throws {
        let (caller, _, _) = try videoCall(calleeDecode: vp9 | hevc | h264)
        XCTAssertEqual(caller.selectedCodec, StreamProtocol.codecHEVC)
        XCTAssertEqual(caller.codecChoice?.reason, "hw_hevc_preferred")
        XCTAssertEqual(caller.localHeader?.codecId, StreamProtocol.codecHEVC)
        let (oldCaller, _, _) = try videoCall(calleeDecode: vp9)
        XCTAssertEqual(oldCaller.selectedCodec, StreamProtocol.codecVP9)
        XCTAssertEqual(oldCaller.codecChoice?.reason, "peer_no_hevc_decode")
        // Without choice inputs (both masters off in the app) the two-codec rule picks VP9 exactly as before.
        let (legacy, _, _) = try videoCall(calleeDecode: vp9 | hevc, inputs: false)
        XCTAssertEqual(legacy.selectedCodec, StreamProtocol.codecVP9)
        XCTAssertNil(legacy.codecChoice)
    }

    func testTheCalleePassesValidHevcDropsInvalidOnesWithAKeyFrameRequestAndClosesOnCodecConfig() throws {
        let (caller, callee, pipe) = try videoCall(calleeDecode: vp9 | hevc)
        var videos: [MediaPacket] = [], rejected: [Int] = [], callerEvents: [CallEngine.Event] = []
        callee.onEvent = { if case .remoteVideo(let p) = $0 { videos.append(p) } }
        callee.onAccessUnitRejected = { _, rule, _, _ in rejected.append(rule) }
        caller.onEvent = { callerEvents.append($0) }
        let withSei = AnnexB.annexB([AnnexBTests.vps, AnnexBTests.sps, AnnexBTests.pps, Data(hex: "4e01050280")!, AnnexBTests.idrSlice])
        XCTAssertTrue(caller.sendVideo(flags: key, presentationTimeUs: 1, payload: withSei))
        XCTAssertTrue(caller.sendVideo(flags: 0, presentationTimeUs: 66_667, payload: hevcP))
        pipe.pump()
        XCTAssertEqual(videos.map(\.payload), [AnnexBTests.keyFrame, hevcP], "the SEI is removed before the decoder")
        XCTAssertEqual(videos.first?.isKeyFrame, true)
        // A P frame that claims to be a keyframe is dropped and the caller is asked for a keyframe.
        XCTAssertTrue(caller.sendVideo(flags: key, presentationTimeUs: 133_333, payload: hevcP))
        pipe.pump()
        XCTAssertEqual(videos.count, 2)
        XCTAssertEqual(rejected, [5])
        XCTAssertTrue(callerEvents.contains(.keyFrameRequested))
        XCTAssertNotEqual(callee.phase, .closed)
        // A codec-config video packet on codec 5 ends the call as an unsupported stream.
        XCTAssertTrue(caller.sendVideo(flags: StreamProtocol.flagCodecConfig, presentationTimeUs: 0, payload: Data(hex: "000000014401c0667c0cc640")!))
        pipe.pump()
        XCTAssertEqual(callee.phase, .closed)
        XCTAssertEqual(callee.closeReason, "Unsupported HEVC stream: codec_config")
    }

    func testAStreamViewerGatesHevcFromASourceAndRefusesItWithoutHevcDecode() throws {
        let header = StreamHeader(width: 352, height: 288, fps: 15, codecId: StreamProtocol.codecHEVC, includeAudio: true)
        let source = StreamSourceEngine(transport: .l2cap, identity: SoftwareSigningIdentity(), header: header, expectedViewerPrefix: nil)
        let viewer = StreamViewerEngine(transport: .l2cap, identity: SoftwareSigningIdentity(), decodeMask: vp9 | hevc, expectedAdjacentPrefix: nil)
        var videos: [MediaPacket] = [], rejected: [Int] = []
        viewer.onEvent = { if case .video(let p) = $0 { videos.append(p) } }
        viewer.onAccessUnitRejected = { _, rule, _, _ in rejected.append(rule) }
        let pipe = HcPipe(source, viewer)
        try source.start(now: 0); try viewer.start(now: 0); pipe.pump()
        XCTAssertEqual(viewer.header?.codecId, StreamProtocol.codecHEVC)
        source.sendVideo(flags: key, presentationTimeUs: 0, payload: AnnexBTests.keyFrame)
        source.sendVideo(flags: 0, presentationTimeUs: 66_667, payload: hevcP)
        source.sendVideo(flags: 0, presentationTimeUs: 133_333, payload: AnnexB.annexB([AnnexBTests.pps]) + hevcP)
        pipe.pump()
        XCTAssertEqual(videos.map(\.payload), [AnnexBTests.keyFrame, hevcP])
        XCTAssertEqual(rejected, [5], "a P frame with a parameter set is dropped")
        source.sendVideo(flags: StreamProtocol.flagDiscardable, presentationTimeUs: 200_000, payload: hevcP)
        pipe.pump()
        XCTAssertEqual(viewer.closeReason, "Unsupported HEVC stream: discardable")
        // A viewer without HEVC decode never gets the stream (the source refuses it, as for any codec).
        let blind = StreamViewerEngine(transport: .l2cap, identity: SoftwareSigningIdentity(), decodeMask: vp9, expectedAdjacentPrefix: nil)
        let source2 = StreamSourceEngine(transport: .l2cap, identity: SoftwareSigningIdentity(), header: header, expectedViewerPrefix: nil)
        let pipe2 = HcPipe(source2, blind)
        try source2.start(now: 0); try blind.start(now: 0); pipe2.pump()
        XCTAssertEqual(source2.closeReason, "Final receiver cannot decode the stream codec")
    }
}
