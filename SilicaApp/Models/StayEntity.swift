import Foundation
import SwiftData

enum StayDepartureSource: String {
    case observedVisit = "observed_visit"
    case inferredCandidate = "inferred_candidate"
}

@Model
final class StayEntity {
    @Attribute(.unique) var id: UUID
    var arrivalAt: Date
    var departureAt: Date?
    var departureSourceRawValue: String?
    /// Core Motion classifications for the movement from this stay to the
    /// next timeline entry.
    var movementModesRawValue: String?
    var movementStartedAt: Date?
    var movementEndedAt: Date?
    /// The exact adjacent destination this outgoing movement was resolved
    /// against. Evidence must never be reused after the timeline changes.
    var movementDestinationStayID: UUID?
    var movementTimingSourceRawValue: String?
    var movementTimingConfidenceRawValue: String?
    /// Pedestrian active time excludes stationary gaps inside the trip.
    var movementActiveDuration: Double?
    var movementDistanceMeters: Double?
    var movementStepCount: Int?
    var movementDistanceSourceRawValue: String?
    /// Selected minute-level pedometer evidence, retained because iOS exposes
    /// only a bounded historical window.
    var movementPedometerBucketsData: Data?
    var movementEvidenceVersion: Int?
    var latitude: Double
    var longitude: Double
    var horizontalAccuracy: Double
    var sourceRawValue: String
    var placeName: String?
    var address: String?
    /// Prevents later sensor refinements from overwriting a location that the
    /// user explicitly corrected on the map.
    var isLocationManuallyAdjusted = false
    var confidenceRawValue: String
    var createdAt: Date
    var updatedAt: Date

    init(
        arrivalAt: Date,
        departureAt: Date? = nil,
        latitude: Double,
        longitude: Double,
        horizontalAccuracy: Double,
        sourceRawValue: String,
        confidenceRawValue: String
    ) {
        self.id = UUID()
        self.arrivalAt = arrivalAt
        self.departureAt = departureAt
        self.departureSourceRawValue = nil
        self.movementModesRawValue = nil
        self.movementStartedAt = nil
        self.movementEndedAt = nil
        self.movementDestinationStayID = nil
        self.movementTimingSourceRawValue = nil
        self.movementTimingConfidenceRawValue = nil
        self.movementActiveDuration = nil
        self.movementDistanceMeters = nil
        self.movementStepCount = nil
        self.movementDistanceSourceRawValue = nil
        self.movementPedometerBucketsData = nil
        self.movementEvidenceVersion = nil
        self.latitude = latitude
        self.longitude = longitude
        self.horizontalAccuracy = horizontalAccuracy
        self.sourceRawValue = sourceRawValue
        self.placeName = nil
        self.address = nil
        self.confidenceRawValue = confidenceRawValue
        self.createdAt = Date()
        self.updatedAt = Date()
    }
}

enum StayCandidateState: String {
    case pending
    case confirmed
    case rejected
}

enum StayCandidateInferredDepartureReason: String {
    case nextCandidate = "next_candidate"
    case motionActivity = "motion_activity"
    case sustainedMovement = "sustained_movement"
}

/// Immutable-source visit data is retained here until independent evidence can
/// promote it to a user-visible `StayEntity`.
@Model
final class StayCandidateEntity {
    @Attribute(.unique) var id: UUID
    var arrivalAt: Date
    var departureAt: Date?
    /// A sensor-derived end boundary. `departureAt` remains the unmodified
    /// value reported by Core Location so a delayed visit update can be
    /// reconciled without losing the original observation.
    var inferredDepartureAt: Date?
    /// A later distinct visit proves this candidate is no longer current, but
    /// does not prove when it ended. This upper bound is intentionally kept
    /// separate from `inferredDepartureAt`.
    var departureNotAfterAt: Date?
    var inferredDepartureReasonRawValue: String?
    var latitude: Double
    var longitude: Double
    var horizontalAccuracy: Double
    /// A fresh one-shot location fix used only for presentation and for the
    /// eventual confirmed stay. The original CLVisit coordinate above remains
    /// unchanged for validation and sensor reconciliation.
    var refinedLatitude: Double?
    var refinedLongitude: Double?
    var refinedHorizontalAccuracy: Double?
    var refinementAttemptedAt: Date?
    var refinedAt: Date?
    var sourceRawValue: String
    /// Reverse-geocoded display metadata. This is derived from the presentation
    /// coordinate and does not participate in stay validation.
    var placeName: String?
    var address: String?
    var stateRawValue: String
    var decisionReasonRawValue: String?
    /// Comma-separated internal diagnostics explaining why no departure could
    /// be resolved. This is retained for audits and is not user-facing.
    var departureResolutionDiagnosticsRawValue: String?
    var confirmedStayID: UUID?
    var createdAt: Date
    var updatedAt: Date

    init(
        arrivalAt: Date,
        departureAt: Date? = nil,
        latitude: Double,
        longitude: Double,
        horizontalAccuracy: Double,
        sourceRawValue: String
    ) {
        self.id = UUID()
        self.arrivalAt = arrivalAt
        self.departureAt = departureAt
        self.inferredDepartureAt = nil
        self.departureNotAfterAt = nil
        self.inferredDepartureReasonRawValue = nil
        self.latitude = latitude
        self.longitude = longitude
        self.horizontalAccuracy = horizontalAccuracy
        self.refinedLatitude = nil
        self.refinedLongitude = nil
        self.refinedHorizontalAccuracy = nil
        self.refinementAttemptedAt = nil
        self.refinedAt = nil
        self.sourceRawValue = sourceRawValue
        self.placeName = nil
        self.address = nil
        self.stateRawValue = StayCandidateState.pending.rawValue
        self.decisionReasonRawValue = nil
        self.departureResolutionDiagnosticsRawValue = nil
        self.confirmedStayID = nil
        self.createdAt = Date()
        self.updatedAt = Date()
    }

    var coordinate: GeoCoordinate {
        GeoCoordinate(latitude: latitude, longitude: longitude)
    }

    var presentationCoordinate: GeoCoordinate {
        guard let refinedLatitude,
              let refinedLongitude,
              let refinedHorizontalAccuracy,
              refinedHorizontalAccuracy > 0,
              refinedHorizontalAccuracy < horizontalAccuracy else {
            return coordinate
        }
        return GeoCoordinate(latitude: refinedLatitude, longitude: refinedLongitude)
    }

    var presentationHorizontalAccuracy: Double {
        guard let refinedHorizontalAccuracy,
              refinedHorizontalAccuracy > 0,
              refinedHorizontalAccuracy < horizontalAccuracy else {
            return horizontalAccuracy
        }
        return refinedHorizontalAccuracy
    }

    var effectiveDepartureAt: Date? {
        StayDepartureSelectionPolicy.effectiveDepartureAt(
            observed: departureAt,
            inferred: inferredDepartureAt
        )
    }

    var usesInferredDeparture: Bool {
        StayDepartureSelectionPolicy.usesInferredDeparture(
            observed: departureAt,
            inferred: inferredDepartureAt
        )
    }

    var isTemporallyOpen: Bool {
        effectiveDepartureAt == nil && departureNotAfterAt == nil
    }

    var temporalBoundaryAt: Date? {
        effectiveDepartureAt ?? departureNotAfterAt
    }
}

extension StayCandidateEntity {
    var isLocationBootstrap: Bool {
        sourceRawValue == LocationSource.locationBootstrap.rawValue
    }
}
