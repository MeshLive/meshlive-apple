import Foundation

/// Where this copy of the app comes from, read from the `MeshLiveDistribution` Info.plist value. Only the exact
/// value `appstore` (set by the archive command) is an App Store build; nil, an empty or unsubstituted build setting
/// and any other text are a source build, so an unknown value never claims the App Store.
public enum StoreDistribution: Equatable {
    case appStore, source

    public init(infoValue: String?) {
        self = infoValue == "appstore" ? .appStore : .source
    }
}
