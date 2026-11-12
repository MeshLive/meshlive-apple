import Foundation
import SwiftUI
import NearbyCore
#if os(iOS)
import UIKit
#else
import AppKit
#endif
#if canImport(NearbyMedia)
import NearbyMedia
#endif

// MARK: - Experimental call relay hop (default off)

/// One relay hop for one call: child (callee or next relay) first as central, then one parent as peripheral.
/// End-to-end records are copied unchanged; this phone never sees the call's audio or video.
/// EXPERIMENTAL relayed calls : this phone helps one call (its listener's first record was SETUP).
final class RelayDutyController: ObservableObject {
    weak var model: AppModel?
    let duty: RelayHelperDuty
    @Published var state = "Connecting a call for a phone near you"
    private var parentDriver: ConnectionDriver?
    private var childDriver: ConnectionDriver?
    private var timer: Timer?
    private var done = false

    init(model: AppModel, duty: RelayHelperDuty, parentLink: MeshLink) {
        self.model = model; self.duty = duty
        let driver = ConnectionDriver(engine: duty.parent, link: parentLink)
        driver.onFinished = { [weak self] reason in self?.duty.close("Parent link: \(reason)") }
        parentDriver = driver
        duty.onStateChange = { [weak self] s in self?.stateChanged(s) }
        duty.onIngressResumable = { [weak self] in
            DispatchQueue.main.async {
                guard let self, !self.done else { return }
                self.duty.resumeIngress(now: ConnectionDriver.now)
                self.childDriver?.pump(); self.parentDriver?.pump()
            }
        }
        duty.parent.onRecordCopied = { [weak self] in self?.parentDriver?.pump() }
        driver.start(adopted: true)
        timer = Timer.scheduledTimer(withTimeInterval: 0.25, repeats: true) { [weak self] _ in
            guard let self else { return }
            self.duty.tick(now: ConnectionDriver.now)
            self.childDriver?.pump(); self.parentDriver?.pump()
        }
    }

    /// Refused: FAIL goes out on the parent, then everything closes.
    func refuse(_ reason: RelaySetupFailure) {
        duty.refuse(reason); parentDriver?.pump()
    }

    /// The onward link opened: run the duty's child on it.
    func attachChild(_ link: MeshLink, next: RelayHelperDuty.NextHop, bmh3: Bmh3CallSettings?) {
        guard !done else { link.close(); return }
        let child = duty.makeChildLink(next: next, bmh3: bmh3)
        child.onRecordCopied = { [weak self] in self?.childDriver?.pump() }
        let driver = ConnectionDriver(engine: child, link: link)
        driver.onFinished = { [weak self] reason in self?.duty.close("Child link: \(reason)") }
        childDriver = driver
        driver.start()
    }

    func childConnectFailed(_ reason: String) { duty.childConnectFailed(reason); parentDriver?.pump() }

    private func stateChanged(_ s: RelayHelperDuty.State) {
        parentDriver?.pump(); childDriver?.pump()
        switch s {
        case .connectingNext, .waitingForNext: state = "Connecting a call for a phone near you"
        case .relaying:
            state = "Passing a call on"
            AppLog.event("relayed_setup", ["role": "helper", "result": "ready", "relays": "\(duty.readyRelays ?? 0)"])
        case .closed(let reason):
            guard !done else { return }
            done = true
            timer?.invalidate(); timer = nil
            onClosed?(duty); onClosed = nil
            if let failure = duty.failure {
                AppLog.event("relayed_setup", ["role": "helper", "result": "failed", "reason": failure.label])
            }
            AppLog.event("relayed_helper", ["event": "relay_ended", "reason": reason, "copiedToCallee": "\(duty.child?.copiedRecords ?? 0)",
                                            "copiedToCaller": "\(duty.parent.copiedRecords)"])
            // Let a FAIL drain before the links go.
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { [weak self] in
                guard let self else { return }
                self.childDriver?.cancel(); self.parentDriver?.cancel()
                self.model?.relayDutyFinished(self)
            }
        }
    }

    func preempt() { duty.close("This device is needed for something else") }
    /// Called once when the duty closed (search budgets and the FAIL cache).
    var onClosed: ((RelayHelperDuty) -> Void)?
}

final class CallRelayController: ObservableObject {
    weak var model: AppModel?
    let row: UUID
    let transport: MeshTransport
    let hop: CallRelayHop
    @Published var state = "Connecting to the callee"
    private var childDriver: ConnectionDriver?
    private var parentDriver: ConnectionDriver?
    private var timer: Timer?
    private var done = false

    init(model: AppModel, identity: SigningIdentity, row: UUID, childOffer: DiscoveryAnnouncement, transport: MeshTransport) {
        self.model = model; self.row = row; self.transport = transport
        hop = CallRelayHop(identity: identity, transport: transport, childOffer: childOffer,
                           hiddenIdentities: model.hiddenIdentities, pins: model.bmh3Pins,
                           pseudonymousEdges: model.bmh3Pseudonyms && model.rotatingIds && AppSettings.relayedPseudonymousEdges)
        hop.onStateChange = { [weak self] s in self?.stateChanged(s) }
        // Backpressure: a hop that drained lets the other one parse again, outside the sealing path that reported it.
        hop.onIngressResumable = { [weak self] in
            DispatchQueue.main.async {
                guard let self, !self.done else { return }
                self.hop.resumeIngress(now: ConnectionDriver.now)
                self.childDriver?.pump(); self.parentDriver?.pump()
            }
        }
    }

    var awaitingParent: Bool { hop.state == .waitingForParent && hop.parent == nil }
    var parentOffer: DiscoveryAnnouncement? { hop.parent == nil ? hop.parentOffer : nil }

    func start() {
        AppLog.event("relay_call", ["stage": "connect_child", "callee": hop.calleePrefix.hex, "childCost": "\(hop.childOffer.routeCost)", "transport": transport.rawValue])
        model?.radio.connect(to: row, transport: transport) { [weak self] result in
            guard let self, !self.done else { return }
            switch result {
            case .success(let link):
                let driver = ConnectionDriver(engine: self.hop.child, link: link)
                driver.onFinished = { [weak self] reason in self?.hop.close("Child link: \(reason)") }
                self.childDriver = driver
                driver.start()
            case .failure(let error):
                self.finish("Could not reach the callee: \(error)")
            }
        }
        timer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            guard let self else { return }
            self.hop.tick(now: ConnectionDriver.now)
            self.childDriver?.pump(); self.parentDriver?.pump()
        }
    }

    func attachParent(_ link: MeshLink) {
        guard link.transport == transport, let engine = hop.attachParent() else { link.close(); return }
        AppLog.event("relay_call", ["stage": "parent_connected", "transport": link.transport.rawValue])
        let driver = ConnectionDriver(engine: engine, link: link)
        driver.onFinished = { [weak self] reason in self?.hop.close("Parent link: \(reason)") }
        parentDriver = driver
        driver.start()
        // Copied records are pulled by each link's own driver; pump the other side when one receives.
        engine.onRecordCopied = { [weak self] in self?.childDriver?.pump() }
        hop.child.onRecordCopied = { [weak self] in self?.parentDriver?.pump() }
    }

    private func stateChanged(_ s: CallRelayHop.State) {
        switch s {
        case .connectingChild: state = "Connecting to the callee"
        case .waitingForParent:
            state = "Passing calls on for a phone near you"
            AppLog.event("relay_call", ["stage": "child_authenticated", "offerCost": "\(hop.parentOffer?.routeCost ?? 0)"])
            model?.refreshAdvertising()
        case .relaying:
            state = "Passing a call on"
            AppLog.event("relay_call", ["stage": "relaying"])
            model?.refreshAdvertising()
        case .closed(let reason): finish(reason)
        }
    }

    func stop() { hop.close("Stopped") }

    private func finish(_ reason: String) {
        guard !done else { return }
        done = true
        timer?.invalidate()
        AppLog.event("relay_call", ["stage": "closed", "reason": reason, "copiedToCallee": "\(hop.child.copiedRecords)", "copiedToCaller": "\(hop.parent?.copiedRecords ?? 0)"])
        // Let copied final records (hang-up) drain before closing (Android drains 400 ms).
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) { [weak self] in
            guard let self else { return }
            self.childDriver?.cancel(); self.parentDriver?.cancel()
            self.model?.callRelayFinished(self)
        }
    }
}
