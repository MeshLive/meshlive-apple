import Foundation
import NearbyCore

/// Native call feedback from the existing version-3 report. Queue estimation follows Android's
/// PeerDeliveryEstimate (LinkRateController.kt); video goodput excludes the audio actually delivered.
/// No wire fields or peer-provided capacity claims are added.
final class DesktopCallDelivery {
    struct Sample {
        let videoKbps: Double
        let queueMs: Int
    }
    struct RateInput {
        let queueAge: TimeInterval
        let deliveredKbps: Double
        let usesPeer: Bool
    }
    private struct Write {
        let total: Int64, video: Int64, atMs: Int64
        let audio: Bool
    }
    private struct Observation {
        let clock: Int64, video: Int64
    }
    private var writes: [Write] = []
    private var pruned = false
    private var sent: Int64 = 0, sentVideo: Int64 = 0
    private var lastBytes: UInt32?, lastClock: UInt32?
    private var received: Int64 = 0, clock: Int64 = 0
    private var history: [Observation] = []
    private var bases: [(bucket: Int64, minimum: Int64)] = []
    private var pending: Sample?
    private(set) var latest: Sample?
    private(set) var fault: String?
    private var reports = 0, legacyReports = 0
    private var usingPeer = false

    func submitted(payloadBytes: Int, audio: Bool, at: TimeInterval) {
        guard payloadBytes > 0 else { return }
        sent += Int64(payloadBytes)
        if !audio { sentVideo += Int64(payloadBytes) }
        let ms = Int64(at * 1_000)
        writes.append(Write(total: sent, video: sentVideo, atMs: ms, audio: audio))
        // Same 20-second write history as Android. An older acknowledgement is unmeasurable.
        while writes.count > 1, ms - writes[0].atMs > 20_000 { writes.removeFirst(); pruned = true }
    }

    func accept(_ report: LinkCapacityReport) {
        reports += 1
        guard let rawBytes = report.receivedBytes, let rawClock = report.clockMs else {
            legacyReports += 1; pending = nil; return
        }
        guard fault == nil else { return }
        if let lastBytes, let lastClock {
            let bytes = rawBytes &- lastBytes, ms = rawClock &- lastClock
            guard bytes < 0x8000_0000, ms < 0x8000_0000 else { invalidate("counter_reset"); return }
            received += Int64(bytes); clock += Int64(ms)
        } else {
            let behind = (sent - Int64(rawBytes)) & 0xffff_ffff
            received = behind >= 0x8000_0000 ? sent + (0x1_0000_0000 - behind) : sent - behind
            clock = Int64(rawClock)
        }
        lastBytes = rawBytes; lastClock = rawClock
        guard received <= sent else {
            pending = nil
            if received - sent > 1_048_576 { invalidate("counter_ahead") }
            return
        }
        guard received > 0, history.last.map({ clock > $0.clock }) ?? true else { return }
        guard let index = writes.firstIndex(where: { $0.total >= received }),
              !(index == 0 && pruned && writes[0].total > received) else { pending = nil; return }
        let write = writes[index]
        let video = write.video - (write.audio ? 0 : write.total - received)
        let delay = clock - write.atMs, bucket = clock / 10_000
        if let last = bases.last, last.bucket == bucket {
            bases[bases.count - 1].minimum = min(last.minimum, delay)
        } else { bases.append((bucket, delay)) }
        while bases.count > 1, bucket - bases[0].bucket >= 12 { bases.removeFirst() }
        let queue = Int(max(0, min(60_000, delay - bases.map(\.minimum).min()!)))

        func rate(_ earlier: Observation) -> Double {
            guard clock > earlier.clock else { return 0 }
            return min(1_000_000, max(0, Double(video - earlier.video) * 8 / Double(clock - earlier.clock)))
        }
        let interval = history.last.flatMap { clock - $0.clock >= 500 ? rate($0) : nil } ?? 0
        history.append(Observation(clock: clock, video: video))
        while history.count > 1, clock - history[0].clock > 2_200 { history.removeFirst() }
        let span = clock - history[0].clock >= 800 ? rate(history[0]) : 0
        let sample = Sample(videoKbps: max(span, interval), queueMs: queue)
        latest = sample; pending = sample
    }

    private func invalidate(_ reason: String) {
        fault = reason; latest = nil; pending = nil; history.removeAll(); bases.removeAll()
    }

    /// Only a new media observation can affect a rate window. Repeated idle heartbeats cannot
    /// repeatedly cut the encoder using stale delay, and legacy/invalid reports use local evidence.
    func rateInput(enabled: Bool, localQueueAge: TimeInterval, localDeliveredKbps: Double) -> RateInput {
        let sample = pending; pending = nil
        if enabled, fault == nil, let sample, sample.videoKbps > 0 {
            usingPeer = true
            return RateInput(queueAge: max(0, localQueueAge) + Double(sample.queueMs) / 1_000,
                             deliveredKbps: sample.videoKbps, usesPeer: true)
        }
        usingPeer = false
        return RateInput(queueAge: localQueueAge, deliveredKbps: localDeliveredKbps, usesPeer: false)
    }

    var logFields: [String: String] {
        ["peerDeliveryReports": "\(reports)", "peerLegacyReports": "\(legacyReports)",
         "peerMediaSubmitted": "\(sent)", "peerFeedbackFault": fault ?? "none",
         "peerMediaAcknowledged": "\(received)", "peerClockMs": "\(clock)", "peerRateUsesPeer": "\(usingPeer)",
         "peerVideoKbps": latest.map { String(format: "%.1f", $0.videoKbps) } ?? "unknown",
         "peerQueueMs": latest.map { "\($0.queueMs)" } ?? "unknown"]
    }
}
