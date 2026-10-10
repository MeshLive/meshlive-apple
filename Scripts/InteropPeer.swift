import Foundation
import CryptoKit

// Test-only pipe harness. The production app still uses Core Bluetooth exclusively.
@main enum InteropPeer {
    static func main() throws {
        let args = CommandLine.arguments
        func bytes(_ hex: String) throws -> Data {
            guard hex.count % 2 == 0 else { throw ProtocolError.malformed("Odd hex") }
            var out = Data(); var i = hex.startIndex
            while i < hex.endIndex {
                let end = hex.index(i, offsetBy: 2)
                guard let v = UInt8(hex[i..<end], radix: 16) else { throw ProtocolError.malformed("Invalid hex") }
                out.append(v); i = end
            }
            return out
        }
        func hex(_ b: Data) -> String { b.map { String(format: "%02x", $0) }.joined() }
        func output(_ type: String, _ value: Any) {
            let data = try! JSONSerialization.data(withJSONObject: ["type":type,"value":value], options: [.sortedKeys])
            FileHandle.standardOutput.write(data + Data([10]))
        }
        let role: NoiseXX.Role = args[1] == "initiator" ? .initiator : .responder
        let transport = TransportKind(rawValue: UInt8(args[2])!)!, mask = Int(args[3])!, limit = Int(args[4])!
        var id: UInt32 = 0, assembler = GATTAssembler(), decoder = FrameDecoder()
        let session = SecureSession(role: role, identity: .init(), capabilities: .init(transport: transport, opus: mask & 1 != 0, pcm: mask & 2 != 0, name: "Swift reference"), hostToken: try bytes(args[5]), now: 0)
        session.onSend = { record in
            let frame = try Wire.frame(record)
            let parts: [Data]
            if transport == .gatt { parts = try GATTFragmenter.chunks(frame, id: id, maximum: limit); id += 1 }
            else { parts = [frame] }
            parts.forEach { output("out", hex($0)) }
        }
        session.onEvent = { event in
            switch event {
            case .verification(let code, _): output("verification", code)
            case .ready(let profile): output("ready", hex(profile.encoded))
            case .text(_, let text): output("text", text)
            case .acknowledged(let id): output("ack", id)
            case .cancelled(let id): output("cancel", id)
            case .audio(let packet): output("audio", hex(packet.encoded))
            case .audioCancelled(let stream): output("audioCancel", stream)
            case .closed(let reason): output("closed", reason)
            default: break
            }
        }
        while let line = readLine() {
            do {
                let command = try JSONSerialization.jsonObject(with: Data(line.utf8)) as! [String: Any]
                let now = (command["now"] as? NSNumber)?.doubleValue ?? 2
                switch command["op"] as! String {
                case "start": try session.start(now: now / 1000)
                case "receive":
                    let data = try bytes(command["hex"] as! String)
                    let frame: Data? = transport == .gatt ? try assembler.feed(data) : data
                    if let frame { for record in try decoder.feed(frame) { try session.receive(record, now: now / 1000) } }
                case "verify": try session.verify(now: now / 1000)
                case "text": _ = try session.sendText(command["text"] as! String, now: now / 1000)
                case "audio": try session.sendAudio(AudioPacket(decoding: bytes(command["hex"] as! String), profile: session.profile!), now: now / 1000)
                case "audioCancel": try session.cancelAudio(stream: (command["stream"] as! NSNumber).uint32Value, now: now / 1000)
                case "tick": try session.tick(now: now / 1000)
                case "close": try session.close(reason: "Interop check", now: now / 1000)
                default: throw ProtocolError.state("Unknown harness command")
                }
            } catch { output("error", String(describing: error)) }
            output("done", session.state.rawValue)
        }
    }
}
