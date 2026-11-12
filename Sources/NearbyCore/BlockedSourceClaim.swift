import Foundation

/// Review RV-C (Windows WP5F rule): what a viewer does when a stream's source turns out to be a person it blocked or
/// reported. Only the source's own authenticated handshake proves who it is. A forwarder's BFG1 grant merely names a
/// source, so a lying forwarder must not be able to end a watch that went through it, or hide the genuine stream.
public enum BlockedSourceClaim {
    public enum Action: Equatable {
        /// The direct source authenticated itself as a hidden person: leave the stream and hide its offer.
        case leaveAndHide
        /// Only a forwarder named a hidden source: drop this route for the rest of the watch and look for the stream on
        /// another route. The watch ends only when no route is left (the lost-stream search bound).
        case dropRoute
    }

    /// `adjacent` is the authenticated link peer of the hop; `source` the stream's source (the same node when direct).
    public static func action(adjacent: NodeId, source: NodeId) -> Action { adjacent == source ? .leaveAndHide : .dropRoute }
}

/// The routes (`ViewerRecovery.routeKey`) one watch no longer tries, whatever later sightings of their offers say.
/// Bounded; owned by the watch, so it ends with it.
public struct WatchRouteExclusions: Equatable {
    public static let maxRoutes = 64
    public private(set) var routes: [String] = []
    public init() {}

    public mutating func drop(_ route: String) {
        routes.removeAll { $0 == route }
        routes.append(route)
        if routes.count > Self.maxRoutes { routes.removeFirst(routes.count - Self.maxRoutes) }
    }

    public func allows(_ route: String) -> Bool { !routes.contains(route) }

    /// `rows` without the dropped routes, in their order.
    public func usable<Row>(_ rows: [Row], route: (Row) -> String) -> [Row] { rows.filter { allows(route($0)) } }
}
