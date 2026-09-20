import Foundation

public struct MovementPoint: Codable, Equatable, Hashable, Sendable {
    public var timestamp: Date
    public var coordinate: GeoCoordinate
    public var horizontalAccuracy: Double

    public init(
        timestamp: Date,
        coordinate: GeoCoordinate,
        horizontalAccuracy: Double
    ) {
        self.timestamp = timestamp
        self.coordinate = coordinate
        self.horizontalAccuracy = horizontalAccuracy
    }
}

public struct MovementSummary: Equatable, Sendable {
    public var departureAt: Date
    public var arrivalAt: Date
    public var distanceMeters: Double

    public var duration: TimeInterval {
        max(0, arrivalAt.timeIntervalSince(departureAt))
    }

    public init(
        departureAt: Date,
        arrivalAt: Date,
        distanceMeters: Double
    ) {
        self.departureAt = departureAt
        self.arrivalAt = arrivalAt
        self.distanceMeters = distanceMeters
    }
}

public enum MovementDurationPolicy {
    public static let maximumDestinationAnchorDelay: TimeInterval = 15 * 60

    /// Sensor timing is presentation-safe only when it fits entirely inside
    /// the raw gap between two observed stays. It may still provide a movement
    /// mode when this check fails, but must not alter stay times, duration,
    /// distance, or steps.
    public static func isWithinObservedGap(
        _ evidence: DateInterval,
        originDepartureAt: Date?,
        destinationArrivalAt: Date
    ) -> Bool {
        guard let originDepartureAt,
              destinationArrivalAt > originDepartureAt else {
            return false
        }
        return evidence.start >= originDepartureAt &&
            evidence.end <= destinationArrivalAt
    }
}

/// Describes what a displayed movement time actually represents. A visit gap
/// is useful chronology, but it is not promoted to sensor-measured travel
/// time: an unobserved stop may exist between the two visits.
public enum MovementTimingKind: String, Equatable, Sendable {
    case measured
    case observedVisitGap
    case inferredVisitGap
    case unavailable
}

public struct MovementTimingResolution: Equatable, Sendable {
    public var kind: MovementTimingKind
    public var interval: DateInterval?

    public init(kind: MovementTimingKind, interval: DateInterval?) {
        self.kind = kind
        self.interval = interval
    }

    public var duration: TimeInterval? {
        interval?.duration
    }
}

/// Keeps sensor travel time and Core Location visit chronology separate.
/// Movement duration is displayed in whole minutes, so values that would
/// render as five minutes or less are omitted instead of presenting noisy
/// visit-boundary differences as useful travel time. There is no upper limit.
public enum MovementTimingPresentationPolicy {
    public static let maximumHiddenRoundedMinutes = 5

    public static func resolve(
        destinationLinkedSensorInterval: DateInterval?,
        originDepartureAt: Date?,
        originDepartureIsObserved: Bool,
        destinationArrivalAt: Date
    ) -> MovementTimingResolution {
        if let sensorInterval = destinationLinkedSensorInterval,
           MovementDurationPolicy.isWithinObservedGap(
               sensorInterval,
               originDepartureAt: originDepartureAt,
               destinationArrivalAt: destinationArrivalAt
           ) {
            guard shouldDisplayDuration(sensorInterval.duration) else {
                return MovementTimingResolution(kind: .unavailable, interval: nil)
            }
            return MovementTimingResolution(kind: .measured, interval: sensorInterval)
        }

        guard let originDepartureAt,
              destinationArrivalAt > originDepartureAt else {
            return MovementTimingResolution(kind: .unavailable, interval: nil)
        }

        let interval = DateInterval(
            start: originDepartureAt,
            end: destinationArrivalAt
        )
        guard shouldDisplayDuration(interval.duration) else {
            return MovementTimingResolution(kind: .unavailable, interval: nil)
        }

        return MovementTimingResolution(
            kind: originDepartureIsObserved ? .observedVisitGap : .inferredVisitGap,
            interval: interval
        )
    }

    public static func shouldDisplayDuration(_ duration: TimeInterval) -> Bool {
        let roundedMinutes = Int((max(0, duration) / 60).rounded())
        return roundedMinutes > maximumHiddenRoundedMinutes
    }
}

public enum MovementPresentationEvidenceKind: Equatable, Sendable {
    case direct
    case excursion
}

public struct MovementPresentationEvidence: Equatable, Sendable {
    public var kind: MovementPresentationEvidenceKind
    public var directDistanceMeters: Double

    public init(
        kind: MovementPresentationEvidenceKind,
        directDistanceMeters: Double
    ) {
        self.kind = kind
        self.directDistanceMeters = directDistanceMeters
    }
}

/// Decides whether two consecutive stays have enough spatial evidence for a
/// movement row. A same-place return can still be movement when a reliable
/// point proves that the device left the shared place between the two stays.
public enum MovementPresentationPolicy {
    public static let maximumReliablePointAccuracy: Double = 250

    public static func evidence(
        origin: GeoCoordinate,
        destination: GeoCoordinate,
        originAccuracy: Double,
        destinationAccuracy: Double,
        excursionInterval: DateInterval?,
        points: [MovementPoint],
        containmentRadiusMeters: Double? = nil
    ) -> MovementPresentationEvidence? {
        guard isValid(origin), isValid(destination) else {
            return nil
        }

        let directDistance = GeoDistance.meters(from: origin, to: destination)
        let minimumDistance = max(
            75,
            min(250, max(0, max(originAccuracy, destinationAccuracy)))
        )
        if directDistance >= minimumDistance {
            return MovementPresentationEvidence(
                kind: .direct,
                directDistanceMeters: directDistance
            )
        }

        guard let excursionInterval,
              MovementTimingPresentationPolicy.shouldDisplayDuration(
                excursionInterval.duration
              ) else {
            return nil
        }

        let containmentRadius: Double
        if let containmentRadiusMeters,
           containmentRadiusMeters.isFinite,
           containmentRadiusMeters >= 0 {
            containmentRadius = max(75, containmentRadiusMeters)
        } else {
            containmentRadius = 250
        }
        let hasReliableExcursionPoint = points.contains { point in
            guard excursionInterval.contains(point.timestamp),
                  point.horizontalAccuracy.isFinite,
                  point.horizontalAccuracy >= 0,
                  point.horizontalAccuracy <= maximumReliablePointAccuracy,
                  isValid(point.coordinate) else {
                return false
            }

            let originRadius = max(
                max(minimumDistance, containmentRadius),
                min(600, max(0, originAccuracy) + point.horizontalAccuracy)
            )
            let destinationRadius = max(
                max(minimumDistance, containmentRadius),
                min(600, max(0, destinationAccuracy) + point.horizontalAccuracy)
            )
            return GeoDistance.meters(from: origin, to: point.coordinate) > originRadius &&
                GeoDistance.meters(from: destination, to: point.coordinate) > destinationRadius
        }

        guard hasReliableExcursionPoint else {
            return nil
        }
        return MovementPresentationEvidence(
            kind: .excursion,
            directDistanceMeters: directDistance
        )
    }

    private static func isValid(_ coordinate: GeoCoordinate) -> Bool {
        coordinate.latitude.isFinite &&
            coordinate.longitude.isFinite &&
            (-90...90).contains(coordinate.latitude) &&
            (-180...180).contains(coordinate.longitude)
    }
}

public enum MovementSummaryBuilder {
    public static func build(
        departureAt: Date,
        arrivalAt: Date,
        origin: GeoCoordinate,
        destination: GeoCoordinate,
        points: [MovementPoint],
        maximumHorizontalAccuracy: Double = 1_000
    ) -> MovementSummary? {
        guard arrivalAt > departureAt else {
            return nil
        }

        var validPoints: [MovementPoint] = []
        validPoints.reserveCapacity(points.count)
        var previousTimestamp: Date?
        var isSortedByTimestamp = true

        for point in points {
            guard point.timestamp >= departureAt,
                  point.timestamp <= arrivalAt,
                  point.horizontalAccuracy >= 0,
                  point.horizontalAccuracy <= maximumHorizontalAccuracy,
                  isValid(point.coordinate) else {
                continue
            }

            if let previousTimestamp, point.timestamp < previousTimestamp {
                isSortedByTimestamp = false
            }
            previousTimestamp = point.timestamp
            validPoints.append(point)
        }

        if isSortedByTimestamp == false {
            validPoints.sort { $0.timestamp < $1.timestamp }
        }

        var distance = 0.0
        var previousCoordinate = origin
        for point in validPoints {
            distance += GeoDistance.meters(from: previousCoordinate, to: point.coordinate)
            previousCoordinate = point.coordinate
        }
        distance += GeoDistance.meters(from: previousCoordinate, to: destination)

        return MovementSummary(
            departureAt: departureAt,
            arrivalAt: arrivalAt,
            distanceMeters: distance
        )
    }

    private static func isValid(_ coordinate: GeoCoordinate) -> Bool {
        (-90...90).contains(coordinate.latitude)
            && (-180...180).contains(coordinate.longitude)
    }
}

public struct MotionMovementSegment: Equatable, Sendable {
    public var interval: DateInterval
    public var modeRawValue: String
    public var confidence: Int
    /// `false` when the segment was the last Core Motion state in a bounded
    /// query and its end was supplied by the query boundary rather than by a
    /// subsequent activity transition.
    public var endIsObserved: Bool

    public init(
        interval: DateInterval,
        modeRawValue: String,
        confidence: Int,
        endIsObserved: Bool = true
    ) {
        self.interval = interval
        self.modeRawValue = modeRawValue
        self.confidence = confidence
        self.endIsObserved = endIsObserved
    }
}

public struct PedometerMovementBucket: Codable, Equatable, Sendable {
    public var interval: DateInterval
    public var stepCount: Int
    public var distanceMeters: Double
    public var activeDuration: TimeInterval?

    public init(
        interval: DateInterval,
        stepCount: Int,
        distanceMeters: Double,
        activeDuration: TimeInterval?
    ) {
        self.interval = interval
        self.stepCount = max(0, stepCount)
        self.distanceMeters = max(0, distanceMeters)
        self.activeDuration = activeDuration.map { max(0, min(interval.duration, $0)) }
    }
}

public struct PedestrianMovementEvidence: Equatable, Sendable {
    public var interval: DateInterval
    public var activeDuration: TimeInterval?
    public var stepCount: Int
    public var distanceMeters: Double
    public var buckets: [PedometerMovementBucket]

    public init(
        interval: DateInterval,
        activeDuration: TimeInterval?,
        stepCount: Int,
        distanceMeters: Double,
        buckets: [PedometerMovementBucket]
    ) {
        self.interval = interval
        self.activeDuration = activeDuration
        self.stepCount = max(0, stepCount)
        self.distanceMeters = max(0, distanceMeters)
        self.buckets = buckets
    }
}

public enum PedestrianMovementPolicy {
    public static let maximumIdleGap: TimeInterval = 3 * 60
    public static let maximumArrivalGap: TimeInterval = 15 * 60
    public static let minimumStepCount = 40
    public static let minimumDistanceMeters: Double = 30
    public static let minimumActiveDuration: TimeInterval = 30

    public static func resolve(
        buckets: [PedometerMovementBucket],
        searchStart: Date,
        destinationAnchorAt: Date,
        queryEndAt: Date? = nil,
        directDistanceMeters: Double,
        combinedHorizontalAccuracy: Double
    ) -> PedestrianMovementEvidence? {
        let evidenceEndAt = queryEndAt ?? destinationAnchorAt
        guard evidenceEndAt > searchStart,
              evidenceEndAt <= destinationAnchorAt.addingTimeInterval(maximumArrivalGap) else {
            return nil
        }

        let activeBuckets = buckets
            .filter { bucket in
                bucket.interval.end > searchStart &&
                    bucket.interval.start < evidenceEndAt &&
                    (bucket.stepCount > 0 || bucket.distanceMeters > 0)
            }
            .map { bucket in
                PedometerMovementBucket(
                    interval: DateInterval(
                        start: max(searchStart, bucket.interval.start),
                        end: min(evidenceEndAt, bucket.interval.end)
                    ),
                    stepCount: bucket.stepCount,
                    distanceMeters: bucket.distanceMeters,
                    activeDuration: bucket.activeDuration
                )
            }
            .filter { $0.interval.duration > 0 }
            .sorted { $0.interval.start < $1.interval.start }

        var episodes: [[PedometerMovementBucket]] = []
        for bucket in activeBuckets {
            if let lastBucket = episodes.last?.last,
               bucket.interval.start.timeIntervalSince(lastBucket.interval.end) < maximumIdleGap {
                episodes[episodes.index(before: episodes.endIndex)].append(bucket)
            } else {
                episodes.append([bucket])
            }
        }

        let meaningfulDirectDistance = max(
            0,
            directDistanceMeters - max(0, combinedHorizontalAccuracy)
        )
        let requiredDistance = max(
            minimumDistanceMeters,
            meaningfulDirectDistance * 0.6
        )

        let candidates = episodes.compactMap { episode -> PedestrianMovementEvidence? in
            guard let first = episode.first, let last = episode.last else {
                return nil
            }
            let stepCount = episode.reduce(0) { $0 + $1.stepCount }
            let distance = episode.reduce(0) { $0 + $1.distanceMeters }
            let knownDurations = episode.compactMap(\.activeDuration)
            let activeDuration = knownDurations.count == episode.count
                ? knownDurations.reduce(0, +)
                : nil
            let hasEnoughActiveDuration = activeDuration.map {
                $0 >= minimumActiveDuration
            } ?? true
            guard stepCount >= minimumStepCount,
                  distance >= requiredDistance,
                  abs(last.interval.end.timeIntervalSince(destinationAnchorAt)) <=
                    maximumArrivalGap,
                  hasEnoughActiveDuration else {
                return nil
            }
            return PedestrianMovementEvidence(
                interval: DateInterval(
                    start: first.interval.start,
                    end: last.interval.end
                ),
                activeDuration: activeDuration,
                stepCount: stepCount,
                distanceMeters: distance,
                buckets: episode
            )
        }

        return candidates.min { lhs, rhs in
            let lhsGap = abs(lhs.interval.end.timeIntervalSince(destinationAnchorAt))
            let rhsGap = abs(rhs.interval.end.timeIntervalSince(destinationAnchorAt))
            if lhsGap == rhsGap {
                return lhs.interval.start > rhs.interval.start
            }
            return lhsGap < rhsGap
        }
    }
}

public struct FusedMovementEvidence: Equatable, Sendable {
    public var interval: DateInterval
    public var modeRawValues: [String]

    public init(interval: DateInterval, modeRawValues: [String]) {
        self.interval = interval
        self.modeRawValues = modeRawValues
    }
}

public enum MovementModeSelectionPolicy {
    public static let longDistanceThresholdMeters: Double = 3_000
    public static let implausibleWalkingSpeedMetersPerSecond: Double = 2.5

    public static func prioritizedModeRawValues(
        detectedModes: [String],
        directDistanceMeters: Double,
        tripDuration: TimeInterval
    ) -> [String] {
        var uniqueModes: [String] = []
        for mode in detectedModes where uniqueModes.contains(mode) == false {
            uniqueModes.append(mode)
        }
        guard directDistanceMeters >= longDistanceThresholdMeters,
              tripDuration > 0 else {
            return Array(uniqueModes.prefix(3))
        }

        let averageSpeed = directDistanceMeters / tripDuration
        let hasHumanPoweredFastMode = uniqueModes.contains("running") ||
            uniqueModes.contains("cycling")
        let shouldPreferVehicle = uniqueModes.contains("vehicle") ||
            (averageSpeed >= implausibleWalkingSpeedMetersPerSecond &&
                hasHumanPoweredFastMode == false)
        guard shouldPreferVehicle else {
            return Array(uniqueModes.prefix(3))
        }

        uniqueModes.removeAll { $0 == "vehicle" }
        uniqueModes.insert("vehicle", at: 0)
        return Array(uniqueModes.prefix(3))
    }

    /// A delayed visit departure can clip a real walk down to an impossible
    /// speed. In that case the caller should retry against the earlier sensor
    /// window before accepting the clipped interval.
    public static func shouldExpandEvidenceSearch(
        detectedModes: [String],
        directDistanceMeters: Double,
        tripDuration: TimeInterval
    ) -> Bool {
        let modes = Set(detectedModes)
        guard modes == ["walking"], tripDuration > 0 else {
            return false
        }
        return directDistanceMeters / tripDuration >=
            implausibleWalkingSpeedMetersPerSecond
    }
}

public enum MovementFusionPolicy {
    public static let maximumLookback: TimeInterval = 4 * 60 * 60
    public static let maximumArrivalGap: TimeInterval = 45 * 60
    /// A trip can contain waits at signals, stations, or transfers. Joining
    /// moving classifications across a bounded idle gap preserves the whole
    /// trip without pulling in unrelated activity from earlier in a stay.
    public static let maximumJoinGap: TimeInterval = 20 * 60
    public static let minimumMovementDuration: TimeInterval = 60
    public static let maximumFallbackDuration: TimeInterval = 4 * 60 * 60

    /// Summarizes the complete trip between two confirmed stays. Modes are
    /// ordered by the amount of classified time, so a short final walk cannot
    /// replace a substantially longer vehicle leg.
    public static func resolveTripEvidence(
        departureAt: Date,
        destinationArrivalAt: Date,
        segments: [MotionMovementSegment]
    ) -> FusedMovementEvidence? {
        guard destinationArrivalAt > departureAt else {
            return nil
        }

        struct ModeSummary {
            var duration: TimeInterval = 0
            var firstOccurrence: Int = .max
        }

        var summaries: [String: ModeSummary] = [:]
        var movementStart: Date?
        var movementEnd: Date?

        for (index, segment) in segments.enumerated()
            where segment.confidence > 0 && segment.endIsObserved {
            let start = max(departureAt, segment.interval.start)
            let end = min(destinationArrivalAt, segment.interval.end)
            let duration = end.timeIntervalSince(start)
            guard duration >= 30 else {
                continue
            }

            var summary = summaries[segment.modeRawValue] ?? ModeSummary()
            summary.duration += duration
            summary.firstOccurrence = min(summary.firstOccurrence, index)
            summaries[segment.modeRawValue] = summary
            movementStart = movementStart.map { min($0, start) } ?? start
            movementEnd = movementEnd.map { max($0, end) } ?? end
        }

        let totalMovementDuration = summaries.values.reduce(0) { $0 + $1.duration }
        guard totalMovementDuration >= minimumMovementDuration,
              let movementStart,
              let movementEnd,
              movementEnd > movementStart else {
            return nil
        }

        let modes = summaries
            .sorted { lhs, rhs in
                if lhs.value.duration == rhs.value.duration {
                    return lhs.value.firstOccurrence < rhs.value.firstOccurrence
                }
                return lhs.value.duration > rhs.value.duration
            }
            .map(\.key)

        return FusedMovementEvidence(
            interval: DateInterval(start: movementStart, end: movementEnd),
            modeRawValues: Array(modes.prefix(3))
        )
    }

    public static func resolveMotionEvidence(
        originArrivalAt: Date,
        destinationArrivalAt: Date,
        lastKnownInsideAt: Date?,
        segments: [MotionMovementSegment]
    ) -> FusedMovementEvidence? {
        guard destinationArrivalAt > originArrivalAt else {
            return nil
        }
        let lookbackStart = destinationArrivalAt.addingTimeInterval(-maximumLookback)
        let searchStart = max(
            originArrivalAt,
            lastKnownInsideAt ?? originArrivalAt,
            lookbackStart
        )
        guard destinationArrivalAt > searchStart else {
            return nil
        }

        let eligible = segments
            .filter {
                $0.confidence > 0 &&
                    $0.endIsObserved &&
                    $0.interval.end > searchStart &&
                    $0.interval.start < destinationArrivalAt
            }
            .sorted { $0.interval.start < $1.interval.start }

        struct ModeSummary {
            var duration: TimeInterval = 0
            var firstOccurrence: Int = .max
        }
        struct Group {
            var start: Date
            var end: Date
            var activeDuration: TimeInterval
            var modes: [String: ModeSummary]
        }
        var groups: [Group] = []
        for (index, segment) in eligible.enumerated() {
            let start = max(searchStart, segment.interval.start)
            let end = min(destinationArrivalAt, segment.interval.end)
            let duration = end.timeIntervalSince(start)
            guard duration >= 30 else {
                continue
            }
            if let last = groups.last,
               start.timeIntervalSince(last.end) <= maximumJoinGap {
                let lastIndex = groups.index(before: groups.endIndex)
                groups[lastIndex].end = max(last.end, end)
                groups[lastIndex].activeDuration += duration
                var summary = groups[lastIndex].modes[segment.modeRawValue] ?? ModeSummary()
                summary.duration += duration
                summary.firstOccurrence = min(summary.firstOccurrence, index)
                groups[lastIndex].modes[segment.modeRawValue] = summary
            } else {
                groups.append(Group(
                    start: start,
                    end: end,
                    activeDuration: duration,
                    modes: [
                        segment.modeRawValue: ModeSummary(
                            duration: duration,
                            firstOccurrence: index
                        )
                    ]
                ))
            }
        }

        let candidates = groups
            .filter {
                $0.activeDuration >= minimumMovementDuration &&
                    $0.end >= destinationArrivalAt.addingTimeInterval(-maximumArrivalGap)
            }
        guard let selected = candidates.min(by: {
            abs($0.end.timeIntervalSince(destinationArrivalAt))
                < abs($1.end.timeIntervalSince(destinationArrivalAt))
        }) else {
            return nil
        }
        let modes = selected.modes
            .sorted { lhs, rhs in
                if lhs.value.duration == rhs.value.duration {
                    return lhs.value.firstOccurrence < rhs.value.firstOccurrence
                }
                return lhs.value.duration > rhs.value.duration
            }
            .map(\.key)
        return FusedMovementEvidence(
            interval: DateInterval(start: selected.start, end: selected.end),
            modeRawValues: Array(modes.prefix(3))
        )
    }

    public static func isPlausibleFallback(
        departureAt: Date,
        arrivalAt: Date
    ) -> Bool {
        let duration = arrivalAt.timeIntervalSince(departureAt)
        return duration >= minimumMovementDuration &&
            duration <= maximumFallbackDuration
    }
}
