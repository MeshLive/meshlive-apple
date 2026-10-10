import Foundation
import CoreBluetooth
import NearbyCore

struct NearbyPeer: Identifiable {
    let id: UUID
    let name: String
    let rssi: Int
}

/// Explicit Host/Join roles prevent crossed links. Either selected link carries both directions.
final class BluetoothTransport: NSObject, CBCentralManagerDelegate, CBPeripheralManagerDelegate, CBPeripheralDelegate {
    enum Mode { case host, join }
    let mode: Mode
    let preferred: TransportKind
    private let serviceID = CBUUID(string: Wire.service), infoID = CBUUID(string: Wire.info)
    private let writeID = CBUUID(string: Wire.write), notifyID = CBUUID(string: Wire.notify)
    private var centralManager: CBCentralManager?
    private var peripheralManager: CBPeripheralManager?
    private var candidates: [UUID: CBPeripheral] = [:]
    private var remotePeripheral: CBPeripheral?
    private var remoteCentral: CBCentral?
    private var writeCharacteristic: CBCharacteristic?
    private var notifyCharacteristic: CBCharacteristic?
    private var infoCharacteristic: CBCharacteristic?
    private var localNotify: CBMutableCharacteristic?
    private var psm: CBL2CAPPSM = 0
    private var hostToken = UUID().rawBytes
    private var discovery: DiscoveryInfo?
    private var selected: TransportKind?
    private var bootstrapPending = false
    private var bootstrapWritePending = false
    private var subscribed = false
    private var active = false
    private var finished = false
    private var timeout: Timer?
    private var assembler = GATTAssembler()
    private var frameDecoder = FrameDecoder()
    private let gattWriter = OrderedWriter()
    private var nextRecord: UInt32 = 0
    private var l2cap: L2CAPStream?
    private var gattReceived: UInt64 = 0
    private var advertisingReady = false
    private var publishResolved = false
    private var bootstrapFinished = false
    var onPeers: (([NearbyPeer]) -> Void)?
    var onState: ((String) -> Void)?
    var onReady: ((TransportKind, Data) -> Void)?
    var onRecord: ((Data) -> Void)?
    var onFailure: ((String) -> Void)?
    var onSubmission: ((UInt64) -> Void)?
    var onEvent: ((String, String) -> Void)?
    private var peerRows: [UUID: NearbyPeer] = [:]
    var maximumWrite = 0
    var maximumUpdate = 0
    var queuedBytes: Int { l2cap?.writer.queuedBytes ?? gattWriter.queuedBytes }
    var queueAge: TimeInterval { guard let t = (l2cap?.writer.oldestSubmission ?? gattWriter.oldestSubmission) else { return 0 }; return max(0, ProcessInfo.processInfo.systemUptime - t) }
    var deliveredToSystem: UInt64 { l2cap?.writer.completedBytes ?? gattWriter.completedBytes }
    var receivedBytes: UInt64 { l2cap?.receivedBytes ?? gattReceived }
    var currentPSM: UInt16 { discovery?.psm ?? psm }

    init(mode: Mode, preferred: TransportKind) { self.mode = mode; self.preferred = preferred; super.init() }
    func start() {
        guard !active, !finished else { return }; active = true
        if mode == .host { peripheralManager = CBPeripheralManager(delegate: self, queue: nil) }
        else { centralManager = CBCentralManager(delegate: self, queue: nil) }
        armTimeout(seconds: 120, reason: "Discovery expired; start again")
        onState?("Waiting for Bluetooth")
    }
    func connect(_ id: UUID) {
        guard active, mode == .join, remotePeripheral == nil, let peer = candidates[id], let manager = centralManager, manager.state == .poweredOn else { return }
        remotePeripheral = peer; peer.delegate = self; manager.stopScan()
        onState?("Connecting"); armTimeout(seconds: 15, reason: "Connection/discovery timeout")
        manager.connect(peer, options: nil)
    }
    func send(_ record: Data) throws {
        guard active, selected != nil else { throw ProtocolError.state("Transport not ready") }
        let frame = try Wire.frame(record)
        var tag: UInt64 = UInt64.max
        if record.first == 4, record.count >= 31 { var r = BinaryReader(Data(record.dropFirst(19))); tag = try r.u64() }
        if let l2cap { try l2cap.send(frame, tag: tag, now: ProcessInfo.processInfo.systemUptime); return }
        guard selected == .gatt else { throw ProtocolError.state("L2CAP not open") }
        let limit = mode == .join ? maximumWrite : maximumUpdate
        let chunks = try GATTFragmenter.chunks(frame, id: nextRecord, maximum: limit)
        guard nextRecord < UInt32.max, queuedBytes + chunks.reduce(0, { $0 + $1.count }) <= 131_072 else { throw ProtocolError.limit("Bluetooth queue full") }
        nextRecord += 1
        for (index, chunk) in chunks.enumerated() {
            try gattWriter.enqueue(chunk, tag: index == chunks.count - 1 ? tag : UInt64.max, now: ProcessInfo.processInfo.systemUptime)
        }
        try drainGATT()
    }
    private func drainGATT() throws {
        gattWriter.onComplete = { [weak self] tag in if tag != UInt64.max { self?.onSubmission?(tag) } }
        try gattWriter.drain { [self] chunk in
            guard active else { return 0 }
            if mode == .join {
                guard let peer = remotePeripheral, let characteristic = writeCharacteristic, peer.canSendWriteWithoutResponse else { return 0 }
                peer.writeValue(chunk, for: characteristic, type: .withoutResponse); return chunk.count
            }
            guard let manager = peripheralManager, let characteristic = localNotify, let peer = remoteCentral, subscribed else { return 0 }
            return manager.updateValue(chunk, for: characteristic, onSubscribedCentrals: [peer]) ? chunk.count : 0
        }
    }
    private func sendBootstrapAck() throws {
        guard let manager = peripheralManager, let peer = remoteCentral, let characteristic = localNotify, let selected else { throw ProtocolError.state("Missing bootstrap state") }
        let data = Data([0xA2, 1, selected.rawValue]) + hostToken
        if manager.updateValue(data, for: characteristic, onSubscribedCentrals: [peer]) {
            bootstrapPending = false
            if selected == .gatt { ready(.gatt, token: hostToken) }
        } else { bootstrapPending = true }
    }
    private func ready(_ transport: TransportKind, token: Data) {
        timeout?.invalidate(); timeout = nil
        peripheralManager?.stopAdvertising(); centralManager?.stopScan()
        onState?(transport == .gatt ? "GATT connected" : "LE L2CAP connected")
        onEvent?("transport.ready", transport == .gatt ? "gatt" : "l2cap")
        onReady?(transport, token)
    }
    private func completeJoinBootstrap() {
        guard !bootstrapFinished, !bootstrapWritePending, let selected, let discovery else { return }
        bootstrapFinished = true
        if selected == .l2cap { onState?("Opening L2CAP PSM \(discovery.psm)"); remotePeripheral?.openL2CAPChannel(discovery.psm) }
        else { ready(.gatt, token: discovery.token) }
    }
    private func advertiseIfReady() {
        guard active, advertisingReady, publishResolved else { return }
        peripheralManager?.startAdvertising([CBAdvertisementDataServiceUUIDsKey: [serviceID], CBAdvertisementDataLocalNameKey: "Nearby"])
    }
    private func receiveChunk(_ data: Data) throws {
        gattReceived += UInt64(data.count)
        if let frame = try assembler.feed(data) { for record in try frameDecoder.feed(frame) { onRecord?(record) } }
    }
    private func armTimeout(seconds: TimeInterval, reason: String) {
        timeout?.invalidate(); timeout = Timer.scheduledTimer(withTimeInterval: seconds, repeats: false) { [weak self] _ in self?.fail(reason) }
    }
    private func fail(_ reason: String) {
        guard active else { return }; onEvent?("transport.failure", reason); stop(); onFailure?(reason)
    }
    func stop() {
        guard !finished else { return }; active = false; finished = true
        timeout?.invalidate(); timeout = nil; l2cap?.close()
        gattWriter.cancel(); centralManager?.stopScan()
        if let peer = remotePeripheral { centralManager?.cancelPeripheralConnection(peer); peer.delegate = nil }
        centralManager?.delegate = nil
        if let manager = peripheralManager {
            manager.stopAdvertising()
            if psm != 0, manager.state == .poweredOn { manager.unpublishL2CAPChannel(psm) }
            if manager.state == .poweredOn { manager.removeAllServices() }
            manager.delegate = nil
        }
        remotePeripheral = nil; remoteCentral = nil
        // Preserve bounded counters for diagnostic export after Stop.
    }

    func centralManagerDidUpdateState(_ central: CBCentralManager) {
        guard active, central === centralManager else { return }
        guard central.state == .poweredOn else { if central.state != .unknown { fail("Bluetooth \(central.state.label)") }; return }
        central.scanForPeripherals(withServices: [serviceID], options: [CBCentralManagerScanOptionAllowDuplicatesKey: false])
        onState?("Choose a nearby host")
    }
    func centralManager(_ central: CBCentralManager, didDiscover peripheral: CBPeripheral, advertisementData: [String: Any], rssi RSSI: NSNumber) {
        guard active, central === centralManager, remotePeripheral == nil, candidates.count < 32 || candidates[peripheral.identifier] != nil else { return }
        candidates[peripheral.identifier] = peripheral
        peerRows[peripheral.identifier] = NearbyPeer(id: peripheral.identifier, name: advertisementData[CBAdvertisementDataLocalNameKey] as? String ?? peripheral.name ?? "Nearby host", rssi: RSSI.intValue)
        onPeers?(peerRows.values.sorted { $0.rssi > $1.rssi })
    }
    func centralManager(_ central: CBCentralManager, didConnect peripheral: CBPeripheral) {
        guard active, central === centralManager, peripheral === remotePeripheral else { return }
        onState?("Discovering service"); peripheral.discoverServices([serviceID])
    }
    func centralManager(_ central: CBCentralManager, didFailToConnect peripheral: CBPeripheral, error: Error?) {
        guard active, central === centralManager, peripheral === remotePeripheral else { return }; fail(error?.localizedDescription ?? "Connection failed")
    }
    func centralManager(_ central: CBCentralManager, didDisconnectPeripheral peripheral: CBPeripheral, error: Error?) {
        guard active, central === centralManager, peripheral === remotePeripheral else { return }; fail(error?.localizedDescription ?? "Peer disconnected")
    }
    func peripheral(_ peripheral: CBPeripheral, didDiscoverServices error: Error?) {
        guard active, peripheral === remotePeripheral else { return }
        if let error { fail(error.localizedDescription); return }
        guard let service = peripheral.services?.first(where: { $0.uuid == serviceID }) else { fail("App service missing"); return }
        peripheral.discoverCharacteristics([infoID, writeID, notifyID], for: service)
    }
    func peripheral(_ peripheral: CBPeripheral, didDiscoverCharacteristicsFor service: CBService, error: Error?) {
        guard active, peripheral === remotePeripheral else { return }
        if let error { fail(error.localizedDescription); return }
        infoCharacteristic = service.characteristics?.first { $0.uuid == infoID }
        writeCharacteristic = service.characteristics?.first { $0.uuid == writeID }
        notifyCharacteristic = service.characteristics?.first { $0.uuid == notifyID }
        guard let info = infoCharacteristic, let write = writeCharacteristic, let notify = notifyCharacteristic,
              write.properties.contains(.write), write.properties.contains(.writeWithoutResponse), notify.properties.contains(.notify) else { fail("Required GATT characteristics missing"); return }
        maximumWrite = peripheral.maximumWriteValueLength(for: .withoutResponse)
        guard maximumWrite > GATTFragmenter.headerSize else { fail("GATT write limit too small"); return }
        peripheral.readValue(for: info)
    }
    func peripheral(_ peripheral: CBPeripheral, didUpdateValueFor characteristic: CBCharacteristic, error: Error?) {
        guard active, peripheral === remotePeripheral else { return }
        if let error { fail(error.localizedDescription); return }
        guard let value = characteristic.value else { fail("Empty characteristic value"); return }
        do {
            if characteristic.uuid == infoID {
                discovery = try DiscoveryInfo(decoding: value)
                guard preferred != .l2cap || discovery!.psm != 0 else { throw ProtocolError.incompatible("Host has no published L2CAP channel. Stop and choose GATT explicitly.") }
                onState?("Subscribing to notifications"); peripheral.setNotifyValue(true, for: notifyCharacteristic!)
            } else if characteristic.uuid == notifyID {
                if selected == nil {
                    guard subscribed, let discovery, value == Data([0xA2, 1, preferred.rawValue]) + discovery.token else { throw ProtocolError.malformed("Invalid transport acceptance") }
                    selected = preferred
                    completeJoinBootstrap()
                } else { guard selected == .gatt else { throw ProtocolError.state("GATT data on L2CAP session") }; try receiveChunk(value) }
            }
        } catch { fail(String(describing: error)) }
    }
    func peripheral(_ peripheral: CBPeripheral, didUpdateNotificationStateFor characteristic: CBCharacteristic, error: Error?) {
        guard active, peripheral === remotePeripheral, characteristic.uuid == notifyID else { return }
        if let error { fail(error.localizedDescription); return }
        guard characteristic.isNotifying, let discovery, let write = writeCharacteristic else { fail("Notification subscription failed"); return }
        subscribed = true; bootstrapWritePending = true
        peripheral.writeValue(Data([0xA1, 1, preferred.rawValue]) + discovery.token, for: write, type: .withResponse)
    }
    func peripheral(_ peripheral: CBPeripheral, didWriteValueFor characteristic: CBCharacteristic, error: Error?) {
        guard active, peripheral === remotePeripheral else { return }
        if let error { fail("GATT bootstrap rejected: \(error.localizedDescription)"); return }
        bootstrapWritePending = false
        completeJoinBootstrap()
    }
    func peripheralIsReady(toSendWriteWithoutResponse peripheral: CBPeripheral) {
        guard active, peripheral === remotePeripheral else { return }; do { try drainGATT() } catch { fail(String(describing: error)) }
    }
    func peripheral(_ peripheral: CBPeripheral, didOpen channel: CBL2CAPChannel?, error: Error?) {
        guard active, peripheral === remotePeripheral, selected == .l2cap else { return }
        open(channel, error: error, token: discovery?.token ?? Data())
    }

    func peripheralManagerDidUpdateState(_ peripheral: CBPeripheralManager) {
        guard active, peripheral === peripheralManager else { return }
        guard peripheral.state == .poweredOn else { if peripheral.state != .unknown { fail("Bluetooth \(peripheral.state.label)") }; return }
        let service = CBMutableService(type: serviceID, primary: true)
        let info = CBMutableCharacteristic(type: infoID, properties: [.read], value: nil, permissions: [.readable])
        let write = CBMutableCharacteristic(type: writeID, properties: [.write, .writeWithoutResponse], value: nil, permissions: [.writeable])
        let notify = CBMutableCharacteristic(type: notifyID, properties: [.notify], value: nil, permissions: [])
        localNotify = notify; service.characteristics = [info, write, notify]
        // False is deliberate: application encryption is separate from Bluetooth pairing/link encryption.
        peripheral.publishL2CAPChannel(withEncryption: false); peripheral.add(service)
    }
    func peripheralManager(_ peripheral: CBPeripheralManager, didAdd service: CBService, error: Error?) {
        guard active, peripheral === peripheralManager else { return }
        if let error { fail(error.localizedDescription); return }
        advertisingReady = true
        advertiseIfReady()
    }
    func peripheralManagerDidStartAdvertising(_ peripheral: CBPeripheralManager, error: Error?) {
        guard active, peripheral === peripheralManager else { return }
        if let error { fail(error.localizedDescription); return }; onState?("Hosting — waiting for one peer")
    }
    func peripheralManager(_ peripheral: CBPeripheralManager, didPublishL2CAPChannel PSM: CBL2CAPPSM, error: Error?) {
        guard active, peripheral === peripheralManager else { return }
        publishResolved = true
        if let error { onEvent?("l2cap.publish.failed", error.localizedDescription) }
        else { psm = PSM; onEvent?("l2cap.published", "Dynamic PSM \(PSM)") }
        advertiseIfReady()
    }
    func peripheralManager(_ peripheral: CBPeripheralManager, didReceiveRead request: CBATTRequest) {
        guard active, peripheral === peripheralManager else { return }
        guard request.characteristic.uuid == infoID else { peripheral.respond(to: request, withResult: .attributeNotFound); return }
        let value = DiscoveryInfo(psm: psm, token: hostToken).encoded
        guard request.offset <= value.count else { peripheral.respond(to: request, withResult: .invalidOffset); return }
        request.value = Data(value.dropFirst(request.offset)); peripheral.respond(to: request, withResult: .success)
    }
    func peripheralManager(_ peripheral: CBPeripheralManager, central: CBCentral, didSubscribeTo characteristic: CBCharacteristic) {
        guard active, peripheral === peripheralManager, characteristic.uuid == notifyID, remoteCentral == nil else { return }
        remoteCentral = central; maximumUpdate = central.maximumUpdateValueLength; subscribed = true
        onState?("Peer subscribed; selecting transport"); armTimeout(seconds: 15, reason: "Transport selection/open timeout")
    }
    func peripheralManager(_ peripheral: CBPeripheralManager, central: CBCentral, didUnsubscribeFrom characteristic: CBCharacteristic) {
        guard active, peripheral === peripheralManager, central.identifier == remoteCentral?.identifier, characteristic.uuid == notifyID else { return }; fail("Peer unsubscribed")
    }
    func peripheralManager(_ peripheral: CBPeripheralManager, didReceiveWrite requests: [CBATTRequest]) {
        guard active, peripheral === peripheralManager, let first = requests.first else { return }
        do {
            for request in requests {
                guard request.characteristic.uuid == writeID, request.offset == 0,
                      request.central.identifier == remoteCentral?.identifier, let data = request.value else { throw ProtocolError.state("Unsubscribed or wrong peer write") }
                if selected == nil {
                    guard data.count == 19, data.prefix(2) == Data([0xA1, 1]), data.suffix(16) == hostToken,
                          let transport = TransportKind(rawValue: data[2]), transport != .l2cap || psm != 0 else { throw ProtocolError.incompatible("Transport selection unsupported") }
                    selected = transport; try sendBootstrapAck()
                } else { guard selected == .gatt else { throw ProtocolError.state("GATT data on L2CAP session") }; try receiveChunk(data) }
            }
            peripheral.respond(to: first, withResult: .success)
        } catch {
            peripheral.respond(to: first, withResult: .unlikelyError)
            if first.central.identifier == remoteCentral?.identifier { fail(String(describing: error)) }
        }
    }
    func peripheralManagerIsReady(toUpdateSubscribers peripheral: CBPeripheralManager) {
        guard active, peripheral === peripheralManager else { return }
        do { if bootstrapPending { try sendBootstrapAck() }; try drainGATT() } catch { fail(String(describing: error)) }
    }
    func peripheralManager(_ peripheral: CBPeripheralManager, didOpen channel: CBL2CAPChannel?, error: Error?) {
        guard active, peripheral === peripheralManager, selected == .l2cap, !bootstrapPending else { channel?.inputStream.close(); channel?.outputStream.close(); return }
        guard error != nil || channel?.peer.identifier == remoteCentral?.identifier else { channel?.inputStream.close(); channel?.outputStream.close(); fail("L2CAP channel from unexpected peer"); return }
        open(channel, error: error, token: hostToken)
    }
    private func open(_ channel: CBL2CAPChannel?, error: Error?, token: Data) {
        if let error { fail("L2CAP open failed: \(error.localizedDescription). Stop and choose GATT explicitly."); return }
        guard let channel, l2cap == nil else { fail("L2CAP channel missing or duplicate"); return }
        let stream = L2CAPStream(channel: channel); l2cap = stream
        stream.onRecord = { [weak self] in self?.onRecord?($0) }
        stream.onFailure = { [weak self] in self?.fail($0) }
        stream.writer.onComplete = { [weak self] tag in if tag != UInt64.max { self?.onSubmission?(tag) } }
        ready(.l2cap, token: token)
    }
    func peripheral(_ peripheral: CBPeripheral, didModifyServices invalidatedServices: [CBService]) {
        guard active, peripheral === remotePeripheral, invalidatedServices.contains(where: { $0.uuid == serviceID }) else { return }
        fail("Peer GATT service invalidated; reconnect explicitly")
    }
    deinit { stop() }
}

extension UUID {
    var rawBytes: Data { var value = uuid; return withUnsafeBytes(of: &value) { Data($0) } }
}
private extension CBManagerState {
    var label: String {
        switch self { case .unknown: return "unknown"; case .resetting: return "resetting"; case .unsupported: return "unsupported"; case .unauthorized: return "permission denied"; case .poweredOff: return "disabled"; case .poweredOn: return "enabled"; @unknown default: return "unrecognized state" }
    }
}
