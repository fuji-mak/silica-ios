import CoreLocation
import CoreMotion
import Foundation
import LocalAuthentication
import SwiftData
import SwiftUI
import UniformTypeIdentifiers
import UIKit

enum AppAppearance: String, CaseIterable, Identifiable {
    case system
    case light
    case dark

    static let userDefaultsKey = "appAppearance"

    var id: String { rawValue }

    var title: String {
        switch self {
        case .system: AppLanguage.localized("システム")
        case .light: AppLanguage.localized("ライト")
        case .dark: AppLanguage.localized("ダーク")
        }
    }

    var colorScheme: ColorScheme? {
        switch self {
        case .system: nil
        case .light: .light
        case .dark: .dark
        }
    }

    static var current: AppAppearance {
        guard let storedValue = UserDefaults.standard.string(forKey: userDefaultsKey),
              let storedAppearance = AppAppearance(rawValue: storedValue) else {
            return .system
        }
        return storedAppearance
    }

    static func persist(_ appearance: AppAppearance) {
        UserDefaults.standard.set(appearance.rawValue, forKey: userDefaultsKey)
    }
}

struct SettingsView: View {
    static let faceIDLockEnabledKey = "faceIDLockEnabled"

    @Environment(\.modelContext) private var modelContext
    @Environment(\.openURL) private var openURL
    @EnvironmentObject private var locationRecorder: LocationRecorder
    @EnvironmentObject private var subscriptionManager: SubscriptionManager
    @EnvironmentObject private var notionStore: SilicaNotionStore
    @Query(sort: \StayEntity.arrivalAt, order: .reverse) private var stays: [StayEntity]
    @Query(sort: \PlaceAliasEntity.priority, order: .reverse) private var aliases: [PlaceAliasEntity]
    @Query(sort: \ExportRecordEntity.exportedAt, order: .reverse) private var exportRecords: [ExportRecordEntity]
    @AppStorage(ExportService.automaticExportEnabledKey) private var automaticExportEnabled = true
    @AppStorage(ExportService.automaticExportNotificationsEnabledKey)
    private var automaticExportNotificationsEnabled = true
    @AppStorage(ExportService.vaultBookmarkKey) private var vaultBookmarkData: Data?
    @AppStorage("vaultFolderDisplayName") private var vaultFolderDisplayName = ""
    @AppStorage(ExportService.selectedDestinationKey)
    private var selectedDestinationRawValue = ExportDestination.obsidian.rawValue
    @AppStorage(Self.faceIDLockEnabledKey) private var faceIDLockEnabled = false
    @AppStorage(SubscriptionCardPreferences.engravingKey) private var subscriptionCardEngraving = ""
    @AppStorage(SubscriptionCardPreferences.paletteKey)
    private var subscriptionCardPaletteRawValue = SubscriptionCardPalette.blue.rawValue
    @Binding var appearance: AppAppearance
    @Binding var language: AppLanguage
    @State private var navigationPath: [SettingsDestination]
    @State private var showingFolderPicker = false
    @State private var isPaywallPresented = false
    @State private var paywallPresentationOrigin: SettingsPaywallPresentationOrigin?
    @State private var faceIDErrorMessage: String?
    @State private var showingFeedback = false
    @State private var showingNotionPagePicker = false

    init(
        appearance: Binding<AppAppearance>,
        language: Binding<AppLanguage>
    ) {
        _appearance = appearance
        _language = language
        #if DEBUG
        _navigationPath = State(
            initialValue: DebugLaunchConfiguration.startsInSubscriptionManagement
                ? [.subscriptions]
                : []
        )
        #else
        _navigationPath = State(initialValue: [])
        #endif
        _stays = Query(sort: \StayEntity.arrivalAt, order: .reverse)
        _aliases = Query(sort: \PlaceAliasEntity.priority, order: .reverse)
        _exportRecords = Query(sort: \ExportRecordEntity.exportedAt, order: .reverse)
    }

    var body: some View {
        NavigationStack(path: $navigationPath) {
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 24) {
                    subscriptionCard
                    recordingStatusCard
                    permissionsSection
                    appearanceSection
                    languageSection
                    automaticExportSection
                    dataSection
                    aboutSection
                }
                .padding(.horizontal, 18)
                .padding(.top, 14)
                .padding(.bottom, 36)
            }
            .background(Color(uiColor: .systemBackground))
            .navigationTitle(AppLanguage.localized("設定"))
            .navigationBarTitleDisplayMode(.inline)
            .navigationDestination(for: SettingsDestination.self) { destination in
                switch destination {
                case .dataManagement:
                    DataManagementView()
                case .subscriptions:
                    SubscriptionManagementView()
                }
            }
            .fileImporter(
                isPresented: $showingFolderPicker,
                allowedContentTypes: [.folder],
                allowsMultipleSelection: false
            ) { result in
                do {
                    guard let url = try result.get().first else { return }
                    vaultBookmarkData = try ExportService.bookmarkData(forFolderURL: url)
                    vaultFolderDisplayName = url.lastPathComponent
                    requestAutomaticExportNotificationAuthorization()
                    runAutomaticExportIfNeeded()
                } catch {
                    faceIDErrorMessage = error.localizedDescription
                }
            }
            .alert(AppLanguage.localized("設定を変更できません"), isPresented: errorAlertBinding) {
                Button(AppLanguage.localized("OK"), role: .cancel) { faceIDErrorMessage = nil }
            } message: {
                Text(faceIDErrorMessage ?? AppLanguage.localized("Face IDの設定を確認してください。"))
            }
        }
        .sheet(
            isPresented: $isPaywallPresented,
            onDismiss: handlePaywallDismissal
        ) {
            SilicaCustomPaywallView()
        }
        .sheet(isPresented: $showingFeedback) {
            SilicaFeedbackView(isPro: showsProSubscriptionCard)
        }
        .sheet(isPresented: $showingNotionPagePicker) {
            NotionPagePickerView(store: notionStore)
        }
        .onChange(of: automaticExportAccessState, initial: true) { previousState, state in
            if state == 2 {
                if previousState != state {
                    requestAutomaticExportNotificationAuthorization()
                }
                runAutomaticExportIfNeeded()
            }
        }
        .onChange(of: notionStore.selectedItem?.id) {
            requestAutomaticExportNotificationAuthorization()
            runAutomaticExportIfNeeded()
        }
        .task(id: selectedDestinationRawValue) {
            if selectedDestination == .notion {
                await notionStore.refresh()
            }
            await requestAutomaticExportNotificationAuthorizationIfNeeded()
            runAutomaticExportIfNeeded()
        }
    }

    @ViewBuilder
    private var subscriptionCard: some View {
        if showsProSubscriptionCard {
            NavigationLink(value: SettingsDestination.subscriptions) {
                subscriptionCardContent
            }
            .buttonStyle(.plain)
            .accessibilityHint(
                AppLanguage.localized("サブスクリプションの管理画面を開きます")
            )
        } else {
            Button {
                presentPaywall(from: .freeSubscriptionCard)
            } label: {
                subscriptionCardContent
            }
            .buttonStyle(.plain)
            .disabled(isSubscriptionCardLoading)
            .opacity(isSubscriptionCardLoading ? 0.72 : 1)
            .accessibilityIdentifier("settings-subscription-card")
            .accessibilityHint(
                isSubscriptionCardLoading
                    ? AppLanguage.localized("Silicaのサブスクリプションを確認中")
                    : AppLanguage.localized("Proプランの選択画面を開きます")
            )
        }
    }

    private var subscriptionCardContent: some View {
        SubscriptionCardView(
            isPro: showsProSubscriptionCard,
            isLoading: isSubscriptionCardLoading,
            engravingText: subscriptionCardEngraving,
            palette: subscriptionCardPalette
        )
    }

    private var isSubscriptionCardLoading: Bool {
        showsProSubscriptionCard == false
            && subscriptionManager.isLoading
            && subscriptionManager.customerInfo == nil
    }

    private var showsProSubscriptionCard: Bool {
        #if DEBUG
        DebugLaunchConfiguration.forcesProSubscription || subscriptionManager.hasProAccess
        #else
        subscriptionManager.hasProAccess
        #endif
    }

    private var subscriptionCardPalette: SubscriptionCardPalette {
        SubscriptionCardPalette(rawValue: subscriptionCardPaletteRawValue) ?? .blue
    }

    private var recordingStatusCard: some View {
        HStack(spacing: 16) {
            VStack(alignment: .leading, spacing: 8) {
                Label(recordingStatusTitle, systemImage: recordingStatusSymbol)
                    .font(.title3.weight(.semibold))
                    .foregroundStyle(recordingStatusColor)
                recordingStatusDescriptionView
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
            Spacer(minLength: 12)
            Image(systemName: recordingStatusEmblemSymbol)
                .font(.system(size: 25, weight: .medium))
                .foregroundStyle(recordingStatusColor)
                .frame(width: 56, height: 56)
                .background(recordingStatusColor.opacity(0.10), in: Circle())
                .accessibilityHidden(true)
        }
        .padding(20)
        .settingsCard()
        .accessibilityElement(children: .combine)
    }

    private var permissionsSection: some View {
        SettingsSection(title: "権限とプライバシー") {
            SettingsValueRow(title: "位置情報", value: authorizationText, symbol: "location.fill", tint: .blue)
            SettingsValueRow(title: "正確な位置情報", value: accuracyAuthorizationText, symbol: "scope", tint: .blue)
            SettingsValueRow(title: "モーションとフィットネス", value: motionAuthorizationText, symbol: "figure.walk.motion", tint: .green)
            SettingsToggleRow(title: "Face IDでロック", symbol: "faceid", tint: .green, isOn: faceIDBinding)
            Button {
                guard let url = URL(string: UIApplication.openSettingsURLString) else { return }
                openURL(url)
            } label: {
                HStack {
                    Text(AppLanguage.localized("iPhoneの設定を開く"))
                    Spacer()
                    Image(systemName: "arrow.up.forward.app")
                }
                .frame(minHeight: 48)
                .padding(.horizontal, 16)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .foregroundStyle(.blue)
            .accessibilityHint(AppLanguage.localized("Silicaの位置情報とモーションの権限設定を開きます"))
        }
    }

    private var automaticExportSection: some View {
        SettingsSection(title: "自動出力") {
            SettingsToggleRow(
                title: "前日分を自動出力",
                symbol: "square.and.arrow.down",
                tint: .orange,
                isOn: automaticExportBinding
            )
            .disabled(isSubscriptionCardLoading)
            .opacity(isSubscriptionCardLoading ? 0.72 : 1)
            .accessibilityHint(
                isSubscriptionCardLoading
                    ? AppLanguage.localized("Silicaのサブスクリプションを確認中")
                    : showsProSubscriptionCard
                        ? AppLanguage.localized(automaticExportAccessibilityHint)
                        : AppLanguage.localized("Proプランの選択画面を開きます")
            )
            SettingsToggleRow(
                title: "出力完了を通知",
                symbol: "bell.fill",
                tint: .purple,
                isOn: $automaticExportNotificationsEnabled
            )
            .accessibilityIdentifier("settings-automatic-export-notifications-toggle")
            .accessibilityHint(
                AppLanguage.localized("前日分の出力内容が作成または更新されたときに通知します")
            )
            .onChange(of: automaticExportNotificationsEnabled) { _, isEnabled in
                if isEnabled {
                    requestAutomaticExportNotificationAuthorization()
                }
            }
            Button {
                configureAutomaticDestination()
            } label: {
                SettingsValueRow(
                    title: automaticDestinationTitle,
                    value: automaticDestinationValue,
                    symbol: automaticDestinationSymbol,
                    tint: .blue,
                    showsChevron: true
                )
            }
            .buttonStyle(.plain)
            SettingsValueRow(
                title: "最後の出力",
                value: lastExportText,
                symbol: "clock",
                tint: lastExportColor,
                valueColor: lastExportColor
            )
        }
    }

    private var automaticExportBinding: Binding<Bool> {
        Binding(
            get: {
                showsProSubscriptionCard
                    && automaticDestinationReady
                    && automaticExportEnabled
            },
            set: { isEnabled in
                guard isEnabled else {
                    automaticExportEnabled = false
                    return
                }
                guard isSubscriptionCardLoading == false else { return }
                guard showsProSubscriptionCard else {
                    presentPaywall(from: .automaticExport)
                    return
                }
                guard automaticDestinationReady else {
                    configureAutomaticDestination()
                    return
                }
                automaticExportEnabled = true
                requestAutomaticExportNotificationAuthorization()
                runAutomaticExportIfNeeded()
            }
        )
    }

    private func requestAutomaticExportNotificationAuthorization() {
        Task {
            guard showsProSubscriptionCard,
                  automaticExportEnabled,
                  automaticExportNotificationsEnabled,
                  automaticDestinationReady else {
                return
            }
            _ = await SilicaNotificationService.requestAuthorizationIfNeeded()
        }
    }

    private func requestAutomaticExportNotificationAuthorizationIfNeeded() async {
        guard showsProSubscriptionCard,
              automaticExportEnabled,
              automaticExportNotificationsEnabled,
              automaticDestinationReady else {
            return
        }
        _ = await SilicaNotificationService.requestAuthorizationIfNeeded()
    }

    /// 0: unresolved, 1: Free, 2: Pro.
    private var automaticExportAccessState: Int {
        if showsProSubscriptionCard { return 2 }
        if subscriptionManager.customerInfo == nil { return 0 }
        return 1
    }

    private var appearanceSection: some View {
        SettingsSection(title: "表示") {
            VStack(alignment: .leading, spacing: 14) {
                Label {
                    Text(AppLanguage.localized("カラーモード"))
                        .font(.body.weight(.medium))
                } icon: {
                    SettingsIcon(symbol: "circle.lefthalf.filled", tint: .blue)
                }

                Picker(AppLanguage.localized("カラーモード"), selection: $appearance) {
                    ForEach(AppAppearance.allCases) { option in
                        Text(option.title).tag(option)
                    }
                }
                .pickerStyle(.segmented)
                .accessibilityHint(AppLanguage.localized("Silicaの表示をシステム、ライト、ダークから選択します"))
            }
            .padding(16)
        }
    }

    private var languageSection: some View {
        SettingsSection(title: "言語") {
            VStack(alignment: .leading, spacing: 14) {
                Label {
                    Text(AppLanguage.localized("アプリの言語"))
                        .font(.body.weight(.medium))
                } icon: {
                    SettingsIcon(symbol: "globe", tint: .gray)
                }

                Picker(AppLanguage.localized("言語"), selection: $language) {
                    ForEach(AppLanguage.allCases) { option in
                        Text(option.title).tag(option)
                    }
                }
                .pickerStyle(.segmented)
            }
            .padding(16)
        }
    }

    private var dataSection: some View {
        SettingsSection(title: "データ") {
            SettingsValueRow(title: "位置履歴", value: AppLanguage.count(stays.count), symbol: "cylinder.split.1x2", tint: .green)
            SettingsValueRow(title: "登録場所", value: AppLanguage.count(aliases.count), symbol: "mappin.and.ellipse", tint: .orange)
            NavigationLink(value: SettingsDestination.dataManagement) {
                SettingsValueRow(title: "データを管理", value: "", symbol: "chart.bar.xaxis", tint: .gray, showsChevron: true)
            }
            .buttonStyle(.plain)
        }
    }

    private var aboutSection: some View {
        SettingsSection(title: "Silicaについて") {
            SettingsValueRow(title: "バージョン", value: appVersion, symbol: "info.circle", tint: .gray)
            NavigationLink {
                LegalDocumentView(document: .privacyPolicy)
            } label: {
                SettingsValueRow(
                    title: "プライバシーポリシー",
                    value: "",
                    symbol: "hand.raised",
                    tint: .blue,
                    showsChevron: true
                )
            }
            .buttonStyle(.plain)
            NavigationLink {
                LegalDocumentView(document: .termsOfUse)
            } label: {
                SettingsValueRow(
                    title: "利用規約",
                    value: "",
                    symbol: "doc.text",
                    tint: .orange,
                    showsChevron: true
                )
            }
            .buttonStyle(.plain)
            Link(destination: LegalDocument.supportPageURL) {
                SettingsValueRow(
                    title: "サポートページ",
                    value: "",
                    symbol: "questionmark.circle",
                    tint: .purple,
                    showsChevron: true
                )
            }
            Button {
                showingFeedback = true
            } label: {
                SettingsValueRow(
                    title: "お問い合わせ",
                    value: "",
                    symbol: "envelope",
                    tint: .green,
                    showsChevron: true
                )
            }
            .buttonStyle(.plain)
        }
    }

    private var recordingStatusTitle: String {
        if locationRecorder.hasAutomaticRecordingPermission == false {
            return AppLanguage.localized("自動記録は停止中")
        }
        if motionPermissionIsReady == false {
            return AppLanguage.localized("記録精度が低下中")
        }
        if locationRecorder.isMonitoring { return AppLanguage.localized("正常に記録中") }
        return AppLanguage.localized("記録を準備しています")
    }

    @ViewBuilder
    private var recordingStatusDescriptionView: some View {
        if locationRecorder.hasAutomaticRecordingPermission == false {
            Text(AppLanguage.localized("自動記録には位置情報の「常に許可」と「正確な位置情報」が必要です。"))
        } else if motionPermissionIsReady == false {
            Text(AppLanguage.localized("モーションとフィットネスを許可すると、滞在と通過の判定精度が上がり、移動方法や歩行距離も記録できます。"))
        } else if let error = locationRecorder.lastErrorMessage {
            Text(error)
        } else {
            Text(recordingStatusDescriptionKey)
        }
    }

    private var recordingStatusDescriptionKey: String {
        return locationRecorder.isMonitoring
            ? AppLanguage.localized("バックグラウンドで位置を記録しています")
            : AppLanguage.localized("位置情報の許可を確認しています")
    }

    private var recordingStatusColor: Color {
        locationRecorder.isMonitoring
            && locationRecorder.hasAutomaticRecordingPermission
            && motionPermissionIsReady
            ? .green
            : .orange
    }

    private var recordingStatusSymbol: String {
        if locationRecorder.hasAutomaticRecordingPermission == false {
            return "pause.circle.fill"
        }
        if motionPermissionIsReady == false {
            return "exclamationmark.triangle.fill"
        }
        return locationRecorder.isMonitoring ? "checkmark.circle.fill" : "pause.circle.fill"
    }

    private var recordingStatusEmblemSymbol: String {
        if locationRecorder.hasAutomaticRecordingPermission == false {
            return "location.slash.fill"
        }
        if motionPermissionIsReady == false {
            return "figure.walk.motion"
        }
        return "location.north.fill"
    }

    private var motionPermissionIsReady: Bool {
        PermissionStatusText.motionIsReady(
            CMMotionActivityManager.authorizationStatus(),
            isAvailable: CMMotionActivityManager.isActivityAvailable()
        )
    }

    private var authorizationText: String {
        PermissionStatusText.location(locationRecorder.authorizationStatus)
    }

    private var accuracyAuthorizationText: String {
        AppLanguage.localized(
            locationRecorder.accuracyAuthorization == .fullAccuracy ? "オン" : "オフ"
        )
    }

    private var motionAuthorizationText: String {
        PermissionStatusText.motion(
            CMMotionActivityManager.authorizationStatus(),
            isAvailable: CMMotionActivityManager.isActivityAvailable()
        )
    }

    private var folderDisplayName: String {
        guard vaultBookmarkData != nil else { return AppLanguage.localized("未設定") }
        return vaultFolderDisplayName.isEmpty ? AppLanguage.localized("設定済み") : vaultFolderDisplayName
    }

    private var selectedDestination: ExportDestination {
        ExportDestination(rawValue: selectedDestinationRawValue) ?? .obsidian
    }

    private var automaticDestinationReady: Bool {
        switch selectedDestination {
        case .obsidian:
            return vaultBookmarkData != nil
        case .notion:
            return notionStore.isConnected && notionStore.hasSelectedDestination
        }
    }

    private var automaticDestinationTitle: String {
        switch selectedDestination {
        case .obsidian:
            return "出力先フォルダ"
        case .notion:
            return "Notionの保存先"
        }
    }

    private var automaticDestinationValue: String {
        switch selectedDestination {
        case .obsidian:
            return folderDisplayName
        case .notion:
            if notionStore.isConnected == false {
                return AppLanguage.localized("未接続")
            }
            return notionStore.selectedDestinationTitle
                ?? AppLanguage.localized("未設定")
        }
    }

    private var automaticDestinationSymbol: String {
        selectedDestination == .obsidian ? "folder" : "doc.text"
    }

    private var automaticExportAccessibilityHint: String {
        switch selectedDestination {
        case .obsidian:
            return "前日の位置ログを設定したフォルダへ自動で書き出します"
        case .notion:
            return "前日の位置ログをNotionへ自動で同期します"
        }
    }

    private var lastExportText: String {
        guard let record = exportRecords.first else { return AppLanguage.localized("履歴なし") }
        let date = DateSupport.formatDateTime(record.exportedAt)
        return record.status == .success
            ? "\(date)\(AppLanguage.localized("・成功"))"
            : "\(date)\(AppLanguage.localized("・失敗"))"
    }

    private var lastExportColor: Color {
        guard let status = exportRecords.first?.status else { return .secondary }
        return status == .success ? .green : .red
    }

    private var appVersion: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "—"
    }

    private var faceIDBinding: Binding<Bool> {
        Binding(
            get: { faceIDLockEnabled },
            set: { newValue in
                if newValue { enableFaceIDLock() } else { faceIDLockEnabled = false }
            }
        )
    }

    private var errorAlertBinding: Binding<Bool> {
        Binding(
            get: { faceIDErrorMessage != nil },
            set: { isPresented in
                if isPresented == false { faceIDErrorMessage = nil }
            }
        )
    }

    private func enableFaceIDLock() {
        let context = LAContext()
        var error: NSError?
        guard context.canEvaluatePolicy(.deviceOwnerAuthenticationWithBiometrics, error: &error) else {
            faceIDErrorMessage = error?.localizedDescription ?? AppLanguage.localized("この端末ではFace IDを利用できません。")
            return
        }
        context.evaluatePolicy(
            .deviceOwnerAuthenticationWithBiometrics,
            localizedReason: AppLanguage.localized("Silicaの位置履歴を保護します")
        ) { success, error in
            let errorDescription = error?.localizedDescription
            Task { @MainActor in
                if success {
                    faceIDLockEnabled = true
                } else {
                    faceIDErrorMessage = errorDescription ?? AppLanguage.localized("Face IDで認証できませんでした。")
                }
            }
        }
    }

    private func presentPaywall(from origin: SettingsPaywallPresentationOrigin) {
        paywallPresentationOrigin = origin
        isPaywallPresented = true
    }

    private func configureAutomaticDestination() {
        switch selectedDestination {
        case .obsidian:
            showingFolderPicker = true
        case .notion:
            if notionStore.isConnected {
                showingNotionPagePicker = true
            } else {
                Task {
                    do {
                        openURL(try await notionStore.authorizationURL())
                    } catch {
                        faceIDErrorMessage = error.localizedDescription
                    }
                }
            }
        }
    }

    private func runAutomaticExportIfNeeded() {
        guard showsProSubscriptionCard else {
            return
        }
        Task { @MainActor in
            await AutomaticExportService.runYesterdayIfNeeded(
                modelContext: modelContext,
                notionStore: notionStore,
                isProActive: true
            )
        }
    }

    private func handlePaywallDismissal() {
        defer { paywallPresentationOrigin = nil }
        guard paywallPresentationOrigin == .freeSubscriptionCard else {
            return
        }
        guard navigationPath.last != .subscriptions else {
            return
        }
        navigationPath.append(.subscriptions)
    }
}

private struct SilicaFeedbackView: View {
    @Environment(\.dismiss) private var dismiss

    let isPro: Bool

    @State private var kind: FeedbackKind = .bug
    @State private var title = ""
    @State private var message = ""
    @State private var contactEmail = ""
    @State private var isSubmitting = false
    @State private var errorMessage: String?
    @State private var showingSuccess = false

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Picker(AppLanguage.localized("種類"), selection: $kind) {
                        ForEach(FeedbackKind.allCases) { item in
                            Text(item.title).tag(item)
                        }
                    }
                    .padding(.leading, 5)

                    TextField(AppLanguage.localized("件名"), text: $title)
                        .textInputAutocapitalization(.sentences)
                        .padding(.leading, 5)

                    ZStack(alignment: .topLeading) {
                        TextEditor(text: $message)
                            .frame(minHeight: 150)
                            if message.isEmpty {
                                Text(AppLanguage.localized("内容を入力してください"))
                                    .foregroundStyle(.tertiary)
                                    .padding(.top, 8)
                                    .padding(.leading, 5)
                                    .allowsHitTesting(false)
                            }
                        }
                        .frame(minHeight: 150)
                } header: {
                    Text(AppLanguage.localized("お問い合わせ"))
                }

                Section {
                    TextField(AppLanguage.localized("返信先メールアドレス（任意）"), text: $contactEmail)
                        .keyboardType(.emailAddress)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .padding(.leading, 5)
                } footer: {
                    Text(AppLanguage.localized("返信が必要な場合だけ入力してください。"))
                }

                if let errorMessage {
                    Section {
                        Text(errorMessage)
                            .foregroundStyle(.red)
                    }
                }

                Section {
                    Button {
                        submit()
                    } label: {
                        HStack {
                            Spacer()
                            if isSubmitting {
                                ProgressView()
                            } else {
                                Text(AppLanguage.localized("送信する"))
                                    .fontWeight(.semibold)
                            }
                            Spacer()
                        }
                    }
                    .disabled(isSubmitting || title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || message.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
            }
            .navigationTitle(AppLanguage.localized("お問い合わせ"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(AppLanguage.localized("閉じる")) { dismiss() }
                }
            }
            .alert(AppLanguage.localized("送信しました"), isPresented: $showingSuccess) {
                Button(AppLanguage.localized("OK")) { dismiss() }
            } message: {
                Text(AppLanguage.localized("お問い合わせを受け付けました。"))
            }
        }
    }

    private func submit() {
        isSubmitting = true
        errorMessage = nil

        let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String
        let payload = SilicaFeedbackPayload(
            kind: kind.rawValue,
            title: title,
            message: message,
            contactEmail: contactEmail.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                ? nil
                : contactEmail.trimmingCharacters(in: .whitespacesAndNewlines),
            appVersion: version,
            osVersion: UIDevice.current.systemVersion,
            deviceModel: UIDevice.current.model,
            locale: AppLanguage.current.rawValue,
            hasPro: isPro
        )

        Task {
            do {
                try await SilicaAPIClient.shared.sendFeedback(payload)
                isSubmitting = false
                showingSuccess = true
            } catch {
                isSubmitting = false
                errorMessage = error.localizedDescription
            }
        }
    }
}

private enum FeedbackKind: String, CaseIterable, Identifiable {
    case bug
    case feature
    case question
    case other

    var id: String { rawValue }

    var title: String {
        switch self {
        case .bug: return AppLanguage.localized("バグ報告")
        case .feature: return AppLanguage.localized("要望")
        case .question: return AppLanguage.localized("質問")
        case .other: return AppLanguage.localized("その他")
        }
    }
}

private enum SettingsDestination: Hashable {
    case dataManagement
    case subscriptions
}

private enum SettingsPaywallPresentationOrigin: Equatable {
    case freeSubscriptionCard
    case automaticExport
}

enum SubscriptionCardPalette: String, CaseIterable, Identifiable {
    case blue
    case graphite
    case purple
    case green
    case red

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .blue:
            AppLanguage.localized("ブルー")
        case .graphite:
            AppLanguage.localized("グラファイト")
        case .purple:
            AppLanguage.localized("パープル")
        case .green:
            AppLanguage.localized("グリーン")
        case .red:
            AppLanguage.localized("レッド")
        }
    }

    var gradient: LinearGradient {
        LinearGradient(
            gradient: Gradient(stops: gradientStops),
            startPoint: UnitPoint(x: 0.04, y: 0.04),
            endPoint: UnitPoint(x: 0.98, y: 0.96)
        )
    }

    var rimLightColor: Color {
        switch self {
        case .blue:
            Color(red: 0.34, green: 0.62, blue: 1.0)
        case .graphite:
            Color(red: 0.70, green: 0.76, blue: 0.86)
        case .purple:
            Color(red: 0.72, green: 0.46, blue: 1.0)
        case .green:
            Color(red: 0.24, green: 0.92, blue: 0.62)
        case .red:
            Color(red: 1.0, green: 0.36, blue: 0.48)
        }
    }

    private var gradientStops: [Gradient.Stop] {
        switch self {
        case .blue:
            [
                .init(color: Color(red: 0.004, green: 0.010, blue: 0.026), location: 0),
                .init(color: Color(red: 0.010, green: 0.040, blue: 0.12), location: 0.44),
                .init(color: Color(red: 0.010, green: 0.13, blue: 0.43), location: 0.76),
                .init(color: Color(red: 0.0, green: 0.29, blue: 0.86), location: 1),
            ]
        case .graphite:
            [
                .init(color: Color(red: 0.004, green: 0.006, blue: 0.012), location: 0),
                .init(color: Color(red: 0.025, green: 0.030, blue: 0.040), location: 0.44),
                .init(color: Color(red: 0.10, green: 0.11, blue: 0.13), location: 0.76),
                .init(color: Color(red: 0.27, green: 0.29, blue: 0.33), location: 1),
            ]
        case .purple:
            [
                .init(color: Color(red: 0.012, green: 0.006, blue: 0.026), location: 0),
                .init(color: Color(red: 0.050, green: 0.016, blue: 0.13), location: 0.44),
                .init(color: Color(red: 0.19, green: 0.045, blue: 0.40), location: 0.76),
                .init(color: Color(red: 0.46, green: 0.12, blue: 0.78), location: 1),
            ]
        case .green:
            [
                .init(color: Color(red: 0.002, green: 0.016, blue: 0.013), location: 0),
                .init(color: Color(red: 0.005, green: 0.065, blue: 0.055), location: 0.44),
                .init(color: Color(red: 0.015, green: 0.22, blue: 0.16), location: 0.76),
                .init(color: Color(red: 0.02, green: 0.50, blue: 0.32), location: 1),
            ]
        case .red:
            [
                .init(color: Color(red: 0.018, green: 0.004, blue: 0.008), location: 0),
                .init(color: Color(red: 0.090, green: 0.010, blue: 0.025), location: 0.44),
                .init(color: Color(red: 0.32, green: 0.025, blue: 0.075), location: 0.76),
                .init(color: Color(red: 0.72, green: 0.070, blue: 0.15), location: 1),
            ]
        }
    }
}

enum SubscriptionCardPreferences {
    static let engravingKey = "subscriptionCardEngraving"
    static let paletteKey = "subscriptionCardPalette"
    static let engravingCharacterLimit = 20
}

struct SubscriptionCardView: View {
    let isPro: Bool
    let isLoading: Bool
    let engravingText: String
    let palette: SubscriptionCardPalette
    let showsNavigationCue: Bool
    let emphasizesShadow: Bool
    let allowsTiltGesture: Bool
    let interactionTranslation: CGSize

    init(
        isPro: Bool,
        isLoading: Bool,
        engravingText: String,
        palette: SubscriptionCardPalette = .blue,
        showsNavigationCue: Bool = true,
        emphasizesShadow: Bool = false,
        allowsTiltGesture: Bool = true,
        interactionTranslation: CGSize = .zero
    ) {
        self.isPro = isPro
        self.isLoading = isLoading
        self.engravingText = engravingText
        self.palette = palette
        self.showsNavigationCue = showsNavigationCue
        self.emphasizesShadow = emphasizesShadow
        self.allowsTiltGesture = allowsTiltGesture
        self.interactionTranslation = interactionTranslation
    }

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @GestureState private var dragTranslation: CGSize = .zero

    private let creditCardAspectRatio: CGFloat = 1.586
    private let cornerRadius: CGFloat = 17

    private var activeDragTranslation: CGSize {
        allowsTiltGesture ? dragTranslation : interactionTranslation
    }

    private var tilt: CGSize {
        guard reduceMotion == false else { return .zero }
        return CGSize(
            width: max(-1, min(1, activeDragTranslation.width / 120)),
            height: max(-1, min(1, activeDragTranslation.height / 120))
        )
    }

    var body: some View {
        Group {
            if isPro {
                SilicaPolishedAluminum(tilt: tilt, intensity: 0.05) {
                    proCard
                }
            } else {
                freeCard
            }
        }
        .aspectRatio(creditCardAspectRatio, contentMode: .fit)
        .frame(maxWidth: .infinity)
        .clipShape(cardShape)
        .rotation3DEffect(
            .degrees(Double(tilt.width) * 11),
            axis: (x: 0, y: 1, z: 0),
            perspective: 0.5
        )
        .rotation3DEffect(
            .degrees(Double(-tilt.height) * 11),
            axis: (x: 1, y: 0, z: 0),
            perspective: 0.5
        )
        .shadow(
            color: .black.opacity(
                emphasizesShadow
                    ? (activeDragTranslation == .zero ? 0.36 : 0.42)
                    : (activeDragTranslation == .zero ? 0.24 : 0.30)
            ),
            radius: emphasizesShadow
                ? (activeDragTranslation == .zero ? 28 : 34)
                : (activeDragTranslation == .zero ? 20 : 26),
            x: 0,
            y: emphasizesShadow
                ? (activeDragTranslation == .zero ? 18 : 22)
                : (activeDragTranslation == .zero ? 12 : 16)
        )
        .contentShape(cardShape)
        .simultaneousGesture(
            cardDragGesture,
            including: allowsTiltGesture ? .all : .none
        )
        .animation(.spring(response: 0.38, dampingFraction: 0.78), value: activeDragTranslation)
        .accessibilityElement(children: .combine)
        .accessibilityLabel(accessibilityTitle)
        .accessibilityHint(
            showsNavigationCue
                ? AppLanguage.localized("サブスクリプションの管理画面を開きます")
                : ""
        )
    }

    private var cardShape: RoundedRectangle {
        RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
    }

    private var cardDragGesture: some Gesture {
        DragGesture(minimumDistance: 6)
            .updating($dragTranslation) { value, state, _ in
                guard reduceMotion == false else { return }
                state = value.translation
            }
    }

    private var proCard: some View {
        ZStack {
            palette.gradient

            VStack(alignment: .leading, spacing: 0) {
                HStack(alignment: .top) {
                    VStack(alignment: .leading, spacing: 7) {
                        Text("Silica")
                            .font(.system(size: 13, weight: .regular, design: .default))
                            .tracking(2.2)
                            .foregroundStyle(.white.opacity(0.90))

                        Text("PRO")
                            .font(.system(size: 42, weight: .regular, design: .default))
                            .tracking(0.6)
                            .foregroundStyle(
                                LinearGradient(
                                    colors: [
                                        Color(red: 0.98, green: 0.98, blue: 0.99),
                                        Color(red: 0.72, green: 0.74, blue: 0.79),
                                        Color(red: 0.94, green: 0.95, blue: 0.97),
                                        Color(red: 0.56, green: 0.59, blue: 0.66),
                                    ],
                                    startPoint: .top,
                                    endPoint: .bottom
                                )
                            )
                    }

                    Spacer()

                    Image("SilicaSplashLogo")
                        .resizable()
                        .scaledToFit()
                        .frame(width: 42, height: 42)
                        .offset(x: 11.5)
                        .opacity(0.94)
                        .accessibilityHidden(true)
                }

                Spacer()

                HStack(alignment: .bottom, spacing: 12) {
                    engravingMark

                    Spacer(minLength: 12)

                    if showsNavigationCue {
                        Image(systemName: "chevron.right")
                            .font(.system(size: 19, weight: .light))
                            .foregroundStyle(.white.opacity(0.86))
                            .accessibilityHidden(true)
                    }
                }
            }
            .foregroundStyle(.white)
            .padding(.horizontal, 25)
            .padding(.vertical, 25)
        }
        .overlay {
            ZStack {
                SubscriptionCardRimLight(cornerRadius: cornerRadius)
                    .stroke(
                        LinearGradient(
                            stops: [
                                .init(color: .clear, location: 0),
                                .init(color: .clear, location: 0.08),
                                .init(color: .white.opacity(0.48), location: 0.23),
                                .init(color: palette.rimLightColor.opacity(0.28), location: 0.58),
                                .init(color: .clear, location: 0.90),
                                .init(color: .clear, location: 1),
                            ],
                            startPoint: .leading,
                            endPoint: .trailing
                        ),
                        style: StrokeStyle(lineWidth: 0.9, lineCap: .round, lineJoin: .round)
                    )

                SubscriptionCardTrailingEdge(
                    cornerRadius: cornerRadius,
                    inset: 0.55
                )
                    .stroke(
                        LinearGradient(
                            stops: [
                                .init(color: .clear, location: 0),
                                .init(color: .black.opacity(0.01), location: 0.10),
                                .init(color: .black.opacity(0.04), location: 0.24),
                                .init(color: .black.opacity(0.10), location: 0.40),
                                .init(color: .black.opacity(0.24), location: 0.56),
                                .init(color: .black.opacity(0.14), location: 0.70),
                                .init(color: palette.rimLightColor.opacity(0.05), location: 0.82),
                                .init(color: palette.rimLightColor.opacity(0.01), location: 0.94),
                                .init(color: .clear, location: 1),
                            ],
                            startPoint: UnitPoint(x: 1, y: 0.42),
                            endPoint: UnitPoint(x: 0.58, y: 1)
                        ),
                        style: StrokeStyle(lineWidth: 0.8, lineCap: .round, lineJoin: .round)
                    )

                SubscriptionCardTrailingEdge(
                    cornerRadius: cornerRadius,
                    inset: 1.65
                )
                .stroke(
                    LinearGradient(
                        stops: [
                            .init(color: .clear, location: 0),
                            .init(color: palette.rimLightColor.opacity(0.005), location: 0.10),
                            .init(color: palette.rimLightColor.opacity(0.02), location: 0.24),
                            .init(color: palette.rimLightColor.opacity(0.055), location: 0.40),
                            .init(color: .white.opacity(0.16), location: 0.56),
                            .init(color: .white.opacity(0.11), location: 0.70),
                            .init(color: palette.rimLightColor.opacity(0.065), location: 0.82),
                            .init(color: palette.rimLightColor.opacity(0.015), location: 0.94),
                            .init(color: .clear, location: 1),
                        ],
                        startPoint: UnitPoint(x: 1, y: 0.42),
                        endPoint: UnitPoint(x: 0.58, y: 1)
                    ),
                    style: StrokeStyle(lineWidth: 0.65, lineCap: .round, lineJoin: .round)
                )

                SubscriptionCardLeadingEdge(
                    cornerRadius: cornerRadius,
                    inset: 0.55
                )
                .stroke(
                    LinearGradient(
                        stops: [
                            .init(color: .clear, location: 0),
                            .init(color: .black.opacity(0.005), location: 0.10),
                            .init(color: .black.opacity(0.02), location: 0.24),
                            .init(color: .black.opacity(0.07), location: 0.40),
                            .init(color: .black.opacity(0.18), location: 0.60),
                            .init(color: .black.opacity(0.10), location: 0.72),
                            .init(color: .black.opacity(0.035), location: 0.84),
                            .init(color: .black.opacity(0.006), location: 0.94),
                            .init(color: .clear, location: 1),
                        ],
                        startPoint: UnitPoint(x: 0, y: 0.54),
                        endPoint: UnitPoint(x: 0.36, y: 1)
                    ),
                    style: StrokeStyle(lineWidth: 0.65, lineCap: .round, lineJoin: .round)
                )
            }
            .allowsHitTesting(false)
        }
    }

    private var freeCard: some View {
        ZStack {
            Color(uiColor: .secondarySystemBackground)

            VStack(alignment: .leading, spacing: 0) {
                VStack(alignment: .leading, spacing: 3) {
                    Text("Silica")
                        .font(.system(size: 13, weight: .regular, design: .default))
                        .tracking(2.2)
                        .foregroundStyle(.secondary)
                    Text("FREE")
                        .font(.system(size: 30, weight: .regular, design: .default))
                        .tracking(0.6)
                        .foregroundStyle(.primary)
                }

                Spacer()

                HStack(alignment: .bottom, spacing: 10) {
                    engravingMark

                    Spacer(minLength: 10)

                    if showsNavigationCue {
                        HStack(spacing: 6) {
                            Text(isLoading ? AppLanguage.localized("確認中") : AppLanguage.localized("プランを見る"))
                                .font(.subheadline.weight(.semibold))
                                .foregroundStyle(.blue)
                            Image(systemName: "chevron.right")
                                .font(.caption.weight(.bold))
                                .foregroundStyle(.blue)
                                .accessibilityHidden(true)
                        }
                    }
                }
            }
            .padding(20)
        }
        .overlay {
            RoundedRectangle(cornerRadius: 20, style: .continuous)
                .stroke(Color(uiColor: .separator).opacity(0.42), lineWidth: 0.8)
        }
    }

    @ViewBuilder
    private var engravingMark: some View {
        if engravingText.isEmpty == false {
            ZStack(alignment: .leading) {
                Text(engravingText)
                    .foregroundStyle(
                        isPro
                            ? Color.black.opacity(0.72)
                            : Color(uiColor: .systemBackground).opacity(0.62)
                    )
                    .offset(x: 0.55, y: 0.75)

                Text(engravingText)
                    .foregroundStyle(
                        isPro
                            ? Color.white.opacity(0.52)
                            : Color.primary.opacity(0.52)
                    )
            }
            .font(.system(size: 10, weight: .regular, design: .default))
            .tracking(0.8)
            .lineLimit(1)
            .minimumScaleFactor(0.72)
            .frame(maxWidth: 178, alignment: .leading)
            .accessibilityLabel(
                "\(AppLanguage.localized("カードの刻印"))、\(engravingText)"
            )
        }
    }

    private var accessibilityTitle: String {
        let planTitle: String
        if isLoading {
            planTitle = AppLanguage.localized("Silicaのサブスクリプションを確認中")
        } else {
            planTitle = isPro
                ? AppLanguage.localized("Silica Pro")
                : AppLanguage.localized("無料プラン")
        }

        guard engravingText.isEmpty == false else { return planTitle }
        return "\(planTitle)、\(AppLanguage.localized("カードの刻印"))、\(engravingText)"
    }
}

/// A short top-edge highlight that catches the card's primary light source.
private struct SubscriptionCardRimLight: Shape {
    let cornerRadius: CGFloat

    func path(in rect: CGRect) -> Path {
        let inset: CGFloat = 0.55
        let radius = min(cornerRadius - inset, min(rect.width, rect.height) / 2)

        var path = Path()
        path.move(to: CGPoint(x: radius + inset, y: inset))
        path.addLine(to: CGPoint(x: rect.maxX - radius, y: inset))
        return path
    }
}

/// A partial lower-trailing edge adds depth without outlining the whole card.
private struct SubscriptionCardTrailingEdge: Shape {
    let cornerRadius: CGFloat
    let inset: CGFloat

    func path(in rect: CGRect) -> Path {
        let radius = min(cornerRadius - inset, min(rect.width, rect.height) / 2)
        let trailingX = rect.maxX - inset
        let bottomY = rect.maxY - inset

        var path = Path()
        path.move(to: CGPoint(x: trailingX, y: rect.minY + rect.height * 0.42))
        path.addLine(to: CGPoint(x: trailingX, y: bottomY - radius))
        path.addQuadCurve(
            to: CGPoint(x: trailingX - radius, y: bottomY),
            control: CGPoint(x: trailingX, y: bottomY)
        )
        path.addLine(to: CGPoint(x: rect.minX + rect.width * 0.58, y: bottomY))
        return path
    }
}

/// A shorter, softer counterpart on the lower-leading edge balances the rim lighting.
private struct SubscriptionCardLeadingEdge: Shape {
    let cornerRadius: CGFloat
    let inset: CGFloat

    func path(in rect: CGRect) -> Path {
        let radius = min(cornerRadius - inset, min(rect.width, rect.height) / 2)
        let leadingX = rect.minX + inset
        let bottomY = rect.maxY - inset

        var path = Path()
        path.move(to: CGPoint(x: leadingX, y: rect.minY + rect.height * 0.54))
        path.addLine(to: CGPoint(x: leadingX, y: bottomY - radius))
        path.addQuadCurve(
            to: CGPoint(x: leadingX + radius, y: bottomY),
            control: CGPoint(x: leadingX, y: bottomY)
        )
        path.addLine(to: CGPoint(x: rect.minX + rect.width * 0.36, y: bottomY))
        return path
    }
}

/// Tilt-reactive metal finish adapted from ShipSwift's `SWPolishedAluminum`.
/// ShipSwift's shader is mainly tilt-driven; time remains fixed at zero.
private struct SilicaPolishedAluminum<Content: View>: View {
    let tilt: CGSize
    let intensity: Float
    let content: Content

    init(
        tilt: CGSize,
        intensity: Float,
        @ViewBuilder content: () -> Content
    ) {
        self.tilt = tilt
        self.intensity = intensity
        self.content = content()
    }

    var body: some View {
        content.layerEffect(
            ShaderLibrary.silicaPolishedAluminum(
                .boundingRect,
                .float2(Float(tilt.width), Float(tilt.height)),
                .float(0),
                .float(intensity)
            ),
            maxSampleOffset: .zero
        )
    }
}

private struct SettingsSection<Content: View>: View {
    let title: String
    let content: () -> Content

    init(title: String, @ViewBuilder content: @escaping () -> Content) {
        self.title = title
        self.content = content
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(AppLanguage.localized(title))
                .font(.subheadline.weight(.medium))
                .foregroundStyle(.secondary)
                .padding(.horizontal, 4)
            VStack(spacing: 0) { content() }
                .settingsCard()
        }
    }
}

private struct SettingsValueRow: View {
    let title: String
    let value: String
    let symbol: String
    let tint: Color
    var showsChevron = false
    var valueColor: Color = .secondary

    var body: some View {
        HStack(spacing: 14) {
            SettingsIcon(symbol: symbol, tint: tint)
            Text(AppLanguage.localized(title)).foregroundStyle(.primary)
            Spacer(minLength: 10)
            if value.isEmpty == false {
                Text(value)
                    .foregroundStyle(valueColor)
                    .lineLimit(1)
                    .minimumScaleFactor(0.75)
            }
            if showsChevron {
                Image(systemName: "chevron.right")
                    .font(.footnote.weight(.semibold))
                    .foregroundStyle(.tertiary)
                    .accessibilityHidden(true)
            }
        }
        .padding(.horizontal, 16)
        .frame(minHeight: 58)
        .contentShape(Rectangle())
        .overlay(alignment: .bottom) {
            Rectangle()
                .fill(Color(uiColor: .separator).opacity(0.32))
                .frame(height: 0.5)
                .padding(.leading, 58)
        }
        .accessibilityElement(children: .combine)
    }
}

enum LegalDocument: String, Identifiable {
    case privacyPolicy
    case termsOfUse

    var id: String { rawValue }

    var resourceName: String {
        let isEnglish = AppLanguage.current == .english
        switch self {
        case .privacyPolicy:
            return isEnglish ? "privacy-policy-en" : "privacy-policy"
        case .termsOfUse:
            return isEnglish ? "terms-of-use-en" : "terms-of-use"
        }
    }

    var titleKey: String {
        switch self {
        case .privacyPolicy: "プライバシーポリシー"
        case .termsOfUse: "利用規約"
        }
    }

    static var supportPageURL: URL {
        let path = AppLanguage.current == .english ? "" : "/ja"
        return URL(string: "https://silica.fuji-maki.me\(path)")!
    }
}

struct LegalDocumentView: View {
    let document: LegalDocument

    @State private var blocks: [LegalDocumentBlock] = []
    @State private var failedToLoad = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                documentHeader

                if blocks.isEmpty && failedToLoad == false {
                    ProgressView()
                        .frame(maxWidth: .infinity, alignment: .center)
                        .padding(.vertical, 32)
                } else if failedToLoad {
                    Text(AppLanguage.localized("法的文書を読み込めません。"))
                        .foregroundStyle(.secondary)
                        .padding(.vertical, 24)
                } else {
                    ForEach(Array(blocks.enumerated()), id: \.offset) { _, block in
                        documentBlockView(block)
                    }
                }
            }
            .padding(.horizontal, 20)
            .padding(.top, 18)
            .padding(.bottom, 34)
        }
        .background(Color(uiColor: .systemGroupedBackground))
        .navigationTitle(AppLanguage.localized(document.titleKey))
        .navigationBarTitleDisplayMode(.inline)
        .task(id: "\(document.id)-\(AppLanguage.current.rawValue)") {
            loadDocument()
        }
    }

    private func loadDocument() {
        failedToLoad = false
        guard let url = Bundle.main.url(forResource: document.resourceName, withExtension: "md"),
              let markdown = try? String(contentsOf: url, encoding: .utf8) else {
            failedToLoad = true
            return
        }

        blocks = parseBlocks(markdown)
        failedToLoad = blocks.isEmpty
    }

    private var documentHeader: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("SILICA")
                .font(.caption.weight(.bold))
                .tracking(1.4)
                .foregroundStyle(.secondary)

            Text(AppLanguage.localized(document.titleKey))
                .font(.system(size: 28, weight: .bold))
                .foregroundStyle(.primary)
        }
        .padding(.bottom, 18)
    }

    @ViewBuilder
    private func documentBlockView(_ block: LegalDocumentBlock) -> some View {
        switch block {
        case let .heading(text, level):
            Text(text)
                .font(level == 2 ? .title3.weight(.bold) : .headline.weight(.semibold))
                .foregroundStyle(.primary)
                .padding(.top, level == 2 ? 22 : 14)
                .padding(.bottom, 4)
        case let .metadata(text):
            Text(text)
                .font(.footnote.weight(.medium))
                .foregroundStyle(.secondary)
                .padding(.bottom, 2)
        case let .paragraph(text):
            markdownText(text)
                .font(.body)
                .foregroundStyle(.primary)
                .lineSpacing(5)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.top, 7)
        case let .bullet(text):
            HStack(alignment: .top, spacing: 10) {
                Text("•")
                    .font(.body.weight(.bold))
                    .foregroundStyle(.blue)
                markdownText(text)
                    .font(.body)
                    .foregroundStyle(.primary)
                    .lineSpacing(4)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.top, 6)
            .padding(.leading, 4)
        case let .numbered(number, text):
            HStack(alignment: .top, spacing: 10) {
                Text(number)
                    .font(.body.weight(.semibold))
                    .foregroundStyle(.blue)
                    .frame(width: 22, alignment: .leading)
                markdownText(text)
                    .font(.body)
                    .foregroundStyle(.primary)
                    .lineSpacing(4)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.top, 6)
            .padding(.leading, 4)
        case let .notice(text):
            HStack(alignment: .top, spacing: 10) {
                Image(systemName: "info.circle.fill")
                    .foregroundStyle(.blue)
                    .padding(.top, 2)
                markdownText(text)
                    .font(.footnote)
                    .foregroundStyle(.primary)
                    .lineSpacing(4)
            }
            .padding(14)
            .background(Color.blue.opacity(0.09), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .stroke(Color.blue.opacity(0.16), lineWidth: 0.8)
            }
            .padding(.top, 12)
        case .divider:
            Divider()
                .padding(.vertical, 12)
        }
    }

    private func markdownText(_ markdown: String) -> Text {
        var options = AttributedString.MarkdownParsingOptions()
        options.interpretedSyntax = .full
        guard let attributed = try? AttributedString(markdown: markdown, options: options) else {
            return Text(markdown)
        }
        return Text(attributed)
    }

    private func parseBlocks(_ markdown: String) -> [LegalDocumentBlock] {
        let lines = markdown.components(separatedBy: .newlines)
        var result: [LegalDocumentBlock] = []
        var paragraphLines: [String] = []
        var skippedTitle = false

        func flushParagraph() {
            guard paragraphLines.isEmpty == false else { return }
            result.append(.paragraph(paragraphLines.joined(separator: " ")))
            paragraphLines.removeAll(keepingCapacity: true)
        }

        for rawLine in lines {
            let line = rawLine.trimmingCharacters(in: .whitespacesAndNewlines)
            guard line.isEmpty == false else {
                flushParagraph()
                continue
            }

            if line.hasPrefix("# ") {
                flushParagraph()
                if skippedTitle == false {
                    skippedTitle = true
                } else {
                    result.append(.heading(String(line.dropFirst(2)), level: 2))
                }
            } else if line.hasPrefix("### ") {
                flushParagraph()
                result.append(.heading(String(line.dropFirst(4)), level: 3))
            } else if line.hasPrefix("## ") {
                flushParagraph()
                result.append(.heading(String(line.dropFirst(3)), level: 2))
            } else if line.hasPrefix("> ") {
                flushParagraph()
                result.append(.notice(String(line.dropFirst(2))))
            } else if line.hasPrefix("- ") {
                flushParagraph()
                result.append(.bullet(String(line.dropFirst(2))))
            } else if let numberEnd = line.firstIndex(of: "."),
                      numberEnd > line.startIndex,
                      line[..<numberEnd].allSatisfy(\.isNumber),
                      line.index(after: numberEnd) < line.endIndex {
                flushParagraph()
                let number = String(line[..<numberEnd]) + "."
                let textStart = line.index(after: numberEnd)
                let text = line[textStart...].trimmingCharacters(in: .whitespaces)
                result.append(.numbered(number, String(text)))
            } else if line == "---" {
                flushParagraph()
                result.append(.divider)
            } else if line.hasPrefix("最終更新日：")
                        || line.hasPrefix("施行日：")
                        || line.hasPrefix("提供者：")
                        || line.hasPrefix("Last updated:")
                        || line.hasPrefix("Effective date:")
                        || line.hasPrefix("Provider:") {
                flushParagraph()
                result.append(.metadata(line))
            } else {
                paragraphLines.append(line)
            }
        }

        flushParagraph()
        return result
    }
}

private enum LegalDocumentBlock {
    case heading(String, level: Int)
    case metadata(String)
    case paragraph(String)
    case bullet(String)
    case numbered(String, String)
    case notice(String)
    case divider
}

private struct SettingsToggleRow: View {
    let title: String
    let symbol: String
    let tint: Color
    @Binding var isOn: Bool

    var body: some View {
        Toggle(isOn: $isOn) {
            HStack(spacing: 14) {
                SettingsIcon(symbol: symbol, tint: tint)
                Text(AppLanguage.localized(title))
            }
        }
        .tint(.blue)
        .padding(.horizontal, 16)
        .frame(minHeight: 58)
        .overlay(alignment: .bottom) {
            Rectangle()
                .fill(Color(uiColor: .separator).opacity(0.32))
                .frame(height: 0.5)
                .padding(.leading, 58)
        }
    }
}

struct SettingsIcon: View {
    let symbol: String
    let tint: Color

    var body: some View {
        Image(systemName: symbol)
            .font(.system(size: 17, weight: .semibold))
            .foregroundStyle(.white)
            .frame(width: 30, height: 30)
            .background(tint, in: RoundedRectangle(cornerRadius: 7, style: .continuous))
            .accessibilityHidden(true)
    }
}

private struct SettingsCardModifier: ViewModifier {
    func body(content: Content) -> some View {
        content
            .background(Color(uiColor: .secondarySystemBackground), in: RoundedRectangle(cornerRadius: 18, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: 18, style: .continuous)
                    .stroke(Color(uiColor: .separator).opacity(0.18), lineWidth: 0.5)
                    .allowsHitTesting(false)
            }
            .shadow(color: .black.opacity(0.035), radius: 12, y: 5)
            .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
    }
}

private extension View {
    func settingsCard() -> some View { modifier(SettingsCardModifier()) }
}

private struct DataManagementView: View {
    @Environment(\.modelContext) private var modelContext
    @Query private var stays: [StayEntity]
    @Query private var movementPoints: [MovementPointEntity]
    @Query private var aliases: [PlaceAliasEntity]
    @Query private var exportRecords: [ExportRecordEntity]
    @AppStorage(ExportService.vaultBookmarkKey) private var vaultBookmarkData: Data?
    @AppStorage("vaultFolderDisplayName") private var vaultFolderDisplayName = ""
    @State private var deletionTarget: DeletionTarget?
    @State private var deleteConfirmationText = ""

    var body: some View {
        Form {
            Section(AppLanguage.localized("保存データ")) {
                LabeledContent(AppLanguage.localized("滞在記録"), value: AppLanguage.count(stays.count))
                LabeledContent(AppLanguage.localized("移動地点"), value: AppLanguage.count(movementPoints.count))
                LabeledContent(AppLanguage.localized("登録場所"), value: AppLanguage.count(aliases.count))
                LabeledContent(AppLanguage.localized("出力履歴"), value: AppLanguage.count(exportRecords.count))
            }
            Section(AppLanguage.localized("削除")) {
                Button(AppLanguage.localized("位置履歴を削除"), role: .destructive) { prepareDeletion(.locationHistory) }
                    .disabled(stays.isEmpty && movementPoints.isEmpty)
                Button(AppLanguage.localized("登録場所を削除"), role: .destructive) { prepareDeletion(.places) }
                    .disabled(aliases.isEmpty)
                Button(AppLanguage.localized("出力履歴を削除"), role: .destructive) { prepareDeletion(.exportHistory) }
                    .disabled(exportRecords.isEmpty)
                Button(AppLanguage.localized("すべての記録データを削除"), role: .destructive) { prepareDeletion(.all) }
            }
            Section {
                Text(AppLanguage.localized("出力済みのMarkdownファイルは削除されません。"))
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
        }
        .navigationTitle(AppLanguage.localized("データを管理"))
        .navigationBarTitleDisplayMode(.inline)
        .alert(deletionTarget?.title ?? AppLanguage.localized("データを削除しますか？"), isPresented: deletionAlertBinding) {
            TextField("silica", text: $deleteConfirmationText)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
            Button(AppLanguage.localized("削除"), role: .destructive) { performDeletion() }
                .disabled(deleteConfirmationText != "silica")
            Button(AppLanguage.localized("キャンセル"), role: .cancel) {
                deletionTarget = nil
                deleteConfirmationText = ""
            }
        } message: {
            Text(AppLanguage.localized("確認のため silica と入力してください。この操作は取り消せません。"))
        }
    }

    private var deletionAlertBinding: Binding<Bool> {
        Binding(
            get: { deletionTarget != nil },
            set: { isPresented in
                if isPresented == false {
                    deletionTarget = nil
                    deleteConfirmationText = ""
                }
            }
        )
    }

    private func prepareDeletion(_ target: DeletionTarget) {
        deleteConfirmationText = ""
        deletionTarget = target
    }

    private func performDeletion() {
        guard deleteConfirmationText == "silica", let deletionTarget else { return }
        let didChangeLocationData: Bool
        switch deletionTarget {
        case .locationHistory:
            for stay in stays { modelContext.delete(stay) }
            for point in movementPoints { modelContext.delete(point) }
            didChangeLocationData = true
        case .places:
            for alias in aliases { modelContext.delete(alias) }
            didChangeLocationData = false
        case .exportHistory:
            for record in exportRecords { modelContext.delete(record) }
            didChangeLocationData = false
        case .all:
            for stay in stays { modelContext.delete(stay) }
            for point in movementPoints { modelContext.delete(point) }
            for alias in aliases { modelContext.delete(alias) }
            for record in exportRecords { modelContext.delete(record) }
            vaultBookmarkData = nil
            vaultFolderDisplayName = ""
            didChangeLocationData = true
        }
        try? modelContext.save()
        if didChangeLocationData {
            NotificationCenter.default.post(
                name: .silicaLocationDataDidChange,
                object: nil
            )
        }
        self.deletionTarget = nil
        deleteConfirmationText = ""
    }
}

private enum DeletionTarget {
    case locationHistory
    case places
    case exportHistory
    case all

    var title: String {
        switch self {
        case .locationHistory: AppLanguage.localized("位置履歴を削除しますか？")
        case .places: AppLanguage.localized("登録場所を削除しますか？")
        case .exportHistory: AppLanguage.localized("出力履歴を削除しますか？")
        case .all: AppLanguage.localized("すべての記録データを削除しますか？")
        }
    }
}
