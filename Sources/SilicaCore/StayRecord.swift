import Foundation

public struct StayRecord: Codable, Equatable, Sendable {
    public var arrivalAt: Date
    public var departureAt: Date?
    public var coordinate: GeoCoordinate
    public var placeName: String?
    public var address: String?

    public init(
        arrivalAt: Date,
        departureAt: Date? = nil,
        coordinate: GeoCoordinate,
        placeName: String? = nil,
        address: String? = nil
    ) {
        self.arrivalAt = arrivalAt
        self.departureAt = departureAt
        self.coordinate = coordinate
        self.placeName = placeName
        self.address = address
    }
}

public struct StayMotionEvidence: Equatable, Sendable {
    public var movingDuration: TimeInterval
    public var stationaryDuration: TimeInterval
    public var walkingDuration: TimeInterval
    public var runningDuration: TimeInterval
    public var cyclingDuration: TimeInterval
    public var automotiveDuration: TimeInterval

    public init(
        movingDuration: TimeInterval = 0,
        stationaryDuration: TimeInterval = 0,
        walkingDuration: TimeInterval = 0,
        runningDuration: TimeInterval = 0,
        cyclingDuration: TimeInterval = 0,
        automotiveDuration: TimeInterval = 0
    ) {
        self.movingDuration = max(0, movingDuration)
        self.stationaryDuration = max(0, stationaryDuration)
        self.walkingDuration = max(0, walkingDuration)
        self.runningDuration = max(0, runningDuration)
        self.cyclingDuration = max(0, cyclingDuration)
        self.automotiveDuration = max(0, automotiveDuration)
    }

    public var classifiedDuration: TimeInterval {
        movingDuration + stationaryDuration
    }
}

public struct StayValidationEvidence: Equatable, Sendable {
    public var arrivalAt: Date
    public var departureAt: Date?
    public var hasObservedDeparture: Bool
    public var coordinate: GeoCoordinate
    public var horizontalAccuracy: Double
    public var locationPoints: [MovementPoint]
    public var routeContextPoints: [MovementPoint]
    public var motion: StayMotionEvidence?
    public var overlapsConfirmedStay: Bool
    public var hasSpatialTransitionBoundary: Bool
    public var requiresPositiveStayEvidence: Bool
    public var containmentCoordinate: GeoCoordinate?
    public var containmentRadiusMeters: Double?
    public var evaluatedAt: Date

    public init(
        arrivalAt: Date,
        departureAt: Date?,
        hasObservedDeparture: Bool = false,
        coordinate: GeoCoordinate,
        horizontalAccuracy: Double,
        locationPoints: [MovementPoint] = [],
        routeContextPoints: [MovementPoint] = [],
        motion: StayMotionEvidence? = nil,
        overlapsConfirmedStay: Bool = false,
        hasSpatialTransitionBoundary: Bool = false,
        requiresPositiveStayEvidence: Bool = false,
        containmentCoordinate: GeoCoordinate? = nil,
        containmentRadiusMeters: Double? = nil,
        evaluatedAt: Date? = nil
    ) {
        self.arrivalAt = arrivalAt
        self.departureAt = departureAt
        self.hasObservedDeparture = hasObservedDeparture
        self.coordinate = coordinate
        self.horizontalAccuracy = max(0, horizontalAccuracy)
        self.locationPoints = locationPoints
        self.routeContextPoints = routeContextPoints
        self.motion = motion
        self.overlapsConfirmedStay = overlapsConfirmedStay
        self.hasSpatialTransitionBoundary = hasSpatialTransitionBoundary
        self.requiresPositiveStayEvidence = requiresPositiveStayEvidence
        self.containmentCoordinate = containmentCoordinate
        self.containmentRadiusMeters = containmentRadiusMeters.map { max(0, $0) }
        self.evaluatedAt = evaluatedAt ?? departureAt ?? arrivalAt
    }
}

/// Infers a fallback temporal boundary only while Core Location has not
/// supplied an observed visit departure.
public enum StayCandidateTemporalPolicy {
    public static let maximumReliablePointAccuracy: Double = 250
    public static let minimumSustainedDepartureSpan: TimeInterval = 3 * 60
    public static let minimumMotionDepartureDuration: TimeInterval = 30
    public static let maximumMotionArrivalGap: TimeInterval = 20 * 60

    /// The last observation proving that the device was still near the visit.
    /// This is a lower bound for departure, never the departure itself.
    public static func lastReliableNearbyAt(
        arrivalAt: Date,
        through upperBound: Date,
        coordinate: GeoCoordinate,
        horizontalAccuracy: Double,
        locationPoints: [MovementPoint]
    ) -> Date? {
        let lastNearbyPoint = reliablePoints(
            locationPoints,
            from: arrivalAt,
            through: max(arrivalAt, upperBound)
        )
        .last { point in
            let distance = GeoDistance.meters(from: coordinate, to: point.coordinate)
            let nearbyRadius = max(
                75,
                min(200, max(0, horizontalAccuracy) + point.horizontalAccuracy)
            )
            return distance <= nearbyRadius
        }
        return lastNearbyPoint?.timestamp
    }

    /// Uses the final sustained movement leading into the next visit. A motion
    /// interval that started before the last known-inside observation cannot
    /// be a departure from that place and is deliberately ignored.
    public static func inferredDepartureAtFromMotion(
        arrivalAt: Date,
        notAfter upperBound: Date,
        lastKnownInsideAt: Date?,
        movingIntervals: [DateInterval]
    ) -> Date? {
        let lowerBound = max(arrivalAt, lastKnownInsideAt ?? arrivalAt)
        let finalMovement = movingIntervals
            .filter { interval in
                interval.duration >= minimumMotionDepartureDuration &&
                    interval.start >= lowerBound &&
                    interval.start < upperBound &&
                    interval.end >= upperBound.addingTimeInterval(-maximumMotionArrivalGap)
            }
            .max { lhs, rhs in lhs.start < rhs.start }
        return finalMovement?.start
    }

    /// Returns the first reliable point outside the visit only after another
    /// outside point confirms that the departure was sustained. Unlike a last
    /// nearby point, this is positive evidence that the device has left.
    public static func inferredDepartureAtFromSustainedLocation(
        arrivalAt: Date,
        through endAt: Date,
        coordinate: GeoCoordinate,
        horizontalAccuracy: Double,
        locationPoints: [MovementPoint]
    ) -> Date? {
        let outsidePoints = sustainedOutsidePoints(
            arrivalAt: arrivalAt,
            through: endAt,
            coordinate: coordinate,
            horizontalAccuracy: horizontalAccuracy,
            locationPoints: locationPoints
        )
        guard outsidePoints.count >= 2,
              let first = outsidePoints.first,
              let last = outsidePoints.last,
              last.timestamp.timeIntervalSince(first.timestamp) >= minimumSustainedDepartureSpan else {
            return nil
        }
        return first.timestamp
    }

    public static func hasSustainedDeparture(
        arrivalAt: Date,
        through endAt: Date,
        coordinate: GeoCoordinate,
        horizontalAccuracy: Double,
        locationPoints: [MovementPoint]
    ) -> Bool {
        let outsidePoints = sustainedOutsidePoints(
            arrivalAt: arrivalAt,
            through: endAt,
            coordinate: coordinate,
            horizontalAccuracy: horizontalAccuracy,
            locationPoints: locationPoints
        )

        guard outsidePoints.count >= 2,
              let first = outsidePoints.first,
              let last = outsidePoints.last else {
            return false
        }
        return last.timestamp.timeIntervalSince(first.timestamp) >= minimumSustainedDepartureSpan
    }

    private static func sustainedOutsidePoints(
        arrivalAt: Date,
        through endAt: Date,
        coordinate: GeoCoordinate,
        horizontalAccuracy: Double,
        locationPoints: [MovementPoint]
    ) -> [MovementPoint] {
        var trailingOutsideRun: [MovementPoint] = []
        for point in reliablePoints(locationPoints, from: arrivalAt, through: endAt) {
            let distance = GeoDistance.meters(from: coordinate, to: point.coordinate)
            let uncertainty = max(0, horizontalAccuracy) + point.horizontalAccuracy
            let departureRadius = max(250, min(600, uncertainty))
            if distance > departureRadius {
                trailingOutsideRun.append(point)
            } else {
                trailingOutsideRun.removeAll(keepingCapacity: true)
            }
        }
        return trailingOutsideRun
    }

    private static func reliablePoints(
        _ points: [MovementPoint],
        from arrivalAt: Date,
        through departureAt: Date
    ) -> [MovementPoint] {
        points
            .filter {
                $0.timestamp >= arrivalAt &&
                    $0.timestamp <= departureAt &&
                    $0.horizontalAccuracy >= 0 &&
                    $0.horizontalAccuracy <= maximumReliablePointAccuracy
            }
            .sorted { $0.timestamp < $1.timestamp }
    }
}

public enum StayValidationReason: String, Equatable, Sendable {
    case awaitingDeparture = "awaiting_departure"
    case belowMinimumDuration = "below_minimum_duration"
    case conflictingStay = "conflicting_stay"
    case continuousLocationMovement = "continuous_location_movement"
    case stationaryWithStableLocation = "stationary_with_stable_location"
    case stationaryMotion = "stationary_motion"
    case stableLocationCluster = "stable_location_cluster"
    case longVisitWithoutContradiction = "long_visit_without_contradiction"
    case awaitingSpatialTransition = "awaiting_spatial_transition"
    case insufficientEvidence = "insufficient_evidence"
    case movingDominantMotion = "moving_dominant_motion"
    case expiredAmbiguousCandidate = "expired_ambiguous_candidate"
    case awaitingRouteContext = "awaiting_route_context"
    // Kept only so persisted decisions from the superseded adjacent-Visit
    // policy can be migrated and re-evaluated once.
    case routePassThrough = "route_pass_through"
    case locationRoutePassThroughV2 = "location_route_pass_through_v2"
    case completedVisitWithoutContradiction = "completed_visit_without_contradiction"
    case completedVisitWithoutRouteContradictionV2 = "completed_visit_without_route_contradiction_v2"
    case observedCompletedVisit = "observed_completed_visit"
    case observedCompletedVisitRouteReviewed = "observed_completed_visit_route_reviewed"
    case duplicateObservedVisit = "duplicate_observed_visit"
}

public enum StayValidationDecision: Equatable, Sendable {
    case confirm(StayValidationReason)
    case reject(StayValidationReason)
    case deferDecision(StayValidationReason)
}

/// Finalizes a candidate that a later distinct visit has proven is no longer
/// current, while keeping that later arrival separate from the unknown
/// departure time. Delayed sensor evidence gets the same grace period as route
/// review; after that, an unprovable stay is rejected instead of remaining
/// pending forever.
public enum StayCandidateFinalizationPolicy {
    public static let departureEvidenceGracePeriod: TimeInterval = 10 * 60

    public static func reviewAt(departureNotAfterAt: Date) -> Date {
        departureNotAfterAt.addingTimeInterval(departureEvidenceGracePeriod)
    }

    public static func evaluateBoundedWithoutDeparture(
        arrivalAt: Date,
        departureNotAfterAt: Date,
        evaluatedAt: Date
    ) -> StayValidationDecision {
        guard evaluatedAt >= reviewAt(departureNotAfterAt: departureNotAfterAt) else {
            return .deferDecision(.awaitingDeparture)
        }
        guard departureNotAfterAt.timeIntervalSince(arrivalAt) >=
                StayValidationPolicy.minimumDuration else {
            return .reject(.belowMinimumDuration)
        }
        return .reject(.insufficientEvidence)
    }

    public static func shouldReopenForLateDeparture(
        previousReason: StayValidationReason?,
        hadObservedDeparture: Bool
    ) -> Bool {
        guard hadObservedDeparture == false else {
            return false
        }
        return previousReason != nil
    }
}

public enum StayDepartureSelectionPolicy {
    public static func effectiveDepartureAt(
        observed: Date?,
        inferred: Date?
    ) -> Date? {
        observed ?? inferred
    }

    public static func usesInferredDeparture(
        observed: Date?,
        inferred: Date?
    ) -> Bool {
        observed == nil && inferred != nil
    }

    public static func requiresFallbackBoundaryResolution(
        hasObservedDeparture: Bool,
        hasTransitionBoundary: Bool,
        hasInferredDeparture: Bool,
        inferredFromNextCandidate: Bool
    ) -> Bool {
        hasObservedDeparture == false &&
            hasTransitionBoundary &&
            (hasInferredDeparture == false || inferredFromNextCandidate)
    }
}

public enum StayCandidateOwnershipPolicy {
    public static func canReuseConfirmedStay(
        candidateArrivalAt: Date,
        stayArrivalAt: Date,
        arrivalTolerance: TimeInterval
    ) -> Bool {
        abs(stayArrivalAt.timeIntervalSince(candidateArrivalAt)) <= arrivalTolerance
    }
}

/// Core Location can report the same visit more than once with a slightly
/// shifted arrival and coordinate. Keep the broad, tight-time match used for
/// ordinary updates, and add a narrower-distance window for that drift.
public enum ObservedVisitIdentityPolicy {
    public static let ordinaryArrivalTolerance: TimeInterval = 2 * 60
    public static let ordinaryMaximumDistanceMeters: Double = 500
    public static let driftedArrivalTolerance: TimeInterval = 5 * 60
    public static let driftedMaximumDistanceMeters: Double = 150

    public static func representsSameVisit(
        existingArrivalAt: Date,
        existingCoordinate: GeoCoordinate,
        incomingArrivalAt: Date,
        incomingCoordinate: GeoCoordinate
    ) -> Bool {
        let arrivalDelta = abs(existingArrivalAt.timeIntervalSince(incomingArrivalAt))
        let distance = GeoDistance.meters(from: existingCoordinate, to: incomingCoordinate)
        return (arrivalDelta <= ordinaryArrivalTolerance &&
                distance <= ordinaryMaximumDistanceMeters) ||
            (arrivalDelta <= driftedArrivalTolerance &&
             distance <= driftedMaximumDistanceMeters)
    }

    public static func representsSameResolvedVisit(
        existingArrivalAt: Date,
        existingDepartureAt: Date,
        existingCoordinate: GeoCoordinate,
        incomingArrivalAt: Date,
        incomingDepartureAt: Date,
        incomingCoordinate: GeoCoordinate
    ) -> Bool {
        representsSameVisit(
            existingArrivalAt: existingArrivalAt,
            existingCoordinate: existingCoordinate,
            incomingArrivalAt: incomingArrivalAt,
            incomingCoordinate: incomingCoordinate
        ) && abs(existingDepartureAt.timeIntervalSince(incomingDepartureAt)) <=
            driftedArrivalTolerance
    }
}

/// Candidate-linked stays are durable projections of separate visit decisions.
/// Automatic cleanup may merge only legacy rows that no candidate owns.
public enum StayDuplicateMergePolicy {
    public static func canAutomaticallyMerge(
        isLeftCandidateLinked: Bool,
        isRightCandidateLinked: Bool
    ) -> Bool {
        isLeftCandidateLinked == false && isRightCandidateLinked == false
    }
}

/// Completed Core Location visits of at least ten minutes are stays by default.
/// Short visits wait for surrounding route context so an observed departure
/// does not preserve a pass-through that continued moving before and after the
/// visit. Motion activity alone never disproves presence at a place.
public enum StayValidationPolicy {
    public static let minimumDuration: TimeInterval = 10 * 60
    public static let longVisitDuration: TimeInterval = 30 * 60
    public static let maximumRouteReviewDuration: TimeInterval = 30 * 60
    public static let routeContextLookaround: TimeInterval = 10 * 60
    public static let routeReviewDelay: TimeInterval = 10 * 60
    public static let maximumReliablePointAccuracy: Double = 250
    public static let minimumStableLocationSpan: TimeInterval = 5 * 60
    public static let minimumClassifiedMotionDuration: TimeInterval = 4 * 60
    public static let stationaryDominanceRatio: Double = 0.60
    public static let movingDominanceRatio: Double = 0.60
    public static let minimumOutsidePointSpan: TimeInterval = 3 * 60
    public static let minimumRouteDisplacementMeters: Double = 500

    public static func evaluate(_ evidence: StayValidationEvidence) -> StayValidationDecision {
        guard let departureAt = evidence.departureAt else {
            return .deferDecision(.awaitingDeparture)
        }

        let duration = departureAt.timeIntervalSince(evidence.arrivalAt)
        guard duration >= minimumDuration else {
            return .reject(.belowMinimumDuration)
        }
        guard evidence.overlapsConfirmedStay == false else {
            return .reject(.conflictingStay)
        }
        if evidence.hasObservedDeparture {
            guard duration <= maximumRouteReviewDuration else {
                return .confirm(.observedCompletedVisit)
            }
            if evidence.evaluatedAt < departureAt.addingTimeInterval(routeReviewDelay) {
                return .deferDecision(.awaitingRouteContext)
            }
            if isShortVisitEmbeddedInRoute(evidence, requiresRouteContext: true) {
                return .reject(.locationRoutePassThroughV2)
            }
            return .confirm(.observedCompletedVisitRouteReviewed)
        }
        let stableLocation = hasStableLocationCluster(evidence)
        if let motion = evidence.motion,
           motion.classifiedDuration >= minimumClassifiedMotionDuration {
            let stationaryRatio = motion.stationaryDuration / motion.classifiedDuration

            if stationaryRatio >= stationaryDominanceRatio {
                return .confirm(stableLocation ? .stationaryWithStableLocation : .stationaryMotion)
            }
        }

        if stableLocation {
            return .confirm(.stableLocationCluster)
        }
        if evidence.requiresPositiveStayEvidence {
            if duration <= maximumRouteReviewDuration,
               evidence.evaluatedAt < departureAt.addingTimeInterval(routeReviewDelay) {
                return .deferDecision(.awaitingRouteContext)
            }
            if isShortVisitEmbeddedInRoute(evidence) {
                return .reject(.locationRoutePassThroughV2)
            }
            if let motion = evidence.motion,
               motion.classifiedDuration >= minimumClassifiedMotionDuration,
               motion.movingDuration / motion.classifiedDuration >= movingDominanceRatio,
               motion.stationaryDuration < minimumStableLocationSpan {
                return .reject(.movingDominantMotion)
            }
            return .reject(.insufficientEvidence)
        }
        if evidence.hasSpatialTransitionBoundary,
           duration >= longVisitDuration {
            return .confirm(.longVisitWithoutContradiction)
        }
        if duration <= maximumRouteReviewDuration,
           evidence.evaluatedAt < departureAt.addingTimeInterval(routeReviewDelay) {
            return .deferDecision(.awaitingRouteContext)
        }
        if isShortVisitEmbeddedInRoute(evidence) {
            return .reject(.locationRoutePassThroughV2)
        }
        return .confirm(.completedVisitWithoutRouteContradictionV2)
    }

    private static func reliablePoints(_ evidence: StayValidationEvidence) -> [MovementPoint] {
        guard let departureAt = evidence.departureAt else {
            return []
        }
        return evidence.locationPoints
            .filter {
                $0.timestamp >= evidence.arrivalAt &&
                    $0.timestamp <= departureAt &&
                    $0.horizontalAccuracy >= 0 &&
                    $0.horizontalAccuracy <= maximumReliablePointAccuracy
            }
            .sorted { $0.timestamp < $1.timestamp }
    }

    private static func hasContinuousLocationMovement(_ evidence: StayValidationEvidence) -> Bool {
        let points = reliablePoints(evidence)
        guard points.count >= 2 else {
            return false
        }

        for pair in zip(points, points.dropFirst()) {
            if let containmentCoordinate = evidence.containmentCoordinate,
               let radius = evidence.containmentRadiusMeters {
                let firstDistance = GeoDistance.meters(
                    from: containmentCoordinate,
                    to: pair.0.coordinate
                )
                let secondDistance = GeoDistance.meters(
                    from: containmentCoordinate,
                    to: pair.1.coordinate
                )
                if firstDistance <= radius, secondDistance <= radius {
                    continue
                }
            }
            let elapsed = pair.1.timestamp.timeIntervalSince(pair.0.timestamp)
            guard elapsed >= 60 else {
                continue
            }
            let distance = GeoDistance.meters(
                from: pair.0.coordinate,
                to: pair.1.coordinate
            )
            let uncertainty = max(0, pair.0.horizontalAccuracy) + max(0, pair.1.horizontalAccuracy)
            let meaningfulDistance = max(0, distance - uncertainty)
            let departureThreshold = max(250, min(600, uncertainty))
            if distance > departureThreshold,
               meaningfulDistance / elapsed >= 0.75 {
                return true
            }
        }
        return false
    }

    private static func isShortVisitEmbeddedInRoute(
        _ evidence: StayValidationEvidence,
        requiresRouteContext: Bool = false
    ) -> Bool {
        guard let departureAt = evidence.departureAt else {
            return false
        }
        let duration = departureAt.timeIntervalSince(evidence.arrivalAt)
        guard duration <= maximumRouteReviewDuration,
              let motion = evidence.motion,
              motion.classifiedDuration >= minimumClassifiedMotionDuration,
              motion.movingDuration / motion.classifiedDuration >= movingDominanceRatio,
              motion.stationaryDuration < minimumStableLocationSpan else {
            return false
        }

        if requiresRouteContext == false, hasContinuousLocationMovement(evidence) {
            return true
        }

        let contextStart = evidence.arrivalAt.addingTimeInterval(-routeContextLookaround)
        let contextEnd = departureAt.addingTimeInterval(routeContextLookaround)
        let contextPoints = evidence.routeContextPoints
            .filter {
                $0.timestamp >= contextStart &&
                    $0.timestamp <= contextEnd &&
                    $0.horizontalAccuracy >= 0 &&
                    $0.horizontalAccuracy <= maximumReliablePointAccuracy
            }
            .sorted { $0.timestamp < $1.timestamp }

        let entryPoints = contextPoints.filter { point in
            point.timestamp <= evidence.arrivalAt && isOutsideCandidate(point, evidence: evidence)
        }
        let exitPoints = contextPoints.filter { point in
            point.timestamp > departureAt && isOutsideCandidate(point, evidence: evidence)
        }
        guard let entry = entryPoints.last,
              let firstExit = exitPoints.first,
              let lastExit = exitPoints.last,
              lastExit.timestamp.timeIntervalSince(firstExit.timestamp) >= minimumOutsidePointSpan,
              GeoDistance.meters(from: entry.coordinate, to: lastExit.coordinate) >=
                minimumRouteDisplacementMeters else {
            return false
        }
        return true
    }

    private static func isOutsideCandidate(
        _ point: MovementPoint,
        evidence: StayValidationEvidence
    ) -> Bool {
        let referenceCoordinate = evidence.containmentCoordinate ?? evidence.coordinate
        let uncertainty = evidence.horizontalAccuracy + point.horizontalAccuracy
        let candidateRadius = max(250, min(600, uncertainty))
        let radius = max(candidateRadius, evidence.containmentRadiusMeters ?? 0)
        return GeoDistance.meters(from: referenceCoordinate, to: point.coordinate) > radius
    }

    private static func hasStableLocationCluster(_ evidence: StayValidationEvidence) -> Bool {
        let points = reliablePoints(evidence).filter { point in
            let distance = GeoDistance.meters(from: evidence.coordinate, to: point.coordinate)
            let radius = max(
                75,
                min(200, evidence.horizontalAccuracy + max(0, point.horizontalAccuracy))
            )
            return distance <= radius
        }
        guard points.count >= 2,
              let first = points.first,
              let last = points.last,
              last.timestamp.timeIntervalSince(first.timestamp) >= minimumStableLocationSpan else {
            return false
        }

        return GeoDistance.meters(from: first.coordinate, to: last.coordinate) <= max(
            100,
            min(250, first.horizontalAccuracy + last.horizontalAccuracy)
        )
    }
}

public enum StayOverlapPolicy {
    public static func overlaps(
        arrivalAt: Date,
        departureAt: Date?,
        intervalStart: Date,
        intervalEnd: Date,
        now: Date
    ) -> Bool {
        let effectiveDepartureAt = departureAt ?? now
        return arrivalAt < intervalEnd && effectiveDepartureAt >= intervalStart
    }
}
