import Foundation

/// One direct call's cutover between carrier 0 (Bluetooth) and one Wi-Fi carrier (Android CarrierCutover, the subset a
/// guest with one Wi-Fi carrier needs). Sequences are BME1 end-to-end content sequences. Lossy, never fatal.
public struct WifiCallCutover {
    public enum Verdict: Equatable { case deliver, hold, drop }
    public enum ControlResult: Equatable { case accepted, repeated, dropped, ignored, closeWifi }

    public static let holdSeconds: TimeInterval = 1
    public static let holdBytes = 5 * 1024 * 1024
    public static let cooldownSeconds: TimeInterval = 30
    public static let minActiveSeconds: TimeInterval = 3
    public static let maxQueueAge: TimeInterval = 0.5
    public static let maxFallbacks = 2

    /// The live Wi-Fi carrier, named by its attempt's ticket.
    public private(set) var ticket: Data?
    /// The attempt whose BIND/READY still runs: a SWITCH naming it is kept until the carrier comes up.
    private var expected: Data?
    private var early: UInt64?
    // Sender (this side's direction).
    public private(set) var sendOnWifi = false
    public private(set) var gen: UInt32 = 0
    public private(set) var fallbacks = 0
    public private(set) var cooldownUntil: TimeInterval = 0
    private var switchPending = false
    private var resumePending: Data?
    // Receiver (the peer's direction).
    public private(set) var acceptWifi = false
    public private(set) var boundary: UInt64 = 0
    public private(set) var oldFrom: UInt64 = 0
    public private(set) var lastOpened: UInt64?
    public private(set) var maxGen: UInt32 = 0
    private var lastSwitch: (gen: UInt32, boundary: UInt64)?
    private var held: [(sequence: UInt64, record: Data, at: TimeInterval)] = []
    private var heldBytes = 0
    // Design WF fragment rules due at the consumer.
    private var suppressDue = false, sendResetDue = false

    public init() {}

    public mutating func expect(ticket: Data) { expected = ticket; early = nil }
    public mutating func attemptEnded() { expected = nil; early = nil }

    public mutating func carrierUp(ticket: Data) {
        self.ticket = ticket; held = []; heldBytes = 0
        if expected == ticket, let b = early { acceptWifi = true; boundary = b } else { acceptWifi = false }
        expected = nil; early = nil
    }

    /// Android maybeSwitch: true when this side may move its own direction now (the SWITCH is sealed by takeMarker).
    public mutating func requestSwitch(now: TimeInterval, activeSince: TimeInterval?, oldestQueuedAge: TimeInterval) -> Bool {
        guard ticket != nil, !sendOnWifi, !switchPending, let since = activeSince, now - since >= Self.minActiveSeconds,
              oldestQueuedAge < Self.maxQueueAge, now >= cooldownUntil, fallbacks < Self.maxFallbacks else { return false }
        switchPending = true
        return true
    }

    public var hasMarker: Bool { switchPending || resumePending != nil }

    /// The SWITCH or RESUME to seal on Bluetooth now, ahead of any further Bluetooth output. `nextSequence` is the BME1
    /// sequence the next sealed content record will carry, so every earlier one already left on Bluetooth.
    public mutating func takeMarker(nextSequence: UInt64) -> Bwf1? {
        if let resumed = resumePending {
            resumePending = nil; switchPending = false; gen += 1
            return .resume(gen: gen, ticket: resumed, e2eNext: nextSequence, meshNext: 0)
        }
        guard switchPending, let ticket else { switchPending = false; return nil }
        switchPending = false; gen += 1; sendOnWifi = true
        return .switchTo(gen: gen, ticket: ticket, e2eBoundary: nextSequence, meshBoundary: 0)
    }

    /// The Wi-Fi carrier is gone (died, released, the peer's RESUME). Reading returns to Bluetooth at once; a RESUME is
    /// due on Bluetooth unless `announce` is false (after a protocol violation no BWF1 is sent).
    public mutating func wifiLost(now: TimeInterval, announce: Bool = true) {
        guard let lost = ticket else { return }
        if sendOnWifi { fallbacks += 1; cooldownUntil = now + Self.cooldownSeconds; sendResetDue = true }
        if acceptWifi { suppressDue = true }
        sendOnWifi = false; switchPending = false; acceptWifi = false; ticket = nil; held = []; heldBytes = 0
        if announce { resumePending = lost }
    }

    public mutating func receivedSwitch(gen g: UInt32, ticket t: Data, boundary b: UInt64) -> ControlResult {
        if let last = lastSwitch, last.gen == g, last.boundary == b { return .repeated }
        guard g > maxGen else { return .dropped }
        maxGen = g
        if let ticket, t == ticket { lastSwitch = (g, b); acceptWifi = true; boundary = b; return .accepted }
        if let expected, t == expected { lastSwitch = (g, b); early = b; return .accepted }
        return .dropped
    }

    public mutating func receivedResume(gen g: UInt32, ticket t: Data, next: UInt64) -> ControlResult {
        guard g > maxGen else { return .dropped }
        maxGen = g
        guard t == ticket || t == expected else { return .ignored }
        oldFrom = max(oldFrom, next)
        return .closeWifi
    }

    public func bluetoothVerdict(sequence s: UInt64) -> Verdict {
        if acceptWifi, s >= boundary { return .drop }
        if s < oldFrom { return .drop }
        if let last = lastOpened, s <= last { return .drop }
        return .deliver
    }

    public mutating func wifiVerdict(sequence s: UInt64, record: Data, now: TimeInterval) -> Verdict {
        guard ticket != nil else { return .drop }
        guard acceptWifi else { held.append((s, record, now)); heldBytes += record.count; return .hold }
        if s < boundary { return .drop }
        if let last = lastOpened, s <= last { return .drop }
        return .deliver
    }

    public mutating func delivered(sequence s: UInt64) { lastOpened = s }

    /// Design WF: `suppressReceive` when the peer's direction left Wi-Fi while this side read it there (the peer's
    /// RESUME, the carrier's loss) or a hold was promoted: drop the half-received frame, skip fragments until a frame
    /// starts, ask the peer for a keyframe. `resetSend` when this side's own direction fell back: drop the unsent
    /// fragments of the current frame (the local keyframe is already requested). Each is reported once.
    public mutating func takeFragmentActions() -> (suppressReceive: Bool, resetSend: Bool) {
        defer { suppressDue = false; sendResetDue = false }
        return (suppressDue, sendResetDue)
    }

    /// Held Wi-Fi records that may be delivered now, in arrival order: after an accepted SWITCH those at or past its
    /// boundary; without one, after 1 s or 5 MiB, all past the last delivered sequence (Android's promotion).
    public mutating func takeReleased(now: TimeInterval) -> [(sequence: UInt64, record: Data)] {
        guard let first = held.first else { return [] }
        if !acceptWifi {
            guard now - first.at >= Self.holdSeconds || heldBytes >= Self.holdBytes else { return [] }
            acceptWifi = true; boundary = lastOpened.map { $0 + 1 } ?? 0
            suppressDue = true
        }
        // Android releaseHeld: each record must be at or past the boundary and past the last one released before it, so a
        // repeated or lower sequence in the hold is dropped here and never reaches the opener (a replay ends the call).
        var high = lastOpened
        var out: [(sequence: UInt64, record: Data)] = []
        for item in held where item.sequence >= boundary && (high.map { item.sequence > $0 } ?? true) {
            out.append((item.sequence, item.record)); high = item.sequence
        }
        held = []; heldBytes = 0
        return out
    }
}
