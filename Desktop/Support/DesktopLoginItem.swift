import Foundation
import Combine
import ServiceManagement

/// The login-item backend: `SMAppService.mainApp` in the app, an in-memory or preview store in tests and screenshots.
public protocol DesktopLoginService: AnyObject {
    var status: SMAppService.Status { get }
    func register() throws
    func unregister() throws
}

extension SMAppService: DesktopLoginService {}

/// Settings › Desktop › Start at login. Off unless the user turns it on: MeshLive never registers itself. The switch
/// shows the system's actual status, including a registration still waiting for approval in Login Items.
public final class DesktopLoginItem: ObservableObject {
    public struct State: Equatable {
        public var on = false
        /// Registered, but the user must still allow it in System Settings › General › Login Items.
        public var needsApproval = false
        public var problem: String?
        public init(on: Bool = false, needsApproval: Bool = false, problem: String? = nil) {
            self.on = on; self.needsApproval = needsApproval; self.problem = problem
        }
    }
    @Published public private(set) var state = State()
    private let service: DesktopLoginService

    public init(service: DesktopLoginService) {
        self.service = service
        refresh()
    }

    public func refresh() {
        let status = service.status
        state.on = status == .enabled || status == .requiresApproval
        state.needsApproval = status == .requiresApproval
    }

    public func set(_ on: Bool) {
        state.problem = nil
        do {
            if on {
                if service.status != .enabled { try service.register() }
            } else if service.status != .notRegistered && service.status != .notFound {
                try service.unregister()
            }
        } catch {
            state.problem = on ? "macOS did not add MeshLive to Login Items: \(error.localizedDescription)"
                               : "macOS did not remove MeshLive from Login Items: \(error.localizedDescription)"
        }
        refresh()
    }
}
