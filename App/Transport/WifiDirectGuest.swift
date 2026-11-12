import Foundation
import Network
import NearbyCore
#if os(iOS)
import NetworkExtension
#else
import CoreWLAN
#endif

/// AW1: the platform half of a call's Wi-Fi Direct guest: join the Android phone's group, pin the Wi-Fi interface,
/// connect to CREDS and move bytes for CallEngine. Logs never carry the network name, password or addresses.
final class WifiDirectGuest {
    private weak var engine: WifiGuestEngine?
    private let pumpBluetooth: () -> Void
    private var ssid: String?
    private var ticket = Data()
    private var connection: NWConnection?
    private var connectStartedAt: TimeInterval = 0
    private var inFlight = 0
    /// When each write still waiting for its completion was handed to the connection, oldest first.
    private var sendTimes: [TimeInterval] = []
    private var timer: Timer?
    private var joinPoll: Timer?
    private var pendingHost: UInt32 = 0
    private var pendingPort: UInt16 = 0
    private var pendingLocal: IPv4Interface?
    private var associated = false
    private var joinGate = WifiJoinGate()
    private var pathMonitor: NWPathMonitor?
    private var pinned: NWInterface?
    private static let lowWater = 64 * 1024

    init(engine: WifiGuestEngine, pumpBluetooth: @escaping () -> Void) {
        self.engine = engine
        self.pumpBluetooth = pumpBluetooth
    }

    private var now: TimeInterval { ProcessInfo.processInfo.systemUptime }

    // MARK: Join

    func join(ssid: String, passphrase: String, ticket: Data) {
        self.ssid = ssid
        self.ticket = ticket
        let token = joinGate.begin(ssid: ssid)
        #if os(iOS)
        #if HOTSPOT_ENTITLED
        let configuration = NEHotspotConfiguration(ssid: ssid, passphrase: passphrase, isWEP: false)
        configuration.joinOnce = false
        NEHotspotConfigurationManager.shared.apply(configuration) { [weak self] error in
            DispatchQueue.main.async {
                // A join that was left (or whose guest is gone) removes its own configuration: leave() may have run
                // before iOS applied it.
                guard let self, self.joinGate.completed(token: token, ssid: ssid) == .proceed else {
                    NEHotspotConfigurationManager.shared.removeConfiguration(forSSID: ssid); return
                }
                guard let error else { self.pollJoinedIphone(ssid: ssid, ticket: ticket); return }
                if let configurationError = error as? NEHotspotConfigurationError {
                    switch configurationError {
                    case .alreadyAssociated:
                        self.pollJoinedIphone(ssid: ssid, ticket: ticket)
                    case .userDenied:
                        self.engine?.wifiJoinFailed(ticket: ticket, reason: .notEligible, detail: "user_denied", now: self.now)
                    default:
                        self.engine?.wifiJoinFailed(ticket: ticket, reason: .setupFailed, detail: "apply_\(configurationError.rawValue)", now: self.now)
                    }
                } else {
                    self.engine?.wifiJoinFailed(ticket: ticket, reason: .setupFailed,
                                                detail: "apply_\((error as NSError).code)", now: self.now)
                }
            }
        }
        #else
        _ = token
        engine?.wifiJoinFailed(ticket: ticket, reason: .notEligible, detail: "no_entitlement", now: now)
        #endif
        #else
        joinMac(ssid: ssid, passphrase: passphrase, ticket: ticket, token: token)
        #endif
    }

    #if os(iOS)
    #if HOTSPOT_ENTITLED
    private func pollJoinedIphone(ssid: String, ticket: Data) {
        stopJoinPoll()
        let timer = Timer(timeInterval: 0.5, repeats: true) { [weak self] _ in
            guard let self else { return }
            NEHotspotNetwork.fetchCurrent { [weak self] network in
                DispatchQueue.main.async {
                    guard let self, network?.ssid == ssid else { return }
                    let all = Self.interfaces()
                    guard let en0 = all.first(where: { $0.name == "en0" && DirectGuestRules.isPrivate($0.address) }) else { return }
                    self.stopJoinPoll()
                    self.engine?.wifiJoined(ticket: ticket, local: en0, all: all, band: .unknown, now: self.now)
                }
            }
        }
        RunLoop.main.add(timer, forMode: .common)
        joinPoll = timer
    }
    #endif
    #else
    private func joinMac(ssid: String, passphrase: String, ticket: Data, token: UInt64) {
        guard let interface = CWWiFiClient.shared().interface(), interface.powerOn() else {
            engine?.wifiJoinFailed(ticket: ticket, reason: .wifiUnavailable, detail: "wifi_off", now: now)
            return
        }
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            guard let self else { return }
            let networks: Set<CWNetwork>
            do { networks = try interface.scanForNetworks(withSSID: Data(ssid.utf8)) }
            catch {
                DispatchQueue.main.async {
                    self.engine?.wifiJoinFailed(ticket: ticket, reason: .setupFailed,
                                                detail: "associate_\((error as NSError).code)", now: self.now)
                }
                return
            }
            guard let network = networks.first(where: { $0.ssid == ssid }) ?? networks.first else {
                DispatchQueue.main.async { self.engine?.wifiJoinFailed(ticket: ticket, reason: .setupFailed, detail: "not_found", now: self.now) }
                return
            }
            do {
                try interface.associate(to: network, password: passphrase)
                DispatchQueue.main.async {
                    // leave() ran while this worker associated: undo the join, unless the interface already moved on.
                    guard self.joinGate.completed(token: token, ssid: ssid) == .proceed else {
                        if interface.ssid() == ssid { interface.disassociate() }
                        return
                    }
                    self.associated = true
                    self.pollJoinedMac(interface: interface, ticket: ticket)
                }
            } catch {
                DispatchQueue.main.async {
                    self.engine?.wifiJoinFailed(ticket: ticket, reason: .setupFailed,
                                                detail: "associate_\((error as NSError).code)", now: self.now)
                }
            }
        }
    }

    private func pollJoinedMac(interface: CWInterface, ticket: Data) {
        stopJoinPoll()
        let timer = Timer(timeInterval: 0.5, repeats: true) { [weak self] _ in
            guard let self, let name = interface.interfaceName else { return }
            let all = Self.interfaces()
            guard let joined = all.first(where: { $0.name == name && DirectGuestRules.isPrivate($0.address) }) else { return }
            self.stopJoinPoll()
            var band = DirectGuestRules.Band.unknown
            if let channel = interface.wlanChannel() {
                switch channel.channelBand {
                case .band2GHz: band = .ghz2_4
                case .band5GHz: band = .ghz5
                case .band6GHz: band = .ghz6
                default: break
                }
            }
            self.engine?.wifiJoined(ticket: ticket, local: joined, all: all, band: band, now: self.now)
        }
        RunLoop.main.add(timer, forMode: .common)
        joinPoll = timer
    }
    #endif

    // MARK: Connect

    func connect(host: UInt32, port: UInt16, local: IPv4Interface) {
        connectStartedAt = now
        pendingHost = host; pendingPort = port; pendingLocal = local
        startConnection()
    }

    /// F-4: the socket requires the joined Wi-Fi interface itself. NWPathMonitor reports interfaces only in its update
    /// handler, so the first connect waits for that; the agent's connect deadline bounds the wait.
    private func startConnection() {
        guard let local = pendingLocal, NWEndpoint.Port(rawValue: pendingPort) != nil else { return }
        if let pinned { open(local: local, interface: pinned); return }
        pathMonitor?.cancel()
        let monitor = NWPathMonitor(requiredInterfaceType: .wifi)
        monitor.pathUpdateHandler = { [weak self, weak monitor] path in
            guard let self, let monitor, self.pathMonitor === monitor,
                  let match = path.availableInterfaces.first(where: { $0.name == local.name }) else { return }
            monitor.cancel(); self.pathMonitor = nil; self.pinned = match
            self.open(local: local, interface: match)
        }
        pathMonitor = monitor
        monitor.start(queue: .main)
    }

    private func open(local: IPv4Interface, interface: NWInterface) {
        guard pendingLocal != nil, let port = NWEndpoint.Port(rawValue: pendingPort) else { return }
        let tcp = NWProtocolTCP.Options()
        tcp.noDelay = true
        tcp.enableKeepalive = false
        tcp.connectionTimeout = 5
        let parameters = NWParameters(tls: nil, tcp: tcp)
        parameters.requiredInterfaceType = .wifi
        parameters.prohibitedInterfaceTypes = [.cellular, .loopback]
        parameters.requiredLocalEndpoint = .hostPort(host: NWEndpoint.Host(Self.dotted(local.address)), port: .any)
        parameters.requiredInterface = interface

        let newConnection = NWConnection(host: NWEndpoint.Host(Self.dotted(pendingHost)), port: port, using: parameters)
        connection = newConnection
        newConnection.stateUpdateHandler = { [weak self, weak newConnection] state in
            guard let self, let newConnection, self.connection === newConnection else { return }
            switch state {
            case .ready:
                self.engine?.wifiConnected(ticket: self.ticket, now: self.now)
                self.receive(on: newConnection)
                self.startTimer()
            case .failed(let error):
                self.retryOrFail(error)
            case .waiting(let error):
                if Self.isConnectionRefused(error) { self.retryOrFail(error) }
            default:
                break
            }
        }
        newConnection.start(queue: .main)
    }

    private func retryOrFail(_ error: Error) {
        connection?.cancel()
        connection = nil
        if now - connectStartedAt < 5 {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) { [weak self] in
                guard let self, self.connection == nil, self.pendingLocal != nil else { return }
                self.startConnection()
            }
        } else {
            engine?.wifiConnectFailed(ticket: ticket, detail: "connect_\(Self.posixCode(error))", now: now)
        }
    }

    private func receive(on connection: NWConnection) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 65_536) { [weak self, weak connection] data, _, isComplete, error in
            guard let self, let connection, self.connection === connection else { return }
            if let data, !data.isEmpty {
                self.engine?.wifiReceive(data, ticket: self.ticket, now: self.now)
                self.pump()
                self.pumpBluetooth()
            }
            if let error {
                self.engine?.wifiSocketClosed(ticket: self.ticket, detail: "error_\(Self.posixCode(error))", now: self.now)
                return
            }
            if isComplete {
                self.engine?.wifiSocketClosed(ticket: self.ticket, detail: "eof", now: self.now)
                return
            }
            self.receive(on: connection)
        }
    }

    private func startTimer() {
        timer?.invalidate()
        let timer = Timer(timeInterval: 0.05, repeats: true) { [weak self] _ in self?.pump() }
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
    }

    private func pump() {
        guard let connection else { return }
        while inFlight < Self.lowWater, let bytes = engine?.nextWifiOutgoing(now: now) {
            inFlight += bytes.count
            sendTimes.append(now)
            connection.send(content: bytes, completion: .contentProcessed { [weak self, weak connection] error in
                DispatchQueue.main.async {
                    // A completion of a cancelled or replaced connection changes nothing.
                    guard let self, let connection, self.connection === connection else { return }
                    self.inFlight -= bytes.count
                    if !self.sendTimes.isEmpty { self.sendTimes.removeFirst() }
                    if let error {
                        self.engine?.wifiSocketClosed(ticket: self.ticket, detail: "send_\(Self.posixCode(error))", now: self.now)
                        return
                    }
                    self.reportSendState()
                    self.pump()
                }
            })
        }
        reportSendState()
        pumpBluetooth()
    }

    /// The oldest write still waiting, for the agent's 2.5 s write-stall rule.
    private func reportSendState() {
        engine?.wifiSendState(oldestPendingSince: sendTimes.first, ticket: ticket, now: now)
    }

    // MARK: End

    func closeSocket() {
        pendingLocal = nil
        pathMonitor?.cancel(); pathMonitor = nil; pinned = nil
        connection?.cancel()
        connection = nil
        timer?.invalidate()
        timer = nil
        inFlight = 0
        sendTimes = []
    }

    func leave() {
        joinGate.end()
        stopJoinPoll()
        closeSocket()
        #if os(iOS)
        if let ssid { NEHotspotConfigurationManager.shared.removeConfiguration(forSSID: ssid) }
        #else
        if associated, let interface = CWWiFiClient.shared().interface() { interface.disassociate() }
        associated = false
        #endif
        ssid = nil
    }

    private func stopJoinPoll() {
        joinPoll?.invalidate()
        joinPoll = nil
    }

    // MARK: Helpers

    /// Every IPv4 interface that is up and not loopback, with its address (host byte order) and prefix length.
    static func interfaces() -> [IPv4Interface] {
        var result: [IPv4Interface] = []
        var addresses: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&addresses) == 0, let first = addresses else { return [] }
        defer { freeifaddrs(addresses) }
        for pointer in sequence(first: first, next: { $0.pointee.ifa_next }) {
            let interface = pointer.pointee
            guard let address = interface.ifa_addr, address.pointee.sa_family == sa_family_t(AF_INET) else { continue }
            let flags = Int32(bitPattern: interface.ifa_flags)
            guard flags & IFF_UP != 0, flags & IFF_LOOPBACK == 0 else { continue }
            let name = String(cString: interface.ifa_name)
            let value = address.withMemoryRebound(to: sockaddr_in.self, capacity: 1) { $0.pointee }
            var prefix = 0
            if let mask = interface.ifa_netmask {
                let maskValue = mask.withMemoryRebound(to: sockaddr_in.self, capacity: 1) { $0.pointee }
                prefix = UInt32(bigEndian: maskValue.sin_addr.s_addr).nonzeroBitCount
            }
            result.append(IPv4Interface(name: name, address: UInt32(bigEndian: value.sin_addr.s_addr), prefixLength: prefix))
        }
        return result
    }

    private static func dotted(_ value: UInt32) -> String {
        "\(value >> 24).\(value >> 16 & 255).\(value >> 8 & 255).\(value & 255)"
    }

    private static func isConnectionRefused(_ error: Error) -> Bool {
        guard let networkError = error as? NWError, case .posix(let code) = networkError else { return false }
        return code == .ECONNREFUSED
    }

    private static func posixCode(_ error: Error) -> Int32 {
        if let networkError = error as? NWError, case .posix(let code) = networkError { return code.rawValue }
        return Int32((error as NSError).code)
    }
}
