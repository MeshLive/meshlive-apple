import Foundation

// Call blocking (Android CallBlocking.kt, PersonPolicy.kt, LocalReporting.kt). Local only: no wire byte changes.
// A block keys on the full identity fingerprint, never on a discovery ID, a name or a 48-bit prefix. A stranger calls
// under a throwaway key, so a ringing stranger cannot be matched; "Block unknown callers" is what stops those, and a
// block follows the real identity once a stranger's reveal shows it (CallEngine).

/// The caller as this phone knows it at the Invite, before anything rings.
public struct CallGateCaller: Equatable {
    /// True while the caller is only a throwaway key: no identity exists to compare yet.
    public let pseudonymous: Bool
    /// The authenticated identity key's fingerprint; nil while pseudonymous.
    public let fingerprint: IdentityFingerprint?
    public init(pseudonymous: Bool, fingerprint: IdentityFingerprint?) { self.pseudonymous = pseudonymous; self.fingerprint = fingerprint }
}

public enum CallGateDecision: Equatable {
    /// Ring as usual.
    case ring
    /// The caller is on the block list: decline without ringing or notifying.
    case declineBlockedPerson
    /// "Block unknown callers" is on and the caller is not a recognised verified contact.
    case declineUnknown
}

/// Whether the caller is a verified contact, as far as the contact store can say.
public enum ContactStanding: Equatable { case verified, notVerified, unknown }

public enum CallBlockingPolicy {
    /// A refused call is declined after 3 s + random(0..4 s), like a person who looked at the screen first.
    public static let declineDelayMin: TimeInterval = 3
    public static let declineDelaySpread: TimeInterval = 4

    /// Android `CallBlockingPolicy.decide`: a real-key caller on the block list never rings (blocked people win over
    /// contacts); with "Block unknown callers" on, only a real-key verified contact rings. A throwaway key cannot be a
    /// recognised contact (a contact whose lease expired arrives like this and is declined too; the setting says so). An
    /// unreadable contact store rings (fail open: it never blocks someone it cannot judge).
    public static func decide(blockUnknown: Bool, pseudonymous: Bool, blocked: Bool, standing: ContactStanding) -> CallGateDecision {
        if !pseudonymous && blocked { return .declineBlockedPerson }
        if !blockUnknown { return .ring }
        if pseudonymous { return .declineUnknown }
        switch standing {
        case .verified, .unknown: return .ring
        case .notVerified: return .declineUnknown
        }
    }

    /// The human-like delay before a refused call's ordinary decline, or a revealed blocked person's ordinary end.
    public static func declineDelay(random: Double = Double.random(in: 0..<1)) -> TimeInterval {
        declineDelayMin + min(max(random, 0), 1) * declineDelaySpread
    }
}

/// One blocked person: the full fingerprint and when the block was made. Nothing else is stored.
public struct BlockedPerson: Codable, Equatable, Identifiable {
    public let fingerprintHex: String
    public let blockedAt: Date
    public var id: String { fingerprintHex }
    public var nodePrefixHex: String { String(fingerprintHex.prefix(12)) }
    public init(fingerprintHex: String, blockedAt: Date) { self.fingerprintHex = fingerprintHex; self.blockedAt = blockedAt }
}

/// The block list (Android `BlockedPeopleStore` and `LocalReporting`): blocked people by full fingerprint, plus the
/// people and stream routes a report hides even after an unblock. A value type: the app seals it at rest.
public struct BlockList: Codable, Equatable {
    public static let maxPeople = 512

    public private(set) var people: [BlockedPerson]
    public private(set) var reportedPeople: [String]
    /// Hidden routes (`BlockedStreams.routeKey`), never a bare token: "Hide this livestream" on a route whose advertised
    /// fixed ID the viewer's hop proved (AB3), and routes that older builds kept with a report. Stricter than Android,
    /// which hides a reported token on every route.
    public private(set) var reportedStreams: [String]

    public init() { people = []; reportedPeople = []; reportedStreams = [] }

    public enum AddResult: Equatable { case blocked, alreadyBlocked, full }

    public func contains(_ fingerprint: IdentityFingerprint) -> Bool { people.contains { $0.fingerprintHex == fingerprint.hex } }

    /// A person known only by the 128-bit node ID (a forwarded stream's source, a link peer): the first 16 bytes of the
    /// fingerprint.
    public func containsNode(_ node: NodeId) -> Bool { people.contains { $0.fingerprintHex.hasPrefix(node.hex) } }

    /// Reported (blocked at the time); their streams stay hidden even after an unblock.
    public func reported(node: NodeId) -> Bool { reportedPeople.contains { $0.hasPrefix(node.hex) } }

    /// 12-hex prefixes whose broadcasts the Live list hides (blocked or reported people).
    public var hiddenPrefixes: Set<String> { Set(people.map(\.nodePrefixHex) + reportedPeople.map { String($0.prefix(12)) }) }

    /// Reported routes (logical token + advertised ID) whose broadcasts stay hidden.
    public var reportedRoutes: Set<String> { Set(reportedStreams) }

    public mutating func add(_ fingerprint: IdentityFingerprint, at date: Date) -> AddResult {
        if contains(fingerprint) { return .alreadyBlocked }
        if people.count >= Self.maxPeople { return .full }
        people.append(BlockedPerson(fingerprintHex: fingerprint.hex, blockedAt: date))
        return .blocked
    }

    /// True when the person was on the list. A report's hiding stays.
    @discardableResult
    public mutating func remove(_ fingerprint: IdentityFingerprint) -> Bool {
        let before = people.count
        people.removeAll { $0.fingerprintHex == fingerprint.hex }
        return people.count != before
    }

    /// Android `LocalReporting.report`: blocks the person; when that worked (or they were blocked already), also keeps
    /// hiding them after any later unblock. AB3: never a route by itself (Android keeps the reported token too): a
    /// route's token and advertised ID are chosen by its sender, so a kept route could hide a genuine stream a spoofer
    /// copied. The person stays hidden through `hiddenPrefixes` (their attributed direct route) and `reported(node:)` (a
    /// route whose source authenticates as them).
    public mutating func report(_ fingerprint: IdentityFingerprint, at date: Date) -> AddResult {
        let result = add(fingerprint, at: date)
        guard result != .full else { return .full }
        if !reportedPeople.contains(fingerprint.hex), reportedPeople.count < Self.maxPeople { reportedPeople.append(fingerprint.hex) }
        return result
    }

    /// Android `LocalReporting.hideStream` ("Hide this livestream", for a source that could not be identified): the route
    /// joins the reported routes, so the Live list keeps hiding it; nobody is blocked. True when it was added.
    @discardableResult
    public mutating func hideStream(route: String) -> Bool {
        guard !reportedStreams.contains(route), reportedStreams.count < Self.maxPeople else { return false }
        reportedStreams.append(route)
        return true
    }

    public func encoded() throws -> Data { try JSONEncoder().encode(self) }

    /// Anything malformed throws: such a list is "unreadable" (blocks nobody) and is never overwritten.
    public static func decode(_ data: Data) throws -> BlockList {
        let list = try JSONDecoder().decode(BlockList.self, from: data)
        let isFingerprint: (String) -> Bool = { s in s.count == 64 && s.allSatisfy { ("0"..."9").contains($0) || ("a"..."f").contains($0) } }
        let isRoute: (String) -> Bool = { s in
            let parts = s.split(separator: ":", omittingEmptySubsequences: false)
            guard parts.count == 2, !parts[0].isEmpty, parts[0].allSatisfy({ ("0"..."9").contains($0) }), parts[1].count == 12 else { return false }
            return parts[1].allSatisfy { ("0"..."9").contains($0) || ("a"..."f").contains($0) }
        }
        guard list.people.count <= maxPeople, list.reportedPeople.count <= maxPeople, list.reportedStreams.count <= maxPeople,
              list.people.allSatisfy({ isFingerprint($0.fingerprintHex) }), list.reportedPeople.allSatisfy(isFingerprint),
              list.reportedStreams.allSatisfy(isRoute) else {
            throw ProtocolError.malformed("Not a block list")
        }
        return list
    }
}

/// What a block-list read found: the list (empty when nothing is stored), not readable yet (the Keychain is locked), or
/// damaged (the file or its contents cannot be opened, so only a reset can recover it).
public enum BlockListLoad: Equatable {
    case loaded(BlockList), unavailable, damaged

    /// Classify one sealed read (P6-A2): a missing file is an empty list; a file that cannot be read yet is unavailable;
    /// a file that is present but cannot be opened or decoded is damaged. A missing records key beside a stored file is
    /// damaged too: another sealed writer would replace the key and lose the list.
    public static func classify(_ read: SealedRead) -> BlockListLoad {
        switch read {
        case .absent: return .loaded(BlockList())
        case .value(let data): return (try? BlockList.decode(data)).map { .loaded($0) } ?? .damaged
        case .unreadable("open"), .unreadable("key_missing"): return .damaged
        case .unreadable: return .unavailable
        }
    }
}

/// The in-memory block list and its read/write discipline (P6-A2): nil while it cannot be read, and never overwritten
/// from an unreadable or damaged store. The app supplies the sealed-file save.
public struct BlockListHolder {
    public private(set) var list: BlockList?
    public private(set) var damaged = false
    private let save: (BlockList) -> Bool

    public init(save: @escaping (BlockList) -> Bool) { self.save = save }

    /// Reload only while the list is unknown; a readable list is not replaced by a later read.
    @discardableResult
    public mutating func reloadIfNeeded(_ load: () -> BlockListLoad) -> Bool {
        guard list == nil else { return false }
        switch load() {
        case .loaded(let loaded): list = loaded; damaged = false
        case .unavailable: list = nil; damaged = false
        case .damaged: list = nil; damaged = true
        }
        return true
    }

    public enum BlockResult: Equatable { case blocked, alreadyBlocked, full, unavailable }

    /// Blocks only from a list that could be read, and keeps the change only after it was saved.
    @discardableResult
    public mutating func block(_ fingerprint: IdentityFingerprint, at date: Date) -> BlockResult {
        guard var next = list else { return .unavailable }
        let result = next.add(fingerprint, at: date)
        guard result == .blocked else { return result == .full ? .full : .alreadyBlocked }
        guard save(next) else { return .unavailable }
        list = next
        return .blocked
    }

    /// Keeps the holder in step with a list the app changed and saved itself (unblock, report).
    public mutating func replace(_ list: BlockList) { self.list = list }

    /// Drops the in-memory list after an emergency wipe or before a fresh session.
    public mutating func clear() { list = nil; damaged = false }

    /// Reset is the recovery for a damaged list only: a locked list is not destroyed.
    public var canReset: Bool { damaged }

    @discardableResult
    public mutating func reset() -> Bool {
        guard damaged else { return false }
        list = BlockList()
        damaged = false
        return true
    }

    /// Android `CallBlocking.gate` for the holder's list; unreadable fails open (blocks nobody).
    public func gateDecision(blockUnknown: Bool, caller: CallGateCaller, standing: ContactStanding) -> CallGateDecision {
        let blocked = caller.fingerprint.map { list?.contains($0) ?? false } ?? false
        return CallBlockingPolicy.decide(blockUnknown: blockUnknown, pseudonymous: caller.pseudonymous, blocked: blocked, standing: standing)
    }
}

/// What a screen that shows blocking says about the saved list (Android `BlockListView`; decision 2026-11-06,
/// "Unreadable block list"). A damaged list shows "Block list can't be read" with Reset and never "No one is blocked"
/// (calls are not blocked, but people may be on it). A list the Keychain keeps locked for now (Apple only) shows its own
/// note without Reset: it is not damaged, and a reset would lose it. Pure.
public struct BlockListView: Equatable {
    public let showUnreadableNote: Bool
    public let showLockedNote: Bool
    public let showEmptyState: Bool

    public static func of(list: BlockList?, damaged: Bool) -> BlockListView {
        BlockListView(showUnreadableNote: list == nil && damaged,
                      showLockedNote: list == nil && !damaged,
                      showEmptyState: list?.people.isEmpty == true)
    }
}

/// The Live list's side of blocking (Android `hideBlockedStreams`, `PersonPolicy.hideStream`).
public enum BlockedStreams {
    /// One route of one stream: its logical token and the advertised ID. Never the token alone (it is public and chosen
    /// by the advertiser, so a blocked broadcaster could copy a genuine stream's token).
    public static func routeKey(_ offer: DiscoveryAnnouncement) -> String { "\(offer.logicalStreamToken):\(offer.nodeIdPrefix.hex)" }

    /// AB3: the route "Hide this livestream" may keep with the block list, or nil. Only a fixed ID that the viewer's hop
    /// proved (the viewer engine refuses a link whose authenticated prefix is not the advertised one) names that sender;
    /// an unproven ID could be a copy of someone else's, and a rotating ID can be replayed and changes every epoch.
    public static func keptRoute(_ offer: DiscoveryAnnouncement, hopAuthenticated: Bool) -> String? {
        hopAuthenticated && !offer.rotating ? routeKey(offer) : nil
    }

    /// Hides (1) routes whose source authenticated as a blocked person this run, (2) reported routes, and (3) the cost-0
    /// routes attributed to a blocked or reported person: by the fixed prefix, or for a rotating ID by the one contact it
    /// is recognised as. Review 2026-11-06 (the rule Windows and Android adopted): the logical stream token and the
    /// advertised prefix are chosen by the advertiser and are not authenticated (a rotating ID can be replayed), so an
    /// attributed route hides only itself. Relayed routes and other direct routes of the same token stay listed, so a
    /// spoofer who copies a genuine broadcast's token cannot hide it. A relayed copy of a blocked person's stream stays
    /// listed until someone opens it; playback then leaves as soon as its source authenticates as the blocked person
    /// (a direct source's route and a certified radio route then stay hidden through `hiddenRoute`). A stream heard only
    /// through relays cannot be attributed and stays.
    /// AB3: `hiddenAddresses` are radio addresses (`address`) hidden for this run by "Hide this livestream" on a route
    /// whose advertised ID was not proven: only that advertiser goes, never another sender's copy of the same route.
    public static func hide<T>(_ rows: [T], offer: (T) -> DiscoveryAnnouncement, blockedPrefixes: Set<String>, hiddenRoutes: Set<String>,
                               recognised: (DiscoveryAnnouncement) -> String?, hiddenRoute: (DiscoveryAnnouncement) -> Bool,
                               hiddenAddresses: Set<String> = [], address: (T) -> String? = { _ in nil }) -> [T] {
        rows.filter { row in
            if let radio = address(row), hiddenAddresses.contains(radio) { return false }
            let route = offer(row)
            if hiddenRoute(route) || hiddenRoutes.contains(routeKey(route)) { return false }
            guard route.routeCost == 0, !blockedPrefixes.isEmpty else { return true }
            let prefix = route.rotating ? recognised(route) : route.nodeIdPrefix.hex
            return !(prefix.map { blockedPrefixes.contains($0) } ?? false)
        }
    }
}
