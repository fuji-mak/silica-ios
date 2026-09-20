import Foundation

public enum LocationSource: String, Sendable {
    case visit
    case locationBootstrap = "location_bootstrap"
}

public enum StayBootstrapPolicy {
    public static let maximumLocationAge: TimeInterval = 5 * 60
    public static let maximumFutureSkew: TimeInterval = 30
    public static let maximumHorizontalAccuracy: Double = 250
    public static let samePlaceRadiusMeters: Double = 300
    public static let openVisitMatchingWindow: TimeInterval = 24 * 60 * 60
    public static let completedVisitBoundaryTolerance: TimeInterval = 10 * 60

    public static func shouldRequestInitialLocation(
        hasRecordedStay: Bool,
        hasCandidate: Bool
    ) -> Bool {
        hasRecordedStay == false && hasCandidate == false
    }

    public static func canUseLocation(
        timestamp: Date,
        horizontalAccuracy: Double,
        evaluatedAt: Date
    ) -> Bool {
        guard horizontalAccuracy >= 0,
              horizontalAccuracy <= maximumHorizontalAccuracy else {
            return false
        }
        let age = evaluatedAt.timeIntervalSince(timestamp)
        return age >= -maximumFutureSkew && age <= maximumLocationAge
    }

    public static func representsSamePlace(
        _ lhs: GeoCoordinate,
        _ rhs: GeoCoordinate
    ) -> Bool {
        GeoDistance.meters(from: lhs, to: rhs) <= samePlaceRadiusMeters
    }

    public static func canPromoteToObservedVisit(
        bootstrapArrivalAt: Date,
        bootstrapCoordinate: GeoCoordinate,
        observedArrivalAt: Date,
        observedDepartureAt: Date?,
        observedCoordinate: GeoCoordinate
    ) -> Bool {
        guard representsSamePlace(bootstrapCoordinate, observedCoordinate) else {
            return false
        }

        let earliest = observedArrivalAt.addingTimeInterval(-completedVisitBoundaryTolerance)
        if let observedDepartureAt {
            let latest = observedDepartureAt.addingTimeInterval(completedVisitBoundaryTolerance)
            return bootstrapArrivalAt >= earliest && bootstrapArrivalAt <= latest
        }
        return bootstrapArrivalAt >= earliest &&
            bootstrapArrivalAt.timeIntervalSince(observedArrivalAt) <= openVisitMatchingWindow
    }
}
