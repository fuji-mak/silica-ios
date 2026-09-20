import CoreLocation
import CoreMotion
import Foundation
import SwiftData
#if canImport(SilicaCore)
import SilicaCore
#endif

private enum StayLocationUpdateError: LocalizedError {
    case invalidLocation

    var errorDescription: String? {
        AppLanguage.localized("有効な位置を選択してください。")
    }
}

@MainActor
final class LocationRecorder: NSObject, ObservableObject {
    @Published private(set) var authorizationStatus: CLAuthorizationStatus = .notDetermined
    @Published private(set) var accuracyAuthorization: CLAccuracyAuthorization = .reducedAccuracy
    @Published private(set) var lastErrorMessage: String?
    @Published private(set) var isMonitoring = false
    @Published private(set) var isInitialLocationRequestInFlight = false

    var hasAutomaticRecordingPermission: Bool {
        authorizationStatus == .authorizedAlways &&
            accuracyAuthorization == .fullAccuracy
    }

    private let manager = CLLocationManager()
    private let refinementManager = CLLocationManager()
    private let refinementDelegate = OneShotLocationDelegate()
    private let geocoder = CLGeocoder()
    private let motionActivityManager = CMMotionActivityManager()
    private let pedometerEvidenceProvider = PedometerEvidenceProvider()
    private weak var modelContext: ModelContext?
    private let duplicateMergeRadiusMeters: Double = 150
    private let duplicateMergeGapSeconds: TimeInterval = 30 * 60
    private let sameVisitArrivalToleranceSeconds: TimeInterval = 2 * 60
    private let sameVisitMaximumDistanceMeters: Double = 500
    private let recentObservedVisitRevalidationWindow: TimeInterval = 14 * 24 * 60 * 60
    private var validatingCandidateIDs: Set<UUID> = []
    private var resolvingCandidateDepartureIDs: Set<UUID> = []
    private var resolvingMovementPairs: Set<MovementPairKey> = []
    private var candidateReviewTasks: [UUID: Task<Void, Never>] = [:]
    private var isBackfillingMovementModes = false
    private var pendingCoordinateRefinement: PendingCoordinateRefinement?
    private var coordinateRefinementTimeoutTask: Task<Void, Never>?
    private var lastBootstrapRequestAt: Date?

    private static let bootstrapRequestCooldown: TimeInterval = 5 * 60

    private struct CandidateUpsertResult {
        let candidate: StayCandidateEntity
        let wasInserted: Bool
    }

    private struct PendingCoordinateRefinement {
        let candidateID: UUID
        let requestedAt: Date
        let rawCoordinate: GeoCoordinate
        let rawHorizontalAccuracy: Double
    }

    private struct ResolvedOutgoingMovement {
        let interval: DateInterval?
        let modes: [MovementMode]
        let source: MovementTimingSource
        let confidence: MovementTimingConfidence
        let activeDuration: TimeInterval?
        let distanceMeters: Double?
        let stepCount: Int?
        let distanceSource: MovementDistanceSource
        let pedometerBuckets: [PedometerMovementBucket]

        init(
            interval: DateInterval?,
            modes: [MovementMode],
            source: MovementTimingSource,
            confidence: MovementTimingConfidence,
            activeDuration: TimeInterval? = nil,
            distanceMeters: Double? = nil,
            stepCount: Int? = nil,
            distanceSource: MovementDistanceSource = .unavailable,
            pedometerBuckets: [PedometerMovementBucket] = []
        ) {
            self.interval = interval
            self.modes = modes
            self.source = source
            self.confidence = confidence
            self.activeDuration = activeDuration
            self.distanceMeters = distanceMeters
            self.stepCount = stepCount
            self.distanceSource = distanceSource
            self.pedometerBuckets = pedometerBuckets
        }
    }

    private struct MovingIntervalResolution {
        let intervals: [DateInterval]
        let diagnostic: DepartureResolutionDiagnostic?
    }

    private enum DepartureResolutionDiagnostic: String {
        case noObservedVisitDeparture = "no_observed_visit_departure"
        case noReliableNearbyPoint = "no_reliable_nearby_point"
        case motionUnavailable = "motion_unavailable"
        case motionUnauthorized = "motion_unauthorized"
        case motionQueryFailed = "motion_query_failed"
        case noClassifiedMovement = "no_classified_movement"
        case noQualifyingMotionDeparture = "no_qualifying_motion_departure"
        case noSustainedOutsideLocation = "no_sustained_outside_location"
    }

    private struct MovementPairKey: Hashable {
        let originID: UUID
        let destinationID: UUID
    }

    override init() {
        super.init()
        manager.delegate = self
        manager.desiredAccuracy = kCLLocationAccuracyHundredMeters
        refinementManager.delegate = refinementDelegate
        refinementManager.desiredAccuracy = kCLLocationAccuracyBest
        refinementDelegate.onLocations = { [weak self] locations in
            self?.handleCoordinateRefinement(locations)
        }
        refinementDelegate.onError = { [weak self] in
            self?.finishCoordinateRefinement()
        }
        authorizationStatus = manager.authorizationStatus
        accuracyAuthorization = manager.accuracyAuthorization
    }

    func attach(modelContext: ModelContext) {
        self.modelContext = modelContext
    }

    func configure(modelContext: ModelContext) {
        attach(modelContext: modelContext)
        reconcileDuplicateObservedVisitCandidates()
        reconcileDuplicateStays()
        let boundedCandidateIDs = reconcileOpenCandidates()
        prepareRecentObservedVisitCandidatesForRevalidation()
        try? modelContext.save()
        validatePendingCompletedCandidates()
        Set(boundedCandidateIDs + pendingBoundedCandidateIDs()).forEach(resolveCandidateDeparture)
        backfillRecentMovementModes()
        resolvePlaceDetailsForPendingCandidates()
        resolvePlaceDetailsForRecentUnresolvedStays()
    }

    func updateStayLocation(
        _ stay: StayEntity,
        to coordinate: CLLocationCoordinate2D
    ) throws {
        guard CLLocationCoordinate2DIsValid(coordinate),
              coordinate.latitude.isFinite,
              coordinate.longitude.isFinite,
              let modelContext else {
            throw StayLocationUpdateError.invalidLocation
        }

        let sortedStays = (try? modelContext.fetch(
            FetchDescriptor<StayEntity>(
                sortBy: [SortDescriptor(\.arrivalAt, order: .forward)]
            )
        )) ?? []
        if let index = sortedStays.firstIndex(where: { $0.id == stay.id }),
           index > sortedStays.startIndex {
            sortedStays[sortedStays.index(before: index)].clearMovementEvidence()
        }
        stay.clearMovementEvidence()
        stay.latitude = coordinate.latitude
        stay.longitude = coordinate.longitude
        stay.placeName = nil
        stay.address = nil
        stay.isLocationManuallyAdjusted = true
        stay.updatedAt = Date()

        do {
            try modelContext.save()
        } catch {
            modelContext.rollback()
            throw error
        }

        resolveMovementModesAround(stayID: stay.id)
        resolvePlaceDetails(for: stay)
        exportYesterdayIfNeeded(
            affectedDates: daysTouched(
                from: stay.arrivalAt,
                through: stay.departureAt ?? stay.arrivalAt
            )
        )
    }

    /// Removes only the projection of a duplicated completed CLVisit. Both raw
    /// candidates remain auditable; the less reliable one is marked rejected.
    private func reconcileDuplicateObservedVisitCandidates() {
        guard let modelContext else {
            return
        }
        let visitSource = LocationSource.visit.rawValue
        let descriptor = FetchDescriptor<StayCandidateEntity>(
            predicate: #Predicate { candidate in
                candidate.sourceRawValue == visitSource
            },
            sortBy: [SortDescriptor(\.arrivalAt, order: .forward)]
        )
        guard let candidates = try? modelContext.fetch(descriptor), candidates.count > 1 else {
            return
        }
        let aliases = (try? modelContext.fetch(
            FetchDescriptor<PlaceAliasEntity>(
                sortBy: [SortDescriptor(\.priority, order: .reverse)]
            )
        )) ?? []
        let rejectedState = StayCandidateState.rejected.rawValue

        for (index, left) in candidates.enumerated() where left.stateRawValue != rejectedState {
            guard let leftDepartureAt = left.effectiveDepartureAt else {
                continue
            }
            for right in candidates.dropFirst(index + 1) {
                let arrivalDelta = right.arrivalAt.timeIntervalSince(left.arrivalAt)
                if arrivalDelta > ObservedVisitIdentityPolicy.driftedArrivalTolerance {
                    break
                }
                guard right.stateRawValue != rejectedState,
                      let rightDepartureAt = right.effectiveDepartureAt,
                      ObservedVisitIdentityPolicy.representsSameResolvedVisit(
                        existingArrivalAt: left.arrivalAt,
                        existingDepartureAt: leftDepartureAt,
                        existingCoordinate: left.coordinate,
                        incomingArrivalAt: right.arrivalAt,
                        incomingDepartureAt: rightDepartureAt,
                        incomingCoordinate: right.coordinate
                      ) else {
                    continue
                }

                let leftAlias = StayResolution.matchingAlias(
                    for: left.presentationCoordinate,
                    aliases: aliases
                )
                let rightAlias = StayResolution.matchingAlias(
                    for: right.presentationCoordinate,
                    aliases: aliases
                )
                let duplicate: StayCandidateEntity
                if (leftAlias != nil) != (rightAlias != nil) {
                    duplicate = leftAlias == nil ? left : right
                } else if left.presentationHorizontalAccuracy != right.presentationHorizontalAccuracy {
                    duplicate = left.presentationHorizontalAccuracy < right.presentationHorizontalAccuracy
                        ? right
                        : left
                } else {
                    duplicate = right
                }
                apply(.reject(.duplicateObservedVisit), to: duplicate, in: modelContext)
                if duplicate.id == left.id {
                    break
                }
            }
        }
    }

    func requestAlwaysAuthorization() {
        manager.requestAlwaysAuthorization()
    }

    func requestWhenInUseAuthorization() {
        manager.requestWhenInUseAuthorization()
    }

    func refreshAuthorizationState() {
        authorizationStatus = manager.authorizationStatus
        accuracyAuthorization = manager.accuracyAuthorization
    }

    func start() {
        refreshAuthorizationState()
        guard hasAutomaticRecordingPermission else {
            stop()
            return
        }
        if isMonitoring == false {
            manager.startMonitoringVisits()
            manager.startMonitoringSignificantLocationChanges()
            isMonitoring = true
        }
        requestInitialLocationIfNeeded()
    }

    func stop() {
        manager.stopMonitoringVisits()
        manager.stopMonitoringSignificantLocationChanges()
        manager.stopUpdatingLocation()
        finishCoordinateRefinement()
        isInitialLocationRequestInFlight = false
        isMonitoring = false
    }

    private func requestInitialLocationIfNeeded(at now: Date = Date()) {
        guard isInitialLocationRequestInFlight == false,
              shouldRequestInitialLocation() else {
            return
        }
        if let lastBootstrapRequestAt,
           now.timeIntervalSince(lastBootstrapRequestAt) < Self.bootstrapRequestCooldown {
            return
        }
        isInitialLocationRequestInFlight = true
        lastBootstrapRequestAt = now
        manager.requestLocation()
    }

    private func shouldRequestInitialLocation() -> Bool {
        guard let modelContext else {
            return false
        }
        var stayDescriptor = FetchDescriptor<StayEntity>()
        stayDescriptor.fetchLimit = 1
        var candidateDescriptor = FetchDescriptor<StayCandidateEntity>()
        candidateDescriptor.fetchLimit = 1
        guard let stays = try? modelContext.fetch(stayDescriptor),
              let candidates = try? modelContext.fetch(candidateDescriptor) else {
            return false
        }
        return StayBootstrapPolicy.shouldRequestInitialLocation(
            hasRecordedStay: stays.isEmpty == false,
            hasCandidate: candidates.isEmpty == false
        )
    }

    private func saveVisit(
        arrivalDate: Date,
        departureDate: Date,
        latitude: Double,
        longitude: Double,
        horizontalAccuracy: Double
    ) {
        guard let modelContext else {
            return
        }
        let accuracy = max(horizontalAccuracy, 0)
        let arrivalAt = arrivalDate == Date.distantPast ? Date() : arrivalDate
        let departureAt = departureDate == Date.distantFuture ? nil : departureDate

        let upsertResult = upsertVisitCandidate(
            arrivalAt: arrivalAt,
            departureAt: departureAt,
            latitude: latitude,
            longitude: longitude,
            horizontalAccuracy: accuracy,
            sourceRawValue: LocationSource.visit.rawValue
        )
        let candidate = upsertResult.candidate
        var boundedCandidateIDs: [UUID] = []
        if departureAt == nil {
            boundedCandidateIDs.append(contentsOf: reconcileOpenCandidates(keeping: candidate))
        }
        if let previousCandidateID = boundPreviousCandidate(before: candidate) {
            boundedCandidateIDs.append(previousCandidateID)
        }
        try? modelContext.save()
        exportYesterdayIfNeeded()
        boundedCandidateIDs.forEach(resolveCandidateDeparture)
        if departureAt != nil {
            reconcileObservedDepartureIfNeeded(for: candidate)
            validateCandidate(candidate.id)
        }
        resolvePlaceDetailsIfNeeded(for: candidate)
        if departureAt == nil, upsertResult.wasInserted {
            considerCoordinateRefinement(for: candidate)
        }
    }

    private func saveMovementPoint(
        timestamp: Date,
        latitude: Double,
        longitude: Double,
        horizontalAccuracy: Double
    ) {
        guard let modelContext,
              horizontalAccuracy >= 0,
              horizontalAccuracy <= 5_000,
              timestamp.timeIntervalSinceNow <= 5 * 60,
              timestamp.timeIntervalSinceNow >= -30 * 60 else {
            return
        }

        let inferredCandidateIDs = inferCandidateDeparturesFromMovement(
            MovementPoint(
                timestamp: timestamp,
                coordinate: GeoCoordinate(latitude: latitude, longitude: longitude),
                horizontalAccuracy: horizontalAccuracy
            )
        )

        var descriptor = FetchDescriptor<MovementPointEntity>(
            sortBy: [SortDescriptor(\.timestamp, order: .reverse)]
        )
        descriptor.fetchLimit = 1
        if let latest = try? modelContext.fetch(descriptor).first {
            let distance = GeoDistance.meters(
                from: GeoCoordinate(latitude: latest.latitude, longitude: latest.longitude),
                to: GeoCoordinate(latitude: latitude, longitude: longitude)
            )
            let intervalSinceLatest = abs(timestamp.timeIntervalSince(latest.timestamp))
            if intervalSinceLatest < 60, distance < 100 {
                if inferredCandidateIDs.isEmpty == false {
                    try? modelContext.save()
                    exportYesterdayIfNeeded()
                    inferredCandidateIDs.forEach(validateCandidate)
                }
                validatePendingCompletedCandidates()
                return
            }
        }

        modelContext.insert(
            MovementPointEntity(
                timestamp: timestamp,
                latitude: latitude,
                longitude: longitude,
                horizontalAccuracy: horizontalAccuracy
            )
        )
        try? modelContext.save()
        exportYesterdayIfNeeded()
        inferredCandidateIDs.forEach(validateCandidate)
        validatePendingCompletedCandidates()
    }

    private func saveBootstrapCandidate(from location: CLLocation, evaluatedAt now: Date = Date()) {
        guard let modelContext,
              StayBootstrapPolicy.canUseLocation(
                timestamp: location.timestamp,
                horizontalAccuracy: location.horizontalAccuracy,
                evaluatedAt: now
              ) else {
            return
        }

        let coordinate = GeoCoordinate(
            latitude: location.coordinate.latitude,
            longitude: location.coordinate.longitude
        )
        if let existing = matchingOpenCandidate(near: coordinate) {
            if location.horizontalAccuracy < existing.presentationHorizontalAccuracy {
                existing.refinedLatitude = coordinate.latitude
                existing.refinedLongitude = coordinate.longitude
                existing.refinedHorizontalAccuracy = location.horizontalAccuracy
                existing.refinedAt = now
                existing.updatedAt = now
                try? modelContext.save()
                resolvePlaceDetailsIfNeeded(for: existing)
                exportYesterdayIfNeeded(affectedDates: [existing.arrivalAt])
            }
            return
        }

        let candidate = StayCandidateEntity(
            arrivalAt: location.timestamp,
            latitude: coordinate.latitude,
            longitude: coordinate.longitude,
            horizontalAccuracy: location.horizontalAccuracy,
            sourceRawValue: LocationSource.locationBootstrap.rawValue
        )
        candidate.decisionReasonRawValue = StayValidationReason.awaitingDeparture.rawValue
        modelContext.insert(candidate)
        let boundedCandidateIDs = reconcileOpenCandidates(keeping: candidate)
        try? modelContext.save()
        exportYesterdayIfNeeded(affectedDates: [candidate.arrivalAt])
        boundedCandidateIDs.forEach(resolveCandidateDeparture)
        resolvePlaceDetailsIfNeeded(for: candidate)
    }

    private func matchingOpenCandidate(near coordinate: GeoCoordinate) -> StayCandidateEntity? {
        guard let modelContext else {
            return nil
        }
        let pendingState = StayCandidateState.pending.rawValue
        let descriptor = FetchDescriptor<StayCandidateEntity>(
            predicate: #Predicate { candidate in
                candidate.departureAt == nil && candidate.stateRawValue == pendingState
            },
            sortBy: [SortDescriptor(\.arrivalAt, order: .reverse)]
        )
        return (try? modelContext.fetch(descriptor))?.first { candidate in
            candidate.effectiveDepartureAt == nil &&
                StayBootstrapPolicy.representsSamePlace(candidate.presentationCoordinate, coordinate)
        }
    }

    private func upsertVisitCandidate(
        arrivalAt: Date,
        departureAt: Date?,
        latitude: Double,
        longitude: Double,
        horizontalAccuracy: Double,
        sourceRawValue: String
    ) -> CandidateUpsertResult {
        if let existing = matchingVisitCandidate(
            arrivalAt: arrivalAt,
            latitude: latitude,
            longitude: longitude
        ) ?? matchingBootstrapCandidateForObservedVisit(
            arrivalAt: arrivalAt,
            departureAt: departureAt,
            latitude: latitude,
            longitude: longitude,
            sourceRawValue: sourceRawValue
        ) {
            let hadObservedDeparture = existing.departureAt != nil
            let previousReason = existing.decisionReasonRawValue.flatMap(StayValidationReason.init)
            if sourceRawValue == LocationSource.visit.rawValue,
               existing.sourceRawValue == LocationSource.locationBootstrap.rawValue {
                existing.arrivalAt = arrivalAt
                existing.sourceRawValue = sourceRawValue
            }
            if let departureAt {
                existing.departureAt = departureAt
                existing.inferredDepartureAt = nil
                existing.inferredDepartureReasonRawValue = nil
                if existing.stateRawValue == StayCandidateState.rejected.rawValue,
                   StayCandidateFinalizationPolicy.shouldReopenForLateDeparture(
                    previousReason: previousReason,
                    hadObservedDeparture: hadObservedDeparture
                   ) {
                    existing.stateRawValue = StayCandidateState.pending.rawValue
                    existing.decisionReasonRawValue = nil
                    existing.departureResolutionDiagnosticsRawValue = nil
                }
            }
            if horizontalAccuracy <= existing.horizontalAccuracy {
                existing.latitude = latitude
                existing.longitude = longitude
                existing.horizontalAccuracy = horizontalAccuracy
            }
            existing.updatedAt = Date()
            return CandidateUpsertResult(candidate: existing, wasInserted: false)
        }

        let candidate = StayCandidateEntity(
            arrivalAt: arrivalAt,
            departureAt: departureAt,
            latitude: latitude,
            longitude: longitude,
            horizontalAccuracy: horizontalAccuracy,
            sourceRawValue: sourceRawValue
        )
        modelContext?.insert(candidate)
        return CandidateUpsertResult(candidate: candidate, wasInserted: true)
    }

    private func matchingBootstrapCandidateForObservedVisit(
        arrivalAt: Date,
        departureAt: Date?,
        latitude: Double,
        longitude: Double,
        sourceRawValue: String
    ) -> StayCandidateEntity? {
        guard sourceRawValue == LocationSource.visit.rawValue,
              let modelContext else {
            return nil
        }
        let bootstrapSource = LocationSource.locationBootstrap.rawValue
        let earliest = arrivalAt.addingTimeInterval(
            -StayBootstrapPolicy.completedVisitBoundaryTolerance
        )
        let latest = (departureAt ?? arrivalAt.addingTimeInterval(
            StayBootstrapPolicy.openVisitMatchingWindow
        )).addingTimeInterval(StayBootstrapPolicy.completedVisitBoundaryTolerance)
        let descriptor = FetchDescriptor<StayCandidateEntity>(
            predicate: #Predicate { candidate in
                candidate.sourceRawValue == bootstrapSource &&
                    candidate.departureAt == nil &&
                    candidate.arrivalAt >= earliest &&
                    candidate.arrivalAt <= latest
            },
            sortBy: [SortDescriptor(\.arrivalAt, order: .reverse)]
        )
        let observedCoordinate = GeoCoordinate(latitude: latitude, longitude: longitude)
        return (try? modelContext.fetch(descriptor))?.first { candidate in
            StayBootstrapPolicy.canPromoteToObservedVisit(
                bootstrapArrivalAt: candidate.arrivalAt,
                bootstrapCoordinate: candidate.coordinate,
                observedArrivalAt: arrivalAt,
                observedDepartureAt: departureAt,
                observedCoordinate: observedCoordinate
            )
        }
    }

    private func considerCoordinateRefinement(for candidate: StayCandidateEntity) {
        guard let modelContext,
              candidate.refinementAttemptedAt == nil,
              pendingCoordinateRefinement == nil else {
            return
        }

        candidate.refinementAttemptedAt = Date()
        candidate.updatedAt = Date()
        try? modelContext.save()
        beginCoordinateRefinement(for: candidate)
    }

    private func beginCoordinateRefinement(for candidate: StayCandidateEntity) {
        let requestedAt = Date()
        pendingCoordinateRefinement = PendingCoordinateRefinement(
            candidateID: candidate.id,
            requestedAt: requestedAt,
            rawCoordinate: candidate.coordinate,
            rawHorizontalAccuracy: candidate.horizontalAccuracy
        )
        refinementManager.requestLocation()
        coordinateRefinementTimeoutTask?.cancel()
        coordinateRefinementTimeoutTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(15))
            guard Task.isCancelled == false else {
                return
            }
            self?.finishCoordinateRefinement()
        }
    }

    private func handleCoordinateRefinement(_ locations: [CLLocation]) {
        guard let request = pendingCoordinateRefinement,
              let modelContext else {
            finishCoordinateRefinement()
            return
        }
        let evaluatedAt = Date()
        let aliases = (try? modelContext.fetch(
            FetchDescriptor<PlaceAliasEntity>(
                sortBy: [SortDescriptor(\.priority, order: .reverse)]
            )
        )) ?? []
        let rawAlias = StayResolution.matchingAlias(
            for: request.rawCoordinate,
            aliases: aliases
        )

        let acceptedLocation = locations
            .sorted { $0.horizontalAccuracy < $1.horizontalAccuracy }
            .first { location in
                let sampleCoordinate = GeoCoordinate(
                    latitude: location.coordinate.latitude,
                    longitude: location.coordinate.longitude
                )
                let sampleAlias = StayResolution.matchingAlias(
                    for: sampleCoordinate,
                    aliases: aliases
                )
                let registeredPlaceRelationship: RegisteredPlaceRelationship
                switch (rawAlias, sampleAlias) {
                case let (raw?, sample?) where raw.id == sample.id:
                    registeredPlaceRelationship = .sameRegisteredPlace
                case (nil, nil):
                    registeredPlaceRelationship = .neitherCoordinateIsRegistered
                default:
                    registeredPlaceRelationship = .differentOrOnlyOneRegisteredPlace
                }
                return VisitCoordinateRefinementPolicy.accepts(
                    rawCoordinate: request.rawCoordinate,
                    rawHorizontalAccuracy: request.rawHorizontalAccuracy,
                    sampleCoordinate: sampleCoordinate,
                    sampleHorizontalAccuracy: location.horizontalAccuracy,
                    sampleTimestamp: location.timestamp,
                    requestedAt: request.requestedAt,
                    evaluatedAt: evaluatedAt,
                    registeredPlaceRelationship: registeredPlaceRelationship
                )
            }

        defer {
            finishCoordinateRefinement()
        }
        guard let acceptedLocation,
              let candidate = fetchCandidate(id: request.candidateID) else {
            return
        }

        candidate.refinedLatitude = acceptedLocation.coordinate.latitude
        candidate.refinedLongitude = acceptedLocation.coordinate.longitude
        candidate.refinedHorizontalAccuracy = acceptedLocation.horizontalAccuracy
        candidate.refinedAt = evaluatedAt
        candidate.placeName = nil
        candidate.address = nil
        candidate.updatedAt = evaluatedAt

        if let stay = confirmedStay(for: candidate),
           stay.isLocationManuallyAdjusted == false,
           acceptedLocation.horizontalAccuracy < stay.horizontalAccuracy {
            stay.latitude = acceptedLocation.coordinate.latitude
            stay.longitude = acceptedLocation.coordinate.longitude
            stay.horizontalAccuracy = acceptedLocation.horizontalAccuracy
            stay.placeName = nil
            stay.address = nil
            stay.updatedAt = evaluatedAt
            resolvePlaceDetails(for: stay)
        }
        try? modelContext.save()
        resolvePlaceDetailsIfNeeded(for: candidate)
        if let stay = confirmedStay(for: candidate) {
            resolveMovementModesAround(stayID: stay.id)
        }
        exportYesterdayIfNeeded(affectedDates: [candidate.arrivalAt])
    }

    private func finishCoordinateRefinement() {
        coordinateRefinementTimeoutTask?.cancel()
        coordinateRefinementTimeoutTask = nil
        if pendingCoordinateRefinement != nil {
            refinementManager.stopUpdatingLocation()
        }
        pendingCoordinateRefinement = nil
    }

    private func matchingVisitCandidate(
        arrivalAt: Date,
        latitude: Double,
        longitude: Double
    ) -> StayCandidateEntity? {
        guard let modelContext else {
            return nil
        }
        let earliest = arrivalAt.addingTimeInterval(-60 * 60)
        let latest = arrivalAt.addingTimeInterval(60 * 60)
        let descriptor = FetchDescriptor<StayCandidateEntity>(
            predicate: #Predicate { candidate in
                candidate.arrivalAt >= earliest && candidate.arrivalAt <= latest
            },
            sortBy: [SortDescriptor(\.arrivalAt, order: .reverse)]
        )
        guard let candidates = try? modelContext.fetch(descriptor) else {
            return nil
        }

        let coordinate = GeoCoordinate(latitude: latitude, longitude: longitude)
        return candidates.first { candidate in
            ObservedVisitIdentityPolicy.representsSameVisit(
                existingArrivalAt: candidate.arrivalAt,
                existingCoordinate: candidate.coordinate,
                incomingArrivalAt: arrivalAt,
                incomingCoordinate: coordinate
            )
        }
    }

    /// A later candidate at a distinct place is independent evidence that an
    /// earlier visit is no longer ongoing, even if Core Location hasn't sent
    /// that visit's departure event yet.
    private func reconcileOpenCandidates(
        keeping currentCandidate: StayCandidateEntity? = nil
    ) -> [UUID] {
        guard let modelContext else {
            return []
        }
        let descriptor = FetchDescriptor<StayCandidateEntity>(
            predicate: #Predicate { candidate in
                candidate.departureAt == nil
            },
            sortBy: [SortDescriptor(\.arrivalAt, order: .forward)]
        )
        guard let candidates = try? modelContext.fetch(descriptor), candidates.count > 1 else {
            return []
        }

        var boundedIDs: [UUID] = []
        for candidate in candidates {
            let boundaryCandidate: StayCandidateEntity?
            if let currentCandidate {
                guard candidate.id != currentCandidate.id,
                      candidate.arrivalAt < currentCandidate.arrivalAt else {
                    continue
                }
                boundaryCandidate = candidatesAreDistinct(candidate, currentCandidate)
                    ? currentCandidate
                    : nil
            } else {
                boundaryCandidate = candidates.first { laterCandidate in
                    laterCandidate.arrivalAt > candidate.arrivalAt &&
                        candidatesAreDistinct(candidate, laterCandidate)
                }
            }
            guard let boundaryCandidate else {
                continue
            }

            if candidate.departureNotAfterAt == nil {
                candidate.departureNotAfterAt = boundaryCandidate.arrivalAt
                if candidate.inferredDepartureAt == nil {
                    candidate.inferredDepartureReasonRawValue =
                        StayCandidateInferredDepartureReason.nextCandidate.rawValue
                }
                candidate.updatedAt = Date()
            }
            if candidate.inferredDepartureAt == nil ||
                candidate.inferredDepartureReasonRawValue ==
                    StayCandidateInferredDepartureReason.nextCandidate.rawValue {
                boundedIDs.append(candidate.id)
            }
        }
        return boundedIDs
    }

    /// Startup recovery must also retry candidates that were bounded in an
    /// earlier process and were still waiting when the app exited.
    private func pendingBoundedCandidateIDs() -> [UUID] {
        guard let modelContext else {
            return []
        }
        let descriptor = FetchDescriptor<StayCandidateEntity>(
            predicate: #Predicate { candidate in
                candidate.stateRawValue == "pending"
            }
        )
        guard let candidates = try? modelContext.fetch(descriptor) else {
            return []
        }
        return candidates.compactMap { candidate in
            guard candidate.departureNotAfterAt != nil,
                  candidate.effectiveDepartureAt == nil else {
                return nil
            }
            return candidate.id
        }
    }

    /// A new candidate only bounds the immediately preceding candidate when
    /// the two coordinates represent different places. Motion by itself never
    /// creates this boundary, which keeps walking inside one registered area
    /// as part of the same place episode.
    private func boundPreviousCandidate(
        before currentCandidate: StayCandidateEntity
    ) -> UUID? {
        guard let modelContext else {
            return nil
        }
        let arrivalAt = currentCandidate.arrivalAt
        var descriptor = FetchDescriptor<StayCandidateEntity>(
            predicate: #Predicate { candidate in
                candidate.arrivalAt < arrivalAt
            },
            sortBy: [SortDescriptor(\.arrivalAt, order: .reverse)]
        )
        descriptor.fetchLimit = 1
        guard let previous = try? modelContext.fetch(descriptor).first,
              previous.stateRawValue != StayCandidateState.rejected.rawValue,
              candidatesAreDistinct(previous, currentCandidate) else {
            return nil
        }

        if previous.departureNotAfterAt.map({ currentCandidate.arrivalAt < $0 }) ?? true {
            previous.departureNotAfterAt = currentCandidate.arrivalAt
            previous.updatedAt = Date()
        }
        guard previous.inferredDepartureAt == nil ||
                previous.inferredDepartureReasonRawValue ==
                    StayCandidateInferredDepartureReason.nextCandidate.rawValue else {
            return nil
        }
        return previous.id
    }

    private func candidatesAreDistinct(
        _ lhs: StayCandidateEntity,
        _ rhs: StayCandidateEntity
    ) -> Bool {
        if let modelContext {
            let aliases = (try? modelContext.fetch(
                FetchDescriptor<PlaceAliasEntity>(
                    sortBy: [SortDescriptor(\.priority, order: .reverse)]
                )
            )) ?? []
            let lhsAlias = StayResolution.matchingAlias(for: lhs.coordinate, aliases: aliases)
            let rhsAlias = StayResolution.matchingAlias(for: rhs.coordinate, aliases: aliases)
            if let lhsAlias, lhsAlias.id == rhsAlias?.id {
                return false
            }
        }
        let distance = GeoDistance.meters(from: lhs.coordinate, to: rhs.coordinate)
        let samePlaceRadius = max(
            duplicateMergeRadiusMeters,
            min(300, max(lhs.horizontalAccuracy, rhs.horizontalAccuracy))
        )
        return distance > samePlaceRadius
    }

    private func inferCandidateDeparturesFromMovement(
        _ currentPoint: MovementPoint
    ) -> [UUID] {
        guard let modelContext,
              currentPoint.horizontalAccuracy <= StayCandidateTemporalPolicy.maximumReliablePointAccuracy else {
            return []
        }
        let descriptor = FetchDescriptor<StayCandidateEntity>(
            predicate: #Predicate { candidate in
                candidate.departureAt == nil
            },
            sortBy: [SortDescriptor(\.arrivalAt, order: .forward)]
        )
        guard let candidates = try? modelContext.fetch(descriptor) else {
            return []
        }

        var inferredIDs: [UUID] = []
        for candidate in candidates where candidate.effectiveDepartureAt == nil {
            let inferenceStartAt = max(candidate.arrivalAt, candidate.createdAt)
            let evidenceEndAt = min(
                currentPoint.timestamp,
                candidate.departureNotAfterAt ?? currentPoint.timestamp
            )
            guard evidenceEndAt > inferenceStartAt else {
                continue
            }
            var points = movementPoints(
                from: inferenceStartAt,
                through: evidenceEndAt
            )
            if currentPoint.timestamp <= evidenceEndAt,
               points.contains(where: { $0.timestamp == currentPoint.timestamp }) == false {
                points.append(currentPoint)
            }
            guard StayCandidateTemporalPolicy.hasSustainedDeparture(
                arrivalAt: inferenceStartAt,
                through: evidenceEndAt,
                coordinate: candidate.coordinate,
                horizontalAccuracy: candidate.horizontalAccuracy,
                locationPoints: points
            ) else {
                continue
            }

            guard let inferredDepartureAt =
                StayCandidateTemporalPolicy.inferredDepartureAtFromSustainedLocation(
                arrivalAt: inferenceStartAt,
                through: evidenceEndAt,
                coordinate: candidate.coordinate,
                horizontalAccuracy: candidate.horizontalAccuracy,
                locationPoints: points
                ) else {
                continue
            }
            candidate.inferredDepartureAt = inferredDepartureAt
            candidate.inferredDepartureReasonRawValue =
                StayCandidateInferredDepartureReason.sustainedMovement.rawValue
            if candidate.stateRawValue == StayCandidateState.rejected.rawValue,
               StayCandidateFinalizationPolicy.shouldReopenForLateDeparture(
                previousReason: candidate.decisionReasonRawValue.flatMap(StayValidationReason.init),
                hadObservedDeparture: false
               ) {
                candidate.stateRawValue = StayCandidateState.pending.rawValue
                candidate.decisionReasonRawValue = nil
            }
            candidate.departureResolutionDiagnosticsRawValue = nil
            candidate.updatedAt = Date()
            inferredIDs.append(candidate.id)
        }
        return inferredIDs
    }

    private func resolveCandidateDeparture(_ candidateID: UUID) {
        guard resolvingCandidateDepartureIDs.insert(candidateID).inserted else {
            return
        }
        Task { @MainActor [weak self] in
            guard let self else {
                return
            }
            defer {
                resolvingCandidateDepartureIDs.remove(candidateID)
            }
            await resolveCandidateDepartureAsync(candidateID)
        }
    }

    private func resolveCandidateDepartureAsync(_ candidateID: UUID) async {
        guard let modelContext,
              let candidate = fetchCandidate(id: candidateID),
              candidate.stateRawValue != StayCandidateState.rejected.rawValue,
              candidate.departureAt == nil,
              let transitionBoundary = candidate.departureNotAfterAt else {
            return
        }
        let inferenceStartAt = max(candidate.arrivalAt, candidate.createdAt)
        let upperBound = min(candidate.departureAt ?? transitionBoundary, transitionBoundary)
        guard upperBound > inferenceStartAt else {
            if candidate.effectiveDepartureAt != nil {
                validateCandidate(candidateID)
            } else {
                finalizeBoundedCandidateWithoutDeparture(candidateID)
            }
            return
        }

        let points = movementPoints(from: inferenceStartAt, through: upperBound)
        let lastKnownInsideAt = StayCandidateTemporalPolicy.lastReliableNearbyAt(
            arrivalAt: inferenceStartAt,
            through: upperBound,
            coordinate: candidate.coordinate,
            horizontalAccuracy: candidate.horizontalAccuracy,
            locationPoints: points
        )
        let movingIntervalResolution = await movingIntervals(
            from: inferenceStartAt,
            through: upperBound
        )
        let motionDepartureAt = StayCandidateTemporalPolicy.inferredDepartureAtFromMotion(
            arrivalAt: inferenceStartAt,
            notAfter: upperBound,
            lastKnownInsideAt: lastKnownInsideAt,
            movingIntervals: movingIntervalResolution.intervals
        )
        let locationDepartureAt =
            StayCandidateTemporalPolicy.inferredDepartureAtFromSustainedLocation(
                arrivalAt: inferenceStartAt,
                through: upperBound,
                coordinate: candidate.coordinate,
                horizontalAccuracy: candidate.horizontalAccuracy,
                locationPoints: points
            )
        let inferredDepartureAt = motionDepartureAt ?? locationDepartureAt
        guard let refreshedCandidate = fetchCandidate(id: candidateID),
              refreshedCandidate.stateRawValue != StayCandidateState.rejected.rawValue,
              refreshedCandidate.departureAt == nil,
              refreshedCandidate.departureNotAfterAt == transitionBoundary else {
            return
        }

        let oldInferredDepartureAt = refreshedCandidate.inferredDepartureAt
        if let inferredDepartureAt,
           oldInferredDepartureAt.map({ inferredDepartureAt < $0 }) ?? true {
            refreshedCandidate.inferredDepartureAt = inferredDepartureAt
            refreshedCandidate.inferredDepartureReasonRawValue = motionDepartureAt == nil
                ? StayCandidateInferredDepartureReason.sustainedMovement.rawValue
                : StayCandidateInferredDepartureReason.motionActivity.rawValue
            refreshedCandidate.updatedAt = Date()
            refreshedCandidate.departureResolutionDiagnosticsRawValue = nil
        } else if refreshedCandidate.effectiveDepartureAt == nil {
            var diagnostics: Set<DepartureResolutionDiagnostic> = []
            if refreshedCandidate.departureAt == nil {
                diagnostics.insert(.noObservedVisitDeparture)
            }
            if lastKnownInsideAt == nil {
                diagnostics.insert(.noReliableNearbyPoint)
            }
            if let diagnostic = movingIntervalResolution.diagnostic {
                diagnostics.insert(diagnostic)
            } else if motionDepartureAt == nil {
                diagnostics.insert(.noQualifyingMotionDeparture)
            }
            if locationDepartureAt == nil {
                diagnostics.insert(.noSustainedOutsideLocation)
            }
            refreshedCandidate.departureResolutionDiagnosticsRawValue = diagnostics
                .map(\.rawValue)
                .sorted()
                .joined(separator: ",")
            refreshedCandidate.updatedAt = Date()
        }

        if refreshedCandidate.stateRawValue == StayCandidateState.confirmed.rawValue,
           let effectiveDepartureAt = refreshedCandidate.effectiveDepartureAt {
            let reusableStay = confirmedStay(for: refreshedCandidate).flatMap { stay in
                StayCandidateOwnershipPolicy.canReuseConfirmedStay(
                    candidateArrivalAt: refreshedCandidate.arrivalAt,
                    stayArrivalAt: stay.arrivalAt,
                    arrivalTolerance: sameVisitArrivalToleranceSeconds
                ) ? stay : nil
            }
            let stay = reusableStay ?? makeConfirmedStayProjection(
                for: refreshedCandidate,
                departureAt: effectiveDepartureAt,
                in: modelContext
            )
            let oldDepartureAt = stay.departureAt
            stay.departureAt = effectiveDepartureAt
            stay.departureSourceRawValue = refreshedCandidate.usesInferredDeparture
                ? StayDepartureSource.inferredCandidate.rawValue
                : StayDepartureSource.observedVisit.rawValue
            stay.clearMovementEvidence()
            stay.updatedAt = Date()
            try? modelContext.save()
            resolveMovementModesAround(stayID: stay.id)
            let affectedDates = Array(Set(
                daysTouched(
                    from: refreshedCandidate.arrivalAt,
                    through: oldDepartureAt ?? oldInferredDepartureAt ?? refreshedCandidate.arrivalAt
                ) +
                    daysTouched(
                        from: refreshedCandidate.arrivalAt,
                        through: effectiveDepartureAt
                    )
            ))
            exportYesterdayIfNeeded(affectedDates: affectedDates)
        } else {
            try? modelContext.save()
            if refreshedCandidate.effectiveDepartureAt != nil {
                validateCandidate(refreshedCandidate.id)
            } else {
                finalizeBoundedCandidateWithoutDeparture(refreshedCandidate.id)
            }
        }
    }

    private func movingIntervals(
        from startAt: Date,
        through endAt: Date
    ) async -> MovingIntervalResolution {
        guard endAt > startAt else {
            return MovingIntervalResolution(intervals: [], diagnostic: .noClassifiedMovement)
        }
        guard CMMotionActivityManager.isActivityAvailable() else {
            return MovingIntervalResolution(intervals: [], diagnostic: .motionUnavailable)
        }
        guard CMMotionActivityManager.authorizationStatus() == .authorized else {
            return MovingIntervalResolution(intervals: [], diagnostic: .motionUnauthorized)
        }
        return await withCheckedContinuation { continuation in
            motionActivityManager.queryActivityStarting(
                from: startAt,
                to: endAt,
                to: .main
            ) { activities, error in
                guard error == nil else {
                    continuation.resume(returning: MovingIntervalResolution(
                        intervals: [],
                        diagnostic: .motionQueryFailed
                    ))
                    return
                }
                guard let activities else {
                    continuation.resume(returning: MovingIntervalResolution(
                        intervals: [],
                        diagnostic: .noClassifiedMovement
                    ))
                    return
                }
                let sorted = activities.sorted { $0.startDate < $1.startDate }
                var intervals: [DateInterval] = []
                for index in sorted.indices {
                    let activity = sorted[index]
                    guard activity.confidence != .low,
                          activity.walking || activity.running || activity.cycling || activity.automotive else {
                        continue
                    }
                    let rawEnd = index < sorted.index(before: sorted.endIndex)
                        ? sorted[sorted.index(after: index)].startDate
                        : endAt
                    let intervalStart = max(startAt, activity.startDate)
                    let intervalEnd = min(endAt, rawEnd)
                    guard intervalEnd > intervalStart else {
                        continue
                    }
                    if let previous = intervals.last,
                       intervalStart.timeIntervalSince(previous.end) <= 3 * 60 {
                        intervals[intervals.index(before: intervals.endIndex)] = DateInterval(
                            start: previous.start,
                            end: max(previous.end, intervalEnd)
                        )
                    } else {
                        intervals.append(DateInterval(start: intervalStart, end: intervalEnd))
                    }
                }
                continuation.resume(returning: MovingIntervalResolution(
                    intervals: intervals,
                    diagnostic: intervals.isEmpty ? .noClassifiedMovement : nil
                ))
            }
        }
    }

    private func finalizeBoundedCandidateWithoutDeparture(_ candidateID: UUID) {
        guard let modelContext,
              let candidate = fetchCandidate(id: candidateID),
              candidate.stateRawValue == StayCandidateState.pending.rawValue,
              candidate.effectiveDepartureAt == nil,
              let departureNotAfterAt = candidate.departureNotAfterAt else {
            return
        }

        let decision = StayCandidateFinalizationPolicy.evaluateBoundedWithoutDeparture(
            arrivalAt: candidate.arrivalAt,
            departureNotAfterAt: departureNotAfterAt,
            evaluatedAt: Date()
        )
        switch decision {
        case .deferDecision:
            apply(decision, to: candidate, in: modelContext)
            scheduleBoundedCandidateReview(
                candidateID,
                at: StayCandidateFinalizationPolicy.reviewAt(
                    departureNotAfterAt: departureNotAfterAt
                )
            )
        case .reject:
            apply(decision, to: candidate, in: modelContext)
        case .confirm:
            assertionFailure("A candidate without a departure cannot be confirmed")
        }
    }

    private func scheduleBoundedCandidateReview(_ candidateID: UUID, at reviewAt: Date) {
        candidateReviewTasks[candidateID]?.cancel()
        candidateReviewTasks[candidateID] = Task { @MainActor [weak self] in
            let delay = max(0, reviewAt.timeIntervalSinceNow)
            if delay > 0 {
                try? await Task.sleep(for: .seconds(delay))
            }
            guard Task.isCancelled == false, let self else {
                return
            }
            candidateReviewTasks[candidateID] = nil
            resolveCandidateDeparture(candidateID)
        }
    }

    private func resolveMovementModesAround(stayID: UUID) {
        guard let modelContext else {
            return
        }
        let stays = ((try? modelContext.fetch(
            FetchDescriptor<StayEntity>(
                sortBy: [SortDescriptor(\.arrivalAt, order: .forward)]
            )
        )) ?? [])
        guard let index = stays.firstIndex(where: { $0.id == stayID }) else {
            return
        }
        if index > stays.startIndex {
            resolveMovementModes(
                from: stays[stays.index(before: index)].id,
                to: stays[index].id
            )
        }
        if index < stays.index(before: stays.endIndex) {
            resolveMovementModes(
                from: stays[index].id,
                to: stays[stays.index(after: index)].id
            )
        } else if stays[index].hasResolvedMovementModes ||
                    stays[index].hasResolvedMovementTiming {
            stays[index].clearMovementEvidence()
            stays[index].updatedAt = Date()
            try? modelContext.save()
        }
    }

    private func adjacentConfirmedPair(
        originID: UUID,
        destinationID: UUID
    ) -> (origin: StayEntity, destination: StayEntity)? {
        guard let modelContext else {
            return nil
        }
        let stays = ((try? modelContext.fetch(
            FetchDescriptor<StayEntity>(
                sortBy: [SortDescriptor(\.arrivalAt, order: .forward)]
            )
        )) ?? [])
        guard let originIndex = stays.firstIndex(where: { $0.id == originID }),
              originIndex < stays.index(before: stays.endIndex) else {
            return nil
        }
        let destination = stays[stays.index(after: originIndex)]
        guard destination.id == destinationID else {
            return nil
        }
        return (stays[originIndex], destination)
    }

    private func resolveMovementModes(
        from originID: UUID,
        to destinationID: UUID
    ) {
        let key = MovementPairKey(originID: originID, destinationID: destinationID)
        guard resolvingMovementPairs.insert(key).inserted else {
            return
        }
        Task { @MainActor [weak self] in
            guard let self else {
                return
            }
            defer {
                resolvingMovementPairs.remove(key)
            }
            guard let pair = adjacentConfirmedPair(
                originID: originID,
                destinationID: destinationID
            ) else {
                return
            }
            let origin = pair.origin
            let destination = pair.destination
            let originArrivalAt = origin.arrivalAt
            let originDepartureAt = origin.departureAt
            guard destination.arrivalAt > originArrivalAt else {
                origin.clearMovementEvidence()
                origin.updatedAt = Date()
                try? modelContext?.save()
                return
            }
            let destinationArrivalAt = destination.arrivalAt
            let resolved = await resolvedOutgoingMovement(
                from: origin,
                to: destination
            )
            guard let refreshedPair = adjacentConfirmedPair(
                originID: originID,
                destinationID: destinationID
            ),
                  refreshedPair.origin.arrivalAt == originArrivalAt,
                  refreshedPair.origin.departureAt == originDepartureAt,
                  refreshedPair.destination.arrivalAt == destinationArrivalAt else {
                return
            }
            let refreshedOrigin = refreshedPair.origin
            refreshedOrigin.storeMovementModes(resolved.modes)
            refreshedOrigin.storeMovementTiming(
                interval: resolved.interval,
                destinationStayID: destinationID,
                source: resolved.source,
                confidence: resolved.confidence,
                activeDuration: resolved.activeDuration,
                distanceMeters: resolved.distanceMeters,
                stepCount: resolved.stepCount,
                distanceSource: resolved.distanceSource,
                pedometerBuckets: resolved.pedometerBuckets
            )
            refreshedOrigin.updatedAt = Date()
            try? modelContext?.save()
            exportYesterdayIfNeeded(
                affectedDates: daysTouched(
                    from: min(
                        origin.arrivalAt,
                        resolved.interval?.start ?? originDepartureAt ?? originArrivalAt
                    ),
                    through: max(
                        destinationArrivalAt,
                        resolved.interval?.end ?? destinationArrivalAt
                    )
                )
            )
        }
    }

    private func resolvedOutgoingMovement(
        from origin: StayEntity,
        to destination: StayEntity
    ) async -> ResolvedOutgoingMovement {
        let destinationArrivalAt = destination.arrivalAt
        guard destinationArrivalAt > origin.arrivalAt else {
            return ResolvedOutgoingMovement(
                interval: nil,
                modes: [],
                source: .unavailable,
                confidence: .unavailable
            )
        }

        let postArrivalEnd = min(
            Date(),
            destinationArrivalAt.addingTimeInterval(
                MovementDurationPolicy.maximumDestinationAnchorDelay
            )
        )
        let preliminaryStart = max(
            origin.arrivalAt,
            destinationArrivalAt.addingTimeInterval(-MovementFusionPolicy.maximumLookback)
        )
        let preliminaryPoints = movementPoints(
            from: preliminaryStart,
            through: max(destinationArrivalAt, postArrivalEnd)
        )
        let observedDestinationAnchorAt = reliableDestinationAnchorAt(
            rawArrivalAt: destinationArrivalAt,
            through: postArrivalEnd,
            coordinate: destination.coordinate,
            horizontalAccuracy: destination.horizontalAccuracy,
            points: preliminaryPoints
        )
        let destinationAnchorAt = observedDestinationAnchorAt ?? destinationArrivalAt
        let observedVisitDepartureAt: Date? = origin.departureAt.flatMap { departureAt in
            guard origin.departureSourceRawValue !=
                    StayDepartureSource.inferredCandidate.rawValue,
                  MovementFusionPolicy.isPlausibleFallback(
                    departureAt: departureAt,
                    arrivalAt: destinationArrivalAt
                  ) else {
                return nil
            }
            return departureAt
        }
        // A plausible observed visit boundary is still the strongest lower
        // bound. Search earlier only when that boundary is missing, reversed,
        // or implausibly short for a movement between distinct places.
        let broadQueryStart = max(
            origin.arrivalAt,
            destinationAnchorAt.addingTimeInterval(-MovementFusionPolicy.maximumLookback)
        )
        let queryStart = max(
            observedVisitDepartureAt ?? origin.arrivalAt,
            broadQueryStart
        )
        let points = preliminaryPoints.filter {
            $0.timestamp >= broadQueryStart && $0.timestamp <= destinationAnchorAt
        }
        let directDistance = GeoDistance.meters(
            from: origin.coordinate,
            to: destination.coordinate
        )
        let lastKnownInsideAt = StayCandidateTemporalPolicy.lastReliableNearbyAt(
            arrivalAt: broadQueryStart,
            through: destinationAnchorAt,
            coordinate: origin.coordinate,
            horizontalAccuracy: origin.horizontalAccuracy,
            locationPoints: points
        )
        let pedestrianSearchStart = max(
            broadQueryStart,
            lastKnownInsideAt ?? broadQueryStart
        )
        let segments = await queriedMovementSegments(
            from: broadQueryStart,
            to: destinationAnchorAt
        )

        if let pedestrianEvidence = await pedometerEvidenceProvider.evidence(
            from: pedestrianSearchStart,
            through: postArrivalEnd,
            arrivingAround: destinationAnchorAt,
            directDistanceMeters: directDistance,
            combinedHorizontalAccuracy:
                origin.horizontalAccuracy + destination.horizontalAccuracy
        ) {
            let detectedPedestrianModes = pedestrianModes(
                in: pedestrianEvidence.interval,
                segments: segments ?? []
            )
            let modes = detectedPedestrianModes.isEmpty
                ? [.walking]
                : detectedPedestrianModes
            return ResolvedOutgoingMovement(
                interval: pedestrianEvidence.interval,
                modes: modes,
                source: .pedometer,
                confidence: observedDestinationAnchorAt != nil &&
                    detectedPedestrianModes.isEmpty == false ? .high : .medium,
                activeDuration: pedestrianEvidence.activeDuration,
                distanceMeters: pedestrianEvidence.distanceMeters,
                stepCount: pedestrianEvidence.stepCount,
                distanceSource: .pedometer,
                pedometerBuckets: pedestrianEvidence.buckets
            )
        }

        var detectedPedestrianModes: [MovementMode] = []
        if let segments {
            var evidence = MovementFusionPolicy.resolveMotionEvidence(
               originArrivalAt: queryStart,
               destinationArrivalAt: destinationAnchorAt,
               lastKnownInsideAt: lastKnownInsideAt,
               segments: segments
            )
            if let clippedEvidence = evidence,
               queryStart > broadQueryStart,
               MovementModeSelectionPolicy.shouldExpandEvidenceSearch(
                    detectedModes: clippedEvidence.modeRawValues,
                    directDistanceMeters: directDistance,
                    tripDuration: clippedEvidence.interval.duration
               ) {
                let broadLastKnownInsideAt = StayCandidateTemporalPolicy
                    .lastReliableNearbyAt(
                        arrivalAt: broadQueryStart,
                        through: destinationAnchorAt,
                        coordinate: origin.coordinate,
                        horizontalAccuracy: origin.horizontalAccuracy,
                        locationPoints: points
                    )
                evidence = MovementFusionPolicy.resolveMotionEvidence(
                    originArrivalAt: broadQueryStart,
                    destinationArrivalAt: destinationAnchorAt,
                    lastKnownInsideAt: broadLastKnownInsideAt,
                    segments: segments
                )
            }
            if let evidence {
                let prioritizedModes = MovementModeSelectionPolicy
                    .prioritizedModeRawValues(
                        detectedModes: evidence.modeRawValues,
                        directDistanceMeters: directDistance,
                        tripDuration: evidence.interval.duration
                    )
                let modes = prioritizedModes.compactMap(MovementMode.init(rawValue:))
                if modes.contains(.vehicle) || modes.contains(.cycling) {
                    let routePoints = points.filter {
                        $0.timestamp >= evidence.interval.start &&
                            $0.timestamp <= evidence.interval.end
                    }
                    let summary = MovementSummaryBuilder.build(
                        departureAt: evidence.interval.start,
                        arrivalAt: evidence.interval.end,
                        origin: origin.coordinate,
                        destination: destination.coordinate,
                        points: routePoints
                    )
                    return ResolvedOutgoingMovement(
                        interval: evidence.interval,
                        modes: modes,
                        source: .coreMotion,
                        confidence: .medium,
                        distanceMeters: summary?.distanceMeters ?? directDistance,
                        distanceSource: routePoints.isEmpty
                            ? .straightLineReference
                            : .locationRoute
                    )
                }
                detectedPedestrianModes = modes.filter {
                    $0 == .walking || $0 == .running
                }
            }
        }

        if let interval = locationMovementInterval(
            originCoordinate: origin.coordinate,
            originArrivalAt: queryStart,
            originAccuracy: origin.horizontalAccuracy,
            destinationArrivalAt: destinationAnchorAt,
            points: points.filter { $0.timestamp >= queryStart }
        ) {
            let routePoints = points.filter {
                $0.timestamp >= interval.start && $0.timestamp <= interval.end
            }
            let summary = MovementSummaryBuilder.build(
                departureAt: interval.start,
                arrivalAt: interval.end,
                origin: origin.coordinate,
                destination: destination.coordinate,
                points: routePoints
            )
            return ResolvedOutgoingMovement(
                interval: interval,
                modes: detectedPedestrianModes,
                source: .locationPoints,
                confidence: .medium,
                distanceMeters: summary?.distanceMeters ?? directDistance,
                distanceSource: routePoints.isEmpty
                    ? .straightLineReference
                    : .locationRoute
            )
        }

        if detectedPedestrianModes.isEmpty == false {
            return ResolvedOutgoingMovement(
                interval: nil,
                modes: detectedPedestrianModes,
                source: .unavailable,
                confidence: .unavailable,
                distanceMeters: directDistance,
                distanceSource: .straightLineReference
            )
        }

        if let departureAt = observedVisitDepartureAt {
            return ResolvedOutgoingMovement(
                interval: DateInterval(start: departureAt, end: destinationArrivalAt),
                modes: [],
                source: .visitFallback,
                confidence: .low,
                distanceMeters: directDistance,
                distanceSource: .straightLineReference
            )
        }

        return ResolvedOutgoingMovement(
            interval: nil,
            modes: [],
            source: .unavailable,
            confidence: .unavailable
        )
    }

    private func reliableDestinationAnchorAt(
        rawArrivalAt: Date,
        through endAt: Date,
        coordinate: GeoCoordinate,
        horizontalAccuracy: Double,
        points: [MovementPoint]
    ) -> Date? {
        guard endAt >= rawArrivalAt else {
            return nil
        }
        return points
            .filter {
                $0.timestamp >= rawArrivalAt &&
                    $0.timestamp <= endAt &&
                    $0.horizontalAccuracy >= 0 &&
                    $0.horizontalAccuracy <=
                        StayCandidateTemporalPolicy.maximumReliablePointAccuracy
            }
            .sorted { $0.timestamp < $1.timestamp }
            .first { point in
                let distance = GeoDistance.meters(
                    from: coordinate,
                    to: point.coordinate
                )
                let nearbyRadius = max(
                    75,
                    min(200, max(0, horizontalAccuracy) + point.horizontalAccuracy)
                )
                return distance <= nearbyRadius
            }?
            .timestamp
    }

    private func pedestrianModes(
        in interval: DateInterval,
        segments: [MotionMovementSegment]
    ) -> [MovementMode] {
        let evidence = MovementFusionPolicy.resolveTripEvidence(
            departureAt: interval.start,
            destinationArrivalAt: interval.end,
            segments: segments
        )
        return (evidence?.modeRawValues ?? [])
            .compactMap(MovementMode.init(rawValue:))
            .filter { $0 == .walking || $0 == .running }
    }

    private func locationMovementInterval(
        originCoordinate: GeoCoordinate,
        originArrivalAt: Date,
        originAccuracy: Double,
        destinationArrivalAt: Date,
        points: [MovementPoint]
    ) -> DateInterval? {
        guard let departureAt = StayCandidateTemporalPolicy
            .inferredDepartureAtFromSustainedLocation(
                arrivalAt: originArrivalAt,
                through: destinationArrivalAt,
                coordinate: originCoordinate,
                horizontalAccuracy: originAccuracy,
                locationPoints: points
            ),
              destinationArrivalAt > departureAt else {
            return nil
        }
        return DateInterval(start: departureAt, end: destinationArrivalAt)
    }

    private func queriedMovementSegments(
        from startAt: Date,
        to endAt: Date
    ) async -> [MotionMovementSegment]? {
        guard endAt > startAt,
              CMMotionActivityManager.isActivityAvailable(),
              CMMotionActivityManager.authorizationStatus() != .denied,
              CMMotionActivityManager.authorizationStatus() != .restricted else {
            return nil
        }
        return await withCheckedContinuation { continuation in
            motionActivityManager.queryActivityStarting(
                from: startAt,
                to: endAt,
                to: .main
            ) { activities, error in
                guard error == nil, let activities else {
                    continuation.resume(returning: nil)
                    return
                }
                continuation.resume(returning: Self.movementSegments(
                    from: activities,
                    startAt: startAt,
                    endAt: endAt
                ))
            }
        }
    }

    private static func movementSegments(
        from activities: [CMMotionActivity],
        startAt: Date,
        endAt: Date
    ) -> [MotionMovementSegment] {
        let sorted = activities.sorted { $0.startDate < $1.startDate }
        return sorted.indices.compactMap { index in
            let activity = sorted[index]
            let mode: MovementMode?
            if activity.running {
                mode = .running
            } else if activity.cycling {
                mode = .cycling
            } else if activity.automotive {
                mode = .vehicle
            } else if activity.walking {
                mode = .walking
            } else {
                mode = nil
            }
            guard let mode else {
                return nil
            }
            let confidence: Int
            switch activity.confidence {
            case .low:
                confidence = 0
            case .medium:
                confidence = 1
            case .high:
                confidence = 2
            @unknown default:
                confidence = 0
            }
            let rawEnd = index < sorted.index(before: sorted.endIndex)
                ? sorted[sorted.index(after: index)].startDate
                : endAt
            let segmentStart = max(startAt, activity.startDate)
            let segmentEnd = min(endAt, rawEnd)
            guard segmentEnd > segmentStart else {
                return nil
            }
            return MotionMovementSegment(
                interval: DateInterval(start: segmentStart, end: segmentEnd),
                modeRawValue: mode.rawValue,
                confidence: confidence,
                endIsObserved: index < sorted.index(before: sorted.endIndex)
            )
        }
    }

    private func backfillRecentMovementModes() {
        guard isBackfillingMovementModes == false else {
            return
        }
        isBackfillingMovementModes = true
        Task { @MainActor [weak self] in
            guard let self else {
                return
            }
            defer {
                isBackfillingMovementModes = false
            }
            guard let modelContext else {
                return
            }
            let stays = ((try? modelContext.fetch(
                FetchDescriptor<StayEntity>(
                    sortBy: [SortDescriptor(\.arrivalAt, order: .forward)]
                )
            )) ?? [])
            let aliases = ((try? modelContext.fetch(
                FetchDescriptor<PlaceAliasEntity>(
                    sortBy: [SortDescriptor(\.priority, order: .reverse)]
                )
            )) ?? [])
            let oldestSupportedArrival = Date().addingTimeInterval(-7 * 24 * 60 * 60)
            var affectedDates: [Date] = []

            for (origin, destination) in zip(stays, stays.dropFirst()) {
                guard destination.arrivalAt >= oldestSupportedArrival else {
                    continue
                }
                guard destination.arrivalAt > origin.arrivalAt else {
                    if origin.hasResolvedMovementModes || origin.hasResolvedMovementTiming {
                        origin.clearMovementEvidence()
                        origin.updatedAt = Date()
                        affectedDates.append(origin.arrivalAt)
                    }
                    continue
                }
                let observedExcursionInterval: DateInterval? = origin.departureAt.flatMap { departureAt in
                    guard origin.departureSourceRawValue !=
                            StayDepartureSource.inferredCandidate.rawValue,
                          destination.arrivalAt > departureAt else {
                        return nil
                    }
                    return DateInterval(start: departureAt, end: destination.arrivalAt)
                }
                let sharedContainmentRadius = StayResolution.sharedRegisteredPlaceRadius(
                    from: origin.coordinate,
                    to: destination.coordinate,
                    aliases: aliases
                )
                var movementEvidence = MovementPresentationPolicy.evidence(
                    origin: origin.coordinate,
                    destination: destination.coordinate,
                    originAccuracy: origin.horizontalAccuracy,
                    destinationAccuracy: destination.horizontalAccuracy,
                    excursionInterval: nil,
                    points: [],
                    containmentRadiusMeters: sharedContainmentRadius
                )
                if movementEvidence == nil, let observedExcursionInterval {
                    movementEvidence = MovementPresentationPolicy.evidence(
                        origin: origin.coordinate,
                        destination: destination.coordinate,
                        originAccuracy: origin.horizontalAccuracy,
                        destinationAccuracy: destination.horizontalAccuracy,
                        excursionInterval: observedExcursionInterval,
                        points: movementPoints(
                            from: observedExcursionInterval.start,
                            through: observedExcursionInterval.end
                        ),
                        containmentRadiusMeters: sharedContainmentRadius
                    )
                }
                guard movementEvidence != nil else {
                    origin.storeMovementModes([])
                    origin.storeMovementTiming(
                        interval: nil,
                        destinationStayID: destination.id,
                        source: .unavailable,
                        confidence: .unavailable
                    )
                    continue
                }
                let resolved = await resolvedOutgoingMovement(
                    from: origin,
                    to: destination
                )
                origin.storeMovementModes(resolved.modes)
                origin.storeMovementTiming(
                    interval: resolved.interval,
                    destinationStayID: destination.id,
                    source: resolved.source,
                    confidence: resolved.confidence,
                    activeDuration: resolved.activeDuration,
                    distanceMeters: resolved.distanceMeters,
                    stepCount: resolved.stepCount,
                    distanceSource: resolved.distanceSource,
                    pedometerBuckets: resolved.pedometerBuckets
                )
                origin.updatedAt = Date()
                affectedDates.append(contentsOf: daysTouched(
                    from: min(
                        origin.arrivalAt,
                        resolved.interval?.start ?? origin.departureAt ?? origin.arrivalAt
                    ),
                    through: max(
                        destination.arrivalAt,
                        resolved.interval?.end ?? destination.arrivalAt
                    )
                ))
            }
            if let latest = stays.last,
               latest.hasResolvedMovementModes || latest.hasResolvedMovementTiming {
                latest.clearMovementEvidence()
                latest.updatedAt = Date()
                affectedDates.append(latest.arrivalAt)
            }
            try? modelContext.save()
            exportYesterdayIfNeeded(affectedDates: Array(Set(affectedDates)))
        }
    }

    private func validatePendingCompletedCandidates() {
        guard let modelContext else {
            return
        }
        let pendingState = StayCandidateState.pending.rawValue
        let descriptor = FetchDescriptor<StayCandidateEntity>(
            predicate: #Predicate { candidate in
                candidate.stateRawValue == pendingState
            }
        )
        guard let candidates = try? modelContext.fetch(descriptor) else {
            return
        }
        for candidate in candidates where candidate.effectiveDepartureAt != nil {
            let needsBoundaryResolution =
                StayDepartureSelectionPolicy.requiresFallbackBoundaryResolution(
                    hasObservedDeparture: candidate.departureAt != nil,
                    hasTransitionBoundary: candidate.departureNotAfterAt != nil,
                    hasInferredDeparture: candidate.inferredDepartureAt != nil,
                    inferredFromNextCandidate:
                        candidate.inferredDepartureReasonRawValue ==
                            StayCandidateInferredDepartureReason.nextCandidate.rawValue
                )
            if needsBoundaryResolution {
                resolveCandidateDeparture(candidate.id)
            } else {
                validateCandidate(candidate.id)
            }
        }
    }

    /// Preserve Apple's observed departure without reopening already confirmed
    /// historical visits. Sensor policy changes apply only to new candidates.
    private func prepareRecentObservedVisitCandidatesForRevalidation() {
        guard let modelContext else {
            return
        }
        let cutoff = Date().addingTimeInterval(-recentObservedVisitRevalidationWindow)
        let descriptor = FetchDescriptor<StayCandidateEntity>(
            predicate: #Predicate { candidate in
                candidate.arrivalAt >= cutoff && candidate.departureAt != nil
            },
            sortBy: [SortDescriptor(\.arrivalAt, order: .forward)]
        )
        guard let candidates = try? modelContext.fetch(descriptor) else {
            return
        }

        let confirmedState = StayCandidateState.confirmed.rawValue
        let rejectedState = StayCandidateState.rejected.rawValue
        let pendingState = StayCandidateState.pending.rawValue
        let recoverableRejectionReasons: Set<String> = [
            StayValidationReason.belowMinimumDuration.rawValue,
            StayValidationReason.insufficientEvidence.rawValue,
        ]
        var affectedDates: [Date] = []

        for candidate in candidates {
            guard let observedDepartureAt = candidate.departureAt else {
                continue
            }
            let observedDuration = observedDepartureAt.timeIntervalSince(candidate.arrivalAt)
            let hadInference = candidate.inferredDepartureAt != nil
            candidate.inferredDepartureAt = nil
            candidate.inferredDepartureReasonRawValue = nil
            candidate.departureResolutionDiagnosticsRawValue = nil

            if candidate.stateRawValue == confirmedState {
                if let stay = confirmedStay(for: candidate),
                   StayCandidateOwnershipPolicy.canReuseConfirmedStay(
                    candidateArrivalAt: candidate.arrivalAt,
                    stayArrivalAt: stay.arrivalAt,
                    arrivalTolerance: sameVisitArrivalToleranceSeconds
                   ) {
                    let needsUpdate = stay.departureAt != observedDepartureAt ||
                        stay.departureSourceRawValue != StayDepartureSource.observedVisit.rawValue ||
                        hadInference
                    guard needsUpdate else {
                        continue
                    }
                    stay.departureAt = observedDepartureAt
                    stay.departureSourceRawValue = StayDepartureSource.observedVisit.rawValue
                    stay.clearMovementEvidence()
                    stay.updatedAt = Date()
                    if candidate.decisionReasonRawValue == nil {
                        candidate.decisionReasonRawValue =
                            StayValidationReason.observedCompletedVisit.rawValue
                    }
                    candidate.updatedAt = Date()
                    affectedDates.append(contentsOf: daysTouched(
                        from: candidate.arrivalAt,
                        through: observedDepartureAt
                    ))
                } else {
                    _ = makeConfirmedStayProjection(
                        for: candidate,
                        departureAt: observedDepartureAt,
                        in: modelContext
                    )
                    if candidate.decisionReasonRawValue == nil {
                        candidate.decisionReasonRawValue =
                            StayValidationReason.observedCompletedVisit.rawValue
                    }
                    candidate.updatedAt = Date()
                    affectedDates.append(contentsOf: daysTouched(
                        from: candidate.arrivalAt,
                        through: observedDepartureAt
                    ))
                }
                continue
            }

            if candidate.stateRawValue == rejectedState {
                let isRecoverable = candidate.decisionReasonRawValue
                    .map(recoverableRejectionReasons.contains) == true
                guard isRecoverable,
                      observedDuration >= StayValidationPolicy.minimumDuration else {
                    continue
                }
            }

            candidate.stateRawValue = pendingState
            candidate.decisionReasonRawValue = nil
            candidate.updatedAt = Date()
        }

        guard affectedDates.isEmpty == false else {
            return
        }
        try? modelContext.save()
        exportYesterdayIfNeeded(affectedDates: Array(Set(affectedDates)))
    }

    private func validateCandidate(_ candidateID: UUID) {
        guard validatingCandidateIDs.insert(candidateID).inserted else {
            return
        }
        Task { @MainActor [weak self] in
            guard let self else {
                return
            }
            defer {
                validatingCandidateIDs.remove(candidateID)
            }
            await validateCandidateAsync(candidateID)
        }
    }

    private func validateCandidateAsync(_ candidateID: UUID) async {
        guard let modelContext,
              let candidate = fetchCandidate(id: candidateID),
              candidate.stateRawValue == StayCandidateState.pending.rawValue,
              let departureAt = candidate.effectiveDepartureAt else {
            return
        }

        let motion = await motionEvidence(
            arrivalAt: candidate.arrivalAt,
            departureAt: departureAt
        )
        guard let refreshedCandidate = fetchCandidate(id: candidateID),
              refreshedCandidate.stateRawValue == StayCandidateState.pending.rawValue,
              let refreshedDepartureAt = refreshedCandidate.effectiveDepartureAt else {
            return
        }

        let aliases = (try? modelContext.fetch(
            FetchDescriptor<PlaceAliasEntity>(
                sortBy: [SortDescriptor(\.priority, order: .reverse)]
            )
        )) ?? []
        let containmentAlias = StayResolution.matchingAlias(
            for: refreshedCandidate.coordinate,
            aliases: aliases
        )

        let evidence = StayValidationEvidence(
            arrivalAt: refreshedCandidate.arrivalAt,
            departureAt: refreshedDepartureAt,
            hasObservedDeparture: refreshedCandidate.departureAt != nil,
            coordinate: refreshedCandidate.coordinate,
            horizontalAccuracy: refreshedCandidate.horizontalAccuracy,
            locationPoints: movementPoints(
                from: refreshedCandidate.arrivalAt,
                through: refreshedDepartureAt
            ),
            routeContextPoints: routeContextPoints(
                for: refreshedCandidate,
                departureAt: refreshedDepartureAt
            ),
            motion: motion,
            overlapsConfirmedStay: hasConflictingConfirmedStay(
                for: refreshedCandidate,
                departureAt: refreshedDepartureAt
            ),
            hasSpatialTransitionBoundary:
                refreshedCandidate.departureNotAfterAt != nil ||
                refreshedCandidate.inferredDepartureReasonRawValue ==
                    StayCandidateInferredDepartureReason.sustainedMovement.rawValue,
            requiresPositiveStayEvidence: refreshedCandidate.isLocationBootstrap,
            containmentCoordinate: containmentAlias?.coordinate,
            containmentRadiusMeters: containmentAlias?.radiusMeters,
            evaluatedAt: Date()
        )
        apply(
            StayValidationPolicy.evaluate(evidence),
            to: refreshedCandidate,
            in: modelContext
        )
    }

    private func fetchCandidate(id: UUID) -> StayCandidateEntity? {
        guard let modelContext else {
            return nil
        }
        var descriptor = FetchDescriptor<StayCandidateEntity>(
            predicate: #Predicate { candidate in
                candidate.id == id
            }
        )
        descriptor.fetchLimit = 1
        return try? modelContext.fetch(descriptor).first
    }

    private func movementPoints(from arrivalAt: Date, through departureAt: Date) -> [MovementPoint] {
        guard let modelContext else {
            return []
        }
        let maximumAccuracy = StayValidationPolicy.maximumReliablePointAccuracy
        let descriptor = FetchDescriptor<MovementPointEntity>(
            predicate: #Predicate { point in
                point.timestamp >= arrivalAt &&
                    point.timestamp <= departureAt &&
                    point.horizontalAccuracy >= 0 &&
                    point.horizontalAccuracy <= maximumAccuracy
            },
            sortBy: [SortDescriptor(\.timestamp, order: .forward)]
        )
        return ((try? modelContext.fetch(descriptor)) ?? []).map(\.corePoint)
    }

    private func routeContextPoints(
        for candidate: StayCandidateEntity,
        departureAt: Date
    ) -> [MovementPoint] {
        routeContextPoints(
            arrivalAt: candidate.arrivalAt,
            departureAt: departureAt,
            excludingStayID: candidate.confirmedStayID
        )
    }

    private func routeContextPoints(
        arrivalAt: Date,
        departureAt: Date,
        excludingStayID: UUID?
    ) -> [MovementPoint] {
        let lookaround = StayValidationPolicy.routeContextLookaround
        let startAt = arrivalAt.addingTimeInterval(-lookaround)
        let endAt = min(Date(), departureAt.addingTimeInterval(lookaround))
        var points = movementPoints(from: startAt, through: endAt)

        let stays = ((try? modelContext?.fetch(
            FetchDescriptor<StayEntity>(
                sortBy: [SortDescriptor(\.arrivalAt, order: .forward)]
            )
        )) ?? [])
        if let previous = stays.last(where: { stay in
            guard stay.id != excludingStayID else {
                return false
            }
            guard let stayDepartureAt = stay.departureAt else {
                return false
            }
            return stayDepartureAt >= startAt && stayDepartureAt <= arrivalAt
        }), let previousDepartureAt = previous.departureAt {
            points.append(MovementPoint(
                timestamp: previousDepartureAt,
                coordinate: previous.coordinate,
                horizontalAccuracy: previous.horizontalAccuracy
            ))
        }
        if let next = stays.first(where: { stay in
            stay.id != excludingStayID &&
                stay.arrivalAt >= departureAt && stay.arrivalAt <= endAt
        }) {
            points.append(MovementPoint(
                timestamp: next.arrivalAt,
                coordinate: next.coordinate,
                horizontalAccuracy: next.horizontalAccuracy
            ))
        }
        return points.sorted { $0.timestamp < $1.timestamp }
    }

    private func hasConflictingConfirmedStay(
        for candidate: StayCandidateEntity,
        departureAt: Date
    ) -> Bool {
        hasConflictingConfirmedStay(
            arrivalAt: candidate.arrivalAt,
            departureAt: departureAt,
            coordinate: candidate.coordinate,
            horizontalAccuracy: candidate.horizontalAccuracy,
            excludingStayID: candidate.confirmedStayID
        )
    }

    private func hasConflictingConfirmedStay(
        arrivalAt: Date,
        departureAt: Date,
        coordinate: GeoCoordinate,
        horizontalAccuracy: Double,
        excludingStayID: UUID?
    ) -> Bool {
        guard let modelContext else {
            return false
        }
        let searchStart = arrivalAt.addingTimeInterval(-24 * 60 * 60)
        let searchEnd = departureAt.addingTimeInterval(24 * 60 * 60)
        let descriptor = FetchDescriptor<StayEntity>(
            predicate: #Predicate { stay in
                stay.arrivalAt >= searchStart && stay.arrivalAt <= searchEnd
            }
        )
        guard let stays = try? modelContext.fetch(descriptor) else {
            return false
        }

        return stays.contains { stay in
            guard stay.id != excludingStayID else {
                return false
            }
            let existingEnd = stay.departureAt ?? departureAt
            let overlapStart = max(stay.arrivalAt, arrivalAt)
            let overlapEnd = min(existingEnd, departureAt)
            guard overlapEnd.timeIntervalSince(overlapStart) >= 60 else {
                return false
            }
            let distance = GeoDistance.meters(from: stay.coordinate, to: coordinate)
            let threshold = max(
                200,
                min(750, stay.horizontalAccuracy + horizontalAccuracy)
            )
            return distance > threshold
        }
    }

    private func motionEvidence(
        arrivalAt: Date,
        departureAt: Date
    ) async -> StayMotionEvidence? {
        guard CMMotionActivityManager.isActivityAvailable(),
              CMMotionActivityManager.authorizationStatus() == .authorized else {
            return nil
        }
        let queryStart = arrivalAt.addingTimeInterval(-10 * 60)
        return await withCheckedContinuation { continuation in
            motionActivityManager.queryActivityStarting(
                from: queryStart,
                to: departureAt,
                to: .main
            ) { activities, error in
                guard error == nil, let activities else {
                    continuation.resume(returning: nil)
                    return
                }
                continuation.resume(returning: Self.summarizeMotion(
                    activities,
                    arrivalAt: arrivalAt,
                    departureAt: departureAt
                ))
            }
        }
    }

    private static func summarizeMotion(
        _ activities: [CMMotionActivity],
        arrivalAt: Date,
        departureAt: Date
    ) -> StayMotionEvidence {
        let sorted = activities.sorted { $0.startDate < $1.startDate }
        var movingDuration: TimeInterval = 0
        var stationaryDuration: TimeInterval = 0
        var walkingDuration: TimeInterval = 0
        var runningDuration: TimeInterval = 0
        var cyclingDuration: TimeInterval = 0
        var automotiveDuration: TimeInterval = 0

        for index in sorted.indices {
            let activity = sorted[index]
            guard activity.confidence != .low else {
                continue
            }
            let rawEnd = index < sorted.index(before: sorted.endIndex)
                ? sorted[sorted.index(after: index)].startDate
                : departureAt
            let start = max(arrivalAt, activity.startDate)
            let end = min(departureAt, rawEnd)
            let duration = end.timeIntervalSince(start)
            guard duration > 0 else {
                continue
            }

            if activity.automotive {
                movingDuration += duration
                automotiveDuration += duration
            } else if activity.cycling {
                movingDuration += duration
                cyclingDuration += duration
            } else if activity.running {
                movingDuration += duration
                runningDuration += duration
            } else if activity.walking {
                movingDuration += duration
                walkingDuration += duration
            } else if activity.stationary {
                stationaryDuration += duration
            }
        }

        return StayMotionEvidence(
            movingDuration: movingDuration,
            stationaryDuration: stationaryDuration,
            walkingDuration: walkingDuration,
            runningDuration: runningDuration,
            cyclingDuration: cyclingDuration,
            automotiveDuration: automotiveDuration
        )
    }

    private func apply(
        _ decision: StayValidationDecision,
        to candidate: StayCandidateEntity,
        in modelContext: ModelContext
    ) {
        var affectedDates: [Date] = []
        switch decision {
        case .confirm(let reason):
            candidateReviewTasks[candidate.id]?.cancel()
            candidateReviewTasks[candidate.id] = nil
            let presentationCoordinate = candidate.presentationCoordinate
            let presentationAccuracy = candidate.presentationHorizontalAccuracy
            let confidence = PlaceConfidence.from(horizontalAccuracy: presentationAccuracy)
            let effectiveDepartureAt = candidate.effectiveDepartureAt
            let stay: StayEntity
            let preservesExistingStayContent: Bool
            if let existingStay = confirmedStay(for: candidate),
               StayCandidateOwnershipPolicy.canReuseConfirmedStay(
                candidateArrivalAt: candidate.arrivalAt,
                stayArrivalAt: existingStay.arrivalAt,
                arrivalTolerance: sameVisitArrivalToleranceSeconds
               ) {
                preservesExistingStayContent =
                    reason == .observedCompletedVisitRouteReviewed &&
                    existingStay.arrivalAt == candidate.arrivalAt &&
                    existingStay.departureAt == effectiveDepartureAt &&
                    existingStay.latitude == presentationCoordinate.latitude &&
                    existingStay.longitude == presentationCoordinate.longitude &&
                    existingStay.horizontalAccuracy == presentationAccuracy
                existingStay.arrivalAt = candidate.arrivalAt
                existingStay.departureAt = effectiveDepartureAt
                existingStay.departureSourceRawValue = candidate.usesInferredDeparture
                    ? StayDepartureSource.inferredCandidate.rawValue
                    : StayDepartureSource.observedVisit.rawValue
                if existingStay.isLocationManuallyAdjusted == false,
                   presentationAccuracy <= existingStay.horizontalAccuracy {
                    existingStay.latitude = presentationCoordinate.latitude
                    existingStay.longitude = presentationCoordinate.longitude
                    existingStay.horizontalAccuracy = presentationAccuracy
                }
                existingStay.updatedAt = Date()
                stay = existingStay
            } else {
                stay = StayEntity(
                    arrivalAt: candidate.arrivalAt,
                    departureAt: effectiveDepartureAt,
                    latitude: presentationCoordinate.latitude,
                    longitude: presentationCoordinate.longitude,
                    horizontalAccuracy: presentationAccuracy,
                    sourceRawValue: candidate.sourceRawValue,
                    confidenceRawValue: confidence.rawValue
                )
                modelContext.insert(stay)
                preservesExistingStayContent = false
            }
            stay.departureSourceRawValue = candidate.usesInferredDeparture
                ? StayDepartureSource.inferredCandidate.rawValue
                : StayDepartureSource.observedVisit.rawValue
            if stay.placeName == nil {
                stay.placeName = candidate.placeName
            }
            if stay.address == nil {
                stay.address = candidate.address
            }
            if preservesExistingStayContent == false {
                stay.clearMovementEvidence()
            }
            candidate.stateRawValue = StayCandidateState.confirmed.rawValue
            candidate.decisionReasonRawValue = reason.rawValue
            candidate.confirmedStayID = stay.id
            candidate.updatedAt = Date()
            try? modelContext.save()
            if preservesExistingStayContent == false {
                affectedDates = daysTouched(
                    from: candidate.arrivalAt,
                    through: effectiveDepartureAt ?? candidate.arrivalAt
                )
            }
            if stay.address == nil {
                resolvePlaceDetails(for: stay)
            }
            if preservesExistingStayContent == false {
                resolveMovementModesAround(stayID: stay.id)
            }
        case .reject(let reason):
            candidateReviewTasks[candidate.id]?.cancel()
            candidateReviewTasks[candidate.id] = nil
            var movementOriginID: UUID?
            var movementDestinationID: UUID?
            if let stay = confirmedStay(for: candidate) {
                let stays = ((try? modelContext.fetch(
                    FetchDescriptor<StayEntity>(
                        sortBy: [SortDescriptor(\.arrivalAt, order: .forward)]
                    )
                )) ?? [])
                if let index = stays.firstIndex(where: { $0.id == stay.id }),
                   index > stays.startIndex {
                    movementOriginID = stays[stays.index(before: index)].id
                    if index < stays.index(before: stays.endIndex) {
                        movementDestinationID = stays[stays.index(after: index)].id
                    }
                }
                modelContext.delete(stay)
            }
            candidate.stateRawValue = StayCandidateState.rejected.rawValue
            candidate.decisionReasonRawValue = reason.rawValue
            candidate.confirmedStayID = nil
            candidate.updatedAt = Date()
            affectedDates = daysTouched(
                from: candidate.arrivalAt,
                through: candidate.effectiveDepartureAt ?? candidate.arrivalAt
            )
            try? modelContext.save()
            if let movementOriginID, let movementDestinationID {
                resolveMovementModes(
                    from: movementOriginID,
                    to: movementDestinationID
                )
            } else if let movementOriginID,
                      let origin = try? modelContext.fetch(
                        FetchDescriptor<StayEntity>(
                            predicate: #Predicate { stay in
                                stay.id == movementOriginID
                            }
                        )
                      ).first {
                origin.clearMovementEvidence()
                origin.updatedAt = Date()
                try? modelContext.save()
            }
        case .deferDecision(let reason):
            candidate.stateRawValue = StayCandidateState.pending.rawValue
            candidate.decisionReasonRawValue = reason.rawValue
            if reason == .awaitingRouteContext,
               let departureAt = candidate.effectiveDepartureAt {
                scheduleCandidateReview(
                    candidate.id,
                    at: departureAt.addingTimeInterval(StayValidationPolicy.routeReviewDelay)
                )
            }
            candidate.updatedAt = Date()
            try? modelContext.save()
        }
        exportYesterdayIfNeeded(affectedDates: affectedDates)
    }

    private func scheduleCandidateReview(_ candidateID: UUID, at reviewAt: Date) {
        candidateReviewTasks[candidateID]?.cancel()
        candidateReviewTasks[candidateID] = Task { @MainActor [weak self] in
            let delay = max(0, reviewAt.timeIntervalSinceNow)
            if delay > 0 {
                try? await Task.sleep(for: .seconds(delay))
            }
            guard Task.isCancelled == false, let self else {
                return
            }
            candidateReviewTasks[candidateID] = nil
            validateCandidate(candidateID)
        }
    }

    private func confirmedStay(for candidate: StayCandidateEntity) -> StayEntity? {
        guard let modelContext, let confirmedStayID = candidate.confirmedStayID else {
            return nil
        }
        var descriptor = FetchDescriptor<StayEntity>(
            predicate: #Predicate { stay in
                stay.id == confirmedStayID
            }
        )
        descriptor.fetchLimit = 1
        return try? modelContext.fetch(descriptor).first
    }

    /// Rebuild only the missing user-visible projection of an already confirmed
    /// candidate. The candidate stays confirmed and is never sent through
    /// sensor validation again.
    private func makeConfirmedStayProjection(
        for candidate: StayCandidateEntity,
        departureAt: Date?,
        in modelContext: ModelContext
    ) -> StayEntity {
        let coordinate = candidate.presentationCoordinate
        let accuracy = candidate.presentationHorizontalAccuracy
        let stay = StayEntity(
            arrivalAt: candidate.arrivalAt,
            departureAt: departureAt,
            latitude: coordinate.latitude,
            longitude: coordinate.longitude,
            horizontalAccuracy: accuracy,
            sourceRawValue: candidate.sourceRawValue,
            confidenceRawValue: PlaceConfidence.from(horizontalAccuracy: accuracy).rawValue
        )
        stay.departureSourceRawValue = candidate.usesInferredDeparture
            ? StayDepartureSource.inferredCandidate.rawValue
            : StayDepartureSource.observedVisit.rawValue
        stay.placeName = candidate.placeName
        stay.address = candidate.address
        modelContext.insert(stay)
        candidate.confirmedStayID = stay.id
        candidate.updatedAt = Date()
        return stay
    }

    /// A delayed Core Location departure updates the derived stay without
    /// deleting the candidate or its previously inferred boundary.
    private func reconcileObservedDepartureIfNeeded(for candidate: StayCandidateEntity) {
        guard candidate.departureAt != nil,
              candidate.stateRawValue == StayCandidateState.confirmed.rawValue,
              let stay = confirmedStay(for: candidate),
              let effectiveDepartureAt = candidate.effectiveDepartureAt else {
            return
        }
        let oldDepartureAt = stay.departureAt
        stay.departureAt = effectiveDepartureAt
        stay.departureSourceRawValue = candidate.usesInferredDeparture
            ? StayDepartureSource.inferredCandidate.rawValue
            : StayDepartureSource.observedVisit.rawValue
        stay.clearMovementEvidence()
        stay.updatedAt = Date()
        candidate.updatedAt = Date()
        try? modelContext?.save()
        resolveMovementModesAround(stayID: stay.id)

        let oldEnd = oldDepartureAt ?? candidate.arrivalAt
        let affectedDates = Array(Set(
            daysTouched(from: candidate.arrivalAt, through: oldEnd) +
                daysTouched(from: candidate.arrivalAt, through: effectiveDepartureAt)
        ))
        exportYesterdayIfNeeded(affectedDates: affectedDates)
    }

    private func bestConfidence(_ lhs: String, _ rhs: String) -> String {
        guard let lhsConfidence = PlaceConfidence(rawValue: lhs) else {
            return rhs
        }
        guard let rhsConfidence = PlaceConfidence(rawValue: rhs) else {
            return lhs
        }
        return PlaceConfidence.best(lhsConfidence, rhsConfidence).rawValue
    }

    private func resolvePlaceDetails(for entity: StayEntity) {
        Task { @MainActor [weak self] in
            guard let self else {
                return
            }
            await resolvePlaceDetailsAsync(for: entity, reportErrors: true)
            reconcileDuplicateStays()
        }
    }

    private func resolvePlaceDetailsForPendingCandidates() {
        guard let modelContext else {
            return
        }
        let pendingState = StayCandidateState.pending.rawValue
        let descriptor = FetchDescriptor<StayCandidateEntity>(
            predicate: #Predicate { candidate in
                candidate.stateRawValue == pendingState &&
                    candidate.placeName == nil &&
                    candidate.address == nil
            },
            sortBy: [SortDescriptor(\.arrivalAt, order: .reverse)]
        )
        guard let candidates = try? modelContext.fetch(descriptor),
              candidates.isEmpty == false else {
            return
        }
        Task { @MainActor [weak self] in
            guard let self else {
                return
            }
            for candidate in candidates {
                await resolveCandidatePlaceDetailsAsync(candidate)
            }
        }
    }

    private func resolvePlaceDetailsForRecentUnresolvedStays() {
        guard let modelContext else {
            return
        }
        let cutoff = Date().addingTimeInterval(-7 * 24 * 60 * 60)
        let descriptor = FetchDescriptor<StayEntity>(
            predicate: #Predicate { stay in
                stay.arrivalAt >= cutoff &&
                    stay.placeName == nil &&
                    stay.address == nil
            },
            sortBy: [SortDescriptor(\.arrivalAt, order: .reverse)]
        )
        guard let stays = try? modelContext.fetch(descriptor),
              stays.isEmpty == false else {
            return
        }
        Task { @MainActor [weak self] in
            guard let self else {
                return
            }
            for stay in stays {
                await resolvePlaceDetailsAsync(for: stay, reportErrors: false)
            }
        }
    }

    private func resolvePlaceDetailsIfNeeded(for candidate: StayCandidateEntity) {
        guard candidate.placeName == nil, candidate.address == nil else {
            return
        }
        Task { @MainActor [weak self] in
            guard let self else {
                return
            }
            await resolveCandidatePlaceDetailsAsync(candidate)
        }
    }

    private func resolveCandidatePlaceDetailsAsync(_ candidate: StayCandidateEntity) async {
        guard candidate.placeName == nil, candidate.address == nil else {
            return
        }
        let coordinate = candidate.presentationCoordinate
        if let modelContext {
            let aliases = (try? modelContext.fetch(FetchDescriptor<PlaceAliasEntity>())) ?? []
            guard StayResolution.matchingAlias(
                for: coordinate,
                aliases: aliases
            ) == nil else {
                return
            }
        }

        let location = CLLocation(latitude: coordinate.latitude, longitude: coordinate.longitude)
        do {
            let placemarks = try await reverseGeocode(location)
            guard let placemark = placemarks.first else {
                return
            }
            guard candidate.presentationCoordinate == coordinate else {
                return
            }
            let details = PlacemarkDetailsResolver.details(for: placemark)
            guard details.placeName != nil || details.address != nil else {
                return
            }
            candidate.placeName = details.placeName
            candidate.address = details.address
            candidate.updatedAt = Date()
            try? modelContext?.save()
        } catch {
            // A future launch or visit update retries unresolved candidates.
        }
    }

    private func resolvePlaceDetailsAsync(for entity: StayEntity, reportErrors: Bool) async {
        let coordinate = entity.coordinate
        let location = CLLocation(latitude: coordinate.latitude, longitude: coordinate.longitude)
        do {
            let placemarks = try await reverseGeocode(location)
            guard let placemark = placemarks.first,
                  entity.coordinate == coordinate else {
                return
            }
            let details = PlacemarkDetailsResolver.details(for: placemark)
            guard details.placeName != nil || details.address != nil else {
                return
            }

            entity.placeName = details.placeName
            entity.address = details.address
            entity.updatedAt = Date()
            try? modelContext?.save()
            exportYesterdayIfNeeded(
                affectedDates: daysTouched(
                    from: entity.arrivalAt,
                    through: entity.departureAt ?? entity.arrivalAt
                )
            )
        } catch {
            if reportErrors {
                lastErrorMessage = error.localizedDescription
            }
        }
    }

    /// Apple recommends avoiding a new geocoding request while one is in
    /// progress. All candidate and stay lookups share this serialized path so
    /// one request cannot cancel another and leave a coordinate-only row.
    private func reverseGeocode(_ location: CLLocation) async throws -> [CLPlacemark] {
        while geocoder.isGeocoding {
            try Task.checkCancellation()
            try await Task.sleep(for: .milliseconds(150))
        }
        return try await geocoder.reverseGeocodeLocation(
            location,
            preferredLocale: AppLanguage.currentLocale
        )
    }

    private func reconcileDuplicateStays() {
        guard let modelContext else {
            return
        }

        let descriptor = FetchDescriptor<StayEntity>(
            sortBy: [SortDescriptor(\.arrivalAt, order: .forward)]
        )
        guard let stays = try? modelContext.fetch(descriptor), stays.count > 1 else {
            return
        }
        let linkedStayIDs = Set(
            ((try? modelContext.fetch(FetchDescriptor<StayCandidateEntity>())) ?? [])
                .compactMap(\.confirmedStayID)
        )

        var didChange = false
        var previous = stays[0]
        for current in stays.dropFirst() {
            let mayMerge = StayDuplicateMergePolicy.canAutomaticallyMerge(
                isLeftCandidateLinked: linkedStayIDs.contains(previous.id),
                isRightCandidateLinked: linkedStayIDs.contains(current.id)
            )
            guard mayMerge, shouldMergeDuplicateStay(previous, current) else {
                previous = current
                continue
            }

            mergeStay(previous, with: current)
            modelContext.delete(current)
            didChange = true
        }

        if didChange {
            try? modelContext.save()
        }
    }

    private func shouldMergeDuplicateStay(_ lhs: StayEntity, _ rhs: StayEntity) -> Bool {
        let distance = GeoDistance.meters(from: lhs.coordinate, to: rhs.coordinate)
        let arrivalDelta = abs(lhs.arrivalAt.timeIntervalSince(rhs.arrivalAt))
        if arrivalDelta <= sameVisitArrivalToleranceSeconds,
           distance <= sameVisitMaximumDistanceMeters {
            return true
        }

        guard let lhsName = LocationFormatter.address(for: lhs),
              let rhsName = LocationFormatter.address(for: rhs),
              lhsName == rhsName else {
            return false
        }

        let gap: TimeInterval
        if let lhsDeparture = lhs.departureAt {
            gap = max(0, rhs.arrivalAt.timeIntervalSince(lhsDeparture))
        } else {
            gap = max(0, rhs.arrivalAt.timeIntervalSince(lhs.arrivalAt))
        }
        return gap <= duplicateMergeGapSeconds
    }

    private func mergeStay(_ target: StayEntity, with duplicate: StayEntity) {
        target.arrivalAt = min(target.arrivalAt, duplicate.arrivalAt)
        if target.departureAt == nil || duplicate.departureAt == nil {
            target.departureAt = nil
        } else if let duplicateDeparture = duplicate.departureAt {
            target.departureAt = max(target.departureAt ?? target.arrivalAt, duplicateDeparture)
        }
        if duplicate.isLocationManuallyAdjusted,
           target.isLocationManuallyAdjusted == false {
            target.latitude = duplicate.latitude
            target.longitude = duplicate.longitude
            target.horizontalAccuracy = duplicate.horizontalAccuracy
            target.isLocationManuallyAdjusted = true
        } else if target.isLocationManuallyAdjusted == false,
                  duplicate.horizontalAccuracy <= target.horizontalAccuracy {
            target.latitude = duplicate.latitude
            target.longitude = duplicate.longitude
            target.horizontalAccuracy = duplicate.horizontalAccuracy
        }
        mergeMetadata(from: duplicate, into: target)
    }

    private func mergeMetadata(from duplicate: StayEntity, into target: StayEntity) {
        if target.sourceRawValue != LocationSource.visit.rawValue,
           duplicate.sourceRawValue == LocationSource.visit.rawValue {
            target.sourceRawValue = duplicate.sourceRawValue
        }
        if target.placeName?.isEmpty != false,
           let placeName = duplicate.placeName?.trimmedNonEmpty {
            target.placeName = placeName
        }
        if target.address?.isEmpty != false,
           let address = duplicate.address?.trimmedNonEmpty {
            target.address = address
        }
        target.confidenceRawValue = bestConfidence(
            target.confidenceRawValue,
            duplicate.confidenceRawValue
        )
        target.createdAt = min(target.createdAt, duplicate.createdAt)
        target.updatedAt = Date()
    }

    private func daysTouched(from start: Date, through end: Date) -> [Date] {
        let calendar = Calendar.current
        var day = calendar.startOfDay(for: min(start, end))
        let finalDay = calendar.startOfDay(for: max(start, end))
        var result: [Date] = []

        while day <= finalDay, result.count < 366 {
            result.append(day)
            guard let nextDay = calendar.date(byAdding: .day, value: 1, to: day) else {
                break
            }
            day = nextDay
        }
        return result
    }

    private func exportYesterdayIfNeeded(affectedDates: [Date] = []) {
        let userInfo: [String: Any]? = affectedDates.isEmpty
            ? nil
            : [LocationDataChangeUserInfo.affectedDates: affectedDates]
        NotificationCenter.default.post(
            name: .silicaLocationDataDidChange,
            object: nil,
            userInfo: userInfo
        )
    }
}

extension LocationRecorder: CLLocationManagerDelegate {
    nonisolated func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
        let status = manager.authorizationStatus
        let accuracy = manager.accuracyAuthorization
        Task { @MainActor in
            authorizationStatus = status
            accuracyAuthorization = accuracy
            if hasAutomaticRecordingPermission {
                start()
            } else {
                stop()
            }
        }
    }

    nonisolated func locationManager(_ manager: CLLocationManager, didVisit visit: CLVisit) {
        let status = manager.authorizationStatus
        let accuracyAuthorization = manager.accuracyAuthorization
        let arrivalDate = visit.arrivalDate
        let departureDate = visit.departureDate
        let latitude = visit.coordinate.latitude
        let longitude = visit.coordinate.longitude
        let horizontalAccuracy = visit.horizontalAccuracy
        Task { @MainActor in
            guard status == .authorizedAlways,
                  accuracyAuthorization == .fullAccuracy,
                  hasAutomaticRecordingPermission else { return }
            saveVisit(
                arrivalDate: arrivalDate,
                departureDate: departureDate,
                latitude: latitude,
                longitude: longitude,
                horizontalAccuracy: horizontalAccuracy
            )
        }
    }

    nonisolated func locationManager(_ manager: CLLocationManager, didUpdateLocations locations: [CLLocation]) {
        guard locations.isEmpty == false else {
            return
        }
        let status = manager.authorizationStatus
        let accuracyAuthorization = manager.accuracyAuthorization
        Task { @MainActor in
            guard status == .authorizedAlways,
                  accuracyAuthorization == .fullAccuracy,
                  hasAutomaticRecordingPermission else {
                isInitialLocationRequestInFlight = false
                return
            }
            let shouldSaveBootstrapCandidate = isInitialLocationRequestInFlight
            lastErrorMessage = nil
            for location in locations.sorted(by: { $0.timestamp < $1.timestamp }) {
                saveMovementPoint(
                    timestamp: location.timestamp,
                    latitude: location.coordinate.latitude,
                    longitude: location.coordinate.longitude,
                    horizontalAccuracy: location.horizontalAccuracy
                )
            }
            if shouldSaveBootstrapCandidate,
               let location = locations.reversed().first(where: {
                   StayBootstrapPolicy.canUseLocation(
                    timestamp: $0.timestamp,
                    horizontalAccuracy: $0.horizontalAccuracy,
                    evaluatedAt: Date()
                   )
               }) {
                saveBootstrapCandidate(from: location)
            }
            isInitialLocationRequestInFlight = false
        }
    }

    nonisolated func locationManager(_ manager: CLLocationManager, didFailWithError error: Error) {
        Task { @MainActor in
            isInitialLocationRequestInFlight = false
            if let locationError = error as? CLError,
               locationError.code == .locationUnknown {
                return
            }
            lastErrorMessage = error.localizedDescription
        }
    }
}

@MainActor
private final class OneShotLocationDelegate: NSObject, CLLocationManagerDelegate {
    var onLocations: (([CLLocation]) -> Void)?
    var onError: (() -> Void)?

    nonisolated func locationManager(
        _ manager: CLLocationManager,
        didUpdateLocations locations: [CLLocation]
    ) {
        Task { @MainActor [weak self] in
            self?.onLocations?(locations)
        }
    }

    nonisolated func locationManager(
        _ manager: CLLocationManager,
        didFailWithError error: Error
    ) {
        Task { @MainActor [weak self] in
            self?.onError?()
        }
    }
}
