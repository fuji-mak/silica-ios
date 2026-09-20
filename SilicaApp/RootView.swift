import CoreMotion
import LocalAuthentication
import SwiftData
import SwiftUI
import UIKit

private enum AppTab: Hashable {
    case log
    case places
    case map
    case export
    case settings
}

private enum GuidedSetupStage: String {
    case places
    case export
    case confirmation
    case complete
}

enum SilicaOnboardingStorage {
    static let firstUsedAtKey = "silica.firstUsedAt"
    static let guidedSetupStageKey = "silica.guidedSetupStage"
    static let hasCompletedOnboardingKey = "silica.hasCompletedOnboarding"
    static let resumeInitialSetupAfterSettingsKey = "silica.resumeInitialSetupAfterSettings"
    static let initialSetupResumePageKey = "silica.initialSetupResumePage"

    static func markCompleted(in defaults: UserDefaults = .standard) {
        defaults.set(true, forKey: hasCompletedOnboardingKey)
        defaults.removeObject(forKey: resumeInitialSetupAfterSettingsKey)
        defaults.removeObject(forKey: initialSetupResumePageKey)
    }
}

struct RootView: View {
    @Environment(\.modelContext) private var modelContext
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.openURL) private var openURL
    @EnvironmentObject private var subscriptionManager: SubscriptionManager
    @EnvironmentObject private var notionStore: SilicaNotionStore
    // Children observe the recording status they display. Root only owns commands.
    let locationRecorder: LocationRecorder
    @AppStorage(SilicaOnboardingStorage.guidedSetupStageKey)
    private var guidedSetupStageRawValue = GuidedSetupStage.complete.rawValue
    @AppStorage(SettingsView.faceIDLockEnabledKey) private var faceIDLockEnabled = false
    @State private var appAppearance: AppAppearance
    @State private var appliedAppearance: AppAppearance
    @State private var appLanguage: AppLanguage
    @State private var selectedTab: AppTab
    @State private var selectedDate: Date
    @State private var pendingMapSelectionID: UUID?
    @State private var selectedPlaceAliasID: UUID?
    @State private var pendingPlaceRegistrationStayID: UUID?
    @State private var isAppUnlocked = false
    @State private var unlockErrorMessage: String?
    @State private var isStartupSplashVisible = true
    @State private var isStartupSplashExiting = false
    @State private var hasStartedInitialLoad = false
    @State private var splashGeneration = 0
    @State private var contentGeneration = 0
    @State private var pendingLanguage: AppLanguage?
    @State private var isWelcomeOnboardingPresented: Bool
    @State private var isInitialSetupOnboardingPresented = false
    @State private var isHistoryPaywallPresented = false
    @State private var isTrialExpirationPaywallPresented = false
    @State private var motionAuthorizationStatus = CMMotionActivityManager.authorizationStatus()

    private let motionActivityManager = CMMotionActivityManager()

    private static let minimumStartupSplashDurationNanoseconds: UInt64 = 1_000_000_000
    private static let minimumLanguageChangeSplashDurationNanoseconds: UInt64 = 1_300_000_000
    private static let appearanceApplicationDelayNanoseconds: UInt64 = 180_000_000
    private static let languagePickerSettleDelayNanoseconds: UInt64 = 300_000_000
    private static let languageContentSwapDelayNanoseconds: UInt64 = 420_000_000

    private var appearanceBinding: Binding<AppAppearance> {
        Binding(
            get: { appAppearance },
            set: { newAppearance in
                guard newAppearance != appAppearance else {
                    return
                }

                AppAppearance.persist(newAppearance)
                appAppearance = newAppearance

                Task { @MainActor in
                    try? await Task.sleep(
                        nanoseconds: Self.appearanceApplicationDelayNanoseconds
                    )
                    guard appAppearance == newAppearance else {
                        return
                    }
                    appliedAppearance = newAppearance
                }
            }
        )
    }

    private var languageBinding: Binding<AppLanguage> {
        Binding(
            get: { pendingLanguage ?? appLanguage },
            set: { newLanguage in
                beginLanguageChange(to: newLanguage)
            }
        )
    }

    private var guidedSetupStage: GuidedSetupStage {
        GuidedSetupStage(rawValue: guidedSetupStageRawValue) ?? .complete
    }

    private var historyDateBinding: Binding<Date> {
        Binding(
            get: { selectedDate },
            set: { requestedDate in
                guard canAccessHistoryDate(requestedDate) else {
                    return
                }
                selectedDate = requestedDate
            }
        )
    }

    private func canAccessHistoryDate(_ requestedDate: Date) -> Bool {
        let requiresPro = LocationHistoryAccessPolicy.requiresPro(
            viewing: requestedDate,
            relativeTo: Date(),
            calendar: .current,
            isProActive: historyAccessState == 2
        )
        guard requiresPro else {
            return true
        }
        requestHistoryPaywall()
        return false
    }

    private func requestHistoryPaywall() {
        Task { @MainActor in
            // Let any date picker or pager rollback finish before presenting a
            // second sheet from the root view.
            await Task.yield()
            isHistoryPaywallPresented = true
        }
    }

    /// 0: unresolved, 1: Free, 2: Pro.
    private var historyAccessState: Int {
        #if DEBUG
        if DebugLaunchConfiguration.forcesFreeSubscription {
            return 1
        }
        if DebugLaunchConfiguration.forcesProSubscription {
            return 2
        }
        #endif
        if subscriptionManager.hasProAccess {
            return 2
        }
        if subscriptionManager.customerInfo == nil {
            if subscriptionManager.isConfigured == false
                || subscriptionManager.isLoading
                || subscriptionManager.errorMessage == nil {
                return 0
            }
        }
        return 1
    }

    private var onboardingInitialPage: Int {
        #if DEBUG
        return DebugLaunchConfiguration.onboardingPage
            ?? (DebugLaunchConfiguration.startsOnboardingMapPage ? 1 : 0)
        #else
        return 0
        #endif
    }

    init(locationRecorder: LocationRecorder) {
        self.locationRecorder = locationRecorder
        let initialAppearance = AppAppearance.current
        _appAppearance = State(initialValue: initialAppearance)
        _appliedAppearance = State(initialValue: initialAppearance)
        _appLanguage = State(initialValue: AppLanguage.current)
        let defaults = UserDefaults.standard
        #if SILICA_ONBOARDING_PREVIEW
        // Keep the standalone review app reusable without touching the
        // production Silica app's onboarding state or location history.
        let hasCompletedOnboarding = false
        #else
        let hasCompletedOnboarding = defaults.bool(
            forKey: SilicaOnboardingStorage.hasCompletedOnboardingKey
        )
        #endif
        let shouldResumeInitialSetup = hasCompletedOnboarding == false && defaults.bool(
            forKey: SilicaOnboardingStorage.resumeInitialSetupAfterSettingsKey
        )
        #if DEBUG
        let forcesWelcomeOnboarding =
            DebugLaunchConfiguration.onboardingPage != nil ||
            DebugLaunchConfiguration.startsOnboardingMapPage
        let shouldPresentOnboarding =
            DebugLaunchConfiguration.skipsWelcomeOnboarding == false &&
            (hasCompletedOnboarding == false || forcesWelcomeOnboarding)
        _isWelcomeOnboardingPresented = State(
            initialValue: shouldPresentOnboarding && shouldResumeInitialSetup == false
        )
        _isInitialSetupOnboardingPresented = State(
            initialValue: shouldPresentOnboarding && shouldResumeInitialSetup
        )
        #else
        _isWelcomeOnboardingPresented = State(
            initialValue: hasCompletedOnboarding == false && shouldResumeInitialSetup == false
        )
        _isInitialSetupOnboardingPresented = State(
            initialValue: hasCompletedOnboarding == false && shouldResumeInitialSetup
        )
        #endif
        #if DEBUG
        let initialTab: AppTab = DebugLaunchConfiguration.startsInSettings
            ? .settings
            : (DebugLaunchConfiguration.startsInExport
                ? .export
                : (DebugLaunchConfiguration.startsInMap
                    ? .map
                    : (DebugLaunchConfiguration.seedsLongTimeline
                        || DebugLaunchConfiguration.startsOnboardingLog
                        || DebugLaunchConfiguration.seedsOnboardingHistory
                        || DebugLaunchConfiguration.startsLogHistory
                        || DebugLaunchConfiguration.startsAtFreeHistoryBoundary
                        ? .log
                        : .map)))
        _selectedTab = State(initialValue: initialTab)
        let initialDate: Date
        if DebugLaunchConfiguration.startsAtFreeHistoryBoundary {
            initialDate = Calendar.current.date(
                byAdding: .day,
                value: -(LocationHistoryAccessPolicy.freeVisibleDayCount - 1),
                to: Calendar.current.startOfDay(for: Date())
            ) ?? Date()
        } else if DebugLaunchConfiguration.seedsLongTimeline {
            initialDate = DebugLaunchConfiguration.longTimelineDate
        } else if DebugLaunchConfiguration.startsLogTomorrow {
            initialDate = Calendar.current.date(byAdding: .day, value: 1, to: Date()) ?? Date()
        } else if DebugLaunchConfiguration.startsLogHistory {
            initialDate = Calendar.current.date(byAdding: .day, value: -3, to: Date()) ?? Date()
        } else {
            initialDate = Date()
        }
        _selectedDate = State(initialValue: initialDate)
        #else
        _selectedTab = State(initialValue: .map)
        _selectedDate = State(initialValue: Date())
        #endif
    }

    private var mapTabContent: some View {
        LocationMapView(
            selectedDate: historyDateBinding,
            requestedSelectionID: $pendingMapSelectionID,
            onRegisterPlace: openPlaceAlias,
            onRegisterNewPlace: openPlaceRegistration
        )
    }

    private var mainTabs: some View {
        TabView(selection: $selectedTab) {
            TodayView(
                selectedDate: historyDateBinding,
                canAccessDate: canAccessHistoryDate,
                onShowStayOnMap: showStayOnMap,
                onShowCandidateOnMap: showCandidateOnMap
            )
                .tabItem {
                    Label(
                        AppLanguage.localized("ログ", language: appLanguage),
                        systemImage: "list.bullet"
                    )
                }
                .tag(AppTab.log)

            PlacesView(
                selectedAliasID: $selectedPlaceAliasID,
                pendingStayRegistrationID: $pendingPlaceRegistrationStayID
            )
                .tabItem {
                    Label(
                        AppLanguage.localized("場所", language: appLanguage),
                        systemImage: "mappin.and.ellipse"
                    )
                }
                .tag(AppTab.places)

            mapTabContent
                .tabItem {
                    Label(
                        AppLanguage.localized("マップ", language: appLanguage),
                        systemImage: "map"
                    )
                }
                .tag(AppTab.map)

            ExportView(selectedDate: historyDateBinding)
                .tabItem {
                    Label(
                        AppLanguage.localized("出力", language: appLanguage),
                        systemImage: "square.and.arrow.up"
                    )
                }
                .tag(AppTab.export)

            SettingsView(
                appearance: appearanceBinding,
                language: languageBinding
            )
                .tabItem {
                    Label(
                        AppLanguage.localized("設定", language: appLanguage),
                        systemImage: "gearshape"
                    )
                }
                .tag(AppTab.settings)
        }
        .safeAreaInset(edge: .top, spacing: 0) {
            if motionPermissionIsReady == false {
                motionPermissionBanner
                    .transition(.move(edge: .top).combined(with: .opacity))
            }
        }
        .animation(.easeInOut(duration: 0.22), value: motionPermissionIsReady)
    }

    private var motionPermissionIsReady: Bool {
        PermissionStatusText.motionIsReady(
            motionAuthorizationStatus,
            isAvailable: CMMotionActivityManager.isActivityAvailable()
        )
    }

    private var motionPermissionBanner: some View {
        Button(action: handleMotionPermissionAction) {
            HStack(spacing: 12) {
                Image(systemName: "figure.walk.motion")
                    .font(.body.weight(.semibold))
                    .foregroundStyle(.orange)
                    .frame(width: 32, height: 32)
                    .background(.orange.opacity(0.14), in: Circle())

                VStack(alignment: .leading, spacing: 2) {
                    Text(AppLanguage.localized("記録精度が低下中"))
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(.primary)
                    Text(AppLanguage.localized("モーションとフィットネスの許可が必要です"))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                Spacer(minLength: 8)

                Text(
                    AppLanguage.localized(
                        motionAuthorizationStatus == .notDetermined
                            ? "許可する"
                            : "設定を開く"
                    )
                )
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(.orange)
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 10)
            .frame(maxWidth: .infinity)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .background(.regularMaterial)
        .overlay(alignment: .bottom) {
            Divider()
        }
        .accessibilityIdentifier("motion-permission-banner")
    }

    var body: some View {
        ZStack {
            Group {
                switch guidedSetupStage {
                case .places:
                    PlacesView(
                        selectedAliasID: $selectedPlaceAliasID,
                        pendingStayRegistrationID: $pendingPlaceRegistrationStayID,
                        isGuidedSetup: true,
                        onGuidedPlaceSaved: { advanceGuidedSetup(to: .export) }
                    )
                case .export:
                    ExportView(
                        selectedDate: historyDateBinding,
                        isGuidedSetup: true,
                        onGuidedSetupCompleted: finishGuidedSetup
                    )
                case .confirmation:
                    mapTabContent
                        .disabled(true)
                        .allowsHitTesting(false)
                        .accessibilityHidden(true)
                        .overlay {
                            GuidedSetupCompletionView(
                                locationRecorder: locationRecorder,
                                hasProAccess: historyAccessState == 2,
                                onContinue: dismissGuidedSetupCompletion
                            )
                        }
                case .complete:
                    mainTabs
                }
            }
            .id(contentGeneration)
            .opacity(isStartupSplashVisible ? 0 : 1)
            .animation(.easeInOut(duration: 0.38), value: isStartupSplashVisible)

            if faceIDLockEnabled && isAppUnlocked == false {
                AppLockView(errorMessage: unlockErrorMessage, unlock: authenticateForAppUnlock)
            }

            if isStartupSplashVisible {
                StartupSplashView(isExiting: isStartupSplashExiting)
                    .transition(.opacity)
                    .zIndex(100)
            }

            if isWelcomeOnboardingPresented,
               isStartupSplashVisible == false,
               isAppUnlocked {
                SilicaWelcomeView(initialPage: onboardingInitialPage) {
                    withAnimation(.easeInOut(duration: 0.28)) {
                        isWelcomeOnboardingPresented = false
                        isInitialSetupOnboardingPresented = true
                    }
                }
                .transition(.move(edge: .bottom).combined(with: .opacity))
                .zIndex(90)
            }

            if isInitialSetupOnboardingPresented,
               isWelcomeOnboardingPresented == false,
               isStartupSplashVisible == false,
               isAppUnlocked {
                SilicaInitialSetupOnboardingView {
                    completeInitialSetup()
                }
                .transition(.move(edge: .bottom).combined(with: .opacity))
                .zIndex(90)
            }
        }
        .environmentObject(locationRecorder)
        .preferredColorScheme(appliedAppearance.colorScheme)
        .environment(\.locale, appLanguage.locale)
        .onAppear {
            guard hasStartedInitialLoad == false else {
                return
            }
            hasStartedInitialLoad = true
            let startupStartedAt = DispatchTime.now().uptimeNanoseconds

            refreshMotionAuthorizationState()
            resumeGuidedSetup()
            prepareInitialLoad()
            scheduleStartupSplashDismissal(
                startedAt: startupStartedAt,
                minimumDuration: Self.minimumStartupSplashDurationNanoseconds
            )
        }
        .onChange(of: scenePhase) {
            if scenePhase == .inactive || scenePhase == .background {
                if faceIDLockEnabled { isAppUnlocked = false }
            } else if scenePhase == .active {
                refreshMotionAuthorizationState()
                subscriptionManager.refreshProTrialStatus()
                locationRecorder.start()
                exportYesterdayIfNeeded()
                presentTrialExpirationPaywallIfNeeded()
                if faceIDLockEnabled && isAppUnlocked == false {
                    authenticateForAppUnlock()
                }
            }
        }
        .onChange(of: faceIDLockEnabled) {
            if faceIDLockEnabled == false {
                isAppUnlocked = true
                unlockErrorMessage = nil
            }
        }
        .onChange(of: subscriptionManager.hasProAccess) { _, isActive in
            if isActive {
                exportYesterdayIfNeeded()
            }
        }
        .onChange(of: subscriptionManager.isSilicaProActive) { _, isActive in
            if isActive {
                SilicaNotificationService.cancelProTrialNotifications()
            }
        }
        .onChange(of: subscriptionManager.customerInfo != nil) { _, isResolved in
            if isResolved {
                presentTrialExpirationPaywallIfNeeded()
            }
        }
        .onChange(of: subscriptionManager.proTrialStatus, initial: true) {
            _, status in
            switch status {
            case .active(let expirationDate):
                Task {
                    await SilicaNotificationService.scheduleProTrialNotifications(
                        expirationDate: expirationDate
                    )
                }
            case .expired:
                SilicaNotificationService.cancelProTrialReminderNotification()
            case .notStarted:
                break
            }
            presentTrialExpirationPaywallIfNeeded()
        }
        .onChange(of: isStartupSplashVisible) { _, isVisible in
            if isVisible == false {
                presentTrialExpirationPaywallIfNeeded()
            }
        }
        .onChange(of: isAppUnlocked) { _, isUnlocked in
            if isUnlocked {
                presentTrialExpirationPaywallIfNeeded()
            }
        }
        .onReceive(
            NotificationCenter.default.publisher(for: .silicaLocationDataDidChange)
        ) { notification in
            let affectedDates = notification.userInfo?[
                LocationDataChangeUserInfo.affectedDates
            ] as? [Date] ?? []
            if affectedDates.isEmpty {
                exportYesterdayIfNeeded()
            } else {
                exportDatesIfNeeded(affectedDates)
            }
        }
        .sheet(isPresented: $isHistoryPaywallPresented) {
            SilicaCustomPaywallView()
                .environmentObject(locationRecorder)
        }
        .fullScreenCover(
            isPresented: $isTrialExpirationPaywallPresented,
            onDismiss: {
                subscriptionManager.acknowledgeProTrialExpiration()
            }
        ) {
            SilicaCustomPaywallView(presentation: .trialExpired)
                .environmentObject(locationRecorder)
        }
    }

    private func prepareInitialLoad() {
        #if DEBUG
        if DebugLaunchConfiguration.seedsLongTimeline ||
            DebugLaunchConfiguration.startsLogHistory ||
            DebugLaunchConfiguration.startsInExport {
            isAppUnlocked = true
            return
        }
        #endif

        locationRecorder.configure(modelContext: modelContext)
        locationRecorder.start()
        exportYesterdayIfNeeded()
        if faceIDLockEnabled {
            authenticateForAppUnlock()
        } else {
            isAppUnlocked = true
        }
    }

    private func exportYesterdayIfNeeded() {
        #if DEBUG
        if DebugLaunchConfiguration.startsInExport {
            return
        }
        #endif
        Task { @MainActor in
            await AutomaticExportService.runYesterdayIfNeeded(
                modelContext: modelContext,
                notionStore: notionStore,
                isProActive: historyAccessState == 2
            )
        }
    }

    private func exportDatesIfNeeded(_ dates: [Date]) {
        #if DEBUG
        if DebugLaunchConfiguration.startsInExport {
            return
        }
        #endif
        Task { @MainActor in
            await AutomaticExportService.runDatesIfNeeded(
                dates,
                modelContext: modelContext,
                notionStore: notionStore,
                isProActive: historyAccessState == 2
            )
        }
    }

    private func openPlaceAlias(_ aliasID: UUID) {
        pendingPlaceRegistrationStayID = nil
        selectedPlaceAliasID = aliasID
        selectedTab = .places
    }

    private func showStayOnMap(_ stay: StayEntity) {
        pendingMapSelectionID = stay.id
        selectedTab = .map
    }

    private func showCandidateOnMap(_ candidate: StayCandidateEntity) {
        pendingMapSelectionID = candidate.id
        selectedTab = .map
    }

    private func openPlaceRegistration(_ stayID: UUID) {
        selectedPlaceAliasID = nil
        pendingPlaceRegistrationStayID = stayID
        selectedTab = .places
    }

    private func refreshMotionAuthorizationState() {
        motionAuthorizationStatus = CMMotionActivityManager.authorizationStatus()
    }

    private func handleMotionPermissionAction() {
        guard CMMotionActivityManager.isActivityAvailable() else {
            return
        }

        guard motionAuthorizationStatus == .notDetermined else {
            guard let url = URL(string: UIApplication.openSettingsURLString) else {
                return
            }
            openURL(url)
            return
        }

        motionActivityManager.queryActivityStarting(
            from: Date().addingTimeInterval(-60),
            to: Date(),
            to: .main
        ) { _, _ in
            Task { @MainActor in
                refreshMotionAuthorizationState()
            }
        }
    }

    private func completeInitialSetup() {
        refreshMotionAuthorizationState()
        guidedSetupStageRawValue = GuidedSetupStage.places.rawValue
        resumeGuidedSetup()
        SilicaOnboardingStorage.markCompleted()
        subscriptionManager.startProTrialIfNeeded()

        let updates = {
            isInitialSetupOnboardingPresented = false
        }
        if reduceMotion {
            updates()
        } else {
            withAnimation(.easeInOut(duration: 0.28), updates)
        }
    }

    private func resumeGuidedSetup() {
        guard guidedSetupStage == .places else { return }
        #if SILICA_ONBOARDING_PREVIEW
        return
        #else
        var descriptor = FetchDescriptor<PlaceAliasEntity>()
        descriptor.fetchLimit = 1
        if let savedPlaces = try? modelContext.fetch(descriptor), savedPlaces.isEmpty == false {
            guidedSetupStageRawValue = GuidedSetupStage.export.rawValue
        }
        #endif
    }

    private func advanceGuidedSetup(to stage: GuidedSetupStage) {
        let generator = UIImpactFeedbackGenerator(style: .light)
        generator.prepare()
        generator.impactOccurred(intensity: 0.72)
        guidedSetupStageRawValue = stage.rawValue
    }

    private func finishGuidedSetup() {
        selectedTab = .map
        advanceGuidedSetup(to: .confirmation)
    }

    private func dismissGuidedSetupCompletion() {
        selectedTab = .map
        advanceGuidedSetup(to: .complete)
        presentTrialExpirationPaywallIfNeeded()
    }

    private func presentTrialExpirationPaywallIfNeeded() {
        guard isStartupSplashVisible == false,
              isAppUnlocked,
              isWelcomeOnboardingPresented == false,
              isInitialSetupOnboardingPresented == false,
              guidedSetupStage == .complete,
              subscriptionManager.customerInfo != nil,
              subscriptionManager.isSilicaProActive == false,
              subscriptionManager.shouldPresentProTrialExpirationPaywall else {
            return
        }
        isTrialExpirationPaywallPresented = true
    }

    private func authenticateForAppUnlock() {
        guard faceIDLockEnabled else {
            isAppUnlocked = true
            return
        }

        let context = LAContext()
        var error: NSError?
        guard context.canEvaluatePolicy(.deviceOwnerAuthenticationWithBiometrics, error: &error) else {
            unlockErrorMessage = error?.localizedDescription ?? AppLanguage.localized("Face IDを利用できません")
            return
        }

        context.evaluatePolicy(
            .deviceOwnerAuthenticationWithBiometrics,
            localizedReason: AppLanguage.localized("Silicaの位置履歴を表示します")
        ) { success, error in
            let errorDescription = error?.localizedDescription
            Task { @MainActor in
                isAppUnlocked = success
                unlockErrorMessage = success ? nil : (errorDescription ?? AppLanguage.localized("認証できませんでした"))
            }
        }
    }

    private func beginLanguageChange(to newLanguage: AppLanguage) {
        guard newLanguage != appLanguage, pendingLanguage == nil else {
            return
        }

        pendingLanguage = newLanguage
        splashGeneration += 1
        let generation = splashGeneration
        let startedAt = DispatchTime.now().uptimeNanoseconds
        isStartupSplashExiting = false

        Task { @MainActor in
            if reduceMotion == false {
                try? await Task.sleep(
                    nanoseconds: Self.languagePickerSettleDelayNanoseconds
                )
            }

            guard Task.isCancelled == false,
                  generation == splashGeneration,
                  pendingLanguage == newLanguage else {
                return
            }

            if reduceMotion {
                isStartupSplashVisible = true
            } else {
                withAnimation(.easeInOut(duration: 0.38)) {
                    isStartupSplashVisible = true
                }
            }

            if reduceMotion == false {
                try? await Task.sleep(
                    nanoseconds: Self.languageContentSwapDelayNanoseconds
                )
            }

            guard generation == splashGeneration,
                  pendingLanguage == newLanguage else {
                return
            }

            AppLanguage.persist(newLanguage)
            appLanguage = newLanguage
            contentGeneration += 1

            scheduleStartupSplashDismissal(
                startedAt: startedAt,
                minimumDuration: Self.minimumLanguageChangeSplashDurationNanoseconds
            )
            pendingLanguage = nil
        }
    }

    private func scheduleStartupSplashDismissal(
        startedAt: UInt64,
        minimumDuration: UInt64
    ) {
        let generation = splashGeneration
        let elapsed = DispatchTime.now().uptimeNanoseconds - startedAt
        let remaining = minimumDuration > elapsed
            ? minimumDuration - elapsed
            : 0

        Task { @MainActor in
            if remaining > 0 {
                try? await Task.sleep(nanoseconds: remaining)
            }

            guard Task.isCancelled == false, generation == splashGeneration else {
                return
            }

            if reduceMotion {
                isStartupSplashVisible = false
            } else {
                withAnimation(.easeIn(duration: 0.34)) {
                    isStartupSplashExiting = true
                }

                try? await Task.sleep(nanoseconds: 360_000_000)
                guard Task.isCancelled == false, generation == splashGeneration else {
                    return
                }
                withAnimation(.easeOut(duration: 0.52)) {
                    isStartupSplashVisible = false
                }
            }
        }
    }
}

private struct StartupSplashView: View {
    private static let background = Color(red: 0.035, green: 0.035, blue: 0.045)
    let isExiting: Bool

    var body: some View {
        ZStack {
            Self.background

            Image("SilicaSplashLogo")
                .resizable()
                .scaledToFit()
                .frame(width: 96, height: 96)
                .grayscale(1)
        }
        .scaleEffect(isExiting ? 1.22 : 1)
        .opacity(isExiting ? 0 : 1)
        .ignoresSafeArea()
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(AppLanguage.localized("Silicaを読み込み中"))
    }
}

private struct AppLockView: View {
    let errorMessage: String?
    let unlock: () -> Void

    var body: some View {
        VStack(spacing: 20) {
            Image(systemName: "faceid")
                .font(.system(size: 44, weight: .medium))
                .foregroundStyle(.blue)
                .accessibilityHidden(true)
            Text(AppLanguage.localized("Silicaはロックされています"))
                .font(.title3.weight(.semibold))
            if let errorMessage {
                Text(errorMessage)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
            }
            Button(AppLanguage.localized("Face IDでロック解除"), action: unlock)
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
        }
        .padding(32)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color(uiColor: .systemGroupedBackground))
        .accessibilityElement(children: .contain)
    }
}

struct GuidedSetupStepBadge: View {
    let step: Int

    var body: some View {
        Text("\(step)/2")
            .font(.caption.weight(.semibold))
            .monospacedDigit()
            .foregroundStyle(Color.accentColor)
            .padding(.horizontal, 10)
            .padding(.vertical, 5)
            .background(Color.accentColor.opacity(0.12), in: Capsule())
            .accessibilityLabel(String(format: AppLanguage.localized("ステップ%1$d/2"), step))
            .accessibilityIdentifier("guidedSetup.step\(step)")
    }
}

struct GuidedSetupCard: View {
    let step: Int
    let title: String
    let message: String
    var titleIdentifier: String = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .firstTextBaseline, spacing: 12) {
                Text(AppLanguage.localized(title))
                    .font(.headline)
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityIdentifier(titleIdentifier)
                Spacer(minLength: 0)
                GuidedSetupStepBadge(step: step)
                    .fixedSize()
            }

            Text(AppLanguage.localized(message))
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(16)
        .guidedSetupCardSurface()
        .padding(.horizontal, 16)
        .padding(.top, 8)
        .padding(.bottom, 12)
    }
}

struct GuidedSetupCardSurface: ViewModifier {
    let cornerRadius: CGFloat

    func body(content: Content) -> some View {
        content
            .background {
                RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                    .fill(.regularMaterial)
                    .overlay {
                        RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                            .stroke(Color.white.opacity(0.28), lineWidth: 0.8)
                    }
                    .shadow(color: .black.opacity(0.06), radius: 2, y: 1)
                    .shadow(color: .black.opacity(0.14), radius: 14, y: 6)
            }
    }
}

extension View {
    func guidedSetupCardSurface(cornerRadius: CGFloat = 18) -> some View {
        modifier(GuidedSetupCardSurface(cornerRadius: cornerRadius))
    }
}

private struct GuidedSetupCompletionView: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @EnvironmentObject private var notionStore: SilicaNotionStore
    @ObservedObject var locationRecorder: LocationRecorder
    @AppStorage(ExportService.vaultBookmarkKey) private var vaultBookmarkData: Data?
    @AppStorage(ExportService.selectedDestinationKey)
    private var selectedDestinationRawValue = ExportDestination.obsidian.rawValue
    @AppStorage(ExportService.automaticExportEnabledKey) private var automaticExportEnabled = true
    @State private var isConfettiActive = true
    let hasProAccess: Bool
    let onContinue: () -> Void

    private var hasRecordingPermission: Bool {
        #if DEBUG
        if DebugLaunchConfiguration.forcesMissingLocationPermission {
            return false
        }
        #endif
        return locationRecorder.hasAutomaticRecordingPermission
    }

    private var isAutomaticExportReady: Bool {
        guard hasProAccess && automaticExportEnabled else { return false }
        switch ExportDestination(rawValue: selectedDestinationRawValue) ?? .obsidian {
        case .obsidian:
            return vaultBookmarkData != nil
        case .notion:
            return notionStore.isConnected && notionStore.hasSelectedDestination
        }
    }

    private var completionMessage: String {
        let introduction: String
        if hasRecordingPermission == false {
            introduction = "場所の登録ができました。滞在履歴の自動記録を始めるには、位置情報の許可が必要です。"
        } else if isAutomaticExportReady == false {
            introduction = "あなたの滞在履歴は自動で記録されます。出力先は「出力」タブからいつでも設定できます。"
        } else {
            introduction = "あなたの滞在履歴は自動で記録され、設定した出力先に出力されます。"
        }
        return AppLanguage.localized(introduction)
            + "\n\n"
            + AppLanguage.localized("よく行く場所をさらに登録すると、記録がもっと便利になります。")
    }

    var body: some View {
        if reduceMotion {
            completionContent
        } else {
            SWConfetti(
                isActive: $isConfettiActive,
                particleCount: 120,
                duration: 3.0
            ) {
                completionContent
            }
        }
    }

    private var completionContent: some View {
        ZStack {
            Color.black.opacity(0.24)
                .ignoresSafeArea()
            ScrollView {
                VStack(spacing: 24) {
                    Image(systemName: "checkmark.circle.fill")
                        .font(.system(size: 64, weight: .medium))
                        .foregroundStyle(Color.accentColor)
                        .accessibilityHidden(true)
                    VStack(spacing: 12) {
                        Text(AppLanguage.localized("お疲れさまでした！"))
                            .font(.title2.bold())
                            .accessibilityIdentifier("guidedSetup.completed")
                        Text(completionMessage)
                            .font(.body)
                            .foregroundStyle(.secondary)
                            .accessibilityIdentifier("guidedSetup.completionMessage")
                    }
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
                }
                .padding(28)
                .frame(maxWidth: 420)
                .background {
                    RoundedRectangle(cornerRadius: 28)
                        .fill(.regularMaterial)
                        .shadow(color: .black.opacity(0.24), radius: 18, y: 8)
                }
                .padding(24)
                .frame(maxWidth: .infinity)
            }
            .defaultScrollAnchor(.center)
        }
        .safeAreaInset(edge: .bottom, spacing: 0) {
            Button(action: onContinue) {
                Text(AppLanguage.localized("Silicaを始める"))
                    .font(.headline)
                    .frame(maxWidth: .infinity)
                    .frame(height: 56)
            }
            .buttonStyle(.plain)
            .foregroundStyle(.white)
            .background(Color.accentColor, in: Capsule())
            .accessibilityIdentifier("guidedSetup.start")
            .padding(.horizontal, 24)
            .padding(.top, 8)
            .padding(.bottom, 18)
        }
    }
}
