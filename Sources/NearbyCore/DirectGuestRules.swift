import Foundation

/// One IPv4 interface address of this device (getifaddrs), for F-4.
public struct IPv4Interface: Equatable {
    public let name: String
    public let address: UInt32
    public let prefixLength: Int
    public init(name: String, address: UInt32, prefixLength: Int) { self.name = name; self.address = address; self.prefixLength = prefixLength }
    public var mask: UInt32 { prefixLength <= 0 ? 0 : (prefixLength >= 32 ? .max : UInt32.max << UInt32(32 - prefixLength)) }
}

/// AW1F: whether an asynchronous join completion (Mac associate, iPhone hotspot apply) still belongs to the current
/// join. A completion of a join that was left or replaced must undo its own network join: nothing else will.
public struct WifiJoinGate {
    public enum Verdict: Equatable { case proceed, undo(ssid: String) }
    private var current: UInt64?
    private var counter: UInt64 = 0
    public init() {}
    public mutating func begin(ssid: String) -> UInt64 { counter &+= 1; current = counter; return counter }
    public mutating func end() { current = nil }
    public func completed(token: UInt64, ssid: String) -> Verdict { current == token ? .proceed : .undo(ssid: ssid) }
}

/// Android DirectPolicy/DirectAddressRules and WifiHopAgent.onHost, for an Apple Wi-Fi Direct guest.
public enum DirectGuestRules {
    public enum Band: String { case ghz2_4 = "2.4", ghz5 = "5", ghz6 = "6", unknown }
    public enum HostVerdict: Equatable { case accept, ignore, decline(DeclineReason) }

    /// The joined network's band if this device read it (Mac), else the host's authenticated HOST frequency (R-16, R-25).
    public static func bandOk(read: Band, hostFreqMhz: Int) -> Bool {
        switch read {
        case .ghz5, .ghz6: return true
        case .ghz2_4: return false
        case .unknown: return hostFreqMhz >= WifiWire.min5GhzMhz
        }
    }

    public static func isPrivate(_ a: UInt32) -> Bool {
        a >> 24 == 10 || a >> 20 == (172 << 4 | 1) || a >> 16 == (192 << 8 | 168)
    }

    /// F-4: CREDS names a private address on the joined interface's subnet, not this device's own.
    public static func credsOnLink(joined: IPv4Interface, host: UInt32) -> Bool {
        isPrivate(host) && host != joined.address && host & joined.mask == joined.address & joined.mask
    }

    /// F-4: another interface shares the joined subnet (masked with the shorter prefix): routing could leave the group.
    public static func subnetOverlap(joined: IPv4Interface, all: [IPv4Interface]) -> Bool {
        all.contains { other in
            guard other.name != joined.name else { return false }
            let mask = other.prefixLength < joined.prefixLength ? other.mask : joined.mask
            return other.address & mask == joined.address & mask
        }
    }

    /// The DECLINE for a joined group, or nil to connect: off-link CREDS 6, an overlapping subnet 3.
    public static func credsRefusal(joined: IPv4Interface, all: [IPv4Interface], host: UInt32) -> DeclineReason? {
        guard credsOnLink(joined: joined, host: host) else { return .setupFailed }
        return subnetOverlap(joined: joined, all: all) ? .wifiUnavailable : nil
    }

    public static let maxHostsPerCall = 6
    public static let hostSpacingSeconds: TimeInterval = 29

    /// Android onHost order for a guest.
    public static func hostVerdict(hasKey: Bool, guestTuple: Bool, status: UInt8, bearer: UInt8, validMs: Int, ticketFresh: Bool,
                                   attemptRunning: Bool, hostsAccepted: Int, sinceLastAttempt: TimeInterval?, foreground: Bool,
                                   eligible: Bool) -> HostVerdict {
        guard hasKey else { return .decline(.notEligible) }
        guard guestTuple else { return .decline(.busy) }
        guard status == 1 else { return .ignore }
        guard bearer == WifiWire.bearerDirect else { return .decline(.notEligible) }
        guard (1...WifiWire.maxValidMs).contains(validMs) else { return .decline(.notEligible) }
        guard ticketFresh else { return .decline(.notEligible) }
        guard !attemptRunning else { return .decline(.busy) }
        if hostsAccepted >= maxHostsPerCall { return .decline(.limit) }
        if let since = sinceLastAttempt, since < hostSpacingSeconds { return .decline(.limit) }
        guard foreground else { return .decline(.notEligible) }
        guard eligible else { return .decline(.notEligible) }
        return .accept
    }
}
