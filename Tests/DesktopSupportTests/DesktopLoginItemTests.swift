import XCTest
import ServiceManagement
@testable import DesktopSupport

final class DesktopLoginItemTests: XCTestCase {
    private final class FakeService: DesktopLoginService {
        var status: SMAppService.Status = .notRegistered
        var calls: [String] = []
        var failRegister = false
        var approvalNeeded = false
        struct Failure: LocalizedError { var errorDescription: String? { "Operation not permitted" } }
        func register() throws {
            calls.append("register")
            if failRegister { throw Failure() }
            status = approvalNeeded ? .requiresApproval : .enabled
        }
        func unregister() throws { calls.append("unregister"); status = .notRegistered }
    }

    func testOffByDefaultAndNeverRegistersOnItsOwn() {
        let service = FakeService()
        let item = DesktopLoginItem(service: service)
        item.refresh()
        XCTAssertEqual(item.state, .init())
        XCTAssertEqual(service.calls, [])
    }

    func testToggleRegistersAndUnregisters() {
        let service = FakeService()
        let item = DesktopLoginItem(service: service)
        item.set(true)
        XCTAssertEqual(item.state, .init(on: true))
        item.set(true)
        item.set(false)
        XCTAssertEqual(item.state, .init())
        item.set(false)
        XCTAssertEqual(service.calls, ["register", "unregister"], "no repeated or needless calls")
    }

    func testApprovalPendingStaysOnAndSaysSo() {
        let service = FakeService()
        service.approvalNeeded = true
        let item = DesktopLoginItem(service: service)
        item.set(true)
        XCTAssertEqual(item.state, .init(on: true, needsApproval: true))
        item.set(false)
        XCTAssertEqual(item.state, .init())
    }

    func testFailureLeavesSwitchOffWithReason() {
        let service = FakeService()
        service.failRegister = true
        let item = DesktopLoginItem(service: service)
        item.set(true)
        XCTAssertFalse(item.state.on)
        XCTAssertEqual(item.state.problem, "macOS did not add MeshLive to Login Items: Operation not permitted")
        service.failRegister = false
        item.set(true)
        XCTAssertEqual(item.state, .init(on: true), "a later success clears the problem")
    }

    func testStatusChangedInSystemSettingsIsShownOnRefresh() {
        let service = FakeService()
        let item = DesktopLoginItem(service: service)
        service.status = .enabled
        item.refresh()
        XCTAssertTrue(item.state.on)
        service.status = .notRegistered
        item.refresh()
        XCTAssertFalse(item.state.on)
    }
}
