import Foundation

/// Paces a stream child link at the child-measured delivery rate (Android LinkSelfMeasurement.kt LinkPacer, same
/// constants), so the backlog stays in the app queue (where audio goes first and rate control sees it) instead of in
/// the Bluetooth stack. Until the child's first measurement the link is paced from a seed (the learned capacity, or a
/// conservative prior); with no report the seed is halved every 2 s after a 4 s grace, down to 150 kbps. On-time
/// reports from an unmeasured child hold the seed (DECISIONS "Starting pace of an unmeasured stream link"), and the
/// on-time seed raise (default ON on Android since 2026-10-16) grows a held seed 25% per report, up to 1500 kbps,
/// while this sender's own queue is at least 0.5 s old. All times are nanoseconds of a monotonic clock.
public final class LinkPacer {
    public static let burstNs: Int64 = 50_000_000
    /// The train median read 10-30% below integrity probes; pacing must not cap below the link.
    public static let paceGain = 1.2
    public static let silenceGraceNs: Int64 = 4_000_000_000
    public static let silenceStepNs: Int64 = 2_000_000_000
    public static let minSeedKbps = 150
    public static let seedRaiseBacklogMs: Int64 = 500
    public static let seedRaiseNum: Int64 = 5, seedRaiseDen: Int64 = 4
    public static let seedRaiseCapKbps = 1500

    private let nanoTime: () -> Int64
    private let burstNs: Int64
    private var measuredBytesPerSecond: Int64 = 0
    private var seedBytesPerSecond: Int64 = 0
    private var seededAtNs: Int64 = 0
    private var virtualDrainNs: Int64 = 0
    /// When a link draining exactly at the un-gained rate would be empty (for logs).
    private var modelDrainNs: Int64 = 0

    public static func monotonicNs() -> Int64 { Int64(DispatchTime.now().uptimeNanoseconds) }

    public init(nanoTime: @escaping () -> Int64 = LinkPacer.monotonicNs, burstNs: Int64 = LinkPacer.burstNs) {
        self.nanoTime = nanoTime; self.burstNs = burstNs
    }

    static func paced(_ kbps: Int) -> Int64 { Int64(Double(Int64(kbps) * 1_000 / 8) * paceGain) }

    /// 0 = unpaced (nothing measured or seeded). The current pace, including seed decay.
    public var bytesPerSecond: Int64 { currentRate() }
    /// True once the child reported a measurement; the seed no longer applies.
    public var measured: Bool { measuredBytesPerSecond > 0 }
    /// The current undecayed seed in link kbps (without the gain), 0 when none.
    public var seedKbps: Int { Int(Double(seedBytesPerSecond * 8 / 1_000) / Self.paceGain) }

    public func setMeasuredLinkKbps(_ kbps: Int) {
        let seededRate = measuredBytesPerSecond == 0 ? currentRate() : 0
        let rate = Self.paced(kbps)
        if seededRate > 0 && rate > 0 {
            // The first report replaces the seed: the bytes already charged drain at the measured rate.
            rescale(from: seededRate, to: rate)
        }
        measuredBytesPerSecond = rate
    }

    /// Paces at `kbps` until the first measurement; ignored once measured or already seeded.
    @discardableResult
    public func seed(kbps: Int) -> Bool {
        guard kbps > 0, measuredBytesPerSecond == 0, seedBytesPerSecond == 0 else { return false }
        seedBytesPerSecond = Self.paced(kbps)
        seededAtNs = nanoTime()
        return true
    }

    /// An on-time report from an unmeasured child: restart the silence clock (restoring a decayed seed) and, with a
    /// sender backlog of at least 0.5 s (`raiseBacklogMs`, negative = raise off), grow the seed by 5/4 up to the cap.
    @discardableResult
    public func holdSeed(raiseBacklogMs: Int64 = -1) -> Bool {
        guard measuredBytesPerSecond == 0, seedBytesPerSecond > 0 else { return false }
        let now = nanoTime()
        if raiseBacklogMs >= Self.seedRaiseBacklogMs {
            let previous = currentRate()
            let raised = min(Self.paced(Self.seedRaiseCapKbps), seedBytesPerSecond * Self.seedRaiseNum / Self.seedRaiseDen)
            if raised > seedBytesPerSecond {
                seedBytesPerSecond = raised
                // Bytes already charged drain at the new pace, as when a measurement replaces the seed.
                if previous > 0 { rescale(from: previous, to: raised) }
            }
        }
        seededAtNs = now
        return true
    }

    private func rescale(from oldRate: Int64, to newRate: Int64) {
        let now = nanoTime()
        if virtualDrainNs > now { virtualDrainNs = now + (virtualDrainNs - now) * oldRate / newRate }
        if modelDrainNs > now { modelDrainNs = now + (modelDrainNs - now) * oldRate / newRate }
    }

    private func currentRate() -> Int64 {
        if measuredBytesPerSecond > 0 { return measuredBytesPerSecond }
        guard seedBytesPerSecond > 0 else { return 0 }
        return Self.decayedSeed(seedBytesPerSecond, silenceNs: nanoTime() - seededAtNs)
    }

    /// Nanoseconds to wait before the next write may start.
    public func waitNs() -> Int64 {
        guard currentRate() > 0 else { return 0 }
        return max(0, virtualDrainNs - burstNs - nanoTime())
    }

    /// Charges `bytes` from `writeStartedNs` (a blocking write is not paid twice).
    public func onSent(_ bytes: Int, writeStartedNs: Int64? = nil) {
        let rate = currentRate()
        guard rate > 0 else { return }
        let start = writeStartedNs ?? nanoTime()
        virtualDrainNs = max(virtualDrainNs, start) + Int64(bytes) * 1_000_000_000 / rate
        let baseRate = max(1, Int64(Double(rate) / Self.paceGain))
        modelDrainNs = max(modelDrainNs, start) + Int64(bytes) * 1_000_000_000 / baseRate
    }

    /// Seed pace after `silenceNs` without any report: halved per step beyond the grace, with a floor.
    public static func decayedSeed(_ seedBytesPerSecond: Int64, silenceNs: Int64) -> Int64 {
        if silenceNs <= silenceGraceNs { return seedBytesPerSecond }
        let steps = Int(min((silenceNs - silenceGraceNs) / silenceStepNs + 1, 16))
        let floor = paced(minSeedKbps)
        return max(min(seedBytesPerSecond, floor), seedBytesPerSecond >> steps)
    }

    /// Android LinkPacerSeed.priorKbps with the PHY unknown (CoreBluetooth does not expose it): the 2M/unknown prior.
    public static func priorKbps(_ transport: MeshTransport) -> Int { 350 }

    /// The phone's own measurement for the transport when it has one, else the conservative prior.
    public static func seedKbps(_ transport: MeshTransport, probeKbps: Int?) -> Int {
        if let probeKbps, probeKbps > 0 { return probeKbps }
        return priorKbps(transport)
    }
}
