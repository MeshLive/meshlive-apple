import XCTest
@testable import NearbyCore

/// The first-run flow: terms before any permission prompt, Skip never leaves onboarding, and the permission prompts
/// run one at a time in order with a denial never stopping the sequence.
final class OnboardingFlowTests: XCTestCase {
    func testAFreshInstallSeesTheTermsBeforeThePermissionsPage() {
        let pages = OnboardingFlow.pages(onboardingComplete: false, termsAccepted: 0)
        XCTAssertEqual(pages, [.welcome, .capabilities, .terms, .permissions, .ready])
        XCTAssertLessThan(pages.firstIndex(of: .terms)!, pages.firstIndex(of: .permissions)!,
                          "the terms are agreed before iOS asks for anything")
    }

    func testAnExistingUserSeesOnlyTheTermsOnceAndThenNothing() {
        XCTAssertEqual(OnboardingFlow.pages(onboardingComplete: true, termsAccepted: 0), [.terms],
                       "an install from before the terms existed sees them once")
        XCTAssertEqual(OnboardingFlow.pages(onboardingComplete: true, termsAccepted: StoreTerms.currentVersion), [],
                       "after agreeing the app opens directly")
        XCTAssertEqual(StoreTerms.currentVersion, 1)
    }

    func testSkipNeverLeavesOnboardingAndNeverPassesTheTerms() {
        let pages = OnboardingFlow.pages(onboardingComplete: false, termsAccepted: 0)
        XCTAssertEqual(OnboardingFlow.skipTarget(from: .welcome, in: pages), 2)
        XCTAssertEqual(OnboardingFlow.skipTarget(from: .capabilities, in: pages), 2)
        XCTAssertEqual(pages[2], .terms, "Skip lands on the terms page")
        for page in [OnboardingPage.terms, .permissions, .ready] {
            XCTAssertNil(OnboardingFlow.skipTarget(from: page, in: pages), "no skipping past the terms")
        }
    }

    func testPermissionPromptsRunOneAtATimeInOrderAndSkipDecidedOnes() {
        let order = PermissionSequence.order(cameraRow: false)
        XCTAssertEqual(order, [.bluetooth, .microphone, .notifications])
        var statuses: [Permission: PermissionStatus] = [:]
        XCTAssertEqual(PermissionSequence.next(order: order, statuses: statuses), .bluetooth)
        statuses[.bluetooth] = .decided
        XCTAssertEqual(PermissionSequence.next(order: order, statuses: statuses), .microphone)
        statuses[.microphone] = .decided
        XCTAssertEqual(PermissionSequence.next(order: order, statuses: statuses), .notifications)
        statuses[.notifications] = .decided
        XCTAssertNil(PermissionSequence.next(order: order, statuses: statuses))
    }

    func testADeniedPermissionNeverStopsTheSequence() {
        let order = PermissionSequence.order(cameraRow: false)
        var statuses: [Permission: PermissionStatus] = [.bluetooth: .notDetermined, .microphone: .decided,
                                                        .notifications: .notDetermined]
        XCTAssertEqual(PermissionSequence.next(order: order, statuses: statuses), .bluetooth)
        statuses[.bluetooth] = .decided
        XCTAssertEqual(PermissionSequence.next(order: order, statuses: statuses), .notifications,
                       "a denied microphone moved the sequence on to notifications")
        statuses[.notifications] = .decided
        XCTAssertNil(PermissionSequence.next(order: order, statuses: statuses), "and then the page can advance")
    }

    func testTheCameraRowIsOnlyInTheControlArm() {
        XCTAssertEqual(PermissionSequence.order(cameraRow: false), [.bluetooth, .microphone, .notifications])
        XCTAssertEqual(PermissionSequence.order(cameraRow: true), [.bluetooth, .camera, .microphone, .notifications])
    }

    func testAnEmptyFlowHasNoPageToShow() {
        XCTAssertNil(OnboardingFlow.page(in: [], at: 0), "an empty flow finishes onboarding instead of showing a page")
        let pages = OnboardingFlow.pages(onboardingComplete: false, termsAccepted: 0)
        XCTAssertEqual(OnboardingFlow.page(in: pages, at: 0), .welcome)
        XCTAssertEqual(OnboardingFlow.page(in: pages, at: pages.count - 1), .ready)
        XCTAssertEqual(OnboardingFlow.page(in: pages, at: 99), .ready, "an out-of-range index clamps to the last page")
        XCTAssertEqual(OnboardingFlow.page(in: pages, at: -1), .welcome, "a negative index clamps to the first page")
    }
}
