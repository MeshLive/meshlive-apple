import Foundation
import CoreBluetooth
import NearbyCore

/// Main-run-loop stream owner. No transport work occurs on audio callbacks.
final class L2CAPStream: NSObject, StreamDelegate {
    private let channel: CBL2CAPChannel
    let writer = OrderedWriter()
    private var decoder = FrameDecoder()
    private var readBuffer = [UInt8](repeating: 0, count: 16_384)
    private var closed = false
    var onRecord: ((Data) -> Void)?
    var onFailure: ((String) -> Void)?
    var receivedBytes: UInt64 = 0
    init(channel: CBL2CAPChannel) {
        self.channel = channel; super.init()
        channel.inputStream.delegate = self; channel.outputStream.delegate = self
        channel.inputStream.schedule(in: .main, forMode: .common)
        channel.outputStream.schedule(in: .main, forMode: .common)
        channel.inputStream.open(); channel.outputStream.open()
    }
    func send(_ framed: Data, tag: UInt64, now: TimeInterval) throws {
        guard !closed else { throw ProtocolError.state("L2CAP channel closed") }
        try writer.enqueue(framed, tag: tag, now: now); try drain()
    }
    private func drain() throws {
        try writer.drain { [self] data in
            guard !closed, channel.outputStream.hasSpaceAvailable else { return 0 }
            return data.withUnsafeBytes { raw in
                channel.outputStream.write(raw.bindMemory(to: UInt8.self).baseAddress!, maxLength: raw.count)
            }
        }
    }
    func stream(_ aStream: Stream, handle eventCode: Stream.Event) {
        guard !closed else { return }
        do {
            switch eventCode {
            case .hasBytesAvailable:
                while !closed && channel.inputStream.hasBytesAvailable {
                    let count = channel.inputStream.read(&readBuffer, maxLength: readBuffer.count)
                    if count < 0 { throw ProtocolError.state(channel.inputStream.streamError?.localizedDescription ?? "L2CAP read error") }
                    if count == 0 { fail("L2CAP EOF"); return }
                    receivedBytes += UInt64(count)
                    for record in try decoder.feed(Data(readBuffer.prefix(count))) { onRecord?(record); if closed { return } }
                }
            case .hasSpaceAvailable: try drain()
            case .errorOccurred: fail(aStream.streamError?.localizedDescription ?? "L2CAP stream error")
            case .endEncountered: fail("L2CAP EOF")
            default: break
            }
        } catch { fail(String(describing: error)) }
    }
    private func fail(_ reason: String) { guard !closed else { return }; close(); onFailure?(reason) }
    func close() {
        guard !closed else { return }; closed = true; writer.cancel()
        for stream in [channel.inputStream as Stream, channel.outputStream as Stream] {
            stream.delegate = nil; stream.close(); stream.remove(from: .main, forMode: .common)
        }
    }
    deinit { close() }
}
