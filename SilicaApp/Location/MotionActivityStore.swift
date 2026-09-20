import CoreMotion
import Foundation
import Observation

enum MovementMode: String, CaseIterable, Hashable, Sendable {
    case walking
    case running
    case cycling
    case vehicle

    var label: String {
        switch self {
        case .walking:
            return AppLanguage.localized("徒歩")
        case .running:
            return AppLanguage.localized("ランニング")
        case .cycling:
            return AppLanguage.localized("自転車")
        case .vehicle:
            return AppLanguage.localized("車両")
        }
    }
}

enum MovementTimingSource: String {
    case pedometer
    case coreMotion = "core_motion"
    case locationPoints = "location_points"
    case visitFallback = "visit_fallback"
    case unavailable

    var isSensorDerived: Bool {
        switch self {
        case .pedometer, .coreMotion, .locationPoints:
            return true
        case .visitFallback, .unavailable:
            return false
        }
    }
}

enum MovementDistanceSource: String {
    case pedometer
    case locationRoute = "location_route"
    case straightLineReference = "straight_line_reference"
    case unavailable
}

enum MovementTimingConfidence: String {
    case high
    case medium
    case low
    case unavailable
}

extension StayEntity {
    var movementModes: [MovementMode] {
        guard let movementModesRawValue else {
            return []
        }
        return movementModesRawValue
            .split(separator: ",")
            .compactMap { MovementMode(rawValue: String($0)) }
    }

    var hasResolvedMovementModes: Bool {
        movementModesRawValue != nil
    }

    var storedMovementInterval: DateInterval? {
        guard let movementStartedAt,
              let movementEndedAt,
              movementEndedAt > movementStartedAt else {
            return nil
        }
        return DateInterval(start: movementStartedAt, end: movementEndedAt)
    }

    var hasResolvedMovementTiming: Bool {
        movementTimingSourceRawValue != nil
    }

    var movementTimingSource: MovementTimingSource {
        movementTimingSourceRawValue.flatMap(MovementTimingSource.init(rawValue:))
            ?? .unavailable
    }

    var movementDisplayDuration: TimeInterval? {
        if let movementActiveDuration, movementActiveDuration > 0 {
            return movementActiveDuration
        }
        return storedMovementInterval?.duration
    }

    var movementDistanceSource: MovementDistanceSource {
        movementDistanceSourceRawValue.flatMap(MovementDistanceSource.init(rawValue:))
            ?? .unavailable
    }

    func movementEvidenceMatches(destinationID: UUID) -> Bool {
        movementDestinationStayID == destinationID
    }

    func storeMovementModes(_ modes: [MovementMode]) {
        var seen: Set<MovementMode> = []
        let uniqueModes = modes.filter { seen.insert($0).inserted }
        movementModesRawValue = uniqueModes.map(\.rawValue).joined(separator: ",")
    }

    func storeMovementTiming(
        interval: DateInterval?,
        destinationStayID: UUID,
        source: MovementTimingSource,
        confidence: MovementTimingConfidence,
        activeDuration: TimeInterval? = nil,
        distanceMeters: Double? = nil,
        stepCount: Int? = nil,
        distanceSource: MovementDistanceSource = .unavailable,
        pedometerBuckets: [PedometerMovementBucket] = [],
        evidenceVersion: Int = 2
    ) {
        movementStartedAt = interval?.start
        movementEndedAt = interval?.end
        movementDestinationStayID = destinationStayID
        movementTimingSourceRawValue = source.rawValue
        movementTimingConfidenceRawValue = confidence.rawValue
        movementActiveDuration = activeDuration.map { max(0, $0) }
        movementDistanceMeters = distanceMeters.map { max(0, $0) }
        movementStepCount = stepCount.map { max(0, $0) }
        movementDistanceSourceRawValue = distanceSource.rawValue
        movementPedometerBucketsData = pedometerBuckets.isEmpty
            ? nil
            : try? JSONEncoder().encode(pedometerBuckets)
        movementEvidenceVersion = evidenceVersion
    }

    func clearMovementEvidence() {
        movementModesRawValue = nil
        movementStartedAt = nil
        movementEndedAt = nil
        movementDestinationStayID = nil
        movementTimingSourceRawValue = nil
        movementTimingConfidenceRawValue = nil
        movementActiveDuration = nil
        movementDistanceMeters = nil
        movementStepCount = nil
        movementDistanceSourceRawValue = nil
        movementPedometerBucketsData = nil
        movementEvidenceVersion = nil
    }
}

final class PedometerEvidenceProvider: @unchecked Sendable {
    private let pedometer = CMPedometer()

    func evidence(
        from searchStart: Date,
        through queryEndAt: Date,
        arrivingAround destinationAnchorAt: Date,
        directDistanceMeters: Double,
        combinedHorizontalAccuracy: Double
    ) async -> PedestrianMovementEvidence? {
        let oldestSupportedAt = Date().addingTimeInterval(-7 * 24 * 60 * 60)
        let supportedSearchStart = max(searchStart, oldestSupportedAt)
        guard queryEndAt > supportedSearchStart,
              CMPedometer.isStepCountingAvailable(),
              CMPedometer.isDistanceAvailable(),
              CMPedometer.authorizationStatus() == .authorized else {
            return nil
        }

        guard let coarseBuckets = await queryBuckets(
            from: supportedSearchStart,
            to: queryEndAt,
            bucketDuration: 5 * 60
        ),
        let coarseEvidence = PedestrianMovementPolicy.resolve(
            buckets: coarseBuckets,
            searchStart: supportedSearchStart,
            destinationAnchorAt: destinationAnchorAt,
            queryEndAt: queryEndAt,
            directDistanceMeters: directDistanceMeters,
            combinedHorizontalAccuracy: combinedHorizontalAccuracy
        ),
        let minuteBuckets = await queryBuckets(
            from: coarseEvidence.interval.start,
            to: coarseEvidence.interval.end,
            bucketDuration: 60
        ) else {
            return nil
        }

        return PedestrianMovementPolicy.resolve(
            buckets: minuteBuckets,
            searchStart: coarseEvidence.interval.start,
            destinationAnchorAt: destinationAnchorAt,
            queryEndAt: coarseEvidence.interval.end,
            directDistanceMeters: directDistanceMeters,
            combinedHorizontalAccuracy: combinedHorizontalAccuracy
        )
    }

    private func queryBuckets(
        from start: Date,
        to end: Date,
        bucketDuration: TimeInterval
    ) async -> [PedometerMovementBucket]? {
        guard end > start, bucketDuration > 0 else {
            return nil
        }
        var buckets: [PedometerMovementBucket] = []
        var bucketStart = start
        while bucketStart < end {
            let bucketEnd = min(bucketStart.addingTimeInterval(bucketDuration), end)
            guard let bucket = await queryBucket(from: bucketStart, to: bucketEnd) else {
                return nil
            }
            buckets.append(bucket)
            bucketStart = bucketEnd
        }
        return buckets
    }

    private func queryBucket(
        from start: Date,
        to end: Date
    ) async -> PedometerMovementBucket? {
        await withCheckedContinuation { continuation in
            pedometer.queryPedometerData(from: start, to: end) { data, error in
                guard error == nil, let data else {
                    continuation.resume(returning: nil)
                    return
                }
                let distance = max(0, data.distance?.doubleValue ?? 0)
                let activeDuration = data.averageActivePace.map {
                    min(end.timeIntervalSince(start), max(0, $0.doubleValue * distance))
                }
                continuation.resume(returning: PedometerMovementBucket(
                    interval: DateInterval(start: start, end: end),
                    stepCount: data.numberOfSteps.intValue,
                    distanceMeters: distance,
                    activeDuration: activeDuration
                ))
            }
        }
    }
}

private struct MotionActivitySample: Sendable {
    let startAt: Date
    let mode: MovementMode?
    let confidence: Int
}

private struct MotionActivityDaySnapshot: Sendable {
    let samples: [MotionActivitySample]
    let loadedFrom: Date
    let loadedThrough: Date
}

@MainActor
@Observable
final class MotionActivityStore {
    private var snapshots: [Date: MotionActivityDaySnapshot] = [:]

    private let manager = CMMotionActivityManager()
    @ObservationIgnored private var requestIDs: [Date: UUID] = [:]

    func load(around date: Date, calendar: Calendar = .current) {
        let dayStart = calendar.startOfDay(for: date)
        guard CMMotionActivityManager.isActivityAvailable() else {
            guard snapshots[dayStart] == nil else { return }
            snapshots[dayStart] = MotionActivityDaySnapshot(
                samples: [],
                loadedFrom: .distantPast,
                loadedThrough: .distantPast
            )
            return
        }

        let queryStart = calendar.date(byAdding: .hour, value: -6, to: dayStart) ?? dayStart
        let dayEnd = calendar.date(byAdding: .day, value: 1, to: dayStart) ?? date
        let requestedEnd = calendar.date(byAdding: .hour, value: 6, to: dayEnd) ?? dayEnd
        let queryEnd = min(requestedEnd, Date())
        guard queryEnd > queryStart else {
            snapshots[dayStart] = MotionActivityDaySnapshot(
                samples: [],
                loadedFrom: queryStart,
                loadedThrough: .distantPast
            )
            requestIDs[dayStart] = nil
            return
        }
        if let snapshot = snapshots[dayStart],
           snapshot.loadedThrough >= queryEnd {
            return
        }
        guard requestIDs[dayStart] == nil else {
            return
        }

        let requestID = UUID()
        requestIDs[dayStart] = requestID
        manager.queryActivityStarting(
            from: queryStart,
            to: queryEnd,
            to: .main
        ) { [weak self] activities, _ in
            let mappedSamples = activities?.map(Self.makeSample) ?? []
            Task { @MainActor [weak self] in
                guard let self, self.requestIDs[dayStart] == requestID else {
                    return
                }
                self.snapshots[dayStart] = MotionActivityDaySnapshot(
                    samples: mappedSamples.sorted { $0.startAt < $1.startAt },
                    loadedFrom: queryStart,
                    loadedThrough: queryEnd
                )
                self.requestIDs[dayStart] = nil
            }
        }
    }

    func modes(from departureAt: Date, to arrivalAt: Date) -> [MovementMode] {
        guard arrivalAt > departureAt else {
            return []
        }
        guard let snapshot = snapshot(around: arrivalAt) else {
            return []
        }
        let samples = snapshot.samples

        struct ModeSummary {
            var duration: TimeInterval = 0
            var firstOccurrence: Int = .max
        }
        var summaries: [MovementMode: ModeSummary] = [:]
        for index in samples.indices {
            let sample = samples[index]
            let sampleEnd = index < samples.index(before: samples.endIndex)
                ? samples[samples.index(after: index)].startAt
                : arrivalAt
            let overlapStart = max(departureAt, sample.startAt)
            let overlapEnd = min(arrivalAt, sampleEnd)
            guard overlapEnd.timeIntervalSince(overlapStart) >= 60,
                  sample.confidence > 0,
                  let mode = sample.mode else {
                continue
            }
            var summary = summaries[mode] ?? ModeSummary()
            summary.duration += overlapEnd.timeIntervalSince(overlapStart)
            summary.firstOccurrence = min(summary.firstOccurrence, index)
            summaries[mode] = summary
        }
        return Array(summaries
            .sorted { lhs, rhs in
                if lhs.value.duration == rhs.value.duration {
                    return lhs.value.firstOccurrence < rhs.value.firstOccurrence
                }
                return lhs.value.duration > rhs.value.duration
            }
            .map(\.key)
            .prefix(3))
    }

    private func snapshot(
        around date: Date,
        calendar: Calendar = .current
    ) -> MotionActivityDaySnapshot? {
        snapshots[calendar.startOfDay(for: date)] ?? snapshots.values.first { snapshot in
            snapshot.loadedFrom <= date && snapshot.loadedThrough >= date
        }
    }

    private static func makeSample(_ activity: CMMotionActivity) -> MotionActivitySample {
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
        return MotionActivitySample(
            startAt: activity.startDate,
            mode: mode,
            confidence: confidence
        )
    }
}
