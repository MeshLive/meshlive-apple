import Foundation

/// Sender-side video rate control from what the link actually carries (Android adapts its call encoder the
/// same way: "sending X of 300 kbps ... delivered ... peer queue"). Measured on an iPhone 14 Plus -> M31 GATT
/// call: the iPhone encoded ~240 kbps of VP9 while the GATT client direction delivered ~125-135 kbps, so
/// video waited longer and longer in the send queue (receiver lateness grew to 3.9 s; a third of the frames
/// were still queued when the call ended). Each window compares the queue age and the delivered video rate
/// with what the encoder produced, and moves the encoder target: down below the delivered rate when a backlog
/// builds, and up slowly while the queue stays near empty. Requested maximum and a floor bound it.
public struct VideoRateController {
    public let maxKbps: Int
    public let minKbps: Int
    public private(set) var targetKbps: Int
    private var calmWindows = 0

    public init(startKbps: Int, maxKbps: Int, minKbps: Int = 48) {
        self.maxKbps = maxKbps; self.minKbps = min(minKbps, maxKbps)
        targetKbps = max(self.minKbps, min(maxKbps, startKbps))
    }

    /// One measurement window (about 1 s). Returns the new encoder target when it changes.
    /// - Parameters:
    ///   - queueAge: age of the oldest unsent video frame at the end of the window.
    ///   - encodedKbps: video bitrate the encoder produced in the window.
    ///   - deliveredKbps: video bitrate handed to the transport in the window.
    public mutating func update(queueAge: TimeInterval, encodedKbps: Double, deliveredKbps: Double) -> Int? {
        // No evidence: the encoder barely produced (camera starting, app stalled or backgrounded). Measured case:
        // a 9 s main-queue stall gave encoded 5 / delivered 4 kbps and drove the target to the floor.
        guard encodedKbps >= max(8, Double(targetKbps) * 0.2) else { calmWindows = 0; return nil }
        var next = targetKbps
        let backlog = queueAge > 0.5 || (queueAge > 0.25 && deliveredKbps < encodedKbps * 0.9)
        if backlog {
            // Aim below what actually got through, lower still when the backlog is already long.
            let basis = deliveredKbps > 1 ? deliveredKbps : Double(targetKbps) * 0.5
            let drain = queueAge > 1 ? 0.7 : 0.85
            next = Int(min(Double(targetKbps) * 0.85, basis * drain))
            calmWindows = 0
        } else if queueAge < 0.15 {
            calmWindows += 1
            if calmWindows >= 2 { next = Int(Double(targetKbps) * 1.08) + 4; calmWindows = 0 }
        } else {
            calmWindows = 0
        }
        next = max(minKbps, min(maxKbps, next))
        guard next != targetKbps else { return nil }
        targetKbps = next
        return next
    }
}
