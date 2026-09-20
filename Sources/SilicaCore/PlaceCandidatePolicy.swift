import Foundation

public enum PlaceCandidatePolicy {
    public static let duplicateRadiusMeters: Double = 25

    public static func matchesRegisteredPlace(
        coordinate: GeoCoordinate,
        registeredCoordinate: GeoCoordinate,
        radiusMeters: Double
    ) -> Bool {
        matchesRegisteredPlace(
            distanceMeters: GeoDistance.meters(from: coordinate, to: registeredCoordinate),
            radiusMeters: radiusMeters
        )
    }

    public static func matchesRegisteredPlace(distanceMeters: Double, radiusMeters: Double) -> Bool {
        distanceMeters <= max(0, radiusMeters)
    }

    public static func representsSameCandidate(
        _ lhs: GeoCoordinate,
        _ rhs: GeoCoordinate
    ) -> Bool {
        GeoDistance.meters(from: lhs, to: rhs) <= duplicateRadiusMeters
    }
}

public enum RegisteredPlaceRelationship: Sendable {
    case neitherCoordinateIsRegistered
    case sameRegisteredPlace
    case differentOrOnlyOneRegisteredPlace
}

public enum VisitCoordinateRefinementPolicy {
    public static let maximumSampleAccuracyMeters: Double = 50
    public static let requiredAccuracyRatio: Double = 0.7
    public static let maximumSampleAgeSeconds: TimeInterval = 15
    public static let sampleTimestampToleranceSeconds: TimeInterval = 2
    public static let maximumUnregisteredDistanceMeters: Double = 100

    public static func accepts(
        rawCoordinate: GeoCoordinate,
        rawHorizontalAccuracy: Double,
        sampleCoordinate: GeoCoordinate,
        sampleHorizontalAccuracy: Double,
        sampleTimestamp: Date,
        requestedAt: Date,
        evaluatedAt: Date,
        registeredPlaceRelationship: RegisteredPlaceRelationship
    ) -> Bool {
        guard rawHorizontalAccuracy.isFinite,
              rawHorizontalAccuracy > 0,
              sampleHorizontalAccuracy.isFinite,
              sampleHorizontalAccuracy > 0,
              sampleHorizontalAccuracy <= maximumSampleAccuracyMeters,
              sampleHorizontalAccuracy <= rawHorizontalAccuracy * requiredAccuracyRatio,
              sampleTimestamp >= requestedAt.addingTimeInterval(-sampleTimestampToleranceSeconds),
              sampleTimestamp <= evaluatedAt,
              evaluatedAt.timeIntervalSince(sampleTimestamp) <= maximumSampleAgeSeconds else {
            return false
        }

        switch registeredPlaceRelationship {
        case .sameRegisteredPlace:
            return true
        case .differentOrOnlyOneRegisteredPlace:
            return false
        case .neitherCoordinateIsRegistered:
            let maximumDistance = min(
                maximumUnregisteredDistanceMeters,
                rawHorizontalAccuracy + sampleHorizontalAccuracy
            )
            return GeoDistance.meters(from: rawCoordinate, to: sampleCoordinate) <= maximumDistance
        }
    }
}
