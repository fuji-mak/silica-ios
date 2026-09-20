import SwiftData
import SwiftUI

#if DEBUG
enum DebugLaunchConfiguration {
    static let seedsLongTimeline = ProcessInfo.processInfo.arguments.contains("--seed-long-timeline")
    static let testsHeaderTodayReturn = ProcessInfo.processInfo.arguments.contains("--debug-header-today-return")
    static let skipsWelcomeOnboarding = ProcessInfo.processInfo.arguments.contains("--debug-skip-welcome-onboarding")
    static let startsInMap = ProcessInfo.processInfo.arguments.contains("--debug-map")
    static let usesWideMap = ProcessInfo.processInfo.arguments.contains("--debug-map-wide")
    static let startsInExport = ProcessInfo.processInfo.arguments.contains("--debug-export")
    static let startsOnboardingLog = ProcessInfo.processInfo.arguments.contains("--debug-onboarding-log")
    static let seedsOnboardingHistory = ProcessInfo.processInfo.arguments.contains(
        "--debug-onboarding-history-data"
    )
    static let startsLogHistory = ProcessInfo.processInfo.arguments.contains("--debug-log-history")
    static let startsOnboardingMapPage = ProcessInfo.processInfo.arguments.contains("--debug-onboarding-map-page")
    static let startsLogAtBottom = ProcessInfo.processInfo.arguments.contains("--debug-log-bottom")
    static let startsLogTomorrow = ProcessInfo.processInfo.arguments.contains("--debug-log-tomorrow")
    static let autoPagesLog = ProcessInfo.processInfo.arguments.contains("--debug-log-auto-page")
    static let startsInSettings = ProcessInfo.processInfo.arguments.contains("--debug-settings")
    static let startsInSubscriptionManagement = ProcessInfo.processInfo.arguments.contains("--debug-subscription")
    static let forcesProSubscription = ProcessInfo.processInfo.arguments.contains("--debug-pro")
    static let forcesFreeSubscription = ProcessInfo.processInfo.arguments.contains("--debug-free")
    static let testsNotionAutomaticExport = ProcessInfo.processInfo.arguments.contains(
        "--debug-test-notion-auto-export"
    )
    static let startsAtFreeHistoryBoundary = ProcessInfo.processInfo.arguments.contains("--debug-history-paywall")
    static let capturesOnboardingScreenshots = ProcessInfo.processInfo.arguments.contains(
        "--debug-onboarding-capture"
    )
    static let forcesMissingLocationPermission = ProcessInfo.processInfo.arguments.contains(
        "--debug-missing-location-permission"
    )
    static let forcesMissingMotionPermission = ProcessInfo.processInfo.arguments.contains(
        "--debug-missing-motion-permission"
    )
    static let forcesPermissionsReady = ProcessInfo.processInfo.arguments.contains(
        "--debug-permissions-ready"
    )
    static let seedsAppStorePlaces = ProcessInfo.processInfo.arguments.contains(
        "--debug-app-store-places"
    )
    static let seedsOngoingCandidate = ProcessInfo.processInfo.arguments.contains(
        "--debug-ongoing-candidate"
    )

    static var longTimelineDate: Date {
        Calendar.current.date(
            byAdding: .day,
            value: testsHeaderTodayReturn ? 0 : -1,
            to: Calendar.current.startOfDay(for: Date())
        ) ?? Date()
    }

    static var onboardingPage: Int? {
        let arguments = ProcessInfo.processInfo.arguments
        guard let flagIndex = arguments.firstIndex(of: "--debug-onboarding-page"),
              arguments.indices.contains(arguments.index(after: flagIndex)),
              let page = Int(arguments[arguments.index(after: flagIndex)]) else {
            return nil
        }
        return min(max(page, 0), 4)
    }
}

@MainActor
private enum DebugOnboardingCaptureCleaner {
    static func clearIfRequested(in container: ModelContainer) {
        guard DebugLaunchConfiguration.capturesOnboardingScreenshots else {
            return
        }

        let context = container.mainContext
        let stays = (try? context.fetch(FetchDescriptor<StayEntity>())) ?? []
        let candidates = (try? context.fetch(FetchDescriptor<StayCandidateEntity>())) ?? []
        let movements = (try? context.fetch(FetchDescriptor<MovementPointEntity>())) ?? []
        let aliases = (try? context.fetch(FetchDescriptor<PlaceAliasEntity>())) ?? []
        let exportRecords = (try? context.fetch(FetchDescriptor<ExportRecordEntity>())) ?? []

        stays.forEach(context.delete)
        candidates.forEach(context.delete)
        movements.forEach(context.delete)
        aliases.forEach(context.delete)
        exportRecords.forEach(context.delete)
        try? context.save()
    }
}

@MainActor
private enum DebugOnboardingData {
    private static let mockAliasSymbols: [String: String] = [
        "自宅": "house",
        "Home": "house",
        "職場": "building.2",
        "Office": "building.2",
        "ジム": "dumbbell",
        "Gym": "dumbbell",
        "東京駅": "tram.fill",
        "Tokyo Station": "tram.fill",
        "銀座": "bag",
        "Ginza": "bag",
        "渋谷ヒカリエ": "building.columns",
        "Shibuya Hikarie": "building.columns",
    ]

    private static let mockPlaceNames: Set<String> = [
        "東京駅", "皇居", "神田", "日本橋", "銀座", "上野公園", "浅草", "渋谷",
        "渋谷ヒカリエ", "職場", "ジム", "自宅",
        "Tokyo Station", "Imperial Palace", "Kanda", "Nihonbashi", "Ginza",
        "Ueno Park", "Asakusa", "Shibuya", "Shibuya Hikarie", "Office", "Gym", "Home"
    ]

    static func clearMockData(in context: ModelContext) {
        let stays = (try? context.fetch(FetchDescriptor<StayEntity>())) ?? []
        for stay in stays {
            guard let placeName = stay.placeName else {
                continue
            }
            if placeName.hasPrefix("検証地点 ") ||
                placeName.hasPrefix("オンボーディング ") ||
                placeName.hasPrefix("Onboarding ") ||
                placeName.hasPrefix("デモ ") ||
                placeName.hasPrefix("履歴 ") ||
                mockPlaceNames.contains(placeName) {
                context.delete(stay)
            }
        }

        let aliases = (try? context.fetch(FetchDescriptor<PlaceAliasEntity>())) ?? []
        for alias in aliases where alias.priority >= 900 && mockPlaceNames.contains(alias.name) {
            context.delete(alias)
        }
    }

    static func makeMockAlias(
        name: String,
        latitude: Double,
        longitude: Double,
        priority: Int = 900
    ) -> PlaceAliasEntity {
        let alias = PlaceAliasEntity(
            name: name,
            latitude: latitude,
            longitude: longitude,
            radiusMeters: 140,
            priority: priority
        )
        alias.symbolName = mockAliasSymbols[name] ?? "mappin"
        return alias
    }
}

@MainActor
private enum DebugLongTimelineSeeder {
    static func seedIfRequested(in container: ModelContainer) {
        guard DebugLaunchConfiguration.seedsLongTimeline else {
            return
        }

        let context = container.mainContext
        DebugOnboardingData.clearMockData(in: context)

        let calendar = Calendar.current
        let startOfDay = DebugLaunchConfiguration.longTimelineDate
        let coordinates: [(latitude: Double, longitude: Double)] = [
            (35.6812, 139.7671),
            (35.6852, 139.7528),
            (35.7210, 139.7300),
            (35.6833, 139.7747),
            (35.6717, 139.7650),
            (35.7148, 139.7745),
            (35.7148, 139.7967),
            (35.6580, 139.7016)
        ]

        for index in 0..<18 {
            let arrivalAt = calendar.date(
                byAdding: .minute,
                value: index * 75,
                to: startOfDay
            ) ?? startOfDay
            let departureAt = calendar.date(byAdding: .minute, value: 52, to: arrivalAt)
            let coordinate = coordinates[index % coordinates.count]
            let stay = StayEntity(
                arrivalAt: arrivalAt,
                departureAt: departureAt,
                latitude: coordinate.latitude,
                longitude: coordinate.longitude,
                horizontalAccuracy: 20,
                sourceRawValue: LocationSource.visit.rawValue,
                confidenceRawValue: PlaceConfidence.high.rawValue
            )
            stay.placeName = "検証地点 \(index + 1)"
            stay.address = "検証住所 \(index + 1)"
            context.insert(stay)
        }

        if ProcessInfo.processInfo.arguments.contains("--debug-date-selector-history") {
            let historyOffset = DebugLaunchConfiguration.testsHeaderTodayReturn ? -42 : -90
            let oldestDay = calendar.date(byAdding: .day, value: historyOffset, to: startOfDay) ?? startOfDay
            let oldest = StayEntity(
                arrivalAt: oldestDay,
                departureAt: oldestDay.addingTimeInterval(3600),
                latitude: 35.6812,
                longitude: 139.7671,
                horizontalAccuracy: 20,
                sourceRawValue: LocationSource.visit.rawValue,
                confidenceRawValue: PlaceConfidence.high.rawValue
            )
            oldest.placeName = "検証地点 履歴開始"
            context.insert(oldest)
        }

        try? context.save()
    }
}

@MainActor
private enum DebugOnboardingLogSeeder {
    static func seedIfRequested(in container: ModelContainer) {
        guard DebugLaunchConfiguration.startsOnboardingLog else {
            return
        }

        let context = container.mainContext
        DebugOnboardingData.clearMockData(in: context)

        let calendar = Calendar.current
        let startOfDay = calendar.startOfDay(for: Date())
        let places: [(name: String, address: String, latitude: Double, longitude: Double)] =
            AppLanguage.current == .english
                ? [
                    ("Home", "Minami-Ikebukuro, Tokyo", 35.7210, 139.7300),
                    ("Tokyo Station", "Marunouchi, Tokyo", 35.6812, 139.7671),
                    ("Office", "Nishi-Shinjuku, Tokyo", 35.6895, 139.6917),
                    ("Ginza", "Ginza, Tokyo", 35.6717, 139.7650),
                    ("Gym", "Ebisu, Tokyo", 35.6467, 139.7101),
                    ("Shibuya Hikarie", "Shibuya, Tokyo", 35.6580, 139.7036),
                ]
                : [
                    ("自宅", "東京都豊島区南池袋", 35.7210, 139.7300),
                    ("東京駅", "東京都千代田区丸の内", 35.6812, 139.7671),
                    ("職場", "東京都新宿区西新宿", 35.6895, 139.6917),
                    ("銀座", "東京都中央区銀座", 35.6717, 139.7650),
                    ("ジム", "東京都渋谷区恵比寿", 35.6467, 139.7101),
                    ("渋谷ヒカリエ", "東京都渋谷区渋谷", 35.6580, 139.7036),
                ]

        let aliasNames: [String]
        if DebugLaunchConfiguration.seedsAppStorePlaces {
            aliasNames = AppLanguage.current == .english
                ? ["Home", "Office", "Gym", "Tokyo Station", "Ginza", "Shibuya Hikarie"]
                : ["自宅", "職場", "ジム", "東京駅", "銀座", "渋谷ヒカリエ"]
        } else {
            aliasNames = AppLanguage.current == .english
                ? ["Home", "Office", "Gym"]
                : ["自宅", "職場", "ジム"]
        }
        let aliasPriorities = Dictionary(
            uniqueKeysWithValues: aliasNames.enumerated().map { index, name in
                (name, 1_000 - index)
            }
        )
        for place in places where aliasNames.contains(place.name) {
            context.insert(
                DebugOnboardingData.makeMockAlias(
                    name: place.name,
                    latitude: place.latitude,
                    longitude: place.longitude,
                    priority: DebugLaunchConfiguration.seedsAppStorePlaces
                        ? aliasPriorities[place.name] ?? 900
                        : 900
                )
            )
        }

        for (index, place) in places.enumerated() {
            let arrivalAt = calendar.date(
                byAdding: .minute,
                value: 7 * 60 + 35 + index * 105,
                to: startOfDay
            ) ?? startOfDay
            let departureAt = calendar.date(byAdding: .minute, value: 58, to: arrivalAt)
            let stay = StayEntity(
                arrivalAt: arrivalAt,
                departureAt: departureAt,
                latitude: place.latitude,
                longitude: place.longitude,
                horizontalAccuracy: 18,
                sourceRawValue: LocationSource.visit.rawValue,
                confidenceRawValue: PlaceConfidence.high.rawValue
            )
            stay.placeName = place.name
            stay.address = place.address
            context.insert(stay)
        }

        try? context.save()
    }
}

@MainActor
private enum DebugOngoingCandidateSeeder {
    static func seedIfRequested(in container: ModelContainer) {
        guard DebugLaunchConfiguration.seedsOngoingCandidate else {
            return
        }

        let context = container.mainContext
        let candidates = (try? context.fetch(FetchDescriptor<StayCandidateEntity>())) ?? []
        for candidate in candidates where
            candidate.placeName == "進行中テスト" || candidate.placeName == "Ongoing Test" {
            context.delete(candidate)
        }

        let candidate = StayCandidateEntity(
            arrivalAt: Date().addingTimeInterval(-30 * 60),
            latitude: 35.6895,
            longitude: 139.6917,
            horizontalAccuracy: 18,
            sourceRawValue: LocationSource.visit.rawValue
        )
        candidate.placeName = AppLanguage.current == .english ? "Ongoing Test" : "進行中テスト"
        candidate.address = AppLanguage.current == .english
            ? "Nishi-Shinjuku, Tokyo"
            : "東京都新宿区西新宿"
        context.insert(candidate)
        try? context.save()
    }
}

@MainActor
private enum DebugOnboardingMapSeeder {
    static func seedIfRequested(in container: ModelContainer) {
        guard DebugLaunchConfiguration.startsInMap else {
            return
        }

        let context = container.mainContext
        DebugOnboardingData.clearMockData(in: context)

        let calendar = Calendar.current
        let startOfDay = calendar.startOfDay(for: Date())
        let places: [(name: String, address: String, latitude: Double, longitude: Double)] =
            AppLanguage.current == .english
                ? [
                    ("Tokyo Station", "Marunouchi, Tokyo", 35.6812, 139.7671),
                    ("Imperial Palace", "Chiyoda, Tokyo", 35.6852, 139.7528),
                    ("Kanda", "Kanda, Tokyo", 35.6917, 139.7708),
                    ("Nihonbashi", "Nihonbashi, Tokyo", 35.6833, 139.7747),
                    ("Ginza", "Ginza, Tokyo", 35.6717, 139.7650),
                    ("Ueno Park", "Ueno Park, Tokyo", 35.7148, 139.7745),
                    ("Asakusa", "Asakusa, Tokyo", 35.7148, 139.7967),
                    ("Shibuya", "Dogenzaka, Tokyo", 35.6580, 139.7016),
                ]
                : [
                    ("東京駅", "東京都千代田区丸の内", 35.6812, 139.7671),
                    ("皇居", "東京都千代田区千代田", 35.6852, 139.7528),
                    ("神田", "東京都千代田区神田", 35.6917, 139.7708),
                    ("日本橋", "東京都中央区日本橋", 35.6833, 139.7747),
                    ("銀座", "東京都中央区銀座", 35.6717, 139.7650),
                    ("上野公園", "東京都台東区上野公園", 35.7148, 139.7745),
                    ("浅草", "東京都台東区浅草", 35.7148, 139.7967),
                    ("渋谷", "東京都渋谷区道玄坂", 35.6580, 139.7016),
                ]

        for (index, place) in places.enumerated() {
            let arrivalAt = calendar.date(
                byAdding: .minute,
                value: 8 * 60 + index * 45,
                to: startOfDay
            ) ?? startOfDay
            let departureAt = calendar.date(byAdding: .minute, value: 28, to: arrivalAt)
            let stay = StayEntity(
                arrivalAt: arrivalAt,
                departureAt: departureAt,
                latitude: place.latitude,
                longitude: place.longitude,
                horizontalAccuracy: 18,
                sourceRawValue: LocationSource.visit.rawValue,
                confidenceRawValue: PlaceConfidence.high.rawValue
            )
            let prefix = AppLanguage.current == .english ? "Onboarding " : "オンボーディング "
            stay.placeName = "\(prefix)\(place.name)"
            stay.address = place.address
            context.insert(stay)
        }

        try? context.save()
    }
}

@MainActor
private enum DebugOnboardingHistorySeeder {
    static func seedIfRequested(in container: ModelContainer) {
        guard DebugLaunchConfiguration.startsLogHistory
                || DebugLaunchConfiguration.seedsOnboardingHistory else {
            return
        }

        let context = container.mainContext
        DebugOnboardingData.clearMockData(in: context)

        let calendar = Calendar.current
        let today = calendar.startOfDay(for: Date())
        let historyOffset = ProcessInfo.processInfo.arguments.contains("--debug-date-selector-history")
            ? -90 : -3
        let historyDay = calendar.date(byAdding: .day, value: historyOffset, to: today) ?? today
        let places: [(name: String, address: String, latitude: Double, longitude: Double)] =
            AppLanguage.current == .english
                ? [
                    ("Shibuya Hikarie", "Shibuya, Tokyo", 35.6580, 139.7036),
                    ("Office", "Nishi-Shinjuku, Tokyo", 35.6895, 139.6917),
                    ("Gym", "Ebisu, Tokyo", 35.6467, 139.7101),
                    ("Home", "Minami-Ikebukuro, Tokyo", 35.7210, 139.7300),
                    ("Imperial Palace", "Chiyoda, Tokyo", 35.6852, 139.7528),
                    ("Tokyo Station", "Marunouchi, Tokyo", 35.6812, 139.7671),
                ]
                : [
                    ("渋谷ヒカリエ", "東京都渋谷区渋谷", 35.6580, 139.7036),
                    ("職場", "東京都新宿区西新宿", 35.6895, 139.6917),
                    ("ジム", "東京都渋谷区恵比寿", 35.6467, 139.7101),
                    ("自宅", "東京都豊島区南池袋", 35.7210, 139.7300),
                    ("皇居", "東京都千代田区千代田", 35.6852, 139.7528),
                    ("東京駅", "東京都千代田区丸の内", 35.6812, 139.7671),
                ]

        let aliasNames = AppLanguage.current == .english
            ? ["Office", "Gym", "Home"]
            : ["職場", "ジム", "自宅"]
        for place in places where aliasNames.contains(place.name) {
            let alias = DebugOnboardingData.makeMockAlias(
                name: place.name,
                latitude: place.latitude,
                longitude: place.longitude
            )
            context.insert(alias)
        }

        for (index, place) in places.enumerated() {
            let arrivalAt = calendar.date(
                byAdding: .minute,
                value: 10 * 60 + 15 + index * 82,
                to: historyDay
            ) ?? historyDay
            let departureAt = calendar.date(byAdding: .minute, value: 44, to: arrivalAt)
            let stay = StayEntity(
                arrivalAt: arrivalAt,
                departureAt: departureAt,
                latitude: place.latitude,
                longitude: place.longitude,
                horizontalAccuracy: 18,
                sourceRawValue: LocationSource.visit.rawValue,
                confidenceRawValue: PlaceConfidence.high.rawValue
            )
            stay.placeName = place.name
            stay.address = place.address
            context.insert(stay)
        }

        try? context.save()
    }
}

@MainActor
private enum DebugOnboardingExportSeeder {
    static func seedIfRequested() {
        guard DebugLaunchConfiguration.startsInExport else {
            return
        }

        let defaults = UserDefaults.standard
        defaults.set(Data("silica-demo-vault".utf8), forKey: ExportService.vaultBookmarkKey)
        defaults.set("Obsidian Vault", forKey: "vaultFolderDisplayName")
        defaults.set(
            ExportDestination.obsidian.rawValue,
            forKey: ExportService.selectedDestinationKey
        )
        defaults.set(true, forKey: ExportService.automaticExportEnabledKey)
        defaults.set(
            true,
            forKey: ExportService.automaticExportNotificationsEnabledKey
        )
    }
}
#endif

@main
struct SilicaApp: App {
    private let modelContainer: ModelContainer
    @StateObject private var locationRecorder: LocationRecorder
    @StateObject private var subscriptionManager = SubscriptionManager()
    @StateObject private var notionStore = SilicaNotionStore()

    init() {
        let defaults = UserDefaults.standard
        if defaults.object(forKey: SilicaOnboardingStorage.firstUsedAtKey) == nil {
            defaults.set(Date(), forKey: SilicaOnboardingStorage.firstUsedAtKey)
        }
        let recorder = LocationRecorder()
        _locationRecorder = StateObject(wrappedValue: recorder)
        SilicaNotificationService.configure()

        // Protect existing store files before opening them.
        AppDataProtection.applyApplicationSupportProtection()
        do {
            let container = try ModelContainer(
                for: StayEntity.self,
                StayCandidateEntity.self,
                MovementPointEntity.self,
                PlaceAliasEntity.self,
                ExportRecordEntity.self
            )
            #if DEBUG
            DebugOnboardingCaptureCleaner.clearIfRequested(in: container)
            DebugLongTimelineSeeder.seedIfRequested(in: container)
            DebugOnboardingLogSeeder.seedIfRequested(in: container)
            DebugOngoingCandidateSeeder.seedIfRequested(in: container)
            DebugOnboardingMapSeeder.seedIfRequested(in: container)
            DebugOnboardingHistorySeeder.seedIfRequested(in: container)
            DebugOnboardingExportSeeder.seedIfRequested()
            #endif
            modelContainer = container
            // Attach before the view hierarchy is created so a background
            // relaunch caused by Visits can persist the delivered event.
            recorder.attach(modelContext: container.mainContext)
            recorder.start()
            // The first launch can create new store and sidecar files.
            AppDataProtection.applyApplicationSupportProtection()
        } catch {
            fatalError("Failed to initialize Silica model container: \(error)")
        }
    }

    var body: some Scene {
        WindowGroup {
            RootView(locationRecorder: locationRecorder)
                .modelContainer(modelContainer)
                .environmentObject(subscriptionManager)
                .environmentObject(notionStore)
                .onOpenURL { url in
                    notionStore.handleIncomingURL(url)
                }
                .task {
                    subscriptionManager.configure()
                }
        }
    }
}
