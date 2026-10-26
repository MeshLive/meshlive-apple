import Foundation

/// Experimental `GR1` lost-chunk recovery (DECISIONS "Design GR" option C, PROTOCOL "Draft: lost-chunk recovery";
/// Android GattChunkRecovery.kt). Every message is a type-2 GATT value, which every older reader ignores. The constants
/// are part of the contract: every platform uses the same values. Default off (`-gattChunkRecovery YES` turns it on).
public enum Gr1 {
    public static let type: UInt8 = 2
    static let g: UInt8 = 0x47, r: UInt8 = 0x52
    public static let opHello: UInt8 = 1, opNack: UInt8 = 2, opGone: UInt8 = 3, opHigh: UInt8 = 4
    public static let version: UInt8 = 1
    public static let historySeconds: TimeInterval = 2
    public static let historyValues = 1_024
    public static let historyBytes = 262_144
    public static let helloRepeat: TimeInterval = 1
    public static let round: TimeInterval = 0.25
    public static let maxRequests = 3
    public static let deadline: TimeInterval = 1
    public static let readerNacksPerSecond = 20
    public static let resendsPerSequence = 3
    public static let resendBudgetPercent = 25
    public static let resendFloorBytesPerSecond = 1_024
    public static let highIdle: TimeInterval = 0.2
    public static let highPerSecond = 2
    public static let maxOutOfRangeNackRanges = 8
    public static let maxRanges = 8
    public static let maxRun = 255
    public static let tick: TimeInterval = 0.05

    /// Sequence arithmetic modulo 2^32: positive when `a` comes after `b`.
    public static func after(_ a: UInt32, _ b: UInt32) -> Int { Int(Int32(bitPattern: a &- b)) }

    public struct SeqRange: Equatable {
        public let first: UInt32, run: Int
        public init(first: UInt32, run: Int) { self.first = first; self.run = run }
        public var last: UInt32 { first &+ UInt32(run - 1) }
        func overlaps(_ otherFirst: UInt32, _ otherLast: UInt32) -> Bool { Gr1.after(last, otherFirst) >= 0 && Gr1.after(otherLast, first) >= 0 }
    }

    public enum Message: Equatable {
        case hello(values: Int, bytes: Int, ms: Int)
        case nack([SeqRange])
        case gone(SeqRange)
        case high(UInt32)
    }

    public static func isGr1(_ v: Data) -> Bool { v.count >= 4 && v[v.startIndex] == type && v[v.startIndex + 1] == g && v[v.startIndex + 2] == r }

    private static func header(_ op: UInt8) -> BinaryWriter { var w = BinaryWriter(capacity: 16); w.byte(type); w.byte(g); w.byte(r); w.byte(op); return w }

    public static func hello(values: Int = historyValues, bytes: Int = historyBytes, ms: Int = Int(historySeconds * 1000)) -> Data {
        var w = header(opHello); w.byte(version); w.u16(UInt16(values)); w.u32(UInt32(bytes)); w.u16(UInt16(ms)); return w.data
    }
    public static func nack(_ ranges: [SeqRange]) -> Data {
        precondition((1...maxRanges).contains(ranges.count) && ranges.allSatisfy { (1...maxRun).contains($0.run) })
        var w = header(opNack); w.byte(UInt8(ranges.count))
        for range in ranges { w.u32(range.first); w.byte(UInt8(range.run)) }
        return w.data
    }
    public static func gone(_ range: SeqRange) -> Data { var w = header(opGone); w.u32(range.first); w.byte(UInt8(range.run)); return w.data }
    public static func high(_ sequence: UInt32) -> Data { var w = header(opHigh); w.u32(sequence); return w.data }

    /// NACK ranges one value can carry at this ATT value limit (0 while the link cannot send).
    public static func nackRangesFitting(valueLimit: Int) -> Int { valueLimit < 10 ? 0 : min(maxRanges, (valueLimit - 5) / 5) }

    /// nil for anything that is not a well-formed `GR1` message (it is then ignored, like any other type-2 value).
    public static func decode(_ value: Data) -> Message? {
        let v = value.rebased
        guard isGr1(v) else { return nil }
        func u16(_ at: Int) -> Int { Int(v[at]) << 8 | Int(v[at + 1]) }
        func u32(_ at: Int) -> UInt32 { UInt32(v[at]) << 24 | UInt32(v[at + 1]) << 16 | UInt32(v[at + 2]) << 8 | UInt32(v[at + 3]) }
        switch v[3] {
        case opHello:
            guard v.count == 13, v[4] == version else { return nil }
            let values = u16(5), bytes = Int(u32(7))
            guard values > 0, bytes > 0 else { return nil }
            // Clamped to this build's own limits: a larger claim cannot widen what the reader waits for.
            return .hello(values: min(values, historyValues), bytes: min(bytes, historyBytes), ms: min(u16(11), Int(historySeconds * 1000)))
        case opNack:
            guard v.count >= 5 else { return nil }
            let count = Int(v[4])
            guard (1...maxRanges).contains(count), v.count == 5 + 5 * count else { return nil }
            let ranges = (0..<count).map { SeqRange(first: u32(5 + 5 * $0), run: Int(v[9 + 5 * $0])) }
            return ranges.contains { $0.run == 0 } ? nil : .nack(ranges)
        case opGone:
            guard v.count == 9, v[8] != 0 else { return nil }
            return .gone(SeqRange(first: u32(4), run: Int(v[8])))
        case opHigh:
            return v.count == 8 ? .high(u32(4)) : nil
        default:
            return nil
        }
    }
}

/// Data values this side sent, byte for byte, for resends (Android ResendHistory).
final class Gr1History {
    final class Entry { let sequence: UInt32, value: Data, sentAt: TimeInterval; var resends = 0
        init(_ s: UInt32, _ v: Data, _ t: TimeInterval) { sequence = s; value = v; sentAt = t } }
    private var entries: [Entry] = []
    private(set) var heldBytes = 0
    private(set) var lastSent: UInt32?

    func record(_ sequence: UInt32, _ value: Data, now: TimeInterval) {
        entries.append(Entry(sequence, Data(value), now)); heldBytes += value.count; lastSent = sequence
        while entries.count > Gr1.historyValues || heldBytes > Gr1.historyBytes { dropOldest() }
        prune(now)
    }
    func find(_ sequence: UInt32, now: TimeInterval) -> Entry? {
        prune(now)
        guard let first = entries.first else { return nil }
        let offset = Gr1.after(sequence, first.sequence)
        guard offset >= 0, offset < entries.count else { return nil }
        return entries[offset].sequence == sequence ? entries[offset] : entries.first { $0.sequence == sequence }
    }
    private func prune(_ now: TimeInterval) { while let first = entries.first, now - first.sentAt > Gr1.historySeconds { dropOldest() } }
    private func dropOldest() { heldBytes -= entries.removeFirst().value.count }
}

/// Bytes over a rolling 1 s window in 10 slots (Android RollingBytes).
struct Gr1RollingBytes {
    private var counts = [Int](repeating: 0, count: 10), epochs = [Int](repeating: Int.min, count: 10)
    mutating func add(_ now: TimeInterval, _ bytes: Int) {
        let epoch = Int((now * 10).rounded(.down)), slot = ((epoch % 10) + 10) % 10
        if epochs[slot] != epoch { epochs[slot] = epoch; counts[slot] = 0 }
        counts[slot] += bytes
    }
    func sum(_ now: TimeInterval) -> Int {
        let epoch = Int((now * 10).rounded(.down))
        return (0..<10).reduce(0) { $0 + (epochs[$1] > epoch - 10 && epochs[$1] <= epoch ? counts[$1] : 0) }
    }
}

/// Lost-chunk recovery for one GATT connection. Single-threaded (the iPhone/Mac links run on the main queue): the
/// link sends `nextPriorityValue()` before each new data value, calls `onDataSent` for every data value, routes type-2
/// values to `onControl` and calls `tick` every 50 ms. The reader half lives in `GattChunkReader` (it calls `update`).
public final class GattChunkRecovery {
    private let log: (String) -> Void
    private var outbound: [(value: Data, kind: String, sequence: UInt32, enqueuedAt: TimeInterval)] = []
    public private(set) var peerHello: (values: Int, bytes: Int, ms: Int)?
    public private(set) var valueLimit = 0
    private var closed = false
    // Sender
    let history = Gr1History()
    private var sentData = Gr1RollingBytes(), resent = Gr1RollingBytes()
    private var outOfRangeRanges = 0, nacksIgnored = false
    private var lastDataSentAt: TimeInterval = 0
    private var highSentFor: UInt32?
    private var highTimes: [TimeInterval] = []
    private var helloSends = 0, helloFirstAt: TimeInterval = 0
    // Reader
    private struct Hole { let first: UInt32, last: UInt32, firstMissingAt: TimeInterval; var requests: Int, lastRequestAt: TimeInterval }
    private var holes: [Hole] = []
    private var highHeard: UInt32?
    private var nackTimes: [TimeInterval] = []

    public init(log: @escaping (String) -> Void) { self.log = log }

    /// The reader waits for resends (instead of the fail-fast) only after the peer's HELLO.
    public var readerActive: Bool { peerHello != nil }

    public func start(valueLimit: Int, now: TimeInterval) {
        guard !closed else { return }
        self.valueLimit = valueLimit
        enqueueHello(now)
    }

    public func close() { closed = true; outbound.removeAll() }

    /// The next control value or resend, sent ahead of any new data value.
    public func nextPriorityValue(now: TimeInterval) -> Data? {
        guard !closed, !outbound.isEmpty else { return nil }
        let item = outbound.removeFirst()
        switch item.kind {
        case "resend": log("event=resend | seq=\(item.sequence) | bytes=\(item.value.count) | queuedAheadMs=\(Int((now - item.enqueuedAt) * 1000))")
        case "gone", "high": log("event=\(item.kind)_sent | seq=\(item.sequence)")
        default: break
        }
        return item.value
    }
    public var hasPriorityValues: Bool { !outbound.isEmpty }
    /// The next value without taking it (a server whose notification queue is full tries it again first).
    public func peekPriorityValue() -> Data? { closed ? nil : outbound.first?.value }

    public func onDataSent(sequence: UInt32, value: Data, now: TimeInterval) {
        history.record(sequence, value, now: now); sentData.add(now, value.count); lastDataSentAt = now
    }

    /// A type-2 value from the peer. GONE and HIGH are handed to `reader` (the link's chunk reader).
    public func onControl(_ value: Data, now: TimeInterval, reader: inout GattChunkReader) {
        guard !closed else { return }
        guard let message = Gr1.decode(value) else {
            if Gr1.isGr1(value.rebased) { log("event=ignored | reason=malformed | bytes=\(value.count)") }
            return
        }
        switch message {
        case .hello(let values, let bytes, let ms):
            if peerHello == nil { log("event=hello | historyValues=\(values) | historyBytes=\(bytes) | historyMs=\(ms)") }
            peerHello = (values, bytes, ms)
        case .nack(let ranges): onNack(ranges, now: now)
        case .gone(let range): reader.recoveryGone(range)
        case .high(let sequence): reader.recoveryHigh(sequence)
        }
    }

    /// Timers: the second HELLO and the idle HIGH probe (the reader's rounds run in its `update`).
    public func tick(now: TimeInterval) {
        guard !closed else { return }
        if helloSends == 1, now - helloFirstAt >= Gr1.helloRepeat { enqueueHello(now) }
        if let last = history.lastSent, peerHello != nil, highSentFor != last, now - lastDataSentAt >= Gr1.highIdle {
            highTimes.removeAll { now - $0 >= 1 }
            if highTimes.count < Gr1.highPerSecond {
                highTimes.append(now); highSentFor = last
                outbound.append((Gr1.high(last), "high", last, now))
            }
        }
    }

    private func enqueueHello(_ now: TimeInterval) {
        helloSends += 1
        if helloSends == 1 { helloFirstAt = now }
        outbound.insert((Gr1.hello(), "hello", 0, now), at: 0)
        log("event=hello_sent | n=\(helloSends)")
    }

    private func onNack(_ ranges: [Gr1.SeqRange], now: TimeInterval) {
        guard !nacksIgnored else { return }
        let budget = max(sentData.sum(now) * Gr1.resendBudgetPercent / 100, Gr1.resendFloorBytesPerSecond)
        var queued = 0, capped = 0, exhausted = 0
        var gone: [UInt32] = []
        for range in ranges {
            var outOfRange = false
            for index in 0..<range.run {
                let sequence = range.first &+ UInt32(index)
                guard let last = history.lastSent, Gr1.after(sequence, last) <= 0 else { outOfRange = true; continue }
                guard let entry = history.find(sequence, now: now) else { gone.append(sequence); continue }
                if entry.resends >= Gr1.resendsPerSequence { exhausted += 1 }
                else if resent.sum(now) + entry.value.count > budget { capped += 1 }
                else { entry.resends += 1; resent.add(now, entry.value.count); outbound.append((Data(entry.value), "resend", sequence, now)); queued += 1 }
            }
            if outOfRange { outOfRangeRanges += 1; if outOfRangeRanges > Gr1.maxOutOfRangeNackRanges { nacksIgnored = true; break } }
        }
        for range in coalesce(gone).reversed() { outbound.insert((Gr1.gone(range), "gone", range.first, now), at: 0) }
        log("event=nack_received | seq=\(ranges[0].first) | ranges=\(ranges.count) | queued=\(queued) | gone=\(gone.count) | exhausted=\(exhausted)")
        if capped > 0 { log("event=capped | values=\(capped) | budgetBytesPerSecond=\(budget)") }
        if nacksIgnored { log("event=nacks_ignored | reason=out_of_range | ranges=\(outOfRangeRanges)") }
    }

    private func coalesce(_ sequences: [UInt32]) -> [Gr1.SeqRange] {
        var out: [Gr1.SeqRange] = []
        for s in sequences {
            if let last = out.last, Gr1.after(s, last.last) == 1, last.run < Gr1.maxRun { out[out.count - 1] = Gr1.SeqRange(first: last.first, run: last.run + 1) }
            else { out.append(Gr1.SeqRange(first: s, run: 1)) }
        }
        return out
    }

    // MARK: Reader half

    private var readerLimit: Int { min(peerHello?.values ?? 0, Gr1.historyValues) }

    func onHigh(_ sequence: UInt32, next: UInt32) -> Bool {
        guard readerActive else { return false }
        let distance = Gr1.after(sequence, next)
        guard distance >= 0 else { return false }
        guard distance < readerLimit else { log("event=ignored | reason=high_out_of_range | seq=\(sequence) | next=\(next)"); return false }
        if highHeard.map({ Gr1.after(sequence, $0) > 0 }) ?? true { highHeard = sequence }
        return true
    }

    func goneHit(_ range: Gr1.SeqRange) -> UInt32? {
        guard let hole = holes.first(where: { range.overlaps($0.first, $0.last) }) else { return nil }
        return Gr1.after(range.first, hole.first) > 0 ? range.first : hole.first
    }

    /// Re-evaluates the missing ranges and sends due requests; a failure reason, or nil.
    func update(next: UInt32, pending: [UInt32], parkedBytes: Int, now: TimeInterval) -> String? {
        guard let peer = peerHello else { return nil }
        let limit = readerLimit
        let farthest = pending.last.map { Gr1.after($0, next) } ?? -1
        if !pending.isEmpty && (farthest >= limit || pending.count >= limit || parkedBytes > peer.bytes) {
            return "GATT chunk \(next) was lost (the peer no longer holds it: \(pending.count) later chunks, \(parkedBytes) bytes)"
        }
        if let heard = highHeard, Gr1.after(heard, next) < 0 { highHeard = nil }
        var fresh: [(UInt32, UInt32)] = []
        var expected = next
        for key in pending {
            if Gr1.after(key, expected) > 0 { fresh.append((expected, key &- 1)) }
            expected = key &+ 1
        }
        if let heard = highHeard, Gr1.after(heard, expected) >= 0 { fresh.append((expected, heard)) }
        let maxSequence = next &+ UInt32(max(limit - 1, 0))
        let old = holes
        holes = fresh.compactMap { first, last in
            guard Gr1.after(first, next) < limit else { return nil }
            let clipped = Gr1.after(last, maxSequence) > 0 ? maxSequence : last
            let prior = old.first { Gr1.after(clipped, $0.first) >= 0 && Gr1.after($0.last, first) >= 0 }
            return Hole(first: first, last: clipped, firstMissingAt: prior?.firstMissingAt ?? now, requests: prior?.requests ?? 0, lastRequestAt: prior?.lastRequestAt ?? 0)
        }
        for filled in old where !holes.contains(where: { Gr1.after($0.last, filled.first) >= 0 && Gr1.after(filled.last, $0.first) >= 0 }) {
            log("event=recovered | seq=\(filled.first) | count=\(Gr1.after(filled.last, filled.first) + 1) | waitedMs=\(Int((now - filled.firstMissingAt) * 1000)) | rounds=\(filled.requests)")
        }
        if let hole = holes.first(where: { now - $0.firstMissingAt >= Gr1.deadline }) {
            return "GATT chunk \(hole.first) was lost (\(hole.requests) requests, \(Int((now - hole.firstMissingAt) * 1000)) ms)"
        }
        requestDue(now)
        return nil
    }

    private func requestDue(_ now: TimeInterval) {
        let due = holes.indices.filter { holes[$0].requests == 0 || (holes[$0].requests < Gr1.maxRequests && now - holes[$0].lastRequestAt >= Gr1.round) }
        guard !due.isEmpty else { return }
        let fit = Gr1.nackRangesFitting(valueLimit: valueLimit)
        guard fit > 0 else { return }
        nackTimes.removeAll { now - $0 >= 1 }
        guard nackTimes.count < Gr1.readerNacksPerSecond else { return }
        var ranges: [Gr1.SeqRange] = [], asked: [Int] = []
        for index in due {
            if ranges.count >= fit { break }
            var start = holes[index].first, left = Gr1.after(holes[index].last, holes[index].first) + 1
            while left > 0 && ranges.count < fit {
                let run = min(left, Gr1.maxRun)
                ranges.append(Gr1.SeqRange(first: start, run: run)); start = start &+ UInt32(run); left -= run
            }
            asked.append(index)
        }
        for index in asked { holes[index].requests += 1; holes[index].lastRequestAt = now }
        nackTimes.append(now)
        outbound.insert((Gr1.nack(ranges), "nack", ranges[0].first, now), at: 0)
        log("event=nack | seq=\(ranges[0].first) | ranges=\(ranges.count) | round=\(asked.map { holes[$0].requests }.max() ?? 0)")
    }
}
