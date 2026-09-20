import Foundation
import SwiftData
#if canImport(SilicaCore)
import SilicaCore
#endif

enum ExportDestination: String {
    case obsidian
    case notion
}

struct ExportResult {
    let outputURL: URL
    let didWrite: Bool
}

extension Notification.Name {
    static let silicaLocationDataDidChange = Notification.Name(
        "com.fujimakitaketo.silica.location-data-did-change"
    )
}

enum LocationDataChangeUserInfo {
    static let affectedDates = "affectedDates"
}

enum ExportService {
    static let vaultBookmarkKey = "vaultBookmark"
    static let automaticExportEnabledKey = "automaticExportEnabled"
    static let automaticExportFirstDateKey = "automaticExportFirstDate"
    static let automaticExportNotificationsEnabledKey =
        "automaticExportNotificationsEnabled"
    static let automaticExportLastNotifiedDateKeyPrefix =
        "automaticExportLastNotifiedDate"
    static let selectedDestinationKey = "selectedExportDestination"

    static func automaticExportLastNotifiedDateKey(
        destination: ExportDestination
    ) -> String {
        "\(automaticExportLastNotifiedDateKeyPrefix).\(destination.rawValue)"
    }

    fileprivate struct Content {
        let stays: [StayRecord]
        let movements: [MovementLogRecord]

        func markdown(date: Date) -> String {
            let dayInterval = DateSupport.dayInterval(containing: date)
            let now = Date()
            let dayStays = stays.filter { stay in
                DateSupport.overlaps(
                    arrivalAt: stay.arrivalAt,
                    departureAt: stay.departureAt,
                    dayInterval: dayInterval,
                    now: now
                )
            }
            let dayMovements = movements.filter { movement in
                DateSupport.overlaps(
                    arrivalAt: movement.departureAt,
                    departureAt: movement.arrivalAt,
                    dayInterval: dayInterval,
                    now: now
                )
            }
            return MarkdownLocationExporter(locale: AppLanguage.currentLocale)
                .render(date: date, stays: dayStays, movements: dayMovements)
        }
    }

    static func bookmarkData(forFolderURL folderURL: URL) throws -> Data {
        try withSecurityScopedAccess(to: folderURL) {
            try folderURL.bookmarkData(
                options: .minimalBookmark,
                includingResourceValuesForKeys: nil,
                relativeTo: nil
            )
        }
    }

    static func markdown(
        date: Date,
        stays: [StayEntity],
        aliases: [PlaceAliasEntity],
        movementPoints: [MovementPointEntity] = []
    ) -> String {
        prepareContent(
            sortedStays: stays.sorted { $0.arrivalAt < $1.arrivalAt },
            aliases: aliases,
            movementPoints: movementPoints.map(\.corePoint),
            dayInterval: DateSupport.dayInterval(containing: date)
        ).markdown(date: date)
    }

    static func markdown(
        date: Date,
        stays: [StayEntity],
        aliases: [PlaceAliasEntity],
        modelContext: ModelContext
    ) -> String {
        markdown(
            date: date,
            stays: stays,
            aliases: aliases,
            movementPoints: movementPoints(
                relevantTo: DateSupport.dayInterval(containing: date),
                stays: stays,
                modelContext: modelContext
            )
        )
    }

    private static func prepareContent(
        sortedStays: [StayEntity],
        aliases: [PlaceAliasEntity],
        movementPoints: [MovementPoint],
        dayInterval: DateInterval? = nil
    ) -> Content {
        let now = Date()
        let resolvedStays = sortedStays.compactMap { stay -> StayRecord? in
            if let dayInterval,
               !DateSupport.overlaps(arrivalAt: stay.arrivalAt, departureAt: stay.departureAt,
                                     dayInterval: dayInterval, now: now) {
                return nil
            }
            return StayResolution.resolvedRecord(for: stay, aliases: aliases)
        }
        let movements = zip(sortedStays, sortedStays.dropFirst())
            .compactMap { origin, destination -> MovementLogRecord? in
                let evidenceMatchesDestination = origin
                    .movementEvidenceMatches(destinationID: destination.id)
                let linkedSensorInterval = origin.storedMovementInterval.flatMap { interval in
                    evidenceMatchesDestination &&
                        origin.movementTimingSource.isSensorDerived
                        ? interval
                        : nil
                }
                let timing = MovementTimingPresentationPolicy.resolve(
                    destinationLinkedSensorInterval: linkedSensorInterval,
                    originDepartureAt: origin.departureAt,
                    originDepartureIsObserved:
                        origin.departureSourceRawValue !=
                            StayDepartureSource.inferredCandidate.rawValue,
                    destinationArrivalAt: destination.arrivalAt
                )
                // Keep adjacency across midnight, but skip unrelated days before
                // resolving aliases and scanning movement-point evidence.
                if let dayInterval,
                   !DateSupport.overlaps(
                    arrivalAt: timing.interval?.start ?? destination.arrivalAt,
                    departureAt: timing.interval?.end ?? destination.arrivalAt,
                    dayInterval: dayInterval, now: now
                   ) {
                    return nil
                }
                let excursionInterval: DateInterval? = switch timing.kind {
                case .measured, .observedVisitGap:
                    timing.interval
                case .inferredVisitGap, .unavailable:
                    nil
                }
                let sharedContainmentRadius = StayResolution.sharedRegisteredPlaceRadius(
                    from: origin.coordinate,
                    to: destination.coordinate,
                    aliases: aliases
                )
                guard let pathEvidence = MovementPresentationPolicy.evidence(
                    origin: origin.coordinate,
                    destination: destination.coordinate,
                    originAccuracy: origin.horizontalAccuracy,
                    destinationAccuracy: destination.horizontalAccuracy,
                    excursionInterval: excursionInterval,
                    points: movementPoints,
                    containmentRadiusMeters: sharedContainmentRadius
                ) else {
                    return nil
                }
                let movementInterval = timing.interval
                let chronologyStart = movementInterval?.start ?? destination.arrivalAt
                let chronologyEnd = movementInterval?.end ?? destination.arrivalAt
                let measuredDistance = timing.kind == .measured
                    ? origin.movementDistanceMeters
                    : nil
                let hasMeasuredExcursionDistance = pathEvidence.kind == .excursion &&
                    measuredDistance != nil &&
                    origin.movementDistanceSource != .straightLineReference &&
                    origin.movementDistanceSource != .unavailable
                let distanceMeters: Double? = switch pathEvidence.kind {
                case .direct:
                    measuredDistance ?? pathEvidence.directDistanceMeters
                case .excursion:
                    hasMeasuredExcursionDistance ? measuredDistance : nil
                }
                let distanceSource: MovementDistanceSource = if measuredDistance != nil &&
                    (pathEvidence.kind == .direct || hasMeasuredExcursionDistance) {
                    origin.movementDistanceSource
                } else if pathEvidence.kind == .direct {
                    .straightLineReference
                } else {
                    .unavailable
                }
                return MovementLogRecord(
                    departureAt: chronologyStart,
                    arrivalAt: chronologyEnd,
                    modeLabels: evidenceMatchesDestination
                        ? origin.movementModes.map(\.label)
                        : [],
                    timingKind: timing.kind,
                    duration: timing.kind == .measured
                        ? origin.movementDisplayDuration
                        : timing.duration,
                    distanceMeters: distanceMeters,
                    stepCount: timing.kind == .measured
                        ? origin.movementStepCount
                        : nil,
                    distanceIsStraightLineReference:
                        distanceSource != .pedometer && distanceSource != .locationRoute
                )
            }
        return Content(stays: resolvedStays, movements: movements)
    }

    fileprivate static func prepareContent(
        for dates: [Date],
        modelContext: ModelContext
    ) -> Content {
        guard let firstDate = dates.min(), let lastDate = dates.max() else {
            return Content(stays: [], movements: [])
        }
        let dayInterval = DateInterval(
            start: DateSupport.dayInterval(containing: firstDate).start,
            end: DateSupport.dayInterval(containing: lastDate).end
        )
        // Keep all stay adjacency, including a trip that crosses midnight, but
        // load points and resolve records only for the requested date range.
        let stays = (try? modelContext.fetch(
            FetchDescriptor<StayEntity>(
                sortBy: [SortDescriptor(\.arrivalAt, order: .forward)]
            )
        )) ?? []
        let aliases = (try? modelContext.fetch(
            FetchDescriptor<PlaceAliasEntity>(
                sortBy: [SortDescriptor(\.priority, order: .reverse)]
            )
        )) ?? []
        let movementPoints = movementPoints(
            relevantTo: dayInterval,
            stays: stays,
            modelContext: modelContext
        ).map(\.corePoint)
        return prepareContent(
            sortedStays: stays,
            aliases: aliases,
            movementPoints: movementPoints,
            dayInterval: dayInterval
        )
    }

    @discardableResult
    static func exportFromBookmark(
        date: Date,
        vaultBookmarkData: Data,
        stays: [StayEntity],
        aliases: [PlaceAliasEntity],
        modelContext: ModelContext,
        skipIfUnchanged: Bool = false
    ) throws -> URL {
        try exportFromBookmarkResult(
            date: date,
            vaultBookmarkData: vaultBookmarkData,
            markdown: markdown(
                date: date,
                stays: stays,
                aliases: aliases,
                modelContext: modelContext
            ),
            modelContext: modelContext,
            skipIfUnchanged: skipIfUnchanged
        ).outputURL
    }

    private static func movementPoints(
        relevantTo dayInterval: DateInterval,
        stays: [StayEntity],
        modelContext: ModelContext
    ) -> [MovementPointEntity] {
        let sortedStays = stays.sorted { $0.arrivalAt < $1.arrivalAt }
        var pointStart = dayInterval.start
        var pointEnd = dayInterval.end

        for (origin, destination) in zip(sortedStays, sortedStays.dropFirst()) {
            guard let departureAt = origin.departureAt,
                  departureAt < dayInterval.end,
                  destination.arrivalAt >= dayInterval.start else {
                continue
            }
            pointStart = min(pointStart, departureAt)
            pointEnd = max(pointEnd, destination.arrivalAt)
        }

        let descriptor = FetchDescriptor<MovementPointEntity>(
            predicate: #Predicate { point in
                point.timestamp >= pointStart && point.timestamp <= pointEnd
            },
            sortBy: [SortDescriptor(\.timestamp, order: .forward)]
        )
        return (try? modelContext.fetch(descriptor)) ?? []
    }

    @discardableResult
    private static func exportFromBookmarkResult(
        date: Date,
        vaultBookmarkData: Data,
        markdown: String,
        modelContext: ModelContext,
        skipIfUnchanged: Bool = false
    ) throws -> ExportResult {
        do {
            let folderURL = try folderURL(from: vaultBookmarkData)
            let result = try withSecurityScopedAccess(to: folderURL) {
                let fileName = MarkdownLocationExporter(locale: AppLanguage.currentLocale)
                    .fileName(for: date)
                let outputURL = folderURL.appendingPathComponent(fileName)
                let didWrite: Bool
                if skipIfUnchanged {
                    didWrite = try MarkdownFileWriter.writeIfChanged(
                        markdown,
                        to: outputURL
                    )
                } else {
                    try markdown.write(
                        to: outputURL,
                        atomically: true,
                        encoding: .utf8
                    )
                    didWrite = true
                }
                return (outputURL: outputURL, didWrite: didWrite)
            }
            if result.didWrite {
                insertExportRecord(
                    date: date,
                    filePath: result.outputURL.path,
                    status: .success,
                    modelContext: modelContext
                )
                try? modelContext.save()
            }
            return ExportResult(
                outputURL: result.outputURL,
                didWrite: result.didWrite
            )
        } catch {
            insertExportRecord(
                date: date,
                filePath: "",
                status: .failed,
                errorMessage: error.localizedDescription,
                modelContext: modelContext
            )
            try? modelContext.save()
            throw error
        }
    }

    @discardableResult
    fileprivate static func exportDateFromStoredBookmarkIfNeeded(
        date: Date,
        content: Content,
        modelContext: ModelContext
    ) -> Bool {
        let defaults = UserDefaults.standard
        let isAutomaticExportEnabled = defaults.object(forKey: automaticExportEnabledKey) as? Bool ?? true
        guard isAutomaticExportEnabled else {
            return false
        }
        let selectedDestination = ExportDestination(
            rawValue: defaults.string(forKey: selectedDestinationKey)
                ?? ExportDestination.obsidian.rawValue
        ) ?? .obsidian
        guard selectedDestination == .obsidian else {
            return false
        }

        guard let vaultBookmarkData = defaults.data(forKey: vaultBookmarkKey) else {
            return false
        }

        return (try? exportFromBookmarkResult(
            date: date,
            vaultBookmarkData: vaultBookmarkData,
            markdown: content.markdown(date: date),
            modelContext: modelContext,
            skipIfUnchanged: true
        ).didWrite) ?? false
    }

    private static func folderURL(from vaultBookmarkData: Data) throws -> URL {
        var stale = false
        return try URL(
            resolvingBookmarkData: vaultBookmarkData,
            options: [],
            relativeTo: nil,
            bookmarkDataIsStale: &stale
        )
    }

    private static func withSecurityScopedAccess<T>(
        to url: URL,
        operation: () throws -> T
    ) rethrows -> T {
        let didAccess = url.startAccessingSecurityScopedResource()
        defer {
            if didAccess {
                url.stopAccessingSecurityScopedResource()
            }
        }
        return try operation()
    }

    @discardableResult
    static func insertExportRecord(
        date: Date,
        filePath: String,
        status: ExportStatus,
        errorMessage: String? = nil,
        modelContext: ModelContext
    ) -> ExportRecordEntity {
        let record = ExportRecordEntity(
            date: date,
            filePath: filePath,
            status: status,
            errorMessage: errorMessage
        )
        modelContext.insert(record)
        return record
    }
}

@MainActor
enum AutomaticExportService {
    static func runYesterdayIfNeeded(
        modelContext: ModelContext,
        notionStore: SilicaNotionStore,
        isProActive: Bool
    ) async {
        let calendar = Calendar.current
        let today = calendar.startOfDay(for: Date())
        guard let yesterday = calendar.date(byAdding: .day, value: -1, to: today) else {
            return
        }
        await runDatesIfNeeded(
            [yesterday],
            modelContext: modelContext,
            notionStore: notionStore,
            isProActive: isProActive
        )
    }

    static func runDatesIfNeeded(
        _ dates: [Date],
        modelContext: ModelContext,
        notionStore: SilicaNotionStore,
        isProActive: Bool
    ) async {
        let calendar = Calendar.current
        let defaults = UserDefaults.standard
        let isEnabled = defaults.object(
            forKey: ExportService.automaticExportEnabledKey
        ) as? Bool ?? true
        #if DEBUG
        let shouldRunAutomaticExportTest =
            DebugLaunchConfiguration.testsNotionAutomaticExport
        #else
        let shouldRunAutomaticExportTest = false
        #endif
        guard shouldRunAutomaticExportTest || (isEnabled && isProActive) else {
            return
        }

        let selectedDestination = ExportDestination(
            rawValue: defaults.string(forKey: ExportService.selectedDestinationKey)
                ?? ExportDestination.obsidian.rawValue
        ) ?? .obsidian

        let evaluatedAt = Date()
        let today = calendar.startOfDay(for: evaluatedAt)
        if selectedDestination == .obsidian {
            guard isEnabled,
                  defaults.data(forKey: ExportService.vaultBookmarkKey) != nil else {
                return
            }
        } else if notionStore.canSyncAutomatically == false {
            return
        }

        let firstExportDate: Date
        if let storedDate = defaults.object(
            forKey: ExportService.automaticExportFirstDateKey
        ) as? Date {
            firstExportDate = calendar.startOfDay(for: storedDate)
        } else {
            // New setups start with today's log, exported from tomorrow onward.
            // Preserve the export history of users upgrading from earlier builds.
            var descriptor = FetchDescriptor<ExportRecordEntity>(
                predicate: #Predicate { $0.statusRawValue == "success" },
                sortBy: [SortDescriptor(\.date, order: .forward)]
            )
            descriptor.fetchLimit = 1
            let priorExportDate = try? modelContext.fetch(descriptor).first?.date
            firstExportDate = min(priorExportDate.map(calendar.startOfDay(for:)) ?? today, today)
            defaults.set(firstExportDate, forKey: ExportService.automaticExportFirstDateKey)
        }

        let exportDates = AutomaticExportDatePolicy.eligibleDates(
            dates,
            startingOn: firstExportDate,
            relativeTo: evaluatedAt,
            calendar: calendar
        )
        guard exportDates.isEmpty == false else {
            return
        }

        // Prepare a single value snapshot for all dates in this export run.
        let content = ExportService.prepareContent(for: exportDates, modelContext: modelContext)
        for date in exportDates {
            let didExport: Bool
            switch selectedDestination {
            case .obsidian:
                #if DEBUG
                if DebugLaunchConfiguration.testsNotionAutomaticExport {
                    print("SILICA_NOTION_AUTO_TEST=skipped destination=obsidian")
                }
                #endif
                didExport = ExportService.exportDateFromStoredBookmarkIfNeeded(
                    date: date,
                    content: content,
                    modelContext: modelContext
                )
            case .notion:
                didExport = await syncDateToNotionIfNeeded(
                    date: date,
                    content: content,
                    modelContext: modelContext,
                    notionStore: notionStore
                )
            }

            let notificationsEnabled = AutomaticExportNotificationPolicy.isEnabled(
                storedValue: defaults.object(
                    forKey: ExportService.automaticExportNotificationsEnabledKey
                ) as? Bool
            )
            let lastNotifiedDateKey = ExportService.automaticExportLastNotifiedDateKey(
                destination: selectedDestination
            )
            if didExport && AutomaticExportNotificationPolicy.shouldNotify(
                notificationsEnabled: notificationsEnabled,
                exportDate: date,
                lastNotifiedExportDate: defaults.object(
                    forKey: lastNotifiedDateKey
                ) as? Date,
                relativeTo: evaluatedAt,
                calendar: calendar
            ) {
                defaults.set(calendar.startOfDay(for: date), forKey: lastNotifiedDateKey)
                await SilicaNotificationService.notifyAutomaticExportSucceeded(
                    destination: selectedDestination,
                    date: date
                )
            }
        }
    }

    private static func syncDateToNotionIfNeeded(
        date: Date,
        content: ExportService.Content,
        modelContext: ModelContext,
        notionStore: SilicaNotionStore
    ) async -> Bool {
        let markdown = content.markdown(date: date)
        let dateText = DateSupport.formatISODate(date)

        do {
            guard let syncResponse = try await notionStore.syncAutomaticallyIfNeeded(
                markdown: markdown,
                date: dateText
            ) else {
                return false
            }

            #if DEBUG
            if DebugLaunchConfiguration.testsNotionAutomaticExport {
                let duplicateResult = try await notionStore.syncAutomaticallyIfNeeded(
                    markdown: markdown,
                    date: dateText
                )
                print(
                    duplicateResult == nil
                        ? "SILICA_NOTION_AUTO_TEST=dedup_success"
                        : "SILICA_NOTION_AUTO_TEST=dedup_failed"
                )
                UserDefaults.standard.set(
                    duplicateResult == nil
                        ? "success_\(syncResponse.mode)_dedup_success"
                        : "success_\(syncResponse.mode)_dedup_failed",
                    forKey: "silica.debug.notionAutoTest.lastResult"
                )
                UserDefaults.standard.set(
                    Date().timeIntervalSince1970,
                    forKey: "silica.debug.notionAutoTest.completedAt"
                )
            }
            #endif

            ExportService.insertExportRecord(
                date: date,
                filePath: "Notion - \(notionStore.selectedDestinationTitle ?? "Notion")",
                status: .success,
                modelContext: modelContext
            )
            try? modelContext.save()
            return true
        } catch {
            #if DEBUG
            if DebugLaunchConfiguration.testsNotionAutomaticExport {
                print("SILICA_NOTION_AUTO_TEST=failed error=\(error.localizedDescription)")
            }
            #endif
            ExportService.insertExportRecord(
                date: date,
                filePath: "",
                status: .failed,
                errorMessage: error.localizedDescription,
                modelContext: modelContext
            )
            try? modelContext.save()
            return false
        }
    }
}
