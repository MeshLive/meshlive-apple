import Foundation
import NearbyCore

// Store-build track (A1): AppModel code for the App Store build.
extension AppModel {
    /// The distribution this copy was built for, from the `MeshLiveDistribution` Info.plist value. DEBUG
    /// `-NearbyDistribution appstore|source` overrides it for tests and screenshots; a release build ignores it.
    var distribution: StoreDistribution {
        #if DEBUG
        if let value = RootView.debugArgument("-NearbyDistribution") { return StoreDistribution(infoValue: value) }
        #endif
        return StoreDistribution(infoValue: Bundle.main.infoDictionary?["MeshLiveDistribution"] as? String)
    }
}
