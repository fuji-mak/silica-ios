import Foundation
import Testing
@testable import SilicaCore

private let utcTimeZone = TimeZone(secondsFromGMT: 0)!

private func isoDate(_ value: String) -> Date {
    ISO8601DateFormatter().date(from: value)!
}

private func markdownExporter() -> MarkdownLocationExporter {
    MarkdownLocationExporter(timeZone: utcTimeZone)
}

@Test func automaticExportStartsOnTheDayAfterSetupInLocalTime() {
    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = TimeZone(identifier: "Etc/GMT-9")!
    let setup = isoDate("2100-01-31T10:00:00Z") // synthetic local-evening setup
    let setupDay = calendar.startOfDay(for: setup)
    let yesterday = calendar.date(byAdding: .day, value: -1, to: setupDay)!
    let requested = [yesterday, setupDay]

    #expect(AutomaticExportDatePolicy.eligibleDates(
        requested, startingOn: setup, relativeTo: setup, calendar: calendar
    ).isEmpty)
    #expect(AutomaticExportDatePolicy.eligibleDates(
        requested, startingOn: setup,
        relativeTo: isoDate("2100-01-31T14:59:00Z"), calendar: calendar
    ).isEmpty)
    #expect(AutomaticExportDatePolicy.eligibleDates(
        requested, startingOn: setup,
        relativeTo: isoDate("2100-01-31T15:00:00Z"), calendar: calendar
    ) == [setupDay])
}

@Test func automaticExportKeepsExistingHistoricalDatesEligible() {
    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = utcTimeZone
    let firstDate = isoDate("2100-01-09T00:00:00Z")
    let yesterday = isoDate("2100-01-30T00:00:00Z")
    let today = isoDate("2100-01-31T00:00:00Z")
    #expect(AutomaticExportDatePolicy.eligibleDates(
        [today, yesterday, firstDate, yesterday], startingOn: firstDate,
        relativeTo: today, calendar: calendar
    ) == [firstDate, yesterday])
}

@Test func automaticExportNotifiesOnlyForYesterday() {
    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = utcTimeZone
    let referenceDate = isoDate("2100-01-24T12:00:00Z")

    #expect(AutomaticExportNotificationPolicy.shouldNotify(
        notificationsEnabled: true,
        exportDate: isoDate("2100-01-23T23:59:00Z"),
        relativeTo: referenceDate,
        calendar: calendar
    ))
    #expect(!AutomaticExportNotificationPolicy.shouldNotify(
        notificationsEnabled: true,
        exportDate: isoDate("2100-01-22T23:59:00Z"),
        relativeTo: referenceDate,
        calendar: calendar
    ))
    #expect(!AutomaticExportNotificationPolicy.shouldNotify(
        notificationsEnabled: true,
        exportDate: isoDate("2100-01-24T00:00:00Z"),
        relativeTo: referenceDate,
        calendar: calendar
    ))
    #expect(!AutomaticExportNotificationPolicy.shouldNotify(
        notificationsEnabled: false,
        exportDate: isoDate("2100-01-23T23:59:00Z"),
        relativeTo: referenceDate,
        calendar: calendar
    ))
}

@Test func automaticExportNotificationsDefaultToEnabled() {
    #expect(AutomaticExportNotificationPolicy.isEnabled(storedValue: nil))
    #expect(AutomaticExportNotificationPolicy.isEnabled(storedValue: true))
    #expect(!AutomaticExportNotificationPolicy.isEnabled(storedValue: false))
}

@Test func automaticExportNotifiesOnlyOnceForTheSameExportDate() {
    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = utcTimeZone
    let referenceDate = isoDate("2100-01-27T14:00:00Z")
    let exportDate = isoDate("2100-01-26T00:00:00Z")

    #expect(!AutomaticExportNotificationPolicy.shouldNotify(
        notificationsEnabled: true,
        exportDate: exportDate,
        lastNotifiedExportDate: isoDate("2100-01-26T18:00:00Z"),
        relativeTo: referenceDate,
        calendar: calendar
    ))
    #expect(AutomaticExportNotificationPolicy.shouldNotify(
        notificationsEnabled: true,
        exportDate: exportDate,
        lastNotifiedExportDate: isoDate("2100-01-25T00:00:00Z"),
        relativeTo: referenceDate,
        calendar: calendar
    ))
}

@Test func visitCoordinateRefinementAcceptsFreshImprovedNearbySample() {
    let requestedAt = isoDate("2100-01-11T03:00:00Z")
    let raw = GeoCoordinate(latitude: 0.1000, longitude: 0.1000)
    let aboutThirtyMetersAway = GeoCoordinate(latitude: 0.10027, longitude: 0.1000)

    #expect(VisitCoordinateRefinementPolicy.accepts(
        rawCoordinate: raw,
        rawHorizontalAccuracy: 60,
        sampleCoordinate: aboutThirtyMetersAway,
        sampleHorizontalAccuracy: 10,
        sampleTimestamp: requestedAt.addingTimeInterval(3),
        requestedAt: requestedAt,
        evaluatedAt: requestedAt.addingTimeInterval(4),
        registeredPlaceRelationship: .neitherCoordinateIsRegistered
    ))
}

@Test func visitCoordinateRefinementHasNoFiftyMeterDistanceFloor() {
    let requestedAt = isoDate("2100-01-11T03:00:00Z")
    let raw = GeoCoordinate(latitude: 0.1000, longitude: 0.1000)
    let aboutThirtyMetersAway = GeoCoordinate(latitude: 0.10027, longitude: 0.1000)

    #expect(!VisitCoordinateRefinementPolicy.accepts(
        rawCoordinate: raw,
        rawHorizontalAccuracy: 20,
        sampleCoordinate: aboutThirtyMetersAway,
        sampleHorizontalAccuracy: 5,
        sampleTimestamp: requestedAt,
        requestedAt: requestedAt,
        evaluatedAt: requestedAt.addingTimeInterval(1),
        registeredPlaceRelationship: .neitherCoordinateIsRegistered
    ))
}

@Test func visitCoordinateRefinementRequiresSameRegisteredPlace() {
    let requestedAt = isoDate("2100-01-11T03:00:00Z")
    let raw = GeoCoordinate(latitude: 0.1000, longitude: 0.1000)

    #expect(VisitCoordinateRefinementPolicy.accepts(
        rawCoordinate: raw,
        rawHorizontalAccuracy: 80,
        sampleCoordinate: GeoCoordinate(latitude: 0.1010, longitude: 0.1000),
        sampleHorizontalAccuracy: 10,
        sampleTimestamp: requestedAt,
        requestedAt: requestedAt,
        evaluatedAt: requestedAt.addingTimeInterval(1),
        registeredPlaceRelationship: .sameRegisteredPlace
    ))
    #expect(!VisitCoordinateRefinementPolicy.accepts(
        rawCoordinate: raw,
        rawHorizontalAccuracy: 80,
        sampleCoordinate: raw,
        sampleHorizontalAccuracy: 10,
        sampleTimestamp: requestedAt,
        requestedAt: requestedAt,
        evaluatedAt: requestedAt.addingTimeInterval(1),
        registeredPlaceRelationship: .differentOrOnlyOneRegisteredPlace
    ))
}

@Test func visitCoordinateRefinementRejectsStaleOrInsufficientlyImprovedSamples() {
    let requestedAt = isoDate("2100-01-11T03:00:00Z")
    let raw = GeoCoordinate(latitude: 0.1000, longitude: 0.1000)

    #expect(!VisitCoordinateRefinementPolicy.accepts(
        rawCoordinate: raw,
        rawHorizontalAccuracy: 40,
        sampleCoordinate: raw,
        sampleHorizontalAccuracy: 30,
        sampleTimestamp: requestedAt,
        requestedAt: requestedAt,
        evaluatedAt: requestedAt.addingTimeInterval(1),
        registeredPlaceRelationship: .neitherCoordinateIsRegistered
    ))
    #expect(!VisitCoordinateRefinementPolicy.accepts(
        rawCoordinate: raw,
        rawHorizontalAccuracy: 40,
        sampleCoordinate: raw,
        sampleHorizontalAccuracy: 10,
        sampleTimestamp: requestedAt,
        requestedAt: requestedAt,
        evaluatedAt: requestedAt.addingTimeInterval(16),
        registeredPlaceRelationship: .neitherCoordinateIsRegistered
    ))
}

@Test func placeCandidateMatchingUsesRegisteredRadiusWithoutHundredMeterFloor() {
    let registeredCoordinate = GeoCoordinate(latitude: 0.1000, longitude: 0.1000)
    let coordinateAboutSeventyMetersAway = GeoCoordinate(latitude: 0.10063, longitude: 0.1000)

    #expect(!PlaceCandidatePolicy.matchesRegisteredPlace(
        coordinate: coordinateAboutSeventyMetersAway,
        registeredCoordinate: registeredCoordinate,
        radiusMeters: 50
    ))
}

@Test func placeCandidateDeduplicationKeepsNearbyDistinctPlaces() {
    let first = GeoCoordinate(latitude: 0.1000, longitude: 0.1000)
    let aboutTwentyMetersAway = GeoCoordinate(latitude: 0.10018, longitude: 0.1000)
    let aboutSeventyMetersAway = GeoCoordinate(latitude: 0.10063, longitude: 0.1000)

    #expect(PlaceCandidatePolicy.representsSameCandidate(first, aboutTwentyMetersAway))
    #expect(!PlaceCandidatePolicy.representsSameCandidate(first, aboutSeventyMetersAway))
}

@Test func freePlanRequiresProStartingWithFourthSavedPlace() {
    #expect(!SavedPlaceAccessPolicy.requiresPro(existingPlaceCount: 0, isProActive: false))
    #expect(!SavedPlaceAccessPolicy.requiresPro(existingPlaceCount: 2, isProActive: false))
    #expect(SavedPlaceAccessPolicy.requiresPro(existingPlaceCount: 3, isProActive: false))
    #expect(SavedPlaceAccessPolicy.requiresPro(existingPlaceCount: 4, isProActive: false))
}

@Test func proPlanAllowsUnlimitedSavedPlaces() {
    #expect(!SavedPlaceAccessPolicy.requiresPro(existingPlaceCount: 3, isProActive: true))
    #expect(!SavedPlaceAccessPolicy.requiresPro(existingPlaceCount: 100, isProActive: true))
}

@Test func freePlanCanViewTodayAndPreviousThirtyCalendarDays() {
    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = utcTimeZone
    let today = isoDate("2100-01-08T12:00:00Z")
    let oldestFreeDate = isoDate("2100-01-07T00:00:00Z")

    #expect(!LocationHistoryAccessPolicy.requiresPro(
        viewing: today,
        relativeTo: today,
        calendar: calendar,
        isProActive: false
    ))
    #expect(!LocationHistoryAccessPolicy.requiresPro(
        viewing: oldestFreeDate,
        relativeTo: today,
        calendar: calendar,
        isProActive: false
    ))
}

@Test func freePlanRequiresProBeforeItsThirtyOneDayWindow() {
    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = utcTimeZone
    let today = isoDate("2100-02-01T12:00:00Z")
    let outsideFreeWindow = isoDate("2100-01-01T00:00:00Z")

    #expect(LocationHistoryAccessPolicy.requiresPro(
        viewing: outsideFreeWindow,
        relativeTo: today,
        calendar: calendar,
        isProActive: false
    ))
    #expect(!LocationHistoryAccessPolicy.requiresPro(
        viewing: outsideFreeWindow,
        relativeTo: today,
        calendar: calendar,
        isProActive: true
    ))
}

@Test func markdownExporterUsesCoordinatesWhenPlaceIsUnknown() {
    let date = isoDate("2100-01-02T00:00:00Z")
    let stay = StayRecord(
        arrivalAt: isoDate("2100-01-02T03:00:00Z"),
        departureAt: isoDate("2100-01-02T04:30:00Z"),
        coordinate: GeoCoordinate(latitude: 0.10200, longitude: 0.09900)
    )
    let exporter = markdownExporter()

    let markdown = exporter.render(date: date, stays: [stay])

    #expect(markdown.contains("未確定: 0.10200, 0.09900"))
    #expect(markdown.contains("| 03:00-04:30 |"))
    #expect(!markdown.contains("信頼度"))
    #expect(!markdown.contains("| low |"))
}

@Test func markdownExporterUsesDailyLocationFileName() {
    let date = isoDate("2100-01-02T00:00:00Z")
    let exporter = markdownExporter()

    #expect(exporter.fileName(for: date) == "2100-01-02-location.md")
}

@Test func markdownExporterUsesEnglishLabelsForEnglishLocale() {
    let date = isoDate("2100-01-02T00:00:00Z")
    let stay = StayRecord(
        arrivalAt: isoDate("2100-01-01T23:30:00Z"),
        departureAt: isoDate("2100-01-02T02:00:00Z"),
        coordinate: GeoCoordinate(latitude: 0.10200, longitude: 0.09900)
    )
    let exporter = MarkdownLocationExporter(
        locale: Locale(identifier: "en_US"),
        timeZone: utcTimeZone
    )

    let markdown = exporter.render(date: date, stays: [stay])

    #expect(markdown.contains("## Location Log"))
    #expect(markdown.contains("| Time | Entry | Duration |"))
    #expect(markdown.contains("Unknown: 0.10200, 0.09900"))
    #expect(markdown.contains("23:30 (previous day)-02:00"))
}

@Test func markdownExporterInterleavesMovementWithoutEndpointsOrDistance() {
    let date = isoDate("2100-01-02T00:00:00Z")
    let home = StayRecord(
        arrivalAt: isoDate("2100-01-02T01:00:00Z"),
        departureAt: isoDate("2100-01-02T02:00:00Z"),
        coordinate: GeoCoordinate(latitude: 0.10200, longitude: 0.09900),
        placeName: "地点A"
    )
    let office = StayRecord(
        arrivalAt: isoDate("2100-01-02T02:30:00Z"),
        departureAt: isoDate("2100-01-02T05:00:00Z"),
        coordinate: GeoCoordinate(latitude: 0.2000, longitude: 0.2000),
        placeName: "地点B"
    )
    let movement = MovementLogRecord(
        departureAt: isoDate("2100-01-02T02:00:00Z"),
        arrivalAt: isoDate("2100-01-02T02:30:00Z"),
        modeLabels: ["徒歩"]
    )

    let markdown = markdownExporter().render(
        date: date,
        stays: [office, home],
        movements: [movement]
    )

    let homeIndex = markdown.range(of: "| 01:00-02:00 | 地点A | 1h00m |")!.lowerBound
    let movementIndex = markdown.range(of: "| 02:00-02:30 | 移動（徒歩） | 30m |")!.lowerBound
    let officeIndex = markdown.range(of: "| 02:30-05:00 | 地点B | 2h30m |")!.lowerBound
    #expect(homeIndex < movementIndex)
    #expect(movementIndex < officeIndex)
    #expect(!markdown.contains("地点A → 地点B"))
    #expect(!markdown.contains("km"))
}

@Test func markdownExporterOmitsInvalidMovementInterval() {
    let date = isoDate("2100-01-02T00:00:00Z")
    let invalidMovement = MovementLogRecord(
        departureAt: isoDate("2100-01-02T03:00:00Z"),
        arrivalAt: isoDate("2100-01-02T03:00:00Z")
    )

    let markdown = markdownExporter().render(
        date: date,
        stays: [],
        movements: [invalidMovement]
    )

    #expect(!markdown.contains("| 移動 |"))
}

@Test func markdownExporterUsesEnglishMovementModes() {
    let date = isoDate("2100-01-02T00:00:00Z")
    let movement = MovementLogRecord(
        departureAt: isoDate("2100-01-02T02:00:00Z"),
        arrivalAt: isoDate("2100-01-02T02:30:00Z"),
        modeLabels: ["Walking", "Vehicle"]
    )
    let exporter = MarkdownLocationExporter(
        locale: Locale(identifier: "en_US"),
        timeZone: utcTimeZone
    )

    let markdown = exporter.render(
        date: date,
        stays: [],
        movements: [movement]
    )

    #expect(markdown.contains("| 02:00-02:30 | Movement (Walking, Vehicle) | 30m |"))
}

@Test func markdownExporterOmitsUnavailableMovementDuration() {
    let date = isoDate("2100-01-02T00:00:00Z")
    let movement = MovementLogRecord(
        departureAt: isoDate("2100-01-02T23:49:00Z"),
        arrivalAt: isoDate("2100-01-02T23:49:00Z"),
        modeLabels: ["徒歩"],
        timingKind: .unavailable
    )

    let markdown = markdownExporter().render(
        date: date,
        stays: [],
        movements: [movement]
    )

    #expect(markdown.contains("| 23:49頃 | 移動（徒歩） | — |"))
    #expect(!markdown.contains("| 0m |"))
}

@Test func markdownExporterUsesPedometerDurationDistanceAndSteps() {
    let date = isoDate("2100-01-17T00:00:00Z")
    let movement = MovementLogRecord(
        departureAt: isoDate("2100-01-17T23:20:00Z"),
        arrivalAt: isoDate("2100-01-17T23:30:00Z"),
        modeLabels: ["徒歩"],
        duration: 8 * 60 + 15,
        distanceMeters: 598,
        stepCount: 785
    )

    let markdown = markdownExporter().render(
        date: date,
        stays: [],
        movements: [movement]
    )

    #expect(markdown.contains(
        "| 23:20-23:30 | 移動（徒歩・約600 m・785歩） | 8m |"
    ))
}

@Test func markdownExporterKeepsUnknownMovementWhenVisitBoundariesOverlap() {
    let date = isoDate("2100-01-02T00:00:00Z")
    let movement = MovementLogRecord(
        departureAt: isoDate("2100-01-02T15:20:00Z"),
        arrivalAt: isoDate("2100-01-02T15:18:00Z"),
        timingKind: .unavailable
    )

    let markdown = markdownExporter().render(
        date: date,
        stays: [],
        movements: [movement]
    )

    #expect(markdown.contains("| 15:18頃 | 移動 | — |"))
}

@Test func markdownExporterShowsPlainCalculatedMovementDuration() {
    let date = isoDate("2100-01-02T00:00:00Z")
    let movement = MovementLogRecord(
        departureAt: isoDate("2100-01-02T02:00:00Z"),
        arrivalAt: isoDate("2100-01-02T02:30:00Z"),
        modeLabels: ["徒歩"],
        timingKind: .observedVisitGap,
        distanceMeters: 4_600,
        distanceIsStraightLineReference: true
    )

    let markdown = markdownExporter().render(
        date: date,
        stays: [],
        movements: [movement]
    )

    #expect(markdown.contains(
        "| 02:00-02:30 | 移動（徒歩・直線約4.6 km） | 30m |"
    ))
}

@Test func markdownExporterShowsPlainDurationForInferredDeparture() {
    let date = isoDate("2100-01-02T00:00:00Z")
    let movement = MovementLogRecord(
        departureAt: isoDate("2100-01-02T02:00:00Z"),
        arrivalAt: isoDate("2100-01-02T02:06:00Z"),
        timingKind: .inferredVisitGap
    )

    let markdown = markdownExporter().render(
        date: date,
        stays: [],
        movements: [movement]
    )

    #expect(markdown.contains("| 02:00-02:06 | 移動 | 6m |"))
}

@Test func markdownExporterPrefersPlaceNameOverAddress() {
    let date = isoDate("2100-01-02T00:00:00Z")
    let stay = StayRecord(
        arrivalAt: isoDate("2100-01-02T03:00:00Z"),
        coordinate: GeoCoordinate(latitude: 0.10200, longitude: 0.09900),
        placeName: "地点C",
        address: "テスト区域3"
    )

    let markdown = markdownExporter().render(date: date, stays: [stay])

    #expect(markdown.contains("| 地点C |"))
    #expect(!markdown.contains("テスト区域3"))
}

@Test func markdownExporterMarksPreviousDayStart() {
    let date = isoDate("2100-01-02T00:00:00Z")
    let stay = StayRecord(
        arrivalAt: isoDate("2100-01-01T23:30:00Z"),
        departureAt: isoDate("2100-01-02T02:00:00Z"),
        coordinate: GeoCoordinate(latitude: 0.10200, longitude: 0.09900),
        placeName: "地点A"
    )
    let exporter = markdownExporter()

    let markdown = exporter.render(date: date, stays: [stay])

    #expect(markdown.contains("| 23:30（前日）-02:00 |"))
}

@Test func markdownExporterMarksNextDayEnd() {
    let date = isoDate("2100-01-02T00:00:00Z")
    let stay = StayRecord(
        arrivalAt: isoDate("2100-01-02T23:30:00Z"),
        departureAt: isoDate("2100-01-03T02:00:00Z"),
        coordinate: GeoCoordinate(latitude: 0.10200, longitude: 0.09900),
        address: "テスト区域"
    )
    let exporter = markdownExporter()

    let markdown = exporter.render(date: date, stays: [stay])

    #expect(markdown.contains("| 23:30-02:00（翌日） |"))
}

@Test func markdownFileWriterOverwritesOnlyWhenRenderedContentChanges() throws {
    let directoryURL = FileManager.default.temporaryDirectory
        .appendingPathComponent(UUID().uuidString, isDirectory: true)
    try FileManager.default.createDirectory(at: directoryURL, withIntermediateDirectories: true)
    defer {
        try? FileManager.default.removeItem(at: directoryURL)
    }

    let outputURL = directoryURL.appendingPathComponent("2100-01-02-location.md")
    let originalMarkdown = "original"
    let updatedMarkdown = "updated with delayed visit"

    #expect(try MarkdownFileWriter.writeIfChanged(originalMarkdown, to: outputURL))
    #expect(try !MarkdownFileWriter.writeIfChanged(originalMarkdown, to: outputURL))
    #expect(try MarkdownFileWriter.writeIfChanged(updatedMarkdown, to: outputURL))
    #expect(try String(contentsOf: outputURL, encoding: .utf8) == updatedMarkdown)
}

@Test func confidenceChoosesMoreReliableValue() {
    #expect(PlaceConfidence.best(.low, .high) == .high)
    #expect(PlaceConfidence.best(.medium, .low) == .medium)
}

@Test func movementSummaryFallsBackToEndpointDistance() {
    let departure = isoDate("2100-01-02T03:00:00Z")
    let arrival = isoDate("2100-01-02T03:30:00Z")
    let origin = GeoCoordinate(latitude: 0.2000, longitude: 0.2000)
    let destination = GeoCoordinate(latitude: 0.1000, longitude: 0.1000)

    let summary = MovementSummaryBuilder.build(
        departureAt: departure,
        arrivalAt: arrival,
        origin: origin,
        destination: destination,
        points: []
    )

    #expect(summary != nil)
    #expect(summary?.distanceMeters ?? 0 > 6_000)
    #expect(summary?.duration == 1_800.0)
}

@Test func movementTimingInsideObservedGapCanBeDisplayed() {
    let departureAt = isoDate("2100-01-15T00:30:00Z")
    let destinationArrivalAt = isoDate("2100-01-15T01:03:00Z")
    let movement = DateInterval(
        start: departureAt.addingTimeInterval(30),
        end: destinationArrivalAt.addingTimeInterval(-30)
    )

    #expect(MovementDurationPolicy.isWithinObservedGap(
        movement,
        originDepartureAt: departureAt,
        destinationArrivalAt: destinationArrivalAt
    ))
}

@Test func movementStartingAtStayArrivalCannotCollapseStay() {
    let rawDepartureAt = isoDate("2100-01-15T00:30:00Z")
    let destinationArrivalAt = isoDate("2100-01-15T01:03:00Z")
    let erroneousMovement = DateInterval(
        start: isoDate("2100-01-14T22:58:00Z"),
        end: isoDate("2100-01-15T01:18:00Z")
    )

    #expect(!MovementDurationPolicy.isWithinObservedGap(
        erroneousMovement,
        originDepartureAt: rawDepartureAt,
        destinationArrivalAt: destinationArrivalAt
    ))
}

@Test func movementEndingAfterDestinationArrivalIsNotPresentationTiming() {
    let departureAt = isoDate("2100-01-15T00:30:00Z")
    let destinationArrivalAt = isoDate("2100-01-15T01:03:00Z")
    let movement = DateInterval(
        start: departureAt,
        end: destinationArrivalAt.addingTimeInterval(15 * 60)
    )

    #expect(!MovementDurationPolicy.isWithinObservedGap(
        movement,
        originDepartureAt: departureAt,
        destinationArrivalAt: destinationArrivalAt
    ))
}

@Test func movementTimingPresentationUsesDestinationLinkedSensorInsideVisitGap() {
    let departureAt = isoDate("2100-01-15T00:30:00Z")
    let destinationArrivalAt = isoDate("2100-01-15T01:03:00Z")
    let sensorInterval = DateInterval(
        start: departureAt.addingTimeInterval(30),
        end: destinationArrivalAt.addingTimeInterval(-30)
    )

    let resolution = MovementTimingPresentationPolicy.resolve(
        destinationLinkedSensorInterval: sensorInterval,
        originDepartureAt: departureAt,
        originDepartureIsObserved: true,
        destinationArrivalAt: destinationArrivalAt
    )

    #expect(resolution.kind == .measured)
    #expect(resolution.interval == sensorInterval)
}

@Test func movementTimingPresentationFallsBackToObservedGapWithoutDurationLimits() {
    let departureAt = isoDate("2100-01-15T00:30:00Z")
    let destinationArrivalAt = departureAt.addingTimeInterval(10 * 60 * 60)
    let broadSensorInterval = DateInterval(
        start: departureAt.addingTimeInterval(-30 * 60),
        end: destinationArrivalAt.addingTimeInterval(15 * 60)
    )

    let resolution = MovementTimingPresentationPolicy.resolve(
        destinationLinkedSensorInterval: broadSensorInterval,
        originDepartureAt: departureAt,
        originDepartureIsObserved: true,
        destinationArrivalAt: destinationArrivalAt
    )

    #expect(resolution.kind == .observedVisitGap)
    let expectedDuration: TimeInterval = 10 * 60 * 60
    #expect(abs((resolution.duration ?? -1) - expectedDuration) < 0.001)
}

@Test func movementTimingPresentationHidesDurationsThatRoundToFiveMinutesOrLess() {
    let departureAt = isoDate("2100-01-17T14:24:00Z")
    let destinationArrivalAt = departureAt.addingTimeInterval(5 * 60 + 29)

    let resolution = MovementTimingPresentationPolicy.resolve(
        destinationLinkedSensorInterval: nil,
        originDepartureAt: departureAt,
        originDepartureIsObserved: true,
        destinationArrivalAt: destinationArrivalAt
    )

    #expect(resolution.kind == .unavailable)
    #expect(resolution.duration == nil)
}

@Test func movementTimingPresentationShowsDurationsThatRoundToSixMinutes() {
    let departureAt = isoDate("2100-01-17T14:24:00Z")
    let destinationArrivalAt = departureAt.addingTimeInterval(5 * 60 + 30)

    let resolution = MovementTimingPresentationPolicy.resolve(
        destinationLinkedSensorInterval: nil,
        originDepartureAt: departureAt,
        originDepartureIsObserved: true,
        destinationArrivalAt: destinationArrivalAt
    )

    #expect(resolution.kind == .observedVisitGap)
    let expectedDuration: TimeInterval = 5 * 60 + 30
    #expect(abs((resolution.duration ?? -1) - expectedDuration) < 0.001)
}

@Test func movementTimingPresentationMarksInferredDepartureAsEstimatedGap() {
    let departureAt = isoDate("2100-01-16T09:13:00Z")
    let destinationArrivalAt = departureAt.addingTimeInterval(6 * 60 + 26)

    let resolution = MovementTimingPresentationPolicy.resolve(
        destinationLinkedSensorInterval: nil,
        originDepartureAt: departureAt,
        originDepartureIsObserved: false,
        destinationArrivalAt: destinationArrivalAt
    )

    #expect(resolution.kind == .inferredVisitGap)
    let expectedDuration: TimeInterval = 6 * 60 + 26
    #expect(abs((resolution.duration ?? -1) - expectedDuration) < 0.001)
}

@Test func movementTimingPresentationRequiresOrderedBoundaries() {
    let destinationArrivalAt = isoDate("2100-01-17T14:24:00Z")

    #expect(MovementTimingPresentationPolicy.resolve(
        destinationLinkedSensorInterval: nil,
        originDepartureAt: nil,
        originDepartureIsObserved: false,
        destinationArrivalAt: destinationArrivalAt
    ).kind == .unavailable)
    #expect(MovementTimingPresentationPolicy.resolve(
        destinationLinkedSensorInterval: nil,
        originDepartureAt: destinationArrivalAt,
        originDepartureIsObserved: true,
        destinationArrivalAt: destinationArrivalAt
    ).kind == .unavailable)
}

@Test func movementPresentationKeepsOrdinaryMovementWithoutTrackedPoints() {
    let evidence = MovementPresentationPolicy.evidence(
        origin: GeoCoordinate(latitude: 0.4968, longitude: 0.4961),
        destination: GeoCoordinate(latitude: 0.5020, longitude: 0.4900),
        originAccuracy: 10,
        destinationAccuracy: 30,
        excursionInterval: nil,
        points: []
    )

    #expect(evidence?.kind == .direct)
    #expect((evidence?.directDistanceMeters ?? 0) > 800)
}

@Test func movementPresentationRecognizesSamePlaceRoundTripFromReliablePoint() {
    let departureAt = isoDate("2100-01-28T08:00:00Z")
    let arrivalAt = departureAt.addingTimeInterval(15 * 60)
    let home = GeoCoordinate(latitude: 0.4968, longitude: 0.4961)
    let evidence = MovementPresentationPolicy.evidence(
        origin: home,
        destination: GeoCoordinate(latitude: 0.49681, longitude: 0.49609),
        originAccuracy: 10,
        destinationAccuracy: 10,
        excursionInterval: DateInterval(start: departureAt, end: arrivalAt),
        points: [
            MovementPoint(
                timestamp: departureAt.addingTimeInterval(5 * 60),
                coordinate: GeoCoordinate(latitude: 0.4960, longitude: 0.4900),
                horizontalAccuracy: 30
            ),
        ],
        containmentRadiusMeters: 100
    )

    #expect(evidence?.kind == .excursion)
    #expect((evidence?.directDistanceMeters ?? 1_000) < 10)
}

@Test func movementPresentationRejectsUnreliableOrOutOfIntervalExcursionPoints() {
    let departureAt = isoDate("2100-01-28T08:00:00Z")
    let arrivalAt = departureAt.addingTimeInterval(15 * 60)
    let home = GeoCoordinate(latitude: 0.4968, longitude: 0.4961)
    let away = GeoCoordinate(latitude: 0.4960, longitude: 0.4900)
    let interval = DateInterval(start: departureAt, end: arrivalAt)

    let inaccurate = MovementPresentationPolicy.evidence(
        origin: home,
        destination: home,
        originAccuracy: 10,
        destinationAccuracy: 10,
        excursionInterval: interval,
        points: [
            MovementPoint(
                timestamp: departureAt.addingTimeInterval(5 * 60),
                coordinate: away,
                horizontalAccuracy: 251
            ),
        ],
        containmentRadiusMeters: 100
    )
    let tooEarly = MovementPresentationPolicy.evidence(
        origin: home,
        destination: home,
        originAccuracy: 10,
        destinationAccuracy: 10,
        excursionInterval: interval,
        points: [
            MovementPoint(
                timestamp: departureAt.addingTimeInterval(-1),
                coordinate: away,
                horizontalAccuracy: 20
            ),
        ],
        containmentRadiusMeters: 100
    )

    #expect(inaccurate == nil)
    #expect(tooEarly == nil)
}

@Test func movementPresentationRequiresLeavingContainmentRadiusAndUsefulDuration() {
    let departureAt = isoDate("2100-01-28T08:00:00Z")
    let home = GeoCoordinate(latitude: 0.4968, longitude: 0.4961)
    let nearby = GeoCoordinate(latitude: 0.4965, longitude: 0.4955)
    let away = GeoCoordinate(latitude: 0.4960, longitude: 0.4900)
    let nearbyPoint = MovementPoint(
        timestamp: departureAt.addingTimeInterval(2 * 60),
        coordinate: nearby,
        horizontalAccuracy: 10
    )

    let insideRegisteredPlace = MovementPresentationPolicy.evidence(
        origin: home,
        destination: home,
        originAccuracy: 10,
        destinationAccuracy: 10,
        excursionInterval: DateInterval(
            start: departureAt,
            end: departureAt.addingTimeInterval(13 * 60)
        ),
        points: [nearbyPoint],
        containmentRadiusMeters: 100
    )
    let tooShort = MovementPresentationPolicy.evidence(
        origin: home,
        destination: home,
        originAccuracy: 10,
        destinationAccuracy: 10,
        excursionInterval: DateInterval(
            start: departureAt,
            end: departureAt.addingTimeInterval(5 * 60 + 29)
        ),
        points: [
            MovementPoint(
                timestamp: departureAt.addingTimeInterval(2 * 60),
                coordinate: away,
                horizontalAccuracy: 10
            ),
        ],
        containmentRadiusMeters: 25
    )

    #expect(insideRegisteredPlace == nil)
    #expect(tooShort == nil)
}

@Test func rawArrivalKeepsStayOnObservedCalendarDay() {
    let rawArrivalAt = isoDate("2100-01-20T14:54:00Z")
    let syntheticDayOne = DateInterval(
        start: isoDate("2100-01-19T15:00:00Z"),
        end: isoDate("2100-01-20T15:00:00Z")
    )
    let syntheticDayTwo = DateInterval(
        start: syntheticDayOne.end,
        end: isoDate("2100-01-21T15:00:00Z")
    )

    #expect(StayOverlapPolicy.overlaps(
        arrivalAt: rawArrivalAt,
        departureAt: isoDate("2100-01-22T02:48:00Z"),
        intervalStart: syntheticDayOne.start,
        intervalEnd: syntheticDayOne.end,
        now: isoDate("2100-01-22T08:00:00Z")
    ))
    #expect(StayOverlapPolicy.overlaps(
        arrivalAt: rawArrivalAt,
        departureAt: isoDate("2100-01-22T02:48:00Z"),
        intervalStart: syntheticDayTwo.start,
        intervalEnd: syntheticDayTwo.end,
        now: isoDate("2100-01-22T08:00:00Z")
    ))
}

@Test func pedometerChoosesTheFinalMeaningfulWalkingEpisode() {
    let evidence = PedestrianMovementPolicy.resolve(
        buckets: [
            PedometerMovementBucket(
                interval: DateInterval(
                    start: isoDate("2100-01-17T22:45:00Z"),
                    end: isoDate("2100-01-17T22:46:00Z")
                ),
                stepCount: 300,
                distanceMeters: 220,
                activeDuration: 52
            ),
            PedometerMovementBucket(
                interval: DateInterval(
                    start: isoDate("2100-01-17T22:46:00Z"),
                    end: isoDate("2100-01-17T22:47:00Z")
                ),
                stepCount: 300,
                distanceMeters: 220,
                activeDuration: 52
            ),
            PedometerMovementBucket(
                interval: DateInterval(
                    start: isoDate("2100-01-17T23:10:00Z"),
                    end: isoDate("2100-01-17T23:11:00Z")
                ),
                stepCount: 137,
                distanceMeters: 96,
                activeDuration: 50
            ),
            PedometerMovementBucket(
                interval: DateInterval(
                    start: isoDate("2100-01-17T23:20:00Z"),
                    end: isoDate("2100-01-17T23:25:00Z")
                ),
                stepCount: 434,
                distanceMeters: 329,
                activeDuration: 5 * 60
            ),
            PedometerMovementBucket(
                interval: DateInterval(
                    start: isoDate("2100-01-17T23:25:00Z"),
                    end: isoDate("2100-01-17T23:30:00Z")
                ),
                stepCount: 351,
                distanceMeters: 269,
                activeDuration: 3 * 60 + 15
            ),
        ],
        searchStart: isoDate("2100-01-17T22:40:00Z"),
        destinationAnchorAt: isoDate("2100-01-17T23:30:00Z"),
        directDistanceMeters: 500,
        combinedHorizontalAccuracy: 50
    )

    #expect(evidence?.interval.start == isoDate("2100-01-17T23:20:00Z"))
    #expect(evidence?.interval.end == isoDate("2100-01-17T23:30:00Z"))
    #expect(evidence?.stepCount == 785)
    #expect(evidence?.distanceMeters == 598)
    #expect(abs((evidence?.activeDuration ?? 0) - 495) < 0.001)
}

@Test func unfinishedCoreMotionTailDoesNotCreateMovementDuration() {
    let evidence = MovementFusionPolicy.resolveMotionEvidence(
        originArrivalAt: isoDate("2100-01-17T22:00:00Z"),
        destinationArrivalAt: isoDate("2100-01-17T23:30:00Z"),
        lastKnownInsideAt: isoDate("2100-01-17T23:00:00Z"),
        segments: [
            MotionMovementSegment(
                interval: DateInterval(
                    start: isoDate("2100-01-17T23:01:00Z"),
                    end: isoDate("2100-01-17T23:30:00Z")
                ),
                modeRawValue: "walking",
                confidence: 2,
                endIsObserved: false
            )
        ]
    )

    #expect(evidence == nil)
}

@Test func pedometerCanFinishShortlyAfterAnEarlyVisitArrival() {
    let rawArrival = isoDate("2100-01-17T23:27:00Z")
    let observedEnd = isoDate("2100-01-17T23:30:00Z")
    let evidence = PedestrianMovementPolicy.resolve(
        buckets: [
            PedometerMovementBucket(
                interval: DateInterval(
                    start: isoDate("2100-01-17T23:20:00Z"),
                    end: isoDate("2100-01-17T23:25:00Z")
                ),
                stepCount: 434,
                distanceMeters: 329,
                activeDuration: 5 * 60
            ),
            PedometerMovementBucket(
                interval: DateInterval(
                    start: isoDate("2100-01-17T23:25:00Z"),
                    end: observedEnd
                ),
                stepCount: 351,
                distanceMeters: 269,
                activeDuration: 3 * 60 + 15
            ),
        ],
        searchStart: isoDate("2100-01-17T23:00:00Z"),
        destinationAnchorAt: rawArrival,
        queryEndAt: rawArrival.addingTimeInterval(15 * 60),
        directDistanceMeters: 500,
        combinedHorizontalAccuracy: 50
    )

    #expect(evidence?.interval.end == observedEnd)
    #expect(evidence?.stepCount == 785)
}

@Test func movementSummaryUsesValidTrackedPointsOnly() {
    let departure = isoDate("2100-01-02T03:00:00Z")
    let arrival = isoDate("2100-01-02T04:00:00Z")
    let origin = GeoCoordinate(latitude: 0.2000, longitude: 0.2000)
    let destination = GeoCoordinate(latitude: 0.1500, longitude: 0.1500)
    let validPoint = MovementPoint(
        timestamp: isoDate("2100-01-02T03:20:00Z"),
        coordinate: GeoCoordinate(latitude: 0.1500, longitude: 0.1500),
        horizontalAccuracy: 80
    )
    let inaccuratePoint = MovementPoint(
        timestamp: isoDate("2100-01-02T03:40:00Z"),
        coordinate: GeoCoordinate(latitude: 0.9000, longitude: 0.9000),
        horizontalAccuracy: 2_000
    )

    let summary = MovementSummaryBuilder.build(
        departureAt: departure,
        arrivalAt: arrival,
        origin: origin,
        destination: destination,
        points: [inaccuratePoint, validPoint]
    )

    #expect(summary?.distanceMeters ?? 0 < 20_000)
}

@Test func movementSummaryPreservesChronologicalPathForUnsortedPoints() {
    let departure = isoDate("2100-01-02T03:00:00Z")
    let arrival = isoDate("2100-01-02T04:00:00Z")
    let origin = GeoCoordinate(latitude: 0.2000, longitude: 0.2000)
    let destination = GeoCoordinate(latitude: 0.1000, longitude: 0.1000)
    let earlierPoint = MovementPoint(
        timestamp: isoDate("2100-01-02T03:15:00Z"),
        coordinate: GeoCoordinate(latitude: 0.2200, longitude: 0.2050),
        horizontalAccuracy: 50
    )
    let laterPoint = MovementPoint(
        timestamp: isoDate("2100-01-02T03:45:00Z"),
        coordinate: GeoCoordinate(latitude: 0.2100, longitude: 0.1900),
        horizontalAccuracy: 50
    )

    let chronological = MovementSummaryBuilder.build(
        departureAt: departure,
        arrivalAt: arrival,
        origin: origin,
        destination: destination,
        points: [earlierPoint, laterPoint]
    )
    let unsorted = MovementSummaryBuilder.build(
        departureAt: departure,
        arrivalAt: arrival,
        origin: origin,
        destination: destination,
        points: [laterPoint, earlierPoint]
    )

    #expect(unsorted == chronological)
}

@Test func movementSummaryRejectsOverlappingStays() {
    let timestamp = isoDate("2100-01-02T03:00:00Z")
    let coordinate = GeoCoordinate(latitude: 0.2000, longitude: 0.2000)

    let summary = MovementSummaryBuilder.build(
        departureAt: timestamp,
        arrivalAt: timestamp,
        origin: coordinate,
        destination: coordinate,
        points: []
    )

    #expect(summary == nil)
}

@Test func movementFusionChoosesFinalContiguousMotionLeadingToArrival() {
    let originArrival = isoDate("2100-01-02T20:00:00Z")
    let destinationArrival = isoDate("2100-01-03T01:00:00Z")
    let evidence = MovementFusionPolicy.resolveMotionEvidence(
        originArrivalAt: originArrival,
        destinationArrivalAt: destinationArrival,
        lastKnownInsideAt: isoDate("2100-01-03T00:50:00Z"),
        segments: [
            MotionMovementSegment(
                interval: DateInterval(
                    start: isoDate("2100-01-02T22:00:00Z"),
                    end: isoDate("2100-01-02T22:20:00Z")
                ),
                modeRawValue: "walking",
                confidence: 2
            ),
            MotionMovementSegment(
                interval: DateInterval(
                    start: isoDate("2100-01-03T00:55:00Z"),
                    end: isoDate("2100-01-03T00:57:00Z")
                ),
                modeRawValue: "walking",
                confidence: 2
            ),
            MotionMovementSegment(
                interval: DateInterval(
                    start: isoDate("2100-01-03T00:58:00Z"),
                    end: destinationArrival
                ),
                modeRawValue: "vehicle",
                confidence: 1
            ),
        ]
    )

    #expect(evidence?.interval.start == isoDate("2100-01-03T00:55:00Z"))
    #expect(evidence?.interval.end == destinationArrival)
    #expect(evidence?.modeRawValues == ["walking", "vehicle"])
}

@Test func movementEvidenceCanStartBeforeADelayedVisitDeparture() {
    let originArrival = isoDate("2100-01-17T10:00:00Z")
    let destinationArrival = isoDate("2100-01-17T11:00:00Z")
    let delayedVisitDeparture = isoDate("2100-01-17T10:59:00Z")
    let actualMovementStart = isoDate("2100-01-17T10:48:00Z")

    let evidence = MovementFusionPolicy.resolveMotionEvidence(
        originArrivalAt: originArrival,
        destinationArrivalAt: destinationArrival,
        lastKnownInsideAt: isoDate("2100-01-17T10:45:00Z"),
        segments: [
            MotionMovementSegment(
                interval: DateInterval(
                    start: actualMovementStart,
                    end: destinationArrival
                ),
                modeRawValue: "walking",
                confidence: 2
            ),
        ]
    )

    #expect(evidence?.interval.start == actualMovementStart)
    #expect(evidence?.interval.start ?? delayedVisitDeparture < delayedVisitDeparture)
    #expect(abs((evidence?.interval.duration ?? 0) - 12 * 60) < 0.001)
}

@Test func movementFusionKeepsWholeTripAcrossABoundedTransferWait() {
    let originArrival = isoDate("2100-01-17T10:00:00Z")
    let destinationArrival = isoDate("2100-01-17T11:00:00Z")
    let evidence = MovementFusionPolicy.resolveMotionEvidence(
        originArrivalAt: originArrival,
        destinationArrivalAt: destinationArrival,
        lastKnownInsideAt: isoDate("2100-01-17T10:05:00Z"),
        segments: [
            MotionMovementSegment(
                interval: DateInterval(
                    start: isoDate("2100-01-17T10:10:00Z"),
                    end: isoDate("2100-01-17T10:42:00Z")
                ),
                modeRawValue: "vehicle",
                confidence: 2
            ),
            MotionMovementSegment(
                interval: DateInterval(
                    start: isoDate("2100-01-17T10:50:00Z"),
                    end: isoDate("2100-01-17T10:58:00Z")
                ),
                modeRawValue: "walking",
                confidence: 2
            ),
        ]
    )

    #expect(evidence?.interval.start == isoDate("2100-01-17T10:10:00Z"))
    #expect(evidence?.interval.end == isoDate("2100-01-17T10:58:00Z"))
    #expect(evidence?.modeRawValues == ["vehicle", "walking"])
}

@Test func movementFusionDoesNotPullUnrelatedEarlierActivityIntoTrip() {
    let originArrival = isoDate("2100-01-17T10:00:00Z")
    let destinationArrival = isoDate("2100-01-17T11:00:00Z")
    let evidence = MovementFusionPolicy.resolveMotionEvidence(
        originArrivalAt: originArrival,
        destinationArrivalAt: destinationArrival,
        lastKnownInsideAt: nil,
        segments: [
            MotionMovementSegment(
                interval: DateInterval(
                    start: isoDate("2100-01-17T10:05:00Z"),
                    end: isoDate("2100-01-17T10:15:00Z")
                ),
                modeRawValue: "vehicle",
                confidence: 2
            ),
            MotionMovementSegment(
                interval: DateInterval(
                    start: isoDate("2100-01-17T10:40:00Z"),
                    end: isoDate("2100-01-17T10:58:00Z")
                ),
                modeRawValue: "walking",
                confidence: 2
            ),
        ]
    )

    #expect(evidence?.interval.start == isoDate("2100-01-17T10:40:00Z"))
    #expect(evidence?.modeRawValues == ["walking"])
}

@Test func movementFusionUsesDominantModeAcrossWholeTrip() {
    let departure = isoDate("2100-01-03T00:00:00Z")
    let arrival = isoDate("2100-01-03T01:00:00Z")
    let evidence = MovementFusionPolicy.resolveTripEvidence(
        departureAt: departure,
        destinationArrivalAt: arrival,
        segments: [
            MotionMovementSegment(
                interval: DateInterval(
                    start: departure,
                    end: departure.addingTimeInterval(8 * 60)
                ),
                modeRawValue: "walking",
                confidence: 2
            ),
            MotionMovementSegment(
                interval: DateInterval(
                    start: departure.addingTimeInterval(12 * 60),
                    end: departure.addingTimeInterval(48 * 60)
                ),
                modeRawValue: "vehicle",
                confidence: 2
            ),
            MotionMovementSegment(
                interval: DateInterval(
                    start: departure.addingTimeInterval(50 * 60),
                    end: arrival
                ),
                modeRawValue: "walking",
                confidence: 2
            ),
        ]
    )

    #expect(evidence?.interval.start == departure)
    #expect(evidence?.interval.end == arrival)
    #expect(evidence?.modeRawValues == ["vehicle", "walking"])
}

@Test func movementFusionIgnoresShortAndLowConfidenceTripNoise() {
    let departure = isoDate("2100-01-03T00:00:00Z")
    let arrival = isoDate("2100-01-03T00:20:00Z")
    let evidence = MovementFusionPolicy.resolveTripEvidence(
        departureAt: departure,
        destinationArrivalAt: arrival,
        segments: [
            MotionMovementSegment(
                interval: DateInterval(
                    start: departure,
                    end: departure.addingTimeInterval(20)
                ),
                modeRawValue: "walking",
                confidence: 2
            ),
            MotionMovementSegment(
                interval: DateInterval(
                    start: departure.addingTimeInterval(60),
                    end: arrival
                ),
                modeRawValue: "vehicle",
                confidence: 0
            ),
        ]
    )

    #expect(evidence == nil)
}

@Test func longDistanceTripPrioritizesDetectedVehicleOverWalking() {
    let modes = MovementModeSelectionPolicy.prioritizedModeRawValues(
        detectedModes: ["walking", "vehicle"],
        directDistanceMeters: 35_000,
        tripDuration: 2 * 60 * 60
    )

    #expect(modes == ["vehicle", "walking"])
}

@Test func implausiblyFastWalkingTripInfersVehicleWithoutOverridingCycling() {
    #expect(MovementModeSelectionPolicy.prioritizedModeRawValues(
        detectedModes: ["walking"],
        directDistanceMeters: 8_000,
        tripDuration: 30 * 60
    ) == ["vehicle", "walking"])
    #expect(MovementModeSelectionPolicy.prioritizedModeRawValues(
        detectedModes: ["cycling"],
        directDistanceMeters: 8_000,
        tripDuration: 30 * 60
    ) == ["cycling"])
}

@Test func implausiblyClippedWalkingEvidenceRequestsAnEarlierSearch() {
    #expect(MovementModeSelectionPolicy.shouldExpandEvidenceSearch(
        detectedModes: ["walking"],
        directDistanceMeters: 501,
        tripDuration: 100
    ))
    #expect(!MovementModeSelectionPolicy.shouldExpandEvidenceSearch(
        detectedModes: ["walking"],
        directDistanceMeters: 402,
        tripDuration: 7 * 60
    ))
    #expect(!MovementModeSelectionPolicy.shouldExpandEvidenceSearch(
        detectedModes: ["vehicle"],
        directDistanceMeters: 501,
        tripDuration: 100
    ))
}

@Test func movementFusionRejectsStaleShortAndLowConfidenceMotion() {
    let originArrival = isoDate("2100-01-02T20:00:00Z")
    let destinationArrival = isoDate("2100-01-03T01:00:00Z")
    let evidence = MovementFusionPolicy.resolveMotionEvidence(
        originArrivalAt: originArrival,
        destinationArrivalAt: destinationArrival,
        lastKnownInsideAt: nil,
        segments: [
            MotionMovementSegment(
                interval: DateInterval(
                    start: isoDate("2100-01-02T23:00:00Z"),
                    end: isoDate("2100-01-02T23:10:00Z")
                ),
                modeRawValue: "vehicle",
                confidence: 2
            ),
            MotionMovementSegment(
                interval: DateInterval(
                    start: isoDate("2100-01-03T00:59:59Z"),
                    end: destinationArrival
                ),
                modeRawValue: "walking",
                confidence: 2
            ),
            MotionMovementSegment(
                interval: DateInterval(
                    start: isoDate("2100-01-03T00:55:00Z"),
                    end: destinationArrival
                ),
                modeRawValue: "cycling",
                confidence: 0
            ),
        ]
    )

    #expect(evidence == nil)
}

@Test func movementVisitFallbackRejectsImpossibleBoundaries() {
    let start = isoDate("2100-01-02T03:00:00Z")

    #expect(!MovementFusionPolicy.isPlausibleFallback(
        departureAt: start,
        arrivalAt: start.addingTimeInterval(4)
    ))
    #expect(!MovementFusionPolicy.isPlausibleFallback(
        departureAt: start,
        arrivalAt: start.addingTimeInterval(59)
    ))
    #expect(MovementFusionPolicy.isPlausibleFallback(
        departureAt: start,
        arrivalAt: start.addingTimeInterval(20 * 60)
    ))
    #expect(!MovementFusionPolicy.isPlausibleFallback(
        departureAt: start,
        arrivalAt: start.addingTimeInterval(5 * 60 * 60)
    ))
}

@Test func visitValidationDefersUntilDepartureArrives() {
    let arrivalAt = isoDate("2100-01-02T03:00:00Z")
    let evidence = StayValidationEvidence(
        arrivalAt: arrivalAt,
        departureAt: nil,
        coordinate: GeoCoordinate(latitude: 0.1000, longitude: 0.1000),
        horizontalAccuracy: 20
    )

    #expect(StayValidationPolicy.evaluate(evidence) == .deferDecision(.awaitingDeparture))
}

@Test func boundedCandidateWaitsForDelayedDepartureDuringGracePeriod() {
    let arrivalAt = isoDate("2100-01-02T03:00:00Z")
    let departureNotAfterAt = arrivalAt.addingTimeInterval(20 * 60)

    #expect(StayCandidateFinalizationPolicy.evaluateBoundedWithoutDeparture(
        arrivalAt: arrivalAt,
        departureNotAfterAt: departureNotAfterAt,
        evaluatedAt: departureNotAfterAt.addingTimeInterval(10 * 60 - 1)
    ) == .deferDecision(.awaitingDeparture))
}

@Test func boundedCandidateRejectsInsufficientEvidenceAfterGracePeriod() {
    let arrivalAt = isoDate("2100-01-02T03:00:00Z")
    let departureNotAfterAt = arrivalAt.addingTimeInterval(20 * 60)

    #expect(StayCandidateFinalizationPolicy.evaluateBoundedWithoutDeparture(
        arrivalAt: arrivalAt,
        departureNotAfterAt: departureNotAfterAt,
        evaluatedAt: departureNotAfterAt.addingTimeInterval(10 * 60)
    ) == .reject(.insufficientEvidence))
}

@Test func boundedCandidateRejectsImpossibleMinimumDurationAfterGracePeriod() {
    let arrivalAt = isoDate("2100-01-02T03:00:00Z")
    let departureNotAfterAt = arrivalAt.addingTimeInterval(9 * 60)

    #expect(StayCandidateFinalizationPolicy.evaluateBoundedWithoutDeparture(
        arrivalAt: arrivalAt,
        departureNotAfterAt: departureNotAfterAt,
        evaluatedAt: departureNotAfterAt.addingTimeInterval(10 * 60)
    ) == .reject(.belowMinimumDuration))
}

@Test func observedDepartureReopensAnyRejectionThatLackedObservedDeparture() {
    #expect(StayCandidateFinalizationPolicy.shouldReopenForLateDeparture(
        previousReason: .insufficientEvidence,
        hadObservedDeparture: false
    ))
    #expect(StayCandidateFinalizationPolicy.shouldReopenForLateDeparture(
        previousReason: .belowMinimumDuration,
        hadObservedDeparture: false
    ))
    #expect(StayCandidateFinalizationPolicy.shouldReopenForLateDeparture(
        previousReason: .locationRoutePassThroughV2,
        hadObservedDeparture: false
    ))
    #expect(!StayCandidateFinalizationPolicy.shouldReopenForLateDeparture(
        previousReason: .insufficientEvidence,
        hadObservedDeparture: true
    ))
}

@Test func observedDepartureAlwaysWinsOverInferredDeparture() {
    let arrivalAt = isoDate("2100-01-18T00:51:00Z")
    let inferredDepartureAt = arrivalAt.addingTimeInterval(2 * 60 + 50)
    let observedDepartureAt = arrivalAt.addingTimeInterval(60 * 60 + 23)

    #expect(StayDepartureSelectionPolicy.effectiveDepartureAt(
        observed: observedDepartureAt,
        inferred: inferredDepartureAt
    ) == observedDepartureAt)
    #expect(!StayDepartureSelectionPolicy.usesInferredDeparture(
        observed: observedDepartureAt,
        inferred: inferredDepartureAt
    ))
}

@Test func inferredDepartureIsUsedOnlyWhileObservedDepartureIsMissing() {
    let inferredDepartureAt = isoDate("2100-01-18T00:53:00Z")

    #expect(StayDepartureSelectionPolicy.effectiveDepartureAt(
        observed: nil,
        inferred: inferredDepartureAt
    ) == inferredDepartureAt)
    #expect(StayDepartureSelectionPolicy.usesInferredDeparture(
        observed: nil,
        inferred: inferredDepartureAt
    ))
}

@Test func completedObservedVisitSkipsFallbackBoundaryResolution() {
    #expect(!StayDepartureSelectionPolicy.requiresFallbackBoundaryResolution(
        hasObservedDeparture: true,
        hasTransitionBoundary: true,
        hasInferredDeparture: false,
        inferredFromNextCandidate: false
    ))
    #expect(StayDepartureSelectionPolicy.requiresFallbackBoundaryResolution(
        hasObservedDeparture: false,
        hasTransitionBoundary: true,
        hasInferredDeparture: false,
        inferredFromNextCandidate: false
    ))
}

@Test func candidateCannotReuseStayOwnedByADifferentVisitArrival() {
    let candidateArrivalAt = isoDate("2100-01-17T14:48:00Z")

    #expect(StayCandidateOwnershipPolicy.canReuseConfirmedStay(
        candidateArrivalAt: candidateArrivalAt,
        stayArrivalAt: candidateArrivalAt.addingTimeInterval(90),
        arrivalTolerance: 2 * 60
    ))
    #expect(!StayCandidateOwnershipPolicy.canReuseConfirmedStay(
        candidateArrivalAt: candidateArrivalAt,
        stayArrivalAt: candidateArrivalAt.addingTimeInterval(-57 * 60),
        arrivalTolerance: 2 * 60
    ))
}

@Test func observedVisitIdentityAbsorbsSmallArrivalAndCoordinateDrift() {
    let arrivalAt = isoDate("2100-01-27T00:10:00Z")
    let original = GeoCoordinate(latitude: 0.4000, longitude: 0.4000)
    let drifted = GeoCoordinate(latitude: 0.4007, longitude: 0.4000)

    #expect(ObservedVisitIdentityPolicy.representsSameVisit(
        existingArrivalAt: arrivalAt,
        existingCoordinate: original,
        incomingArrivalAt: arrivalAt.addingTimeInterval(4 * 60 + 54),
        incomingCoordinate: drifted
    ))
}

@Test func observedVisitIdentityDoesNotMergeBeyondTheDriftWindow() {
    let arrivalAt = isoDate("2100-01-27T00:10:00Z")
    let original = GeoCoordinate(latitude: 0.4000, longitude: 0.4000)
    let nearby = GeoCoordinate(latitude: 0.4007, longitude: 0.4000)
    let farther = GeoCoordinate(latitude: 0.4100, longitude: 0.4000)

    #expect(!ObservedVisitIdentityPolicy.representsSameVisit(
        existingArrivalAt: arrivalAt,
        existingCoordinate: original,
        incomingArrivalAt: arrivalAt.addingTimeInterval(5 * 60 + 1),
        incomingCoordinate: nearby
    ))
    #expect(!ObservedVisitIdentityPolicy.representsSameVisit(
        existingArrivalAt: arrivalAt,
        existingCoordinate: original,
        incomingArrivalAt: arrivalAt.addingTimeInterval(4 * 60 + 54),
        incomingCoordinate: farther
    ))
}

@Test func resolvedObservedVisitIdentityAlsoRequiresMatchingDeparture() {
    let arrivalAt = isoDate("2100-01-27T00:10:00Z")
    let departureAt = isoDate("2100-01-27T14:07:00Z")
    let original = GeoCoordinate(latitude: 0.4000, longitude: 0.4000)
    let drifted = GeoCoordinate(latitude: 0.4007, longitude: 0.4000)

    #expect(ObservedVisitIdentityPolicy.representsSameResolvedVisit(
        existingArrivalAt: arrivalAt,
        existingDepartureAt: departureAt,
        existingCoordinate: original,
        incomingArrivalAt: arrivalAt.addingTimeInterval(4 * 60 + 54),
        incomingDepartureAt: departureAt.addingTimeInterval(3 * 60 + 11),
        incomingCoordinate: drifted
    ))
    #expect(!ObservedVisitIdentityPolicy.representsSameResolvedVisit(
        existingArrivalAt: arrivalAt,
        existingDepartureAt: departureAt,
        existingCoordinate: original,
        incomingArrivalAt: arrivalAt.addingTimeInterval(4 * 60 + 54),
        incomingDepartureAt: departureAt.addingTimeInterval(5 * 60 + 1),
        incomingCoordinate: drifted
    ))
}

@Test func automaticDuplicateMergeNeverDeletesACandidateLinkedStay() {
    #expect(StayDuplicateMergePolicy.canAutomaticallyMerge(
        isLeftCandidateLinked: false,
        isRightCandidateLinked: false
    ))
    #expect(!StayDuplicateMergePolicy.canAutomaticallyMerge(
        isLeftCandidateLinked: true,
        isRightCandidateLinked: false
    ))
    #expect(!StayDuplicateMergePolicy.canAutomaticallyMerge(
        isLeftCandidateLinked: false,
        isRightCandidateLinked: true
    ))
    #expect(!StayDuplicateMergePolicy.canAutomaticallyMerge(
        isLeftCandidateLinked: true,
        isRightCandidateLinked: true
    ))
}

@Test func visitValidationRejectsShortCompletedVisit() {
    let arrivalAt = isoDate("2100-01-02T03:00:00Z")
    let evidence = StayValidationEvidence(
        arrivalAt: arrivalAt,
        departureAt: arrivalAt.addingTimeInterval(9 * 60),
        coordinate: GeoCoordinate(latitude: 0.1000, longitude: 0.1000),
        horizontalAccuracy: 20
    )

    #expect(StayValidationPolicy.evaluate(evidence) == .reject(.belowMinimumDuration))
}

@Test func visitValidationRejectsConflictingStay() {
    let arrivalAt = isoDate("2100-01-02T03:00:00Z")
    let evidence = StayValidationEvidence(
        arrivalAt: arrivalAt,
        departureAt: arrivalAt.addingTimeInterval(20 * 60),
        coordinate: GeoCoordinate(latitude: 0.1000, longitude: 0.1000),
        horizontalAccuracy: 20,
        overlapsConfirmedStay: true
    )

    #expect(StayValidationPolicy.evaluate(evidence) == .reject(.conflictingStay))
}

@Test func visitValidationRejectsShortVisitEmbeddedInContinuousRoute() {
    let arrivalAt = isoDate("2100-01-02T03:00:00Z")
    let departureAt = arrivalAt.addingTimeInterval(12 * 60)
    let evidence = StayValidationEvidence(
        arrivalAt: arrivalAt,
        departureAt: departureAt,
        coordinate: GeoCoordinate(latitude: 0.1000, longitude: 0.1000),
        horizontalAccuracy: 20,
        locationPoints: [
            MovementPoint(
                timestamp: arrivalAt.addingTimeInterval(2 * 60),
                coordinate: GeoCoordinate(latitude: 0.1000, longitude: 0.1000),
                horizontalAccuracy: 15
            ),
            MovementPoint(
                timestamp: arrivalAt.addingTimeInterval(9 * 60),
                coordinate: GeoCoordinate(latitude: 0.1050, longitude: 0.1000),
                horizontalAccuracy: 20
            ),
        ],
        motion: StayMotionEvidence(
            movingDuration: 9 * 60,
            stationaryDuration: 60
        ),
        evaluatedAt: departureAt.addingTimeInterval(10 * 60)
    )

    #expect(StayValidationPolicy.evaluate(evidence) == .reject(.locationRoutePassThroughV2))
}

@Test func observedCompletedVisitIsNotRejectedBySignificantLocationRouteEvidence() {
    let arrivalAt = isoDate("2100-01-18T00:51:00Z")
    let departureAt = arrivalAt.addingTimeInterval(12 * 60)
    let visitCoordinate = GeoCoordinate(latitude: 0.6000, longitude: 0.6000)
    let evidence = StayValidationEvidence(
        arrivalAt: arrivalAt,
        departureAt: departureAt,
        hasObservedDeparture: true,
        coordinate: visitCoordinate,
        horizontalAccuracy: 105,
        locationPoints: [
            MovementPoint(
                timestamp: arrivalAt.addingTimeInterval(2 * 60 + 50),
                coordinate: GeoCoordinate(latitude: 0.6010, longitude: 0.5990),
                horizontalAccuracy: 36
            ),
            MovementPoint(
                timestamp: arrivalAt.addingTimeInterval(7 * 60),
                coordinate: GeoCoordinate(latitude: 0.2040, longitude: 0.1980),
                horizontalAccuracy: 14
            ),
            MovementPoint(
                timestamp: arrivalAt.addingTimeInterval(11 * 60),
                coordinate: GeoCoordinate(latitude: 0.2015, longitude: 0.1990),
                horizontalAccuracy: 32
            ),
        ],
        routeContextPoints: [],
        motion: StayMotionEvidence(movingDuration: 12 * 60, stationaryDuration: 0),
        evaluatedAt: departureAt.addingTimeInterval(10 * 60)
    )

    #expect(StayValidationPolicy.evaluate(evidence) ==
        .confirm(.observedCompletedVisitRouteReviewed))
}

@Test func observedShortVisitWaitsForRouteContextBeforeFinalizing() {
    let arrivalAt = isoDate("2100-01-22T14:00:00Z")
    let departureAt = arrivalAt.addingTimeInterval(15 * 60)
    let evidence = StayValidationEvidence(
        arrivalAt: arrivalAt,
        departureAt: departureAt,
        hasObservedDeparture: true,
        coordinate: GeoCoordinate(latitude: 0.6020, longitude: 0.6010),
        horizontalAccuracy: 100,
        motion: StayMotionEvidence(movingDuration: 11 * 60, stationaryDuration: 0),
        evaluatedAt: departureAt.addingTimeInterval(5 * 60)
    )

    #expect(StayValidationPolicy.evaluate(evidence) ==
        .deferDecision(.awaitingRouteContext))
}

@Test func observedShortVisitEmbeddedInContinuingRouteIsRejected() {
    let arrivalAt = isoDate("2100-01-22T14:00:00Z")
    let departureAt = arrivalAt.addingTimeInterval(15 * 60)
    let evidence = StayValidationEvidence(
        arrivalAt: arrivalAt,
        departureAt: departureAt,
        hasObservedDeparture: true,
        coordinate: GeoCoordinate(latitude: 0.6020, longitude: 0.6010),
        horizontalAccuracy: 100,
        routeContextPoints: [
            MovementPoint(
                timestamp: arrivalAt.addingTimeInterval(-1),
                coordinate: GeoCoordinate(latitude: 0.6050, longitude: 0.6000),
                horizontalAccuracy: 18
            ),
            MovementPoint(
                timestamp: departureAt.addingTimeInterval(60),
                coordinate: GeoCoordinate(latitude: 0.6080, longitude: 0.6000),
                horizontalAccuracy: 45
            ),
            MovementPoint(
                timestamp: departureAt.addingTimeInterval(6 * 60),
                coordinate: GeoCoordinate(latitude: 0.6200, longitude: 0.6060),
                horizontalAccuracy: 24
            ),
        ],
        motion: StayMotionEvidence(movingDuration: 11 * 60, stationaryDuration: 0),
        evaluatedAt: departureAt.addingTimeInterval(10 * 60)
    )

    #expect(StayValidationPolicy.evaluate(evidence) ==
        .reject(.locationRoutePassThroughV2))
}

@Test func visitValidationDoesNotRejectMovingDominantMotionByItself() {
    let arrivalAt = isoDate("2100-01-02T03:00:00Z")
    let departureAt = arrivalAt.addingTimeInterval(15 * 60)
    let evidence = StayValidationEvidence(
        arrivalAt: arrivalAt,
        departureAt: departureAt,
        coordinate: GeoCoordinate(latitude: 0.1000, longitude: 0.1000),
        horizontalAccuracy: 20,
        motion: StayMotionEvidence(
            movingDuration: 10 * 60,
            stationaryDuration: 2 * 60,
            walkingDuration: 10 * 60
        ),
        evaluatedAt: departureAt.addingTimeInterval(10 * 60)
    )

    #expect(StayValidationPolicy.evaluate(evidence) ==
        .confirm(.completedVisitWithoutRouteContradictionV2))
}

@Test func adjacentVisitsAloneDoNotRejectNearbyCandidates() {
    let firstArrival = isoDate("2100-01-13T09:00:00Z")
    let firstDeparture = firstArrival.addingTimeInterval(20 * 60)
    let first = StayValidationEvidence(
        arrivalAt: firstArrival,
        departureAt: firstDeparture,
        coordinate: GeoCoordinate(latitude: 0.4012, longitude: 0.4015),
        horizontalAccuracy: 14,
        motion: StayMotionEvidence(
            movingDuration: 9 * 60,
            stationaryDuration: 1 * 60,
            walkingDuration: 5 * 60,
            automotiveDuration: 4 * 60
        ),
        evaluatedAt: firstDeparture.addingTimeInterval(10 * 60)
    )
    #expect(StayValidationPolicy.evaluate(first) ==
        .confirm(.completedVisitWithoutRouteContradictionV2))

    let secondArrival = firstDeparture.addingTimeInterval(60)
    let secondDeparture = secondArrival.addingTimeInterval(25 * 60)
    let second = StayValidationEvidence(
        arrivalAt: secondArrival,
        departureAt: secondDeparture,
        coordinate: GeoCoordinate(latitude: 0.4050, longitude: 0.4010),
        horizontalAccuracy: 50,
        motion: StayMotionEvidence(
            movingDuration: 5 * 60,
            stationaryDuration: 1 * 60,
            walkingDuration: 5 * 60
        ),
        evaluatedAt: secondDeparture.addingTimeInterval(10 * 60)
    )
    #expect(StayValidationPolicy.evaluate(second) ==
        .confirm(.completedVisitWithoutRouteContradictionV2))
}

@Test func completedShortVisitWaitsOnlyForBoundedRouteContext() {
    let arrival = isoDate("2100-01-02T02:45:00Z")
    let departure = isoDate("2100-01-02T03:00:00Z")
    let baseEvidence = StayValidationEvidence(
        arrivalAt: arrival,
        departureAt: departure,
        coordinate: GeoCoordinate(latitude: 0.1000, longitude: 0.1000),
        horizontalAccuracy: 20,
        evaluatedAt: departure.addingTimeInterval(10 * 60 - 1)
    )

    #expect(StayValidationPolicy.evaluate(baseEvidence) ==
        .deferDecision(.awaitingRouteContext))
    var finalizedEvidence = baseEvidence
    finalizedEvidence.evaluatedAt = departure.addingTimeInterval(10 * 60)
    #expect(StayValidationPolicy.evaluate(finalizedEvidence) ==
        .confirm(.completedVisitWithoutRouteContradictionV2))
}

@Test func visitValidationConfirmsStationaryShortStay() {
    let arrivalAt = isoDate("2100-01-02T03:00:00Z")
    let evidence = StayValidationEvidence(
        arrivalAt: arrivalAt,
        departureAt: arrivalAt.addingTimeInterval(15 * 60),
        coordinate: GeoCoordinate(latitude: 0.1000, longitude: 0.1000),
        horizontalAccuracy: 20,
        motion: StayMotionEvidence(
            movingDuration: 60,
            stationaryDuration: 10 * 60
        )
    )

    #expect(StayValidationPolicy.evaluate(evidence) == .confirm(.stationaryMotion))
}

@Test func visitValidationConfirmsStableShortStayWithoutMotionHistory() {
    let arrivalAt = isoDate("2100-01-02T03:00:00Z")
    let evidence = StayValidationEvidence(
        arrivalAt: arrivalAt,
        departureAt: arrivalAt.addingTimeInterval(15 * 60),
        coordinate: GeoCoordinate(latitude: 0.1000, longitude: 0.1000),
        horizontalAccuracy: 20,
        locationPoints: [
            MovementPoint(
                timestamp: arrivalAt.addingTimeInterval(2 * 60),
                coordinate: GeoCoordinate(latitude: 0.1001, longitude: 0.1001),
                horizontalAccuracy: 12
            ),
            MovementPoint(
                timestamp: arrivalAt.addingTimeInterval(9 * 60),
                coordinate: GeoCoordinate(latitude: 0.1003, longitude: 0.1002),
                horizontalAccuracy: 15
            ),
        ]
    )

    #expect(StayValidationPolicy.evaluate(evidence) == .confirm(.stableLocationCluster))
}

@Test func visitValidationTemporarilyDefersShortVisitForRouteContext() {
    let arrivalAt = isoDate("2100-01-02T03:00:00Z")
    let evidence = StayValidationEvidence(
        arrivalAt: arrivalAt,
        departureAt: arrivalAt.addingTimeInterval(15 * 60),
        coordinate: GeoCoordinate(latitude: 0.1000, longitude: 0.1000),
        horizontalAccuracy: 20
    )

    #expect(StayValidationPolicy.evaluate(evidence) == .deferDecision(.awaitingRouteContext))
}

@Test func visitValidationConfirmsLongVisitWithoutContradiction() {
    let arrivalAt = isoDate("2100-01-02T03:00:00Z")
    let evidence = StayValidationEvidence(
        arrivalAt: arrivalAt,
        departureAt: arrivalAt.addingTimeInterval(45 * 60),
        coordinate: GeoCoordinate(latitude: 0.1000, longitude: 0.1000),
        horizontalAccuracy: 20,
        hasSpatialTransitionBoundary: true
    )

    #expect(StayValidationPolicy.evaluate(evidence) == .confirm(.longVisitWithoutContradiction))
}

@Test func visitValidationConfirmsCompletedLongVisitWithoutExtraEvidence() {
    let arrivalAt = isoDate("2100-01-02T03:00:00Z")
    let evidence = StayValidationEvidence(
        arrivalAt: arrivalAt,
        departureAt: arrivalAt.addingTimeInterval(45 * 60),
        coordinate: GeoCoordinate(latitude: 0.1000, longitude: 0.1000),
        horizontalAccuracy: 20
    )

    #expect(StayValidationPolicy.evaluate(evidence) ==
        .confirm(.completedVisitWithoutRouteContradictionV2))
}

@Test func shortRouteNearRegisteredPlaceIsRejected() {
    let arrivalAt = isoDate("2100-01-10T10:00:00Z")
    let departureAt = arrivalAt.addingTimeInterval(15 * 60)
    let evidence = StayValidationEvidence(
        arrivalAt: arrivalAt,
        departureAt: departureAt,
        coordinate: GeoCoordinate(latitude: 0.5010, longitude: 0.5010),
        horizontalAccuracy: 22,
        routeContextPoints: [
            MovementPoint(
                timestamp: arrivalAt.addingTimeInterval(-60),
                coordinate: GeoCoordinate(latitude: 0.4970, longitude: 0.4960),
                horizontalAccuracy: 25
            ),
            MovementPoint(
                timestamp: arrivalAt.addingTimeInterval(5 * 60),
                coordinate: GeoCoordinate(latitude: 0.5008, longitude: 0.5008),
                horizontalAccuracy: 4
            ),
            MovementPoint(
                timestamp: departureAt.addingTimeInterval(60),
                coordinate: GeoCoordinate(latitude: 0.5050, longitude: 0.4990),
                horizontalAccuracy: 37
            ),
            MovementPoint(
                timestamp: departureAt.addingTimeInterval(6 * 60),
                coordinate: GeoCoordinate(latitude: 0.5300, longitude: 0.4800),
                horizontalAccuracy: 21
            ),
        ],
        motion: StayMotionEvidence(
            movingDuration: 9 * 60,
            stationaryDuration: 2 * 60
        ),
        hasSpatialTransitionBoundary: true,
        evaluatedAt: departureAt.addingTimeInterval(10 * 60)
    )

    #expect(StayValidationPolicy.evaluate(evidence) == .reject(.locationRoutePassThroughV2))
}

@Test func themeParkWalkingRemainsAStay() {
    let arrivalAt = isoDate("2100-01-02T03:00:00Z")
    let departureAt = arrivalAt.addingTimeInterval(3 * 60 * 60)
    let parkCenter = GeoCoordinate(latitude: 0.3000, longitude: 0.3000)
    let evidence = StayValidationEvidence(
        arrivalAt: arrivalAt,
        departureAt: departureAt,
        coordinate: parkCenter,
        horizontalAccuracy: 25,
        locationPoints: [
            MovementPoint(
                timestamp: arrivalAt.addingTimeInterval(20 * 60),
                coordinate: GeoCoordinate(latitude: 0.2990, longitude: 0.2980),
                horizontalAccuracy: 12
            ),
            MovementPoint(
                timestamp: arrivalAt.addingTimeInterval(150 * 60),
                coordinate: GeoCoordinate(latitude: 0.3020, longitude: 0.3030),
                horizontalAccuracy: 15
            ),
        ],
        motion: StayMotionEvidence(
            movingDuration: 2 * 60 * 60,
            stationaryDuration: 30 * 60
        ),
        hasSpatialTransitionBoundary: true,
        containmentCoordinate: parkCenter,
        containmentRadiusMeters: 600,
        evaluatedAt: departureAt.addingTimeInterval(10 * 60)
    )

    #expect(StayValidationPolicy.evaluate(evidence) ==
        .confirm(.longVisitWithoutContradiction))
}

@Test func movementInsideRegisteredPlaceDoesNotRejectStay() {
    let arrivalAt = isoDate("2100-01-02T03:00:00Z")
    let place = GeoCoordinate(latitude: 0.1000, longitude: 0.1000)
    let evidence = StayValidationEvidence(
        arrivalAt: arrivalAt,
        departureAt: arrivalAt.addingTimeInterval(45 * 60),
        coordinate: place,
        horizontalAccuracy: 20,
        locationPoints: [
            MovementPoint(
                timestamp: arrivalAt.addingTimeInterval(5 * 60),
                coordinate: GeoCoordinate(latitude: 0.0980, longitude: 0.1000),
                horizontalAccuracy: 10
            ),
            MovementPoint(
                timestamp: arrivalAt.addingTimeInterval(35 * 60),
                coordinate: GeoCoordinate(latitude: 0.1020, longitude: 0.1000),
                horizontalAccuracy: 10
            ),
        ],
        hasSpatialTransitionBoundary: true,
        containmentCoordinate: place,
        containmentRadiusMeters: 250
    )

    #expect(StayValidationPolicy.evaluate(evidence) == .confirm(.longVisitWithoutContradiction))
}

@Test func shortWalkingRouteInsideRegisteredPlaceRemainsAStay() {
    let arrivalAt = isoDate("2100-01-02T03:00:00Z")
    let departureAt = arrivalAt.addingTimeInterval(20 * 60)
    let parkCenter = GeoCoordinate(latitude: 0.3000, longitude: 0.3000)
    let evidence = StayValidationEvidence(
        arrivalAt: arrivalAt,
        departureAt: departureAt,
        coordinate: parkCenter,
        horizontalAccuracy: 20,
        routeContextPoints: [
            MovementPoint(
                timestamp: arrivalAt,
                coordinate: GeoCoordinate(latitude: 0.2980, longitude: 0.2970),
                horizontalAccuracy: 10
            ),
            MovementPoint(
                timestamp: departureAt.addingTimeInterval(60),
                coordinate: GeoCoordinate(latitude: 0.3030, longitude: 0.3030),
                horizontalAccuracy: 10
            ),
            MovementPoint(
                timestamp: departureAt.addingTimeInterval(6 * 60),
                coordinate: GeoCoordinate(latitude: 0.3040, longitude: 0.3040),
                horizontalAccuracy: 10
            ),
        ],
        motion: StayMotionEvidence(
            movingDuration: 15 * 60,
            stationaryDuration: 2 * 60
        ),
        containmentCoordinate: parkCenter,
        containmentRadiusMeters: 700,
        evaluatedAt: departureAt.addingTimeInterval(10 * 60)
    )

    #expect(StayValidationPolicy.evaluate(evidence) ==
        .confirm(.completedVisitWithoutRouteContradictionV2))
}

@Test func lastNearbyPointIsOnlyADepartureLowerBound() {
    let arrivalAt = isoDate("2100-01-02T03:00:00Z")
    let nextArrivalAt = arrivalAt.addingTimeInterval(70 * 60)
    let oldPlace = GeoCoordinate(latitude: 0.5000, longitude: 0.5000)
    let lastInside = StayCandidateTemporalPolicy.lastReliableNearbyAt(
        arrivalAt: arrivalAt,
        through: nextArrivalAt,
        coordinate: oldPlace,
        horizontalAccuracy: 75,
        locationPoints: [
            MovementPoint(
                timestamp: arrivalAt.addingTimeInterval(16 * 60),
                coordinate: GeoCoordinate(latitude: 0.5001, longitude: 0.5001),
                horizontalAccuracy: 19
            ),
            MovementPoint(
                timestamp: arrivalAt.addingTimeInterval(29 * 60),
                coordinate: GeoCoordinate(latitude: 0.5002, longitude: 0.5002),
                horizontalAccuracy: 8
            ),
            MovementPoint(
                timestamp: arrivalAt.addingTimeInterval(65 * 60),
                coordinate: GeoCoordinate(latitude: 0.4970, longitude: 0.4960),
                horizontalAccuracy: 17
            ),
        ]
    )

    #expect(lastInside == arrivalAt.addingTimeInterval(29 * 60))
}

@Test func missingNearbyPointDoesNotInventADepartureAtNextArrival() {
    let arrivalAt = isoDate("2100-01-02T03:00:00Z")
    let nextArrivalAt = arrivalAt.addingTimeInterval(20 * 60)
    let lastInside = StayCandidateTemporalPolicy.lastReliableNearbyAt(
        arrivalAt: arrivalAt,
        through: nextArrivalAt,
        coordinate: GeoCoordinate(latitude: 0.5000, longitude: 0.5000),
        horizontalAccuracy: 20,
        locationPoints: []
    )

    #expect(lastInside == nil)
}

@Test func finalMotionLeadingToNextVisitDeterminesDeparture() {
    let arrivalAt = isoDate("2100-01-02T03:00:00Z")
    let nextArrivalAt = arrivalAt.addingTimeInterval(70 * 60)
    let lastInside = arrivalAt.addingTimeInterval(29 * 60)
    let inferred = StayCandidateTemporalPolicy.inferredDepartureAtFromMotion(
        arrivalAt: arrivalAt,
        notAfter: nextArrivalAt,
        lastKnownInsideAt: lastInside,
        movingIntervals: [
            DateInterval(
                start: arrivalAt.addingTimeInterval(10 * 60),
                end: arrivalAt.addingTimeInterval(20 * 60)
            ),
            DateInterval(
                start: arrivalAt.addingTimeInterval(62 * 60),
                end: nextArrivalAt
            ),
        ]
    )

    #expect(inferred == arrivalAt.addingTimeInterval(62 * 60))
}

@Test func motionBeforeLastInsideCannotBecomeDeparture() {
    let arrivalAt = isoDate("2100-01-02T03:00:00Z")
    let nextArrivalAt = arrivalAt.addingTimeInterval(70 * 60)
    let inferred = StayCandidateTemporalPolicy.inferredDepartureAtFromMotion(
        arrivalAt: arrivalAt,
        notAfter: nextArrivalAt,
        lastKnownInsideAt: arrivalAt.addingTimeInterval(55 * 60),
        movingIntervals: [
            DateInterval(
                start: arrivalAt.addingTimeInterval(40 * 60),
                end: nextArrivalAt
            ),
        ]
    )

    #expect(inferred == nil)
}

@Test func sustainedOutsidePointsUseFirstOutsideObservation() {
    let arrivalAt = isoDate("2100-01-02T03:00:00Z")
    let oldPlace = GeoCoordinate(latitude: 0.5000, longitude: 0.5000)
    let firstOutsideAt = arrivalAt.addingTimeInterval(40 * 60)
    let inferred = StayCandidateTemporalPolicy.inferredDepartureAtFromSustainedLocation(
        arrivalAt: arrivalAt,
        through: arrivalAt.addingTimeInterval(45 * 60),
        coordinate: oldPlace,
        horizontalAccuracy: 20,
        locationPoints: [
            MovementPoint(
                timestamp: firstOutsideAt,
                coordinate: GeoCoordinate(latitude: 0.4962, longitude: 0.5000),
                horizontalAccuracy: 15
            ),
            MovementPoint(
                timestamp: arrivalAt.addingTimeInterval(44 * 60),
                coordinate: GeoCoordinate(latitude: 0.4960, longitude: 0.5000),
                horizontalAccuracy: 15
            ),
        ]
    )

    #expect(inferred == firstOutsideAt)
}

@Test func insideObservationResetsSustainedOutsideDepartureSequence() {
    let arrivalAt = isoDate("2100-01-18T00:51:00Z")
    let visitCoordinate = GeoCoordinate(latitude: 0.6000, longitude: 0.6000)
    let inferred = StayCandidateTemporalPolicy.inferredDepartureAtFromSustainedLocation(
        arrivalAt: arrivalAt,
        through: arrivalAt.addingTimeInterval(63 * 60 + 13),
        coordinate: visitCoordinate,
        horizontalAccuracy: 105,
        locationPoints: [
            MovementPoint(
                timestamp: arrivalAt.addingTimeInterval(2 * 60 + 50),
                coordinate: GeoCoordinate(latitude: 0.6010, longitude: 0.5990),
                horizontalAccuracy: 36
            ),
            MovementPoint(
                timestamp: arrivalAt.addingTimeInterval(9 * 60 + 24),
                coordinate: GeoCoordinate(latitude: 0.6008, longitude: 0.5990),
                horizontalAccuracy: 14
            ),
            MovementPoint(
                timestamp: arrivalAt.addingTimeInterval(63 * 60 + 13),
                coordinate: GeoCoordinate(latitude: 0.6012, longitude: 0.5988),
                horizontalAccuracy: 32
            ),
        ]
    )

    #expect(inferred == nil)
}

@Test func sparseButSustainedDepartureIsDetected() {
    let arrivalAt = isoDate("2100-01-02T03:00:00Z")
    let oldPlace = GeoCoordinate(latitude: 0.5000, longitude: 0.5000)
    let points = [
        MovementPoint(
            timestamp: arrivalAt.addingTimeInterval(29 * 60),
            coordinate: oldPlace,
            horizontalAccuracy: 8
        ),
        MovementPoint(
            timestamp: arrivalAt.addingTimeInterval(75 * 60),
            coordinate: GeoCoordinate(latitude: 0.4970, longitude: 0.4960),
            horizontalAccuracy: 17
        ),
        MovementPoint(
            timestamp: arrivalAt.addingTimeInterval(129 * 60),
            coordinate: GeoCoordinate(latitude: 0.4968, longitude: 0.4958),
            horizontalAccuracy: 12
        ),
    ]
    #expect(StayCandidateTemporalPolicy.hasSustainedDeparture(
        arrivalAt: arrivalAt,
        through: arrivalAt.addingTimeInterval(130 * 60),
        coordinate: oldPlace,
        horizontalAccuracy: 76,
        locationPoints: points
    ))
}

@Test func singleRemotePointDoesNotEndOngoingCandidate() {
    let arrivalAt = isoDate("2100-01-02T03:00:00Z")
    let oldPlace = GeoCoordinate(latitude: 0.5000, longitude: 0.5000)
    let points = [
        MovementPoint(
            timestamp: arrivalAt.addingTimeInterval(40 * 60),
            coordinate: GeoCoordinate(latitude: 0.4970, longitude: 0.4960),
            horizontalAccuracy: 17
        ),
    ]

    #expect(StayCandidateTemporalPolicy.hasSustainedDeparture(
        arrivalAt: arrivalAt,
        through: arrivalAt.addingTimeInterval(45 * 60),
        coordinate: oldPlace,
        horizontalAccuracy: 20,
        locationPoints: points
    ) == false)
}

@Test func multiDayStayOverlapsEveryIntermediateDay() {
    let arrivalAt = isoDate("2100-01-02T03:00:00Z")
    let departureAt = isoDate("2100-01-05T03:00:00Z")
    let middleDayStart = isoDate("2100-01-04T00:00:00Z")
    let middleDayEnd = isoDate("2100-01-05T00:00:00Z")

    #expect(StayOverlapPolicy.overlaps(
        arrivalAt: arrivalAt,
        departureAt: departureAt,
        intervalStart: middleDayStart,
        intervalEnd: middleDayEnd,
        now: departureAt
    ))
}

@Test func openCandidateRemainsVisibleOnItsPreviousDay() {
    let arrivalAt = isoDate("2100-01-11T14:30:00Z")
    let previousDayStart = isoDate("2100-01-11T00:00:00Z")
    let previousDayEnd = isoDate("2100-01-12T00:00:00Z")
    let now = isoDate("2100-01-12T03:00:00Z")

    #expect(StayOverlapPolicy.overlaps(
        arrivalAt: arrivalAt,
        departureAt: nil,
        intervalStart: previousDayStart,
        intervalEnd: previousDayEnd,
        now: now
    ))
}

@Test func stayBootstrapAcceptsOnlyFreshAccurateLocations() {
    let now = isoDate("2100-01-20T11:00:00Z")

    #expect(StayBootstrapPolicy.canUseLocation(
        timestamp: now.addingTimeInterval(-60),
        horizontalAccuracy: 35,
        evaluatedAt: now
    ))
    #expect(!StayBootstrapPolicy.canUseLocation(
        timestamp: now.addingTimeInterval(-6 * 60),
        horizontalAccuracy: 35,
        evaluatedAt: now
    ))
    #expect(!StayBootstrapPolicy.canUseLocation(
        timestamp: now,
        horizontalAccuracy: 300,
        evaluatedAt: now
    ))
}

@Test func stayBootstrapReusesOnlyNearbyPlace() {
    let origin = GeoCoordinate(latitude: 0.2000, longitude: 0.2000)
    let nearby = GeoCoordinate(latitude: 0.2006, longitude: 0.2000)
    let distant = GeoCoordinate(latitude: 0.2100, longitude: 0.1800)

    #expect(StayBootstrapPolicy.representsSamePlace(origin, nearby))
    #expect(!StayBootstrapPolicy.representsSamePlace(origin, distant))
}

@Test func observedVisitPromotesBootstrapInsideVisitInterval() {
    let arrivalAt = isoDate("2100-01-20T09:00:00Z")
    let departureAt = isoDate("2100-01-20T11:30:00Z")
    let coordinate = GeoCoordinate(latitude: 0.2000, longitude: 0.2000)

    #expect(StayBootstrapPolicy.canPromoteToObservedVisit(
        bootstrapArrivalAt: isoDate("2100-01-20T10:00:00Z"),
        bootstrapCoordinate: coordinate,
        observedArrivalAt: arrivalAt,
        observedDepartureAt: departureAt,
        observedCoordinate: coordinate
    ))
    #expect(!StayBootstrapPolicy.canPromoteToObservedVisit(
        bootstrapArrivalAt: isoDate("2100-01-20T12:00:00Z"),
        bootstrapCoordinate: coordinate,
        observedArrivalAt: arrivalAt,
        observedDepartureAt: departureAt,
        observedCoordinate: coordinate
    ))
}

@Test func initialLocationBootstrapRunsOnlyBeforeAnyStayOrCandidateExists() {
    #expect(StayBootstrapPolicy.shouldRequestInitialLocation(
        hasRecordedStay: false,
        hasCandidate: false
    ))
    #expect(!StayBootstrapPolicy.shouldRequestInitialLocation(
        hasRecordedStay: true,
        hasCandidate: false
    ))
    #expect(!StayBootstrapPolicy.shouldRequestInitialLocation(
        hasRecordedStay: false,
        hasCandidate: true
    ))
}

@Test func bootstrapCandidateRejectsMovingWithoutPositiveStayEvidence() {
    let arrivalAt = isoDate("2100-01-20T09:00:00Z")
    let departureAt = arrivalAt.addingTimeInterval(20 * 60)
    let evidence = StayValidationEvidence(
        arrivalAt: arrivalAt,
        departureAt: departureAt,
        coordinate: GeoCoordinate(latitude: 0.2000, longitude: 0.2000),
        horizontalAccuracy: 20,
        motion: StayMotionEvidence(
            movingDuration: 15 * 60,
            stationaryDuration: 60,
            automotiveDuration: 15 * 60
        ),
        requiresPositiveStayEvidence: true,
        evaluatedAt: departureAt.addingTimeInterval(10 * 60)
    )

    #expect(StayValidationPolicy.evaluate(evidence) == .reject(.movingDominantMotion))
}

@Test func bootstrapCandidateStillConfirmsStationaryEvidence() {
    let arrivalAt = isoDate("2100-01-20T09:00:00Z")
    let evidence = StayValidationEvidence(
        arrivalAt: arrivalAt,
        departureAt: arrivalAt.addingTimeInterval(20 * 60),
        coordinate: GeoCoordinate(latitude: 0.2000, longitude: 0.2000),
        horizontalAccuracy: 20,
        motion: StayMotionEvidence(
            movingDuration: 60,
            stationaryDuration: 15 * 60
        ),
        requiresPositiveStayEvidence: true
    )

    #expect(StayValidationPolicy.evaluate(evidence) == .confirm(.stationaryMotion))
}

@Test func proTrialIsNotStartedWithoutAStartDate() {
    let now = isoDate("2100-01-26T03:00:00Z")

    #expect(
        ProTrialAccessPolicy.status(startedAt: nil, relativeTo: now)
            == .notStarted
    )
}

@Test func proTrialExpiresAtExactlySevenDays() {
    let startedAt = isoDate("2100-01-26T03:00:00Z")
    let expirationDate = startedAt.addingTimeInterval(
        ProTrialAccessPolicy.duration
    )

    #expect(
        ProTrialAccessPolicy.status(
            startedAt: startedAt,
            relativeTo: expirationDate.addingTimeInterval(-1)
        ) == .active(expiresAt: expirationDate)
    )
    #expect(
        ProTrialAccessPolicy.status(
            startedAt: startedAt,
            relativeTo: expirationDate
        ) == .expired(expiresAt: expirationDate)
    )
}

@Test func proTrialReminderNotificationIsNextCalendarDayAtTen() throws {
    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = try #require(TimeZone(identifier: "UTC"))
    let expirationDate = isoDate("2100-01-29T14:30:00Z")
    let notificationDate = try #require(
        ProTrialAccessPolicy.reminderNotificationDate(
            forExpirationDate: expirationDate,
            calendar: calendar
        )
    )
    let components = calendar.dateComponents(
        [.year, .month, .day, .hour, .minute],
        from: notificationDate
    )

    #expect(components.year == 2100)
    #expect(components.month == 1)
    #expect(components.day == 30)
    #expect(components.hour == 10)
    #expect(components.minute == 0)
}
