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
    /// When a data write last actually left this side (a GATT value written or notification accepted, stream bytes
    /// written), on the system uptime clock; nil before the first. The in-call link renewal's "own writes complete".
    var lastWriteAt: TimeInterval? { get }
    /// CoreBluetooth's per-peer identifier of the remote device (stable for this device's view of the peer while its
    /// address does not change); nil when unknown. Used only as a local rate-limit key, never sent or logged.
    var peerIdentifier: UUID? { get }
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

extension MeshLink {
    var lastWriteAt: TimeInterval? { nil }
}

/// GATT lost-chunk fail-fast (Android ChunkGapPolicy, `test_gatt_gap_fast_fail`, on): a gap held 1 s or behind 128
/// later chunks ends the link with its reason. Control arm for tests only: launch argument `-gattGapFastFail NO`.
enum GattLinkSettings {
    static var gapFastFail: Bool { LabSwitch.read("gattGapFastFail", shipped: true) }
    /// GR1 lost-chunk recovery (Android `gattChunkRecovery`, on since 2026-10-21). Control arm for tests only: launch
    /// argument `-gattChunkRecovery NO` (no history, no type-2 values; the fail-fast alone).
    static var chunkRecovery: Bool { LabSwitch.read("gattChunkRecovery", shipped: true) }
    /// EXPERIMENTAL aligned values (Android `test_gatt_aligned_writes`, off): ATT values of whole 251-octet LE data PDUs
    /// (495 instead of 512). `-gattAlignedValues YES`; read when a link opens.
    static var alignedValues: Bool { LabSwitch.read("gattAlignedValues", shipped: false) }
    /// EXPERIMENTAL client write pacing (`-gattWriteBurst N`, off = 0; DEBUG builds only, as every lab switch): the
    /// central writes at most N data values per 10 ms window (`GattWritePacer`) instead of filling CoreBluetooth's whole
    /// write queue. A full queue delayed the peer's notifications (GR1 NACKs) by 0.5-0.9 s on a Mac -> Android video
    /// call. Read when a client link opens.
    static var writeBurst: Int { storedWriteBurst(in: .standard) }
    static func storedWriteBurst(in store: UserDefaults, debugBuild: Bool = LabSwitch.isDebugBuild) -> Int {
        max(0, LabSwitch.integer("gattWriteBurst", shipped: 0, in: store, debugBuild: debugBuild))
    }
}

/// GR1 for one GATT link: the recovery object, its 50 ms timer, and the shared receive/timer steps.
final class GattLinkRecovery {
    let core: GattChunkRecovery
    private var timer: Timer?
    init(label: String) {
        core = GattChunkRecovery { line in AppLog.event("gatt_recovery", ["detail": line, "link": label]) }
    }
    static func make(label: String) -> GattLinkRecovery? { GattLinkSettings.chunkRecovery ? GattLinkRecovery(label: label) : nil }
    func start(valueLimit: Int, tick: @escaping () -> Void) {
        core.start(valueLimit: valueLimit, now: ProcessInfo.processInfo.systemUptime)
        let t = Timer(timeInterval: Gr1.tick, repeats: true) { _ in tick() }
        RunLoop.main.add(t, forMode: .common); timer = t
    }
    func stop() { timer?.invalidate(); timer = nil; core.close() }
    /// The data sequence of a chunk value this side sent.
    static func sequence(of value: Data) -> UInt32 {
        let v = value.rebased
        return UInt32(v[1]) << 24 | UInt32(v[2]) << 16 | UInt32(v[3]) << 8 | UInt32(v[4])
    }
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
    var peerIdentifier: UUID? { channel.peer?.identifier }
    private let writer = OrderedWriter(limit: 4 * 1024 * 1024)
    private var readBuffer = [UInt8](repeating: 0, count: 16_384)
    private var closed = false
    /// Keeps the owning connection (central side) alive for the channel's lifetime.
    var onRelease: (() -> Void)?
    var queuedBytes: Int { writer.queuedBytes }
    private(set) var lastWriteAt: TimeInterval?
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
            let written = data.withUnsafeBytes { raw in channel.outputStream.write(raw.bindMemory(to: UInt8.self).baseAddress!, maxLength: raw.count) }
            if written > 0 { lastWriteAt = ProcessInfo.processInfo.systemUptime }
            return written
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
    var peerIdentifier: UUID? { peripheral.identifier }
    private let write: CBCharacteristic
    /// EXPERIMENTAL write pacing (`-gattWriteBurst N`, off = 0), read when the link opens.
    private var pacer = GattWritePacer(burst: GattLinkSettings.writeBurst)
    private var chunker = GattChunkWriter()
    private let aligned = GattLinkSettings.alignedValues
    private var reader = GattChunkReader(failFast: GattLinkSettings.gapFastFail)
    private var gapCheckScheduled = false
    private var recovery: GattLinkRecovery?
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
    private(set) var lastWriteAt: TimeInterval?

    /// The notify characteristic this link subscribed to (notifications of another instance on the same peripheral are
    /// not this link's).
    var notifyCharacteristic: CBCharacteristic?
    /// Design SR, offerer over the existing connection: closing this (old) link unsubscribes it but keeps the LE
    /// connection, which the renewed link then uses.
    var keepConnectionOnClose = false
    /// The data service instance this link writes to.
    var service: CBService? { write.service }

    init(peripheral: CBPeripheral, write: CBCharacteristic, label: String) {
        self.peripheral = peripheral; self.write = write; self.label = label
        let limit = peripheral.maximumWriteValueLength(for: .withoutResponse)
        AppLog.event("gatt_values", ["link": "client", "limit": "\(limit)", "value": "\(GattChunk.valueBytes(valueLimit: limit, aligned: aligned))", "aligned": "\(aligned)",
                                     "writeBurst": "\(pacer.burst)"])
        if let recovery = GattLinkRecovery.make(label: "client") {
            self.recovery = recovery; reader.recovery = recovery.core
            recovery.start(valueLimit: peripheral.maximumWriteValueLength(for: .withoutResponse)) { [weak self] in self?.recoveryTick() }
        }
    }

    func send(_ data: Data) {
        guard !closed else { return }
        let limit = peripheral.maximumWriteValueLength(for: .withoutResponse)
        for value in chunker.chunks(data, valueLimit: limit, aligned: aligned) { pending.append(value); pendingBytes += value.count }
        pump()
    }

    func pump() {
        let now = ProcessInfo.processInfo.systemUptime
        while !closed, peripheral.canSendWriteWithoutResponse {
            // GR1 control values and resends go ahead of new data.
            if let control = recovery?.core.nextPriorityValue(now: now) { peripheral.writeValue(control, for: write, type: .withoutResponse); continue }
            guard let value = pending.first else { break }
            // EXPERIMENTAL pacing: at most N data values per 10 ms window, whoever pumps; one resume at a time.
            guard pacer.mayWrite(now: now) else {
                if let delay = pacer.scheduleResume(now: now) {
                    DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
                        guard let self else { return }
                        self.pacer.resumeFired(); self.pump()
                    }
                }
                return
            }
            peripheral.writeValue(value, for: write, type: .withoutResponse)
            pending.removeFirst(); pendingBytes -= value.count
            lastWriteAt = now
            recovery?.core.onDataSent(sequence: GattLinkRecovery.sequence(of: value), value: value, now: now)
        }
        if pending.isEmpty { onWritable?() }
    }

    func received(_ value: Data) {
        guard !closed else { return }
        #if os(macOS)
        inputValues += 1; lastInputAt = ProcessInfo.processInfo.systemUptime
        #endif
        if let recovery, value.first == Gr1.type {
            recovery.core.onControl(value, now: ProcessInfo.processInfo.systemUptime, reader: &reader)
            recoveryTick(); return
        }
        do { let bytes = try reader.accept(value); if !bytes.isEmpty { onBytes?(bytes) } }
        catch { fail("GATT input: \(error)"); return }
        scheduleGapCheck()
        if recovery?.core.hasPriorityValues == true { pump() }
    }

    /// GR1 timer step: HELLO repeat, HIGH, the reader's rounds and deadline, then send what is due.
    private func recoveryTick() {
        guard !closed, let recovery else { return }
        let now = ProcessInfo.processInfo.systemUptime
        recovery.core.tick(now: now)
        do { try reader.check(now: now) } catch { fail("GATT input: \(error)"); return }
        if recovery.core.hasPriorityValues { pump() }
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
    private func shutdown() {
        closed = true; recovery?.stop(); pending.removeAll(); pendingBytes = 0
        if keepConnectionOnClose, let notify = notifyCharacteristic, peripheral.state == .connected { peripheral.setNotifyValue(false, for: notify) }
        onRelease?(); onRelease = nil
    }
}

/// Android GATT byte stream as a peripheral (iPhone hosts c8d5a105): central writes in, notifications out.
final class GattServerLink: MeshLink {
    let transport = MeshTransport.gatt
    let label: String
    var onBytes: ((Data) -> Void)?
    var onClosed: ((String) -> Void)?
    var onWritable: (() -> Void)?
    let central: CBCentral
    var peerIdentifier: UUID? { central.identifier }
    private let manager: CBPeripheralManager
    private let notify: CBMutableCharacteristic
    private var chunker = GattChunkWriter()
    private let aligned = GattLinkSettings.alignedValues
    private var reader = GattChunkReader(failFast: GattLinkSettings.gapFastFail)
    private var gapCheckScheduled = false
    private var recovery: GattLinkRecovery?
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
    private(set) var lastWriteAt: TimeInterval?
    /// Not closed yet (a renewal never takes a central that still holds a live server link).
    var isOpen: Bool { !closed }
    /// Design SR: a renewal connection (its own first HELLO is never a new stream).
    var isRenewal = false
    /// The peer's GR1 HELLO arrived on this link (a later HELLO starts a new stream on the same connection).
    var peerHelloSeen: Bool { recovery?.core.peerHello != nil }

    init(central: CBCentral, manager: CBPeripheralManager, notify: CBMutableCharacteristic, label: String) {
        self.central = central; self.manager = manager; self.notify = notify; self.label = label
        let limit = central.maximumUpdateValueLength
        AppLog.event("gatt_values", ["link": "server", "limit": "\(limit)", "value": "\(GattChunk.valueBytes(valueLimit: limit, aligned: aligned))", "aligned": "\(aligned)"])
        if let recovery = GattLinkRecovery.make(label: "server") {
            self.recovery = recovery; reader.recovery = recovery.core
            recovery.start(valueLimit: central.maximumUpdateValueLength) { [weak self] in self?.recoveryTick() }
        }
    }

    func send(_ data: Data) {
        guard !closed else { return }
        for value in chunker.chunks(data, valueLimit: central.maximumUpdateValueLength, aligned: aligned) { pending.append(value); pendingBytes += value.count }
        pump()
    }

    func pump() {
        let now = ProcessInfo.processInfo.systemUptime
        while !closed {
            // GR1 control values and resends go ahead of new data; a refused one is tried again first.
            if let control = recovery?.core.peekPriorityValue() {
                guard manager.updateValue(control, for: notify, onSubscribedCentrals: [central]) else { return }
                _ = recovery?.core.nextPriorityValue(now: now); continue
            }
            guard let value = pending.first else { break }
            guard manager.updateValue(value, for: notify, onSubscribedCentrals: [central]) else { return }
            pending.removeFirst(); pendingBytes -= value.count
            lastWriteAt = now
            recovery?.core.onDataSent(sequence: GattLinkRecovery.sequence(of: value), value: value, now: now)
        }
        if pending.isEmpty { onWritable?() }
    }

    func received(_ value: Data) {
        guard !closed else { return }
        #if os(macOS)
        inputValues += 1; lastInputAt = ProcessInfo.processInfo.systemUptime
        #endif
        if let recovery, value.first == Gr1.type {
            recovery.core.onControl(value, now: ProcessInfo.processInfo.systemUptime, reader: &reader)
            recoveryTick(); return
        }
        do { let bytes = try reader.accept(value); if !bytes.isEmpty { onBytes?(bytes) } }
        catch { fail("GATT input: \(error)"); return }
        scheduleGapCheck()
        if recovery?.core.hasPriorityValues == true { pump() }
    }

    /// GR1 timer step: HELLO repeat, HIGH, the reader's rounds and deadline, then send what is due.
    private func recoveryTick() {
        guard !closed, let recovery else { return }
        let now = ProcessInfo.processInfo.systemUptime
        recovery.core.tick(now: now)
        do { try reader.check(now: now) } catch { fail("GATT input: \(error)"); return }
        if recovery.core.hasPriorityValues { pump() }
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
    private func shutdown() { closed = true; recovery?.stop(); pending.removeAll(); pendingBytes = 0; onRelease?(); onRelease = nil }
}

/// Binds one sans-I/O engine to one link: pushes received bytes in, pulls sealed records out while the
/// link has little queued (so priority is decided late), runs timers and closes after a graceful finish.
final class ConnectionDriver {
    let engine: MeshConnection
    /// Replaced only by an in-call link renewal (`replaceLink`).
    private(set) var link: MeshLink
    /// Design SR: the engine kept the call after its transport ended (a renewal owns it); nothing is pulled meanwhile.
    private(set) var linkDown = false
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
        guard !detached else { return }
        link.onBytes = nil; link.onWritable = nil; link.onClosed = nil
        link.close()
        #endif
    }

    /// The link moves to another engine (a helper listener's link adopted by a relay duty): this driver stops
    /// without closing it and without reporting a finish.
    private var detached = false
    private var gracefulCloseArmed = false
    func detach() {
        detached = true; closing = true
        timer?.invalidate(); timer = nil
        link.onBytes = nil; link.onWritable = nil; link.onClosed = nil
        onFinished = nil
    }

    /// The driver's monotonic clock (system uptime; a test passes its own).
    private let clock: () -> TimeInterval

    init(engine: MeshConnection, link: MeshLink, clock: @escaping () -> TimeInterval = { ConnectionDriver.now }) {
        self.engine = engine; self.link = link; self.clock = clock
        bind(link)
        // Design SR: "own writes still complete" is the current transport's completed writes, not records handed to it.
        engine.writeProgress = { [weak self] in self?.link.lastWriteAt }
    }

    private func bind(_ link: MeshLink) {
        link.onBytes = { [weak self] data in
            guard let self else { return }
            self.engine.receive(data, now: self.clock()); self.pump()
        }
        link.onWritable = { [weak self] in self?.pump() }
        link.onClosed = { [weak self, weak link] reason in
            guard let self, let link, link === self.link else { return }
            AppLog.event("link_closed", ["link": link.label, "reason": reason, "rxBytes": "\(self.engine.receivedBytes)", "txBytes": "\(self.engine.sentBytes)"])
            self.engine.linkLost(reason)
            // Design SR: a renewal that owns the call keeps it (and this driver's timer) without a transport.
            if self.engine.phase != .closed { self.linkDown = true; return }
            self.finish(reason)
        }
    }

    private func unbind(_ link: MeshLink) { link.onBytes = nil; link.onWritable = nil; link.onClosed = nil }

    /// Design SR, offerer: stops sending on the old link and closes it (the call goes on; nothing is pulled until
    /// `replaceLink`).
    func dropLink() {
        unbind(link); link.close()
        linkDown = true
    }

    /// Design SR: the call's engine now runs on `renewed` (its renewed hop link was adopted); the old link closes and
    /// nothing that still arrives on it is read.
    func replaceLink(_ renewed: MeshLink) {
        let old = link
        unbind(old)
        link = renewed
        bind(renewed)
        linkDown = false
        if old !== renewed { old.close() }
        engine.processBufferedInput(now: clock())
        pump()
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

    /// - Parameter adopted: the engine took over an already authenticated link (no start, parse what it buffered).
    func start(adopted: Bool = false) {
        if adopted { engine.processBufferedInput(now: clock()) }
        else { do { try engine.start(now: clock()) } catch { engine.fail("\(error)") } }
        pump()
        #if os(macOS)
        // A synchronous setup/send failure may already have finished the driver in pump().
        guard !closing else { return }
        #endif
        let tick: (Timer) -> Void = { [weak self] _ in
            guard let self else { return }
            let now = self.clock()
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
        if LabSwitch.read("NearbyDefaultModeLinkTimer", shipped: false) {
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
        if linkDown {
            // A local hang-up during a renewal ends the call here at once (the peer ends at its own bound).
            if engine.phase == .closed { closing = true; finish(engine.closeReason ?? "Closed") }
            return
        }
        // Stop reading while the engine holds input (call relay backpressure); resume once it parsed it.
        if let pausable = link as? PausableMeshLink, pausable.readingPaused != engine.ingressHeld {
            pausable.readingPaused = engine.ingressHeld
        }
        while link.queuedBytes < Self.lowWater, let bytes = engine.nextOutgoing(now: clock()) {
            link.send(bytes)
            #if os(macOS)
            guard !closing else { return }
            #endif
        }
        // Sealing or send() can synchronously fail after the initial check.
        guard !releaseFailedEngine() else { return }
        if engine.phase == .closed && !gracefulCloseArmed {
            // As Android: a local End/Cancel/Decline on a link that no longer drains must still finish
            // (media, the radio slot and advertising come back): the link closes 2.5 s after the end whatever is queued.
            gracefulCloseArmed = true
            DispatchQueue.main.asyncAfter(deadline: .now() + 2.5) { [weak self] in
                guard let self, !self.closing else { return }
                self.closing = true
                AppLog.event("link_closed", ["link": self.link.label, "reason": "end did not drain", "queued": "\(self.link.queuedBytes)"])
                self.link.close(); self.finish(self.engine.closeReason ?? "Closed")
            }
        }
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
