import Foundation
import CoreBluetooth
import NearbyCore
#if canImport(DesktopSupport)
import DesktopSupport
#endif

/// An ordered, reliable byte pipe to one Bluetooth peer (LE L2CAP CoC or Android-framed GATT).
/// All methods run on the main queue, like Core Bluetooth's delegate callbacks in this app.
protocol MeshLink: AnyObject {
    var transport: MeshTransport { get }
    var label: String { get }
    var onBytes: ((Data) -> Void)? { get set }
    var onClosed: ((String) -> Void)? { get set }
    var onWritable: (() -> Void)? { get set }
    /// Bytes accepted by `send` but not yet handed to Core Bluetooth / the stream.
    var queuedBytes: Int { get }
    #if os(macOS)
    var logFields: [String: String] { get }
    #endif
    func send(_ data: Data)
    func close()
}

#if os(macOS)
extension MeshLink {
    var logFields: [String: String] { ["transportQueuedBytes": "\(queuedBytes)"] }
}
#endif

/// GATT lost-chunk fail-fast (Android ChunkGapPolicy, `test_gatt_gap_fast_fail`, on): a gap held 1 s or behind 128
/// later chunks ends the link with its reason. Control arm for tests only: launch argument `-gattGapFastFail NO`.
enum GattLinkSettings {
    static var gapFastFail: Bool { UserDefaults.standard.object(forKey: "gattGapFastFail") as? Bool ?? true }
}

/// A link whose reads can stop while the engine holds input (call relay backpressure). An LE credit-based channel
/// then stops granting credits, which slows the sender; a GATT peer cannot be slowed (the engine bounds what it holds).
protocol PausableMeshLink: MeshLink {
    var readingPaused: Bool { get set }
}

/// LE credit-based channel: raw stream bytes both ways (no extra framing on Android CoC).
final class L2CAPLink: NSObject, PausableMeshLink, StreamDelegate {
    let transport = MeshTransport.l2cap
    let label: String
    var onBytes: ((Data) -> Void)?
    var onClosed: ((String) -> Void)?
    var onWritable: (() -> Void)?
    private let channel: CBL2CAPChannel
    private let writer = OrderedWriter(limit: 4 * 1024 * 1024)
    private var readBuffer = [UInt8](repeating: 0, count: 16_384)
    private var closed = false
    /// Keeps the owning connection (central side) alive for the channel's lifetime.
    var onRelease: (() -> Void)?
    var queuedBytes: Int { writer.queuedBytes }
    var readingPaused = false {
        didSet {
            guard oldValue, !readingPaused else { return }
            // Bytes that arrived while paused raised no new event: read them now, outside the caller's stack.
            DispatchQueue.main.async { [weak self] in self?.readAvailable() }
        }
    }

    init(channel: CBL2CAPChannel, label: String) {
        self.channel = channel; self.label = label
        super.init()
        for stream in [channel.inputStream as Stream, channel.outputStream as Stream] {
            stream.delegate = self; stream.schedule(in: .main, forMode: .common); stream.open()
        }
    }

    func send(_ data: Data) {
        guard !closed else { return }
        do { try writer.enqueue(data, now: ProcessInfo.processInfo.systemUptime); try drain() }
        catch { fail("L2CAP send failed: \(error)") }
    }

    private func drain() throws {
        try writer.drain { data in
            guard !closed, channel.outputStream.hasSpaceAvailable else { return 0 }
            return data.withUnsafeBytes { raw in channel.outputStream.write(raw.bindMemory(to: UInt8.self).baseAddress!, maxLength: raw.count) }
        }
    }

    func stream(_ aStream: Stream, handle eventCode: Stream.Event) {
        guard !closed else { return }
        switch eventCode {
        case .hasBytesAvailable:
            readAvailable()
        case .hasSpaceAvailable:
            do { try drain(); onWritable?() } catch { fail("L2CAP write failed") }
        case .errorOccurred: fail(aStream.streamError?.localizedDescription ?? "L2CAP stream error")
        case .endEncountered: fail("L2CAP channel closed by the peer")
        default: break
        }
    }

    private func readAvailable() {
        while !closed && !readingPaused && channel.inputStream.hasBytesAvailable {
            let count = channel.inputStream.read(&readBuffer, maxLength: readBuffer.count)
            if count < 0 { fail(channel.inputStream.streamError?.localizedDescription ?? "L2CAP read error"); return }
            if count == 0 { fail("L2CAP channel closed by the peer"); return }
            onBytes?(Data(readBuffer[0..<count]))
        }
    }

    private func fail(_ reason: String) { guard !closed else { return }; shutdown(); onClosed?(reason) }

    func close() { guard !closed else { return }; shutdown() }

    private func shutdown() {
        closed = true; writer.cancel()
        for stream in [channel.inputStream as Stream, channel.outputStream as Stream] {
            stream.delegate = nil; stream.close(); stream.remove(from: .main, forMode: .common)
        }
        onRelease?(); onRelease = nil
    }
}

/// Android GATT byte stream as a central: writes to c8d5a103 without response, notifications on c8d5a104.
final class GattClientLink: MeshLink {
    let transport = MeshTransport.gatt
    let label: String
    var onBytes: ((Data) -> Void)?
    var onClosed: ((String) -> Void)?
    var onWritable: (() -> Void)?
    let peripheral: CBPeripheral
    private let write: CBCharacteristic
    private var chunker = GattChunkWriter()
    private var reader = GattChunkReader(failFast: GattLinkSettings.gapFastFail)
    private var gapCheckScheduled = false
    private var pending: [Data] = []
    private var pendingBytes = 0
    private var closed = false
    #if os(macOS)
    private var inputValues = 0
    private var lastInputAt: TimeInterval?
    var logFields: [String: String] {
        ["transportQueuedBytes": "\(queuedBytes)", "gattInputValues": "\(inputValues)",
         "gattNextInputSequence": "\(reader.nextSequence)",
         "gattInputIdleMs": lastInputAt.map { "\(Int((ProcessInfo.processInfo.systemUptime - $0) * 1000))" } ?? "none"]
    }
    #endif
    var onRelease: (() -> Void)?
    var queuedBytes: Int { pendingBytes }

    init(peripheral: CBPeripheral, write: CBCharacteristic, label: String) {
        self.peripheral = peripheral; self.write = write; self.label = label
    }

    func send(_ data: Data) {
        guard !closed else { return }
        let limit = peripheral.maximumWriteValueLength(for: .withoutResponse)
        for value in chunker.chunks(data, valueLimit: limit) { pending.append(value); pendingBytes += value.count }
        pump()
    }

    func pump() {
        while !closed, let value = pending.first, peripheral.canSendWriteWithoutResponse {
            peripheral.writeValue(value, for: write, type: .withoutResponse)
            pending.removeFirst(); pendingBytes -= value.count
        }
        if pending.isEmpty { onWritable?() }
    }

    func received(_ value: Data) {
        guard !closed else { return }
        #if os(macOS)
        inputValues += 1; lastInputAt = ProcessInfo.processInfo.systemUptime
        #endif
        do { let bytes = try reader.accept(value); if !bytes.isEmpty { onBytes?(bytes) } }
        catch { fail("GATT input: \(error)"); return }
        scheduleGapCheck()
    }

    /// ChunkGapPolicy: a gap that nothing else fills ends the stream when its 1 s passes, not 8 s later.
    private func scheduleGapCheck() {
        guard let opened = reader.gapOpenedAt, !gapCheckScheduled else { return }
        gapCheckScheduled = true
        let wait = max(0, opened + ChunkGapPolicy.gapSeconds - ProcessInfo.processInfo.systemUptime) + 0.01
        DispatchQueue.main.asyncAfter(deadline: .now() + wait) { [weak self] in
            guard let self, !self.closed else { return }
            self.gapCheckScheduled = false
            do { try self.reader.check(now: ProcessInfo.processInfo.systemUptime) } catch { self.fail("GATT input: \(error)"); return }
            self.scheduleGapCheck()
        }
    }

    func fail(_ reason: String) { guard !closed else { return }; shutdown(); onClosed?(reason) }
    func close() { guard !closed else { return }; shutdown() }
    private func shutdown() { closed = true; pending.removeAll(); pendingBytes = 0; onRelease?(); onRelease = nil }
}

/// Android GATT byte stream as a peripheral (iPhone hosts c8d5a105): central writes in, notifications out.
final class GattServerLink: MeshLink {
    let transport = MeshTransport.gatt
    let label: String
    var onBytes: ((Data) -> Void)?
    var onClosed: ((String) -> Void)?
    var onWritable: (() -> Void)?
    let central: CBCentral
    private let manager: CBPeripheralManager
    private let notify: CBMutableCharacteristic
    private var chunker = GattChunkWriter()
    private var reader = GattChunkReader(failFast: GattLinkSettings.gapFastFail)
    private var gapCheckScheduled = false
    private var pending: [Data] = []
    private var pendingBytes = 0
    private var closed = false
    #if os(macOS)
    private var inputValues = 0
    private var lastInputAt: TimeInterval?
    var logFields: [String: String] {
        ["transportQueuedBytes": "\(queuedBytes)", "gattInputValues": "\(inputValues)",
         "gattNextInputSequence": "\(reader.nextSequence)",
         "gattInputIdleMs": lastInputAt.map { "\(Int((ProcessInfo.processInfo.systemUptime - $0) * 1000))" } ?? "none"]
    }
    #endif
    var onRelease: (() -> Void)?
    var queuedBytes: Int { pendingBytes }

    init(central: CBCentral, manager: CBPeripheralManager, notify: CBMutableCharacteristic, label: String) {
        self.central = central; self.manager = manager; self.notify = notify; self.label = label
    }

    func send(_ data: Data) {
        guard !closed else { return }
        for value in chunker.chunks(data, valueLimit: central.maximumUpdateValueLength) { pending.append(value); pendingBytes += value.count }
        pump()
    }

    func pump() {
        while !closed, let value = pending.first {
            guard manager.updateValue(value, for: notify, onSubscribedCentrals: [central]) else { return }
            pending.removeFirst(); pendingBytes -= value.count
        }
        if pending.isEmpty { onWritable?() }
    }

    func received(_ value: Data) {
        guard !closed else { return }
        #if os(macOS)
        inputValues += 1; lastInputAt = ProcessInfo.processInfo.systemUptime
        #endif
        do { let bytes = try reader.accept(value); if !bytes.isEmpty { onBytes?(bytes) } }
        catch { fail("GATT input: \(error)"); return }
        scheduleGapCheck()
    }

    /// ChunkGapPolicy: a gap that nothing else fills ends the stream when its 1 s passes, not 8 s later.
    private func scheduleGapCheck() {
        guard let opened = reader.gapOpenedAt, !gapCheckScheduled else { return }
        gapCheckScheduled = true
        let wait = max(0, opened + ChunkGapPolicy.gapSeconds - ProcessInfo.processInfo.systemUptime) + 0.01
        DispatchQueue.main.asyncAfter(deadline: .now() + wait) { [weak self] in
            guard let self, !self.closed else { return }
            self.gapCheckScheduled = false
            do { try self.reader.check(now: ProcessInfo.processInfo.systemUptime) } catch { self.fail("GATT input: \(error)"); return }
            self.scheduleGapCheck()
        }
    }

    func fail(_ reason: String) { guard !closed else { return }; shutdown(); onClosed?(reason) }
    func close() { guard !closed else { return }; shutdown() }
    private func shutdown() { closed = true; pending.removeAll(); pendingBytes = 0; onRelease?(); onRelease = nil }
}

/// Binds one sans-I/O engine to one link: pushes received bytes in, pulls sealed records out while the
/// link has little queued (so priority is decided late), runs timers and closes after a graceful finish.
final class ConnectionDriver {
    let engine: MeshConnection
    let link: MeshLink
    private var timer: Timer?
    private var closing = false
    #if os(macOS)
    private var lastTickAt: TimeInterval?
    private var maxTickGapMs = 0
    #endif
    var onFinished: ((String) -> Void)?
    static let lowWater = 4_096

    deinit {
        #if os(macOS)
        // The owner can leave while a graceful transport drain is blocked. Release its radio slot
        // and run-loop timer even when there will be no further writable callback.
        timer?.invalidate()
        link.onBytes = nil; link.onWritable = nil; link.onClosed = nil
        link.close()
        #endif
    }

    init(engine: MeshConnection, link: MeshLink) {
        self.engine = engine; self.link = link
        link.onBytes = { [weak self] data in
            guard let self else { return }
            self.engine.receive(data, now: Self.now); self.pump()
        }
        link.onWritable = { [weak self] in self?.pump() }
        link.onClosed = { [weak self] reason in
            guard let self else { return }
            AppLog.event("link_closed", ["link": self.link.label, "reason": reason, "rxBytes": "\(self.engine.receivedBytes)", "txBytes": "\(self.engine.sentBytes)"])
            self.engine.linkLost(reason); self.finish(reason)
        }
    }

    static var now: TimeInterval { ProcessInfo.processInfo.systemUptime }

    #if os(macOS)
    var logFields: [String: String] {
        var fields = link.logFields
        fields["linkReceiveIdleMs"] = "\(Int((Self.now - engine.lastReceiveAt) * 1000))"
        fields["linkSendIdleMs"] = "\(Int((Self.now - engine.lastSendAt) * 1000))"
        fields["connectionTickIdleMs"] = lastTickAt.map { "\(Int((Self.now - $0) * 1000))" } ?? "none"
        fields["connectionMaxTickGapMs"] = "\(maxTickGapMs)"
        return fields
    }
    #endif

    func start() {
        do { try engine.start(now: Self.now) } catch { engine.fail("\(error)") }
        pump()
        #if os(macOS)
        // A synchronous setup/send failure may already have finished the driver in pump().
        guard !closing else { return }
        #endif
        let tick: (Timer) -> Void = { [weak self] _ in
            guard let self else { return }
            let now = Self.now
            #if os(macOS)
            if let last = self.lastTickAt { self.maxTickGapMs = max(self.maxTickGapMs, Int((now - last) * 1000)) }
            self.lastTickAt = now
            #endif
            self.engine.tick(now: now); self.pump()
        }
        #if os(macOS)
        lastTickAt = Self.now
        timer = DesktopConnectionTimer.schedule(tick: tick)
        #else
        if UserDefaults.standard.bool(forKey: "NearbyDefaultModeLinkTimer") {
            // Control arm: the old default-mode timer, which pauses while a scroll or held control tracks touches.
            timer = Timer.scheduledTimer(withTimeInterval: 0.1, repeats: true, block: tick)
        } else {
            // Common modes keep link liveness running during UI tracking, as on the Mac (DesktopConnectionTimer).
            let linkTimer = Timer(timeInterval: 0.1, repeats: true, block: tick)
            RunLoop.main.add(linkTimer, forMode: .common)
            timer = linkTimer
        }
        #endif
    }

    func pump() {
        guard !closing else { return }
        guard !releaseFailedEngine() else { return }
        // Stop reading while the engine holds input (call relay backpressure); resume once it parsed it.
        if let pausable = link as? PausableMeshLink, pausable.readingPaused != engine.ingressHeld {
            pausable.readingPaused = engine.ingressHeld
        }
        while link.queuedBytes < Self.lowWater, let bytes = engine.nextOutgoing(now: Self.now) {
            link.send(bytes)
            #if os(macOS)
            guard !closing else { return }
            #endif
        }
        // Sealing or send() can synchronously fail after the initial check.
        guard !releaseFailedEngine() else { return }
        if engine.phase == .closed && !engine.hasPendingOutput && link.queuedBytes == 0 {
            closing = true
            // Give the final record (hang-up, END_ACK, route ack) time to reach the peer, as Android waits for it.
            let reason = engine.closeReason ?? "Closed"
            DispatchQueue.main.asyncAfter(deadline: .now() + (engine.closeReason == nil ? 0 : 1.5)) { [weak self] in
                self?.link.close(); self?.finish(reason)
            }
        }
    }

    /// A fatal engine close (an error, a missed deadline such as the Invite deadline) releases the transport at once,
    /// even when its queue is blocked: nothing more will be sent on it.
    private func releaseFailedEngine() -> Bool {
        guard engine.phase == .closed, engine.closedWithError else { return false }
        closing = true
        link.close()
        finish(engine.closeReason ?? "Closed")
        return true
    }

    private func finish(_ reason: String) {
        #if os(macOS)
        closing = true
        link.onBytes = nil; link.onWritable = nil; link.onClosed = nil
        #endif
        timer?.invalidate(); timer = nil
        let callback = onFinished; onFinished = nil
        callback?(reason)
    }

    func cancel() { engine.finish("Stopped", error: false); timer?.invalidate(); timer = nil; link.close(); finish("Stopped") }
}
