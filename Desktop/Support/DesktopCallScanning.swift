import Foundation

/// Owns the Mac discovery scan across a call's connection attempt, attached link and termination.
/// A selected outgoing call still needs discovery for address-refresh retries. Only an attached
/// call may pause scanning; stream/viewer discovery is never claimed by this coordinator.
final class DesktopCallScanning {
    private var enabled: Bool
    private var running = false
    private var call: UUID?
    private var attached = false
    private var ended = false
    private var applied: Bool?
    private let scan: (Bool) -> Void

    init(enabled: Bool = false, scan: @escaping (Bool) -> Void) {
        self.enabled = enabled; self.scan = scan
    }

    func start() { running = true; apply() }
    func stop() { running = false; apply() }
    func setEnabled(_ enabled: Bool) { self.enabled = enabled; apply() }

    func selectCall(_ id: UUID?) {
        guard call != id else { return }
        call = id; attached = false; ended = false
        apply()
    }

    /// Rejects a delayed connection result from a cancelled, replaced or stopped call.
    @discardableResult
    func linkAttached(to id: UUID) -> Bool {
        guard running, call == id, !ended, !attached else { return false }
        attached = true; apply()
        return true
    }

    func callEnded(_ id: UUID) {
        guard call == id else { return }
        ended = true; attached = false
        apply()
    }

    private func apply() {
        // Preview/settings construction must not touch the radio before start.
        guard running || applied != nil else { return }
        let wanted = running && !(enabled && attached && !ended)
        guard applied != wanted else { return }
        applied = wanted
        scan(wanted)
    }
}
