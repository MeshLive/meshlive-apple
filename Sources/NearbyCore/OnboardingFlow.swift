import Foundation

/// One page of the first-run flow, in the order a fresh install sees them.
public enum OnboardingPage: Equatable, CaseIterable {
    case welcome, capabilities, terms, permissions, ready
}

/// The terms the app asks a person to agree to, and the version stored when they do.
public enum StoreTerms {
    public static let currentVersion = 1
}

/// The pages the first-run flow shows. A fresh install sees all five (the terms come before any system permission
/// prompt); an install from before the terms existed sees only the terms, once; after agreeing, nothing.
public enum OnboardingFlow {
    public static func pages(onboardingComplete: Bool, termsAccepted: Int) -> [OnboardingPage] {
        if !onboardingComplete { return [.welcome, .capabilities, .terms, .permissions, .ready] }
        if termsAccepted < StoreTerms.currentVersion { return [.terms] }
        return []
    }

    /// Where the Skip link goes: the terms page for the two pages before it, nowhere else. Skip never leaves onboarding
    /// and never passes the terms.
    public static func skipTarget(from page: OnboardingPage, in pages: [OnboardingPage]) -> Int? {
        guard page == .welcome || page == .capabilities else { return nil }
        return pages.firstIndex(of: .terms)
    }

    /// The page at `index`, clamped to the list, or nil when the list is empty: the caller must then finish onboarding
    /// instead of indexing `-1`.
    public static func page(in pages: [OnboardingPage], at index: Int) -> OnboardingPage? {
        guard !pages.isEmpty else { return nil }
        return pages[min(max(index, 0), pages.count - 1)]
    }
}

/// The permissions the permissions page asks for, one system prompt at a time.
public enum Permission: Equatable, Hashable {
    case bluetooth, camera, microphone, notifications
}

public enum PermissionStatus: Equatable {
    case notDetermined, decided
}

public enum PermissionSequence {
    /// The first permission in `order` that has not been decided yet, or nil when every prompt has been answered.
    public static func next(order: [Permission], statuses: [Permission: PermissionStatus]) -> Permission? {
        order.first { (statuses[$0] ?? .notDetermined) == .notDetermined }
    }

    /// Bluetooth, then the camera only in the control arm, then the microphone, then notifications.
    public static func order(cameraRow: Bool) -> [Permission] {
        var order: [Permission] = [.bluetooth]
        if cameraRow { order.append(.camera) }
        order.append(contentsOf: [.microphone, .notifications])
        return order
    }
}
