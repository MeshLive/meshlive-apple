import XCTest
import AppKit
import NearbyCore
@testable import DesktopSupport

final class DesktopConnectionTimerTests: XCTestCase {
    private final class Call {
        let mac: CallEngine
        let peer: CallEngine
        var now: TimeInterval = 0

        init() throws {
            let vp9 = NodeCapabilities.codecVP9
            mac = CallEngine(role: .caller, transport: .gatt, identity: SoftwareSigningIdentity(),
                             requestedType: .voice, encodeMask: vp9, decodeMask: vp9)
            peer = CallEngine(role: .callee, transport: .gatt, identity: SoftwareSigningIdentity(),
                              requestedType: .voice, encodeMask: vp9, decodeMask: vp9)
            try mac.start(now: 0); try peer.start(now: 0); pump()
            try peer.accept(as: .voice); pump()
            peer.setMuted(true); mac.setMuted(true); pump()
        }

        func pump() {
            for _ in 0..<80 {
                var moved = false
                while let bytes = mac.nextOutgoing(now: now) { peer.receive(bytes, now: now); moved = true }
                while let bytes = peer.nextOutgoing(now: now) { mac.receive(bytes, now: now); moved = true }
                if !moved { return }
            }
            XCTFail("Call did not settle")
        }

        func advancePeer() { peer.tick(now: now); pump() }
    }

    private func run(_ mode: RunLoop.Mode) {
        // AppKit includes event tracking and modal panels in its common modes. Reproduce that
        // environment in this command-line XCTest process without launching an application.
        CFRunLoopAddCommonMode(CFRunLoopGetMain(), CFRunLoopMode(rawValue: mode.rawValue as CFString))
        let deadline = Date(timeIntervalSinceNow: 0.015)
        while Date() < deadline { _ = RunLoop.main.run(mode: mode, before: deadline) }
    }

    func testMutedCallSurvivesDefaultTrackingAndModalModes() throws {
        XCTAssertTrue(Thread.isMainThread)
        for mode in [RunLoop.Mode.default, .eventTracking, .modalPanel] {
            let call = try Call()
            let timer = DesktopConnectionTimer.schedule(every: 0.001) { _ in
                call.mac.tick(now: call.now); call.pump()
            }
            defer { timer.invalidate() }
            // Only the production timer can tick the Mac. The remote endpoint's independent
            // clock will close the call after eight seconds if Mac heartbeats stop in this mode.
            for second in 1...14 {
                call.now = TimeInterval(second)
                run(mode)
                call.advancePeer()
            }
            XCTAssertEqual(call.peer.state?.phase, .active, "\(mode): \(call.peer.closeReason ?? "")")
            XCTAssertEqual(call.mac.state?.phase, .active, "\(mode): \(call.mac.closeReason ?? "")")
            call.mac.setMuted(false); call.peer.setMuted(false)
            call.mac.sendAudio(presentationTimeUs: 15_000_000, opus: Data([0xfc, 1]))
            call.peer.sendAudio(presentationTimeUs: 15_000_000, opus: Data([0xfc, 2]))
            call.pump()
            XCTAssertEqual(call.peer.receivedAudioPackets, 1, "\(mode)")
            XCTAssertEqual(call.mac.receivedAudioPackets, 1, "\(mode)")
            call.mac.end(); call.pump()
            XCTAssertEqual(call.peer.state?.phase, .ended)
        }
    }

    func testInvalidationStopsHeartbeats() throws {
        let call = try Call()
        let timer = DesktopConnectionTimer.schedule(every: 0.001) { _ in
            call.mac.tick(now: call.now); call.pump()
        }
        timer.invalidate()
        for second in 1...10 {
            call.now = TimeInterval(second)
            run(.eventTracking)
            call.advancePeer()
        }
        XCTAssertEqual(call.peer.phase, .closed)
        XCTAssertEqual(call.peer.closeReason, "Call peer stopped responding")
    }
}
