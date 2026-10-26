import Foundation
import NearbyCore

/// Mac scheduling for the existing rotating-ID experiment. Only this Mac's idle call presence
/// rotates in phase 1; streams, viewer requests and mirrored offers retain their existing behavior.
final class DesktopDiscoveryAdvertising {
    enum CallPresence: Equatable {
        case rotating(OpeningEntry)
        case fixed
    }

    private let pins: OpeningPins
    private let nowMs: () -> Int64
    private let silenceMs: () -> Int64
    private let schedule: (Int64, @escaping () -> Void) -> Void
    private let publish: (DiscoveryAnnouncement?) -> Void
    private let refresh: () -> Void
    private var previousCall: CallPresence?
    private var silenceUntilMs: Int64?
    private var generation: UInt64 = 0
    private var restartRequested = false

    init(pins: OpeningPins,
         nowMs: @escaping () -> Int64 = { Int64(ProcessInfo.processInfo.systemUptime * 1_000) },
         silenceMs: @escaping () -> Int64 = { Int64.random(in: 1_000...8_000) },
         schedule: @escaping (Int64, @escaping () -> Void) -> Void = { delay, action in
             DispatchQueue.main.asyncAfter(deadline: .now() + Double(delay) / 1_000, execute: action)
         }, publish: @escaping (DiscoveryAnnouncement?) -> Void, refresh: @escaping () -> Void) {
        self.pins = pins; self.nowMs = nowMs; self.silenceMs = silenceMs
        self.schedule = schedule; self.publish = publish; self.refresh = refresh
    }

    /// An explicit Visible-by-handle request also restarts an already fixed call offer.
    func requestCallRestart() { restartRequested = true }

    func advertise(_ announcement: DiscoveryAnnouncement?, callPresence: CallPresence? = nil) {
        let now = nowMs()
        if let callPresence {
            guard let announcement, announcement.isPrivateCallOffer else { stop(); return }
            switch callPresence {
            case .rotating(let entry):
                guard announcement.rotating, entry.role == RotatingDiscoveryIds.roleCallOffer,
                      announcement.nodeIdPrefix == entry.rdi else { stop(); return }
            case .fixed:
                guard !announcement.rotating else { stop(); return }
            }
        }

        // A media role takes precedence over an idle call's pending rotation. Its old delayed
        // callback must never blank the new offer or restore an obsolete call announcement.
        if callPresence == nil {
            cancelSilence()
            deliver(announcement, callPresence: nil, now: now)
            return
        }

        if let until = silenceUntilMs {
            guard now >= until else { return }
            cancelSilence()
            restartRequested = false
            deliver(announcement, callPresence: callPresence, now: now)
            return
        }

        if restartRequested || (previousCall != nil && previousCall != callPresence) {
            beginSilence(now: now)
            return
        }
        deliver(announcement, callPresence: callPresence, now: now)
    }

    /// Quit/wipe invalidates outstanding callbacks before the radio is shut down.
    func stop() {
        cancelSilence()
        previousCall = nil; restartRequested = false
        pins.offAir(elapsedMs: nowMs())
        publish(nil)
    }

    private func cancelSilence() {
        generation &+= 1
        silenceUntilMs = nil
    }

    private func beginSilence(now: Int64) {
        let delay = max(1_000, min(8_000, silenceMs()))
        generation &+= 1
        let token = generation
        silenceUntilMs = now + delay
        pins.offAir(elapsedMs: now)
        publish(nil)
        schedule(delay) { [weak self] in
            guard let self, self.generation == token, self.silenceUntilMs != nil else { return }
            // Recompute the current role and epoch; never publish a captured, obsolete advert.
            self.refresh()
        }
    }

    private func deliver(_ announcement: DiscoveryAnnouncement?, callPresence: CallPresence?, now: Int64) {
        if case .rotating(let entry) = callPresence { pins.onAdvertised(entry, elapsedMs: now) }
        else { pins.offAir(elapsedMs: now) }
        if let callPresence { previousCall = callPresence }
        publish(announcement)
    }
}
