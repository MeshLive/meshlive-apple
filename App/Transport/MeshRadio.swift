import Foundation
import CoreBluetooth
import NearbyCore

/// A nearby advertiser: an Android 22-byte announcement (manufacturer data) or an iPhone compact UUID.
struct DiscoveredPeer: Identifiable, Equatable {
    /// Stable row ID: node prefix + kind + route token (DiscoveryKey), not the peripheral, whose address rotates.
    let id: UUID
    /// The Core Bluetooth peripheral that advertised this row most recently (used for connecting).
    let peripheralId: UUID
    var announcement: DiscoveryAnnouncement
    var rssi: Int
    var lastSeen: TimeInterval
    var isIPhone: Bool
    var prefixHex: String { announcement.prefixHex }
}

enum RadioError: Error, CustomStringConvertible {
    case unavailable(String), setup(String)
    /// An outgoing connection failed at `stage` (connect, services, characteristics, psm_read, l2cap_open, subscribe, timeout).
    case connect(stage: String, reason: String)
    var description: String {
        switch self {
        case .unavailable(let s), .setup(let s): return s
        case .connect(let stage, let reason): return "\(reason) (\(stage))"
        }
    }
    var stage: String { if case .connect(let stage, _) = self { return stage }; return "setup" }
}

/// Owns Core Bluetooth for the whole app (main queue): scanning, one advertisement, the GATT database
/// Android expects (c8d5a101/c8d5a102 PSM and c8d5a105/103/104 data), the published L2CAP PSM, and
/// outgoing/incoming links.
final class MeshRadio: NSObject, CBCentralManagerDelegate, CBPeripheralManagerDelegate, CBPeripheralDelegate {
    private(set) var central: CBCentralManager!
    private(set) var peripheralManager: CBPeripheralManager!
    private(set) var psm: CBL2CAPPSM = 0
    private var psmValue = Data()
    private var notifyCharacteristic: CBMutableCharacteristic?
    private var servicesAdded = 0
    private var wantScan = false
    private var wantedAdvertisement: (uuid: String, name: String)?
    private(set) var advertisingUUID: String?
    /// Discovery rows keyed by node prefix + kind + route token (Android rotates its advertising address).
    let table = DiscoveryTable(window: 8)
    var peers: [UUID: DiscoveredPeer] {
        Dictionary(uniqueKeysWithValues: table.entries.values.map {
            ($0.rowId, DiscoveredPeer(id: $0.rowId, peripheralId: $0.handle, announcement: $0.announcement, rssi: $0.rssi, lastSeen: $0.lastSeen, isIPhone: $0.isIPhone))
        })
    }
    /// Outgoing attempts keyed by Core Bluetooth peripheral identifier (delegate callbacks carry the peripheral).
    private var attempts: [UUID: OutgoingAttempt] = [:]
    private var clientLinks: [UUID: GattClientLink] = [:]
    private var serverLinks: [UUID: GattServerLink] = [:]
    private var knownPeripherals: [UUID: CBPeripheral] = [:]

    /// Experimental labels: read public title pages (version-3 manufacturer data) into this board.
    var titlePages = false
    /// Experimental rotating IDs: accept compact v2 / announcement version 5 ("Nearby phone").
    var acceptRotating = false
    let titleBoard = TitleBoard()
    var onState: ((String) -> Void)?
    /// For BluetoothGuidance: when the central state last changed, and whether the stack refused to host the service.
    private(set) var centralStateSince = ProcessInfo.processInfo.systemUptime
    private(set) var hostingFailed = false
    var guidanceState: BluetoothGuidance.State {
        switch central?.state {
        case .poweredOn?: return .poweredOn
        case .poweredOff?: return .poweredOff
        case .unauthorized?: return .unauthorized
        case .unsupported?: return .unsupported
        case .resetting?: return .resetting
        default: return .unknown
        }
    }
    var onPeersChanged: (() -> Void)?
    var onIncomingLink: ((MeshLink) -> Void)?
    var onReady: (() -> Void)?
    var allowIncomingGatt: (() -> Bool)?

    var centralReady: Bool { central?.state == .poweredOn }
    var peripheralReady: Bool { peripheralManager?.state == .poweredOn && servicesAdded == 2 && psm != 0 }
    #if os(macOS)
    // Counts at the delegate boundary distinguish a silent Bluetooth input from a request that
    // reached this process but could not be routed. No payload, address or peer ID is retained.
    private var desktopWriteBatches = 0, desktopRawWrites = 0, desktopAcceptedWrites = 0
    private var desktopWrongCharacteristic = 0, desktopWrongOffset = 0
    private var desktopUnknownWriter = 0, desktopMissingWriteValue = 0
    private var desktopLastRawWriteAt: TimeInterval?
    private var desktopRawNotifications = 0, desktopNotificationErrors = 0
    private var desktopUnknownNotifier = 0, desktopMissingNotificationValue = 0
    private var desktopLastRawNotificationAt: TimeInterval?
    private var desktopLastNotificationError = "none"
    var desktopLogFields: [String: String] {
        let now = ProcessInfo.processInfo.systemUptime
        return ["discoveryScanWanted": "\(wantScan)", "discoveryScanning": "\(central?.isScanning == true)",
                "gattServerLinks": "\(serverLinks.count)", "gattClientLinks": "\(clientLinks.count)",
                "gattWriteBatches": "\(desktopWriteBatches)", "gattRawWriteRequests": "\(desktopRawWrites)",
                "gattAcceptedWriteRequests": "\(desktopAcceptedWrites)",
                "gattWrongWriteCharacteristic": "\(desktopWrongCharacteristic)", "gattWrongWriteOffset": "\(desktopWrongOffset)",
                "gattUnknownWriter": "\(desktopUnknownWriter)", "gattMissingWriteValue": "\(desktopMissingWriteValue)",
                "gattRawWriteIdleMs": desktopLastRawWriteAt.map { "\(Int((now - $0) * 1_000))" } ?? "none",
                "gattRawNotifications": "\(desktopRawNotifications)", "gattNotificationErrors": "\(desktopNotificationErrors)",
                "gattUnknownNotifier": "\(desktopUnknownNotifier)", "gattMissingNotificationValue": "\(desktopMissingNotificationValue)",
                "gattRawNotificationIdleMs": desktopLastRawNotificationAt.map { "\(Int((now - $0) * 1_000))" } ?? "none",
                "gattLastNotificationError": desktopLastNotificationError]
    }
    #endif

    func start() {
        if advertisingWatchdog == nil {
            // Reachable whenever the app is in the foreground: re-apply the wanted advertisement if iOS stopped it
            // (Bluetooth reset, a failed start). iOS cannot advertise discoverably in the background.
            advertisingWatchdog = Timer.scheduledTimer(withTimeInterval: 5, repeats: true) { [weak self] _ in self?.checkAdvertising() }
        }
        guard central == nil else { return }
        central = CBCentralManager(delegate: self, queue: .main)
        centralStateSince = ProcessInfo.processInfo.systemUptime
        peripheralManager = CBPeripheralManager(delegate: self, queue: .main)
    }

    private var advertisingWatchdog: Timer?
    private func checkAdvertising() {
        guard let wanted = wantedAdvertisement, peripheralReady, !peripheralManager.isAdvertising else { return }
        AppLog.event("advertise_restart", ["uuid": wanted.uuid])
        applyAdvertisement()
    }

    func stopAll() {
        wantScan = false; wantedAdvertisement = nil
        if centralReady { central.stopScan() }
        peripheralManager?.stopAdvertising(); advertisingUUID = nil
        for attempt in attempts.values { attempt.fail("Stopped", stage: "stopped") }
        attempts.removeAll()
        for link in clientLinks.values { link.close() }
        for link in serverLinks.values { link.close() }
        clientLinks.removeAll(); serverLinks.removeAll()
    }

    /// Stops scanning and advertising but keeps established links (background during a call).
    func pauseDiscovery() {
        wantScan = false; wantedAdvertisement = nil
        if centralReady { central.stopScan() }
        peripheralManager?.stopAdvertising(); advertisingUUID = nil
    }

    // MARK: Scanning

    func setScanning(_ on: Bool) {
        #if os(macOS)
        let changed = wantScan != on
        #endif
        wantScan = on
        guard centralReady else { return }
        #if os(macOS)
        guard changed || central.isScanning != on else { return }
        #endif
        if on {
            // Foreground scan without a service filter: iPhone compact UUIDs differ per device.
            central.scanForPeripherals(withServices: nil, options: [CBCentralManagerScanOptionAllowDuplicatesKey: true])
        } else { central.stopScan() }
        #if os(macOS)
        AppLog.event("discovery_scan", desktopLogFields)
        #endif
    }

    func prune(olderThan seconds: TimeInterval) {
        table.window = seconds
        let removed = table.expire(now: ProcessInfo.processInfo.systemUptime)
        // Release peripherals no row, attempt or link still uses.
        let keep = table.liveHandles.union(attempts.keys).union(clientLinks.keys)
        knownPeripherals = knownPeripherals.filter { keep.contains($0.key) }
        if !removed.isEmpty { AppLog.event("discovery_expired", ["rows": "\(removed.count)", "remaining": "\(table.entries.count)"]); onPeersChanged?() }
    }

    /// Restarts the scan (flushes Core Bluetooth's duplicate filter so a re-advertising peer is reported promptly).
    func restartScan() {
        guard wantScan, centralReady else { return }
        central.stopScan()
        central.scanForPeripherals(withServices: nil, options: [CBCentralManagerScanOptionAllowDuplicatesKey: true])
    }

    func centralManager(_ central: CBCentralManager, didDiscover peripheral: CBPeripheral, advertisementData: [String: Any], rssi RSSI: NSNumber) {
        var announcement: DiscoveryAnnouncement?
        var iPhone = false
        if let mfr = advertisementData[CBAdvertisementDataManufacturerDataKey] as? Data {
            if titlePages, mfr.count > 3, mfr.prefix(2) == Data([0xff, 0xff]), TitlePageCodec.isTitlePage(mfr.dropFirst(2).rebased) {
                // Title pages take their own path before any per-device dedup (rotated pages must all be seen).
                if let page = try? TitlePageCodec.decode(mfr.dropFirst(2).rebased), titleBoard.add(page) != nil { onPeersChanged?() }
                return
            }
            announcement = try? DiscoveryAnnouncement(manufacturerData: mfr, acceptRotating: acceptRotating)
        }
        if announcement == nil {
            let uuids = (advertisementData[CBAdvertisementDataServiceUUIDsKey] as? [CBUUID] ?? [])
                + (advertisementData[CBAdvertisementDataOverflowServiceUUIDsKey] as? [CBUUID] ?? [])
            for uuid in uuids where uuid.data.count == 16 {
                if let decoded = CompactAnnouncement.decode(uuid.uuidString, acceptRotating: acceptRotating) { announcement = decoded; iPhone = true; break }
            }
        }
        guard let announcement else { return }
        knownPeripherals[peripheral.identifier] = peripheral
        let change = table.observe(handle: peripheral.identifier, announcement: announcement, rssi: RSSI.intValue, isIPhone: iPhone,
                                   now: ProcessInfo.processInfo.systemUptime)
        if change.isNew || change.announcementChanged || change.handleReplaced {
            let kind = announcement.isStreamOffer ? "stream_offer" : announcement.isPrivateCallOffer ? "call_offer" : "viewer_request"
            AppLog.event("discovery_peer", ["prefix": announcement.prefixHex, "handle": IdentityHandle.handle(prefix: announcement.nodeIdPrefix) ?? "?",
                                            "kind": kind, "transport": announcement.transport?.rawValue ?? "classic", "iphone": "\(iPhone)",
                                            "routeCost": "\(announcement.routeCost)", "rssi": "\(RSSI.intValue)", "new": "\(change.isNew)",
                                            "addressChanged": "\(change.handleReplaced)", "rows": "\(table.entries.count)"])
        }
        if change.listChanged { onPeersChanged?() }
    }

    // MARK: Advertising (one kind at a time, review R5)

    /// Advertises one announcement as the compact UUID (foreground PDU) plus a local name of at most 8 bytes (R7).
    func advertise(_ announcement: DiscoveryAnnouncement?, name: String) {
        guard let announcement, let uuid = try? CompactAnnouncement.encode(announcement) else {
            wantedAdvertisement = nil; peripheralManager?.stopAdvertising(); advertisingUUID = nil; return
        }
        let short = MeshRadio.shortName(name)
        if wantedAdvertisement?.uuid == uuid && wantedAdvertisement?.name == short && advertisingUUID == uuid { return }
        wantedAdvertisement = (uuid, short)
        applyAdvertisement()
    }

    static func shortName(_ name: String) -> String {
        var out = ""
        for ch in name where (out + String(ch)).utf8.count <= 8 { out.append(ch) }
        return out
    }

    private func applyAdvertisement() {
        guard peripheralReady else { return }
        peripheralManager.stopAdvertising(); advertisingUUID = nil
        guard let wanted = wantedAdvertisement else { return }
        var data: [String: Any] = [CBAdvertisementDataServiceUUIDsKey: [CBUUID(string: wanted.uuid)]]
        peripheralManager.startAdvertising(data)
        advertisingUUID = wanted.uuid
        let kind = CompactAnnouncement.decode(wanted.uuid, acceptRotating: true).map { $0.isStreamOffer ? "stream_offer" : $0.isPrivateCallOffer ? "call_offer" : "viewer_request" } ?? "?"
        AppLog.event("advertise", ["uuid": wanted.uuid, "kind": kind, "localName": wanted.name.isEmpty ? "none" : "set"])
    }

    // MARK: Central state

    func centralManagerDidUpdateState(_ central: CBCentralManager) {
        AppLog.event("radio_state", ["role": "central", "state": "\(central.state.rawValue)"])
        centralStateSince = ProcessInfo.processInfo.systemUptime
        switch central.state {
        case .poweredOn:
            if wantScan { setScanning(true) }
            onReady?()
        case .unauthorized: onState?("Bluetooth permission is off. Allow it in Settings > Privacy > Bluetooth.")
        case .poweredOff: onState?("Bluetooth is off.")
        case .unsupported: onState?("This device has no Bluetooth LE.")
        default: break
        }
        if central.state != .poweredOn {
            for attempt in attempts.values { attempt.fail("Bluetooth unavailable") }
            attempts.removeAll()
        }
    }

    // MARK: Peripheral (GATT server + L2CAP)

    func peripheralManagerDidUpdateState(_ peripheral: CBPeripheralManager) {
        AppLog.event("radio_state", ["role": "peripheral", "state": "\(peripheral.state.rawValue)"])
        guard peripheral.state == .poweredOn else {
            servicesAdded = 0; psm = 0; advertisingUUID = nil
            for link in serverLinks.values { link.fail("Bluetooth unavailable") }
            serverLinks.removeAll()
            return
        }
        guard servicesAdded == 0 else { return }
        hostingFailed = false
        peripheral.removeAllServices()
        let psmCharacteristic = CBMutableCharacteristic(type: CBUUID(string: MeshUUIDs.psmCharacteristic), properties: [.read], value: nil, permissions: [.readable])
        let control = CBMutableService(type: CBUUID(string: MeshUUIDs.controlService), primary: true)
        control.characteristics = [psmCharacteristic]
        let write = CBMutableCharacteristic(type: CBUUID(string: MeshUUIDs.gattWrite), properties: [.write, .writeWithoutResponse], value: nil, permissions: [.writeable])
        let notify = CBMutableCharacteristic(type: CBUUID(string: MeshUUIDs.gattNotify), properties: [.notify], value: nil, permissions: [.readable])
        notifyCharacteristic = notify
        let data = CBMutableService(type: CBUUID(string: MeshUUIDs.gattDataService), primary: true)
        data.characteristics = [write, notify]
        peripheral.add(control); peripheral.add(data)
        peripheral.publishL2CAPChannel(withEncryption: false)
    }

    func peripheralManager(_ peripheral: CBPeripheralManager, didAdd service: CBService, error: Error?) {
        if let error { hostingFailed = true; onState?("Could not host the Bluetooth service: \(error.localizedDescription)"); return }
        servicesAdded += 1
        if peripheralReady { applyAdvertisement(); onReady?() }
    }

    func peripheralManager(_ peripheral: CBPeripheralManager, didPublishL2CAPChannel PSM: CBL2CAPPSM, error: Error?) {
        if let error { hostingFailed = true; onState?("Could not open an L2CAP channel: \(error.localizedDescription)"); return }
        psm = PSM
        psmValue = (try? MeshUUIDs.encodePSM(PSM)) ?? Data()
        AppLog.event("l2cap_publish", ["psm": "\(PSM)"])
        if peripheralReady { applyAdvertisement(); onReady?() }
    }

    func peripheralManagerDidStartAdvertising(_ peripheral: CBPeripheralManager, error: Error?) {
        if let error {
            advertisingUUID = nil
            AppLog.event("advertise_error", ["error": error.localizedDescription])
            DispatchQueue.main.asyncAfter(deadline: .now() + 2) { [weak self] in self?.checkAdvertising() }
        }
    }

    func peripheralManager(_ peripheral: CBPeripheralManager, didReceiveRead request: CBATTRequest) {
        guard request.characteristic.uuid == CBUUID(string: MeshUUIDs.psmCharacteristic), !psmValue.isEmpty else {
            peripheral.respond(to: request, withResult: .readNotPermitted); return
        }
        guard request.offset <= psmValue.count else { peripheral.respond(to: request, withResult: .invalidOffset); return }
        request.value = psmValue.subdata(in: request.offset..<psmValue.count)
        peripheral.respond(to: request, withResult: .success)
    }

    func peripheralManager(_ peripheral: CBPeripheralManager, didOpen channel: CBL2CAPChannel?, error: Error?) {
        guard let channel, error == nil else { AppLog.event("incoming_link", ["transport": "l2cap", "error": "\(error?.localizedDescription ?? "nil")"]); return }
        AppLog.event("incoming_link", ["transport": "l2cap", "psm": "\(channel.psm)"])
        let link = L2CAPLink(channel: channel, label: "LE L2CAP (incoming)")
        onIncomingLink?(link)
    }

    func peripheralManager(_ peripheral: CBPeripheralManager, central: CBCentral, didSubscribeTo characteristic: CBCharacteristic) {
        guard characteristic.uuid == CBUUID(string: MeshUUIDs.gattNotify), let notify = notifyCharacteristic else { return }
        // One central at a time, admitted on its subscription (as Android's GATT server).
        guard serverLinks.isEmpty, allowIncomingGatt?() ?? true else { return }
        let link = GattServerLink(central: central, manager: peripheral, notify: notify, label: "LE GATT (incoming)")
        AppLog.event("incoming_link", ["transport": "gatt", "maxUpdate": "\(central.maximumUpdateValueLength)"])
        let id = central.identifier
        link.onRelease = { [weak self] in self?.serverLinks[id] = nil }
        serverLinks[id] = link
        onIncomingLink?(link)
    }

    func peripheralManager(_ peripheral: CBPeripheralManager, central: CBCentral, didUnsubscribeFrom characteristic: CBCharacteristic) {
        serverLinks[central.identifier]?.fail("The peer unsubscribed")
    }

    func peripheralManager(_ peripheral: CBPeripheralManager, didReceiveWrite requests: [CBATTRequest]) {
        #if os(macOS)
        desktopWriteBatches += 1; desktopRawWrites += requests.count
        if !requests.isEmpty { desktopLastRawWriteAt = ProcessInfo.processInfo.systemUptime }
        #endif
        var ok = true
        for request in requests {
            guard request.characteristic.uuid == CBUUID(string: MeshUUIDs.gattWrite), request.offset == 0,
                  let link = serverLinks[request.central.identifier], let value = request.value else {
                ok = false
                #if os(macOS)
                if request.characteristic.uuid != CBUUID(string: MeshUUIDs.gattWrite) { desktopWrongCharacteristic += 1 }
                else if request.offset != 0 { desktopWrongOffset += 1 }
                else if serverLinks[request.central.identifier] == nil { desktopUnknownWriter += 1 }
                else { desktopMissingWriteValue += 1 }
                #endif
                continue
            }
            #if os(macOS)
            desktopAcceptedWrites += 1
            #endif
            link.received(value)
        }
        if let first = requests.first { peripheral.respond(to: first, withResult: ok ? .success : .requestNotSupported) }
    }

    func peripheralManagerIsReady(toUpdateSubscribers peripheral: CBPeripheralManager) {
        for link in serverLinks.values { link.pump() }
    }

    // MARK: Outgoing connections (central)

    /// Connects to a discovery row with the transport its announcement declares, always through the peripheral
    /// that advertised that row most recently. A failed attempt waits once (up to 6 s, scan restarted) for the
    /// row to be re-seen, possibly under a new address, and retries once, like Android's rediscovering retry.
    func connect(to rowId: UUID, transport: MeshTransport, completion: @escaping (Result<MeshLink, Error>) -> Void) {
        connect(rowId: rowId, transport: transport, retried: false, completion: completion)
    }

    private func connect(rowId: UUID, transport: MeshTransport, retried: Bool, completion: @escaping (Result<MeshLink, Error>) -> Void) {
        guard centralReady, let entry = table.entry(rowId: rowId), let peripheral = knownPeripherals[entry.handle] else {
            AppLog.event("connect", ["stage": "not_nearby", "row": rowId.uuidString, "retried": "\(retried)"])
            completion(.failure(RadioError.connect(stage: "not_nearby", reason: "No longer advertising"))); return
        }
        let key = peripheral.identifier
        attempts[key]?.fail("Replaced", stage: "stopped")
        AppLog.event("connect", ["stage": "start", "transport": transport.rawValue, "prefix": entry.announcement.prefixHex,
                                 "ageMs": "\(Int((ProcessInfo.processInfo.systemUptime - entry.lastSeen) * 1000))", "retried": "\(retried)"])
        let attempt = OutgoingAttempt(peripheral: peripheral, transport: transport) { [weak self] result in
            guard let self else { return }
            if case .failure(let error) = result, !retried, let radioError = error as? RadioError, radioError.stage != "stopped" {
                self.rediscover(rowId: rowId, after: ProcessInfo.processInfo.systemUptime, failure: radioError) { found in
                    if found { self.connect(rowId: rowId, transport: transport, retried: true, completion: completion) }
                    else { completion(.failure(error)) }
                }
                return
            }
            completion(result)
        }
        attempts[key] = attempt
        peripheral.delegate = self
        attempt.timer = Timer.scheduledTimer(withTimeInterval: 15, repeats: false) { [weak self] _ in
            #if os(macOS)
            if let pending = self?.attempts[key] {
                AppLog.event("connect_details", ["phase": "timeout", "setupStage": pending.stage,
                                                 "delegateAttached": "\(pending.peripheral.delegate === self)"].merging(pending.timing()) { a, _ in a })
            }
            #endif
            self?.failAttempt(key, "Connection timed out", stage: "timeout")
        }
        central.connect(peripheral, options: nil)
    }

    /// Waits for a fresh advertisement of the row (any address) after `after`; restarts the scan once.
    private func rediscover(rowId: UUID, after: TimeInterval, failure: RadioError, _ done: @escaping (Bool) -> Void) {
        AppLog.event("connect", ["stage": "rediscover", "failedStage": failure.stage, "reason": failure.description])
        restartScan()
        var ticks = 0
        Timer.scheduledTimer(withTimeInterval: 0.25, repeats: true) { [weak self] timer in
            ticks += 1
            guard let self else { timer.invalidate(); return }
            if let entry = self.table.entry(rowId: rowId), entry.lastSeen > after {
                timer.invalidate()
                AppLog.event("connect", ["stage": "rediscovered", "waitMs": "\(ticks * 250)"])
                done(true)
            } else if ticks >= 24 {
                timer.invalidate()
                AppLog.event("connect", ["stage": "rediscover_timeout", "waitMs": "\(ticks * 250)"])
                done(false)
            }
        }
    }

    /// The user ended a call that was still connecting: stop every outgoing attempt now (stage "stopped": no
    /// rediscover retry), so the radio is released and no late link reaches a peer after the call ended.
    func cancelOutgoingAttempts(_ reason: String = "Cancelled") {
        for key in Array(attempts.keys) { failAttempt(key, reason, stage: "stopped") }
    }

    private func failAttempt(_ id: UUID, _ reason: String, stage: String? = nil) {
        guard let attempt = attempts.removeValue(forKey: id) else { return }
        let failedStage = stage ?? attempt.stage
        AppLog.event("connect", ["stage": "failed", "failedStage": failedStage, "transport": attempt.transport.rawValue, "reason": reason]
                        .merging(attempt.timing()) { a, _ in a })
        attempt.fail(reason, stage: failedStage)
        central.cancelPeripheralConnection(attempt.peripheral)
    }

    private func succeed(_ id: UUID, link: MeshLink) {
        guard let attempt = attempts.removeValue(forKey: id) else { link.close(); return }
        AppLog.event("connect", ["stage": "link_open", "transport": attempt.transport.rawValue, "link": link.label,
                                 "maxWrite": "\(attempt.peripheral.maximumWriteValueLength(for: .withoutResponse))"]
                        .merging(attempt.timing()) { a, _ in a })
        attempt.succeeded()
        attempt.completion(.success(link))
    }

    func centralManager(_ central: CBCentralManager, didConnect peripheral: CBPeripheral) {
        guard let attempt = attempts[peripheral.identifier] else { central.cancelPeripheralConnection(peripheral); return }
        AppLog.event("connect", ["stage": "connected", "transport": attempt.transport.rawValue,
                                 "maxWrite": "\(peripheral.maximumWriteValueLength(for: .withoutResponse))"].merging(attempt.timing()) { a, _ in a })
        attempt.stage = "services"
        let service = attempt.transport == .l2cap ? MeshUUIDs.controlService : MeshUUIDs.gattDataService
        #if os(macOS)
        AppLog.event("connect_details", ["phase": "services_request", "delegateAttached": "\(peripheral.delegate === self)",
                                         "samePeripheralInstance": "\(peripheral === attempt.peripheral)",
                                         "peripheralState": "\(peripheral.state.rawValue)",
                                         "cachedServices": "\(peripheral.services?.count ?? 0)"].merging(attempt.timing()) { a, _ in a })
        #endif
        peripheral.discoverServices([CBUUID(string: service)])
    }

    func centralManager(_ central: CBCentralManager, didFailToConnect peripheral: CBPeripheral, error: Error?) {
        failAttempt(peripheral.identifier, "Could not connect: \(error?.localizedDescription ?? "unknown")")
    }

    func centralManager(_ central: CBCentralManager, didDisconnectPeripheral peripheral: CBPeripheral, error: Error?) {
        AppLog.event("disconnect", ["error": error?.localizedDescription ?? "none", "hadClientLink": "\(clientLinks[peripheral.identifier] != nil)"])
        failAttempt(peripheral.identifier, "Disconnected during setup")
        if let link = clientLinks.removeValue(forKey: peripheral.identifier) { link.fail("Bluetooth link lost") }
    }

    func peripheral(_ peripheral: CBPeripheral, didDiscoverServices error: Error?) {
        #if os(macOS)
        AppLog.event("connect_details", ["phase": "services_callback", "attemptActive": "\(attempts[peripheral.identifier] != nil)",
                                         "services": (peripheral.services ?? []).map { $0.uuid.uuidString }.joined(separator: ","),
                                         "error": error?.localizedDescription ?? "none"].merging(attempts[peripheral.identifier]?.timing() ?? [:]) { a, _ in a })
        #endif
        guard let attempt = attempts[peripheral.identifier] else { return }
        let serviceId = CBUUID(string: attempt.transport == .l2cap ? MeshUUIDs.controlService : MeshUUIDs.gattDataService)
        guard error == nil, let service = peripheral.services?.first(where: { $0.uuid == serviceId }) else {
            failAttempt(peripheral.identifier, "The peer does not offer the \(attempt.transport.label) service"); return
        }
        attempt.stage = "characteristics"
        let wanted = attempt.transport == .l2cap ? [CBUUID(string: MeshUUIDs.psmCharacteristic)]
            : [CBUUID(string: MeshUUIDs.gattWrite), CBUUID(string: MeshUUIDs.gattNotify)]
        peripheral.discoverCharacteristics(wanted, for: service)
    }

    func peripheral(_ peripheral: CBPeripheral, didDiscoverCharacteristicsFor service: CBService, error: Error?) {
        #if os(macOS)
        AppLog.event("connect_details", ["phase": "characteristics_callback", "attemptActive": "\(attempts[peripheral.identifier] != nil)",
                                         "characteristics": "\(service.characteristics?.count ?? 0)",
                                         "error": error?.localizedDescription ?? "none"].merging(attempts[peripheral.identifier]?.timing() ?? [:]) { a, _ in a })
        #endif
        guard let attempt = attempts[peripheral.identifier] else { return }
        let characteristics = service.characteristics ?? []
        if attempt.transport == .l2cap {
            guard let psmChar = characteristics.first(where: { $0.uuid == CBUUID(string: MeshUUIDs.psmCharacteristic) }) else {
                failAttempt(peripheral.identifier, "The peer has no L2CAP PSM characteristic"); return
            }
            attempt.stage = "psm_read"
            peripheral.readValue(for: psmChar)
        } else {
            guard let write = characteristics.first(where: { $0.uuid == CBUUID(string: MeshUUIDs.gattWrite) }),
                  let notify = characteristics.first(where: { $0.uuid == CBUUID(string: MeshUUIDs.gattNotify) }) else {
                failAttempt(peripheral.identifier, "The peer's GATT data service is incomplete"); return
            }
            attempt.write = write
            attempt.stage = "subscribe"
            peripheral.setNotifyValue(true, for: notify)
        }
    }

    func peripheral(_ peripheral: CBPeripheral, didUpdateNotificationStateFor characteristic: CBCharacteristic, error: Error?) {
        #if os(macOS)
        AppLog.event("connect_details", ["phase": "subscribe_callback", "attemptActive": "\(attempts[peripheral.identifier] != nil)",
                                         "notifying": "\(characteristic.isNotifying)", "error": error?.localizedDescription ?? "none"]
                            .merging(attempts[peripheral.identifier]?.timing() ?? [:]) { a, _ in a })
        #endif
        guard let attempt = attempts[peripheral.identifier], characteristic.uuid == CBUUID(string: MeshUUIDs.gattNotify) else { return }
        guard error == nil, characteristic.isNotifying, let write = attempt.write else {
            failAttempt(peripheral.identifier, "GATT subscription failed: \(error?.localizedDescription ?? "not notifying")"); return
        }
        let link = GattClientLink(peripheral: peripheral, write: write, label: "LE GATT")
        let id = peripheral.identifier
        link.onRelease = { [weak self] in
            guard let self else { return }
            self.clientLinks[id] = nil
            if self.centralReady { self.central.cancelPeripheralConnection(peripheral) }
        }
        clientLinks[id] = link
        succeed(id, link: link)
    }

    func peripheral(_ peripheral: CBPeripheral, didUpdateValueFor characteristic: CBCharacteristic, error: Error?) {
        if characteristic.uuid == CBUUID(string: MeshUUIDs.gattNotify) {
            #if os(macOS)
            desktopRawNotifications += 1; desktopLastRawNotificationAt = ProcessInfo.processInfo.systemUptime
            if let error = error as NSError? {
                desktopNotificationErrors += 1
                desktopLastNotificationError = "\(error.domain)/\(error.code)"
            }
            if clientLinks[peripheral.identifier] == nil { desktopUnknownNotifier += 1 }
            if characteristic.value == nil { desktopMissingNotificationValue += 1 }
            #endif
            if let value = characteristic.value { clientLinks[peripheral.identifier]?.received(value) }
            return
        }
        guard characteristic.uuid == CBUUID(string: MeshUUIDs.psmCharacteristic), attempts[peripheral.identifier] != nil else { return }
        guard error == nil, let value = characteristic.value, let psm = try? MeshUUIDs.decodePSM(value) else {
            failAttempt(peripheral.identifier, "Could not read the peer's L2CAP PSM"); return
        }
        AppLog.event("connect", ["stage": "psm_read", "psm": "\(psm)"].merging(attempts[peripheral.identifier]?.timing() ?? [:]) { a, _ in a })
        attempts[peripheral.identifier]?.stage = "l2cap_open"
        peripheral.openL2CAPChannel(CBL2CAPPSM(psm))
    }

    func peripheral(_ peripheral: CBPeripheral, didOpen channel: CBL2CAPChannel?, error: Error?) {
        guard attempts[peripheral.identifier] != nil else { return }
        guard let channel, error == nil else {
            failAttempt(peripheral.identifier, "L2CAP channel failed: \(error?.localizedDescription ?? "unknown")"); return
        }
        let link = L2CAPLink(channel: channel, label: "LE L2CAP")
        link.onRelease = { [weak self] in
            guard let self, self.centralReady else { return }
            self.central.cancelPeripheralConnection(peripheral)
        }
        succeed(peripheral.identifier, link: link)
    }

    func peripheralIsReady(toSendWriteWithoutResponse peripheral: CBPeripheral) {
        clientLinks[peripheral.identifier]?.pump()
    }
}

final class OutgoingAttempt {
    let peripheral: CBPeripheral
    let transport: MeshTransport
    let completion: (Result<MeshLink, Error>) -> Void
    var write: CBCharacteristic?
    var timer: Timer?
    /// Where the attempt is: connect, services, characteristics, psm_read, l2cap_open, subscribe.
    var stage = "connect"
    private let startedAt = ProcessInfo.processInfo.systemUptime
    private var lastStepAt = ProcessInfo.processInfo.systemUptime
    /// Log fields: `ms` since the attempt started and `stepMs` since the previous logged step.
    func timing() -> [String: String] {
        let now = ProcessInfo.processInfo.systemUptime
        defer { lastStepAt = now }
        return ["ms": "\(Int(((now - startedAt) * 1000).rounded()))", "stepMs": "\(Int(((now - lastStepAt) * 1000).rounded()))"]
    }
    private var done = false
    init(peripheral: CBPeripheral, transport: MeshTransport, completion: @escaping (Result<MeshLink, Error>) -> Void) {
        self.peripheral = peripheral; self.transport = transport; self.completion = completion
    }
    func fail(_ reason: String, stage: String? = nil) {
        guard !done else { return }; done = true; timer?.invalidate()
        completion(.failure(RadioError.connect(stage: stage ?? self.stage, reason: reason)))
    }
    func succeeded() { done = true; timer?.invalidate() }
}
