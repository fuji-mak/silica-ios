import SwiftData
import SwiftUI
#if canImport(SilicaCore)
import SilicaCore
#endif

struct ExportView: View {
    @Environment(\.modelContext) private var modelContext
    @Environment(\.openURL) private var openURL
    @EnvironmentObject private var subscriptionManager: SubscriptionManager
    @EnvironmentObject private var notionStore: SilicaNotionStore
    @Query(sort: \StayEntity.arrivalAt, order: .forward) private var stays: [StayEntity]
    @Query(sort: \PlaceAliasEntity.priority, order: .reverse) private var aliases: [PlaceAliasEntity]
    @Query(sort: \ExportRecordEntity.exportedAt, order: .reverse) private var records: [ExportRecordEntity]
    @AppStorage(ExportService.vaultBookmarkKey) private var vaultBookmarkData: Data?
    @AppStorage("vaultFolderDisplayName") private var vaultFolderDisplayName = ""
    @AppStorage(ExportService.selectedDestinationKey)
    private var selectedDestinationRawValue = ExportDestination.obsidian.rawValue
    @AppStorage(ExportService.automaticExportEnabledKey) private var automaticExportEnabled = true
    @AppStorage(ExportService.automaticExportNotificationsEnabledKey)
    private var automaticExportNotificationsEnabled = true
    @Binding var selectedDate: Date
    @State private var lastMessage: String?
    @State private var showingDatePicker = false
    @State private var showingFolderPicker = false
    @State private var isHistoryExpanded = false
    @State private var showingDeleteHistoryConfirmation = false
    @State private var showingNotionPagePicker = false
    @State private var isNotionSyncing = false
    @State private var isPaywallPresented = false
    @State private var historyPage = 0
    private let isGuidedSetup: Bool
    private let onGuidedSetupCompleted: () -> Void

    private static let historyPageSize = 5

    init(
        selectedDate: Binding<Date>,
        isGuidedSetup: Bool = false,
        onGuidedSetupCompleted: @escaping () -> Void = {}
    ) {
        _selectedDate = selectedDate
        _stays = Query(sort: \StayEntity.arrivalAt, order: .forward)
        _aliases = Query(sort: \PlaceAliasEntity.priority, order: .reverse)
        _records = Query(sort: \ExportRecordEntity.exportedAt, order: .reverse)
        self.isGuidedSetup = isGuidedSetup
        self.onGuidedSetupCompleted = onGuidedSetupCompleted
    }

    private var historyPageCount: Int {
        max(1, Int(ceil(Double(records.count) / Double(Self.historyPageSize))))
    }

    private var clampedHistoryPage: Int {
        min(historyPage, historyPageCount - 1)
    }

    private var pagedRecords: [ExportRecordEntity] {
        guard records.isEmpty == false else { return [] }
        let startIndex = clampedHistoryPage * Self.historyPageSize
        let endIndex = min(startIndex + Self.historyPageSize, records.count)
        return Array(records[startIndex..<endIndex])
    }

    private var showsHistoryPagination: Bool {
        records.count > Self.historyPageSize
    }

    private var markdownPreview: String {
        ExportService.markdown(
            date: selectedDate,
            stays: stays,
            aliases: aliases,
            modelContext: modelContext
        )
    }

    private var selectedDestination: ExportDestination {
        ExportDestination(rawValue: selectedDestinationRawValue) ?? .obsidian
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    destinationSection
                    if selectedDestination == .notion {
                        notionSection
                            .padding(.top, 30)
                    }
                    if selectedDestination == .obsidian {
                        folderSection
                            .padding(.top, 30)
                    }
                    automaticExportSection
                        .padding(.top, 24)
                    if isGuidedSetup, let lastMessage {
                        Text(lastMessage)
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                            .frame(maxWidth: .infinity, alignment: .center)
                            .padding(.top, 12)
                    }
                    if isGuidedSetup == false {
                        historySection
                            .padding(.top, 24)

                        Divider()
                            .padding(.vertical, 32)

                        manualExportSection
                    }
                }
                .padding(.horizontal, 20)
                .padding(.top, 20)
                .padding(.bottom, 32)
            }
            .background(Color(uiColor: .systemBackground))
            .navigationTitle(AppLanguage.localized("出力"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar(isGuidedSetup ? .hidden : .visible, for: .navigationBar)
            .onChange(of: records.count) {
                historyPage = min(historyPage, historyPageCount - 1)
            }
            .onChange(of: automaticDestinationReady) { _, isReady in
                if isReady {
                    runAutomaticExportIfNeeded()
                }
            }
            .onChange(of: selectedDestinationRawValue) { _, newValue in
                if newValue == ExportDestination.notion.rawValue {
                    Task {
                        await notionStore.refresh()
                        runAutomaticExportIfNeeded()
                    }
                } else {
                    runAutomaticExportIfNeeded()
                }
            }
            .onChange(of: notionStore.selectedItem?.id) {
                requestAutomaticExportNotificationAuthorization()
                runAutomaticExportIfNeeded()
            }
            .sheet(isPresented: $showingDatePicker) {
                DatePickerSheet(title: "出力日", date: $selectedDate) {
                    showingDatePicker = false
                }
            }
            .confirmationDialog(
                AppLanguage.localized("出力履歴を削除しますか？"),
                isPresented: $showingDeleteHistoryConfirmation,
                titleVisibility: .visible
            ) {
                Button(AppLanguage.localized("削除"), role: .destructive) {
                    deleteExportHistory()
                }
                Button(AppLanguage.localized("キャンセル"), role: .cancel) {}
            } message: {
                Text(
                    AppLanguage.current == .english
                        ? "Only \(records.count) export records will be deleted. Exported Markdown files will not be deleted."
                        : "出力履歴の記録\(records.count)件だけを削除します。出力済みのMarkdownファイルは削除されません。"
                )
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
                    lastMessage = AppLanguage.localized("出力先を保存しました")
                } catch {
                    lastMessage = error.localizedDescription
                }
            }
            .sheet(isPresented: $showingNotionPagePicker) {
                NotionPagePickerView(store: notionStore)
            }
            .safeAreaInset(edge: .top, spacing: 0) {
                if isGuidedSetup {
                    guidedSetupCard
                }
            }
            .safeAreaInset(edge: .bottom, spacing: 0) {
                if isGuidedSetup {
                    guidedSetupAction
                }
            }
        }
        .sheet(isPresented: $isPaywallPresented) {
            SilicaCustomPaywallView()
        }
        .onChange(of: automaticExportAccessState, initial: true) { previousState, state in
            if state == 2 {
                if previousState != state {
                    requestAutomaticExportNotificationAuthorization()
                }
                runAutomaticExportIfNeeded()
            }
        }
        .task {
            if selectedDestination == .notion {
                await notionStore.refresh()
            }
            await requestAutomaticExportNotificationAuthorizationIfNeeded()
            runAutomaticExportIfNeeded()
        }
    }

    private var guidedSetupCard: some View {
        GuidedSetupCard(
            step: 2,
            title: "保存先を選びましょう",
            message: "前日の記録を自動で保存できます。出力先を選び、自動出力をオンにしてください。"
        )
    }

    private var guidedSetupAction: some View {
        Group {
            if hasProAccess && automaticDestinationReady && automaticExportEnabled {
                Button(action: onGuidedSetupCompleted) {
                    Text(AppLanguage.localized("設定を完了"))
                        .font(.headline)
                        .frame(maxWidth: .infinity, minHeight: 54)
                        .foregroundStyle(.white)
                        .background(Color.accentColor, in: RoundedRectangle(cornerRadius: 14))
                }
                .buttonStyle(.plain)
                .accessibilityIdentifier("guidedSetup.finish")
                .padding(.horizontal, 16)
                .padding(.vertical, 8)
                .background(.bar)
            } else {
                Button(action: onGuidedSetupCompleted) {
                    Text(AppLanguage.localized("あとで設定する"))
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                        .padding(.horizontal, 12)
                        .frame(minHeight: 44)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityIdentifier("guidedSetup.skipExport")
                .frame(maxWidth: .infinity)
                .padding(.vertical, 4)
            }
        }
    }

    private var destinationSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            sectionTitle("出力先")

            Button {
                selectedDestinationRawValue = ExportDestination.obsidian.rawValue
            } label: {
                destinationCard(
                    destination: .obsidian,
                    title: "Markdown",
                    subtitle: "任意のフォルダにMarkdown形式で書き出し",
                    isSelected: selectedDestination == .obsidian,
                    isEnabled: true
                )
            }
            .buttonStyle(PressedCardButtonStyle())
            .accessibilityHint(AppLanguage.localized("Markdown形式の出力を選択します"))

            Button {
                selectedDestinationRawValue = ExportDestination.notion.rawValue
            } label: {
                destinationCard(
                    destination: .notion,
                    title: "Notion",
                    subtitle: "データベースへ直接同期",
                    isSelected: selectedDestination == .notion,
                    isEnabled: true
                )
            }
            .buttonStyle(PressedCardButtonStyle())
            .accessibilityLabel(AppLanguage.localized("Notion"))
            .accessibilityHint(AppLanguage.localized("Notionを出力先に選択します"))
        }
    }

    private var folderSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            sectionTitle("出力先フォルダ")

            Button {
                chooseFolder()
            } label: {
                HStack(spacing: 16) {
                    Image(systemName: "folder")
                        .font(.system(size: 24, weight: .regular))
                        .foregroundStyle(.blue)
                        .frame(width: 38)

                    VStack(alignment: .leading, spacing: 4) {
                        Text(folderDisplayName)
                            .font(.headline)
                            .foregroundStyle(.primary)
                            .lineLimit(1)
                        Text(
                            vaultBookmarkData == nil
                                ? AppLanguage.localized("タップしてフォルダを選択")
                                : AppLanguage.localized("タップして変更")
                        )
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                    }

                    Spacer(minLength: 8)
                    Image(systemName: "chevron.right")
                        .font(.system(size: 17, weight: .semibold))
                        .foregroundStyle(.tertiary)
                }
                .padding(.horizontal, 18)
                .frame(minHeight: 78)
                .cardSurface()
                .contentShape(Rectangle())
            }
            .buttonStyle(PressedCardButtonStyle())
            .accessibilityLabel(
                AppLanguage.current == .english
                    ? "Export folder, \(folderDisplayName)"
                    : "出力先フォルダ、\(folderDisplayName)"
            )
        }
    }

    private var notionSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            sectionTitle("Notion")

            if notionStore.isConnected {
                VStack(alignment: .leading, spacing: 14) {
                    HStack(spacing: 12) {
                        Image("NotionLogo")
                            .resizable()
                            .scaledToFit()
                            .frame(width: 30, height: 30)

                        VStack(alignment: .leading, spacing: 3) {
                            Text(AppLanguage.localized("Notionに接続済み"))
                                .font(.headline)
                            Text(notionStore.workspaceName ?? AppLanguage.localized("ワークスペース"))
                                .font(.subheadline)
                                .foregroundStyle(.secondary)
                        }

                        Spacer()
                        Image(systemName: "checkmark.circle.fill")
                            .foregroundStyle(.green)
                    }

                    Button {
                        showingNotionPagePicker = true
                    } label: {
                        HStack(spacing: 12) {
                            Image(systemName: "rectangle.stack")
                                .foregroundStyle(.blue)
                                .frame(width: 26)
                            VStack(alignment: .leading, spacing: 3) {
                                Text(notionStore.selectedItem?.displayTitle ?? AppLanguage.localized("保存先を選択"))
                                    .font(.headline)
                                    .foregroundStyle(.primary)
                                    .lineLimit(1)
                                Text(
                                    notionStore.selectedItem?.typeLabel
                                        ?? AppLanguage.localized("Notionのページまたはデータベース")
                                )
                                    .font(.subheadline)
                                    .foregroundStyle(.secondary)
                            }
                            Spacer()
                            Image(systemName: "chevron.right")
                                .foregroundStyle(.tertiary)
                        }
                        .padding(14)
                        .background(Color(uiColor: .tertiarySystemBackground), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                    }
                    .buttonStyle(.plain)

                    Button(AppLanguage.localized("Notionの接続を解除"), role: .destructive) {
                        Task { await notionStore.disconnect() }
                    }
                    .font(.subheadline)
                }
                .padding(16)
                .cardSurface()
            } else {
                Button {
                    connectToNotion()
                } label: {
                    HStack(spacing: 14) {
                        Image("NotionLogo")
                            .resizable()
                            .scaledToFit()
                            .frame(width: 34, height: 34)
                        VStack(alignment: .leading, spacing: 4) {
                            Text(AppLanguage.localized("Notionに接続"))
                                .font(.headline)
                                .foregroundStyle(.primary)
                            Text(AppLanguage.localized("Notionのページを保存先に設定"))
                                .font(.subheadline)
                                .foregroundStyle(.secondary)
                        }
                        Spacer()
                        if notionStore.isLoading {
                            ProgressView()
                        } else {
                            Image(systemName: "arrow.up.right")
                                .foregroundStyle(.blue)
                        }
                    }
                    .padding(16)
                    .cardSurface()
                }
                .buttonStyle(PressedCardButtonStyle())
                .disabled(notionStore.isLoading)
            }

            if let errorMessage = notionStore.errorMessage {
                Text(errorMessage)
                    .font(.footnote)
                    .foregroundStyle(.red)
            }
        }
    }

    private var periodSection: some View {
        let formattedDate = DateSupport.formatDay(selectedDate)

        return VStack(alignment: .leading, spacing: 12) {
            sectionTitle("出力する日付")

            Button {
                showingDatePicker = true
            } label: {
                HStack(spacing: 18) {
                    Image(systemName: "calendar")
                        .font(.system(size: 25, weight: .regular))
                        .foregroundStyle(.blue)
                        .frame(width: 38)

                    VStack(alignment: .leading, spacing: 3) {
                        Text(dayLabel)
                            .font(.headline)
                            .foregroundStyle(.primary)
                        Text(formattedDate)
                            .font(.body)
                            .foregroundStyle(.secondary)
                    }

                    Spacer()
                    Image(systemName: "chevron.right")
                        .font(.system(size: 17, weight: .semibold))
                        .foregroundStyle(.tertiary)
                }
                .padding(.horizontal, 18)
                .frame(minHeight: 82)
                .cardSurface()
                .contentShape(Rectangle())
            }
            .buttonStyle(PressedCardButtonStyle())
            .accessibilityLabel(
                AppLanguage.current == .english
                    ? "Export date, \(formattedDate)"
                    : "出力日、\(formattedDate)"
            )
        }
    }

    private var automaticExportSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            sectionTitle("自動出力")

            Toggle(isOn: automaticExportBinding) {
                VStack(alignment: .leading, spacing: 4) {
                    Text(AppLanguage.localized("自動出力"))
                        .font(.headline)
                    Text(automaticExportDescription)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
            }
            .tint(.blue)
            .padding(.horizontal, 18)
            .frame(minHeight: 78)
            .cardSurface()
            .disabled(
                isSubscriptionStatusLoading
                    || (hasProAccess && automaticDestinationReady == false)
            )
            .opacity(isSubscriptionStatusLoading ? 0.72 : 1)
            .accessibilityHint(
                isSubscriptionStatusLoading
                    ? AppLanguage.localized("Silicaのサブスクリプションを確認中")
                    : hasProAccess
                        ? AppLanguage.localized(automaticExportAccessibilityHint)
                        : AppLanguage.localized("Proプランの選択画面を開きます")
            )
        }
    }

    private var manualExportSection: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(AppLanguage.localized("手動出力"))
                .font(.title3.weight(.bold))

            periodSection
                .padding(.top, 24)
            previewSection
                .padding(.top, 30)
            exportButton
                .padding(.top, 28)

            if let lastMessage {
                Text(lastMessage)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .center)
                    .padding(.top, 12)
            }
        }
    }

    private var previewSection: some View {
        let previewMarkdown = markdownPreview

        return VStack(alignment: .leading, spacing: 12) {
            sectionTitle("プレビュー")

            ScrollView([.horizontal, .vertical], showsIndicators: true) {
                Text(previewMarkdown)
                    .font(.system(.callout, design: .monospaced))
                    .foregroundStyle(.primary)
                    .lineSpacing(5)
                    .fixedSize(horizontal: true, vertical: true)
                    .padding(18)
            }
            .frame(height: 260)
            .cardSurface()
            .accessibilityLabel(AppLanguage.localized("Markdownプレビュー"))
            .accessibilityValue(previewMarkdown)
        }
    }

    private var exportButton: some View {
        Button {
            if selectedDestination == .notion {
                syncSelectedDateToNotion()
            } else {
                exportSelectedDate()
            }
        } label: {
            HStack(spacing: 8) {
                if isNotionSyncing {
                    ProgressView()
                        .tint(.white)
                }
                Text(
                    selectedDestination == .notion
                        ? AppLanguage.localized("Notionに同期")
                        : AppLanguage.localized("Markdownを書き出す")
                )
            }
            .font(.headline)
                .frame(maxWidth: .infinity)
                .frame(minHeight: 56)
                .foregroundStyle(.white)
                .background(.blue, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        }
        .buttonStyle(PressedCardButtonStyle(scale: 0.985))
        .disabled(isNotionSyncing)
    }

    private var historySection: some View {
        DisclosureGroup(isExpanded: $isHistoryExpanded) {
            VStack(alignment: .leading, spacing: 14) {
                if records.isEmpty {
                    Text(AppLanguage.localized("履歴はありません"))
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                } else {
                    ForEach(pagedRecords) { record in
                        VStack(alignment: .leading, spacing: 4) {
                            Text(record.filePath.isEmpty ? AppLanguage.localized("書き出し失敗") : URL(fileURLWithPath: record.filePath).lastPathComponent)
                                .font(.subheadline.weight(.medium))
                            Text("\(DateSupport.formatDay(record.date)) / \(AppLanguage.localized(record.statusRawValue))")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                            if let error = record.errorMessage {
                                Text(error)
                                    .font(.caption)
                                    .foregroundStyle(.red)
                            }
                        }
                    }

                    if showsHistoryPagination {
                        historyPaginationControls
                    }

                    Button(AppLanguage.localized("出力履歴をすべて削除"), role: .destructive) {
                        showingDeleteHistoryConfirmation = true
                    }
                    .font(.subheadline)
                }
            }
            .padding(.top, 12)
        } label: {
            HStack {
                Label(AppLanguage.localized("出力履歴"), systemImage: "clock.arrow.circlepath")
                Spacer()
                Text(AppLanguage.count(records.count))
                    .foregroundStyle(.secondary)
            }
            .font(.subheadline.weight(.medium))
        }
        .padding(16)
        .cardSurface()
    }

    private func sectionTitle(_ title: String) -> some View {
        Text(AppLanguage.localized(title))
            .font(.headline)
            .foregroundStyle(.secondary)
    }

    private func destinationCard(
        destination: ExportDestination,
        title: String,
        subtitle: String,
        isSelected: Bool,
        isEnabled: Bool
    ) -> some View {
        HStack(spacing: 16) {
            DestinationIcon(destination: destination)
                .frame(width: 70, height: 70)

            VStack(alignment: .leading, spacing: 8) {
                Text(title)
                    .font(.title3.weight(.bold))
                    .foregroundStyle(isEnabled ? .primary : .secondary)
                Text(AppLanguage.localized(subtitle))
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }

            Spacer(minLength: 8)

            Group {
                if isSelected {
                    Image(systemName: "checkmark.circle.fill")
                        .font(.system(size: 27))
                        .symbolRenderingMode(.palette)
                        .foregroundStyle(.white, .blue)
                } else if isEnabled == false {
                    Text(AppLanguage.localized("近日対応"))
                        .font(.caption.weight(.medium))
                        .foregroundStyle(.secondary)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 5)
                        .background(Color(uiColor: .tertiarySystemFill), in: Capsule())
                } else {
                    // Reserve the same trailing width so text never reflows when selection changes.
                    Color.clear
                        .frame(width: 27, height: 27)
                }
            }
            .frame(minWidth: 27, minHeight: 27, alignment: .trailing)
        }
        .padding(.horizontal, 16)
        .frame(minHeight: 104)
        .cardSurface()
        .opacity(isEnabled ? 1 : 0.78)
        .contentShape(Rectangle())
    }

    private var dayLabel: String {
        let calendar = Calendar.current
        if calendar.isDateInToday(selectedDate) { return AppLanguage.localized("今日") }
        if calendar.isDateInYesterday(selectedDate) { return AppLanguage.localized("昨日") }
        if calendar.isDateInTomorrow(selectedDate) { return AppLanguage.localized("明日") }
        return AppLanguage.localized("指定日")
    }

    private var folderDisplayName: String {
        if vaultBookmarkData == nil {
            return AppLanguage.localized("未設定")
        }
        return vaultFolderDisplayName.isEmpty
            ? AppLanguage.localized("設定済みのフォルダ")
            : vaultFolderDisplayName
    }

    private var automaticExportBinding: Binding<Bool> {
        Binding(
            get: {
                hasProAccess && automaticDestinationReady && automaticExportEnabled
            },
            set: { isEnabled in
                guard isEnabled else {
                    automaticExportEnabled = false
                    return
                }
                guard isSubscriptionStatusLoading == false else { return }
                guard hasProAccess else {
                    isPaywallPresented = true
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
            guard hasProAccess,
                  automaticExportEnabled,
                  automaticExportNotificationsEnabled,
                  automaticDestinationReady else {
                return
            }
            _ = await SilicaNotificationService.requestAuthorizationIfNeeded()
        }
    }

    private func requestAutomaticExportNotificationAuthorizationIfNeeded() async {
        guard hasProAccess,
              automaticExportEnabled,
              automaticExportNotificationsEnabled,
              automaticDestinationReady else {
            return
        }
        _ = await SilicaNotificationService.requestAuthorizationIfNeeded()
    }

    private var automaticExportDescription: String {
        if isSubscriptionStatusLoading {
            return AppLanguage.localized("Silicaのサブスクリプションを確認中")
        }
        guard hasProAccess else {
            return AppLanguage.localized("Silica Proで前日の記録を自動出力できます")
        }
        switch selectedDestination {
        case .obsidian:
            guard vaultBookmarkData != nil else {
                return AppLanguage.localized("先に出力先フォルダを設定してください")
            }
            return AppLanguage.localized("前日の記録を自動で書き出します")
        case .notion:
            guard notionStore.isConnected else {
                return AppLanguage.localized("先にNotionに接続してください")
            }
            guard notionStore.hasSelectedDestination else {
                return AppLanguage.localized("先にNotionの保存先を選択してください")
            }
            return AppLanguage.localized("前日の記録をNotionへ自動で同期します")
        }
    }

    private var automaticDestinationReady: Bool {
        switch selectedDestination {
        case .obsidian:
            return vaultBookmarkData != nil
        case .notion:
            return notionStore.isConnected && notionStore.hasSelectedDestination
        }
    }

    private var automaticExportAccessibilityHint: String {
        switch selectedDestination {
        case .obsidian:
            return "前日の位置ログを設定したフォルダへ自動で書き出します"
        case .notion:
            return "前日の位置ログをNotionへ自動で同期します"
        }
    }

    private var hasProAccess: Bool {
        #if DEBUG
        DebugLaunchConfiguration.forcesProSubscription
            || subscriptionManager.hasProAccess
        #else
        subscriptionManager.hasProAccess
        #endif
    }

    private var isSubscriptionStatusLoading: Bool {
        #if DEBUG
        if DebugLaunchConfiguration.forcesProSubscription {
            return false
        }
        #endif
        return hasProAccess == false
            && subscriptionManager.isLoading
            && subscriptionManager.customerInfo == nil
    }

    /// 0: unresolved, 1: Free, 2: Pro.
    private var automaticExportAccessState: Int {
        if hasProAccess { return 2 }
        if subscriptionManager.customerInfo == nil { return 0 }
        return 1
    }

    private var historyPaginationControls: some View {
        HStack {
            Button {
                historyPage = max(0, clampedHistoryPage - 1)
            } label: {
                Image(systemName: "chevron.left")
                    .frame(width: 44, height: 44)
            }
            .disabled(clampedHistoryPage == 0)
            .accessibilityLabel(AppLanguage.localized("前の履歴ページ"))

            Spacer()
            Text("\(clampedHistoryPage + 1) / \(historyPageCount)")
                .font(.caption.monospacedDigit())
                .foregroundStyle(.secondary)
            Spacer()

            Button {
                historyPage = min(historyPageCount - 1, clampedHistoryPage + 1)
            } label: {
                Image(systemName: "chevron.right")
                    .frame(width: 44, height: 44)
            }
            .disabled(clampedHistoryPage >= historyPageCount - 1)
            .accessibilityLabel(AppLanguage.localized("次の履歴ページ"))
        }
        .buttonStyle(.plain)
    }

    private func chooseFolder() {
        showingFolderPicker = true
    }

    private func exportSelectedDate() {
        guard let vaultBookmarkData else {
            lastMessage = AppLanguage.localized("先に出力先フォルダを選択してください")
            return
        }

        do {
            let outputURL = try ExportService.exportFromBookmark(
                date: selectedDate,
                vaultBookmarkData: vaultBookmarkData,
                stays: stays,
                aliases: aliases,
                modelContext: modelContext
            )
            historyPage = 0
            lastMessage = AppLanguage.current == .english
                ? "\(outputURL.lastPathComponent) exported"
                : "\(outputURL.lastPathComponent) を書き出しました"
        } catch {
            historyPage = 0
            lastMessage = error.localizedDescription
        }
    }

    private func connectToNotion() {
        Task {
            do {
                let authorizationURL = try await notionStore.authorizationURL()
                openURL(authorizationURL)
            } catch {
                lastMessage = error.localizedDescription
            }
        }
    }

    private func configureAutomaticDestination() {
        switch selectedDestination {
        case .obsidian:
            chooseFolder()
        case .notion:
            if notionStore.isConnected {
                showingNotionPagePicker = true
            } else {
                connectToNotion()
            }
        }
    }

    private func runAutomaticExportIfNeeded() {
        guard hasProAccess else {
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

    private func syncSelectedDateToNotion() {
        guard notionStore.isConnected else {
            connectToNotion()
            return
        }
        guard notionStore.selectedItem != nil else {
            showingNotionPagePicker = true
            return
        }

        isNotionSyncing = true
        let markdown = markdownPreview
        Task {
            do {
                let result = try await notionStore.sync(
                    markdown: markdown,
                    date: DateSupport.formatISODate(selectedDate)
                )
                let title = notionStore.selectedItem?.displayTitle ?? "Notion"
                let record = ExportRecordEntity(
                    date: selectedDate,
                    filePath: "Notion - \(title)",
                    status: .success
                )
                modelContext.insert(record)
                try? modelContext.save()
                historyPage = 0
                lastMessage = result.mode == "created"
                    ? AppLanguage.localized("Notionにページを作成しました")
                    : AppLanguage.localized("Notionを更新しました")
            } catch {
                let record = ExportRecordEntity(
                    date: selectedDate,
                    filePath: "",
                    status: .failed,
                    errorMessage: error.localizedDescription
                )
                modelContext.insert(record)
                try? modelContext.save()
                historyPage = 0
                lastMessage = error.localizedDescription
            }
            isNotionSyncing = false
        }
    }

    private func deleteExportHistory() {
        guard records.isEmpty == false else { return }
        for record in records {
            modelContext.delete(record)
        }
        try? modelContext.save()
        historyPage = 0
        isHistoryExpanded = false
    }
}

struct NotionPagePickerView: View {
    @ObservedObject var store: SilicaNotionStore
    @Environment(\.dismiss) private var dismiss
    @State private var query = ""

    var body: some View {
        NavigationStack {
            Group {
                if store.isLoading && store.searchResults.isEmpty {
                    ProgressView()
                } else if store.searchResults.isEmpty {
                    ContentUnavailableView(
                        AppLanguage.localized("ページが見つかりません"),
                        systemImage: "doc.text.magnifyingglass",
                        description: Text(AppLanguage.localized("Notionで共有したページが表示されます"))
                    )
                } else {
                    List(store.searchResults) { item in
                        Button {
                            store.select(item)
                            dismiss()
                        } label: {
                            HStack(spacing: 12) {
                                Image(systemName: item.isDataSource ? "tablecells" : "doc.text")
                                    .foregroundStyle(.blue)
                                    .frame(width: 24)
                                VStack(alignment: .leading, spacing: 4) {
                                    Text(item.displayTitle)
                                        .foregroundStyle(.primary)
                                        .lineLimit(2)
                                    Text(item.typeLabel)
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                }
                                Spacer()
                                if store.selectedItem?.id == item.id {
                                    Image(systemName: "checkmark.circle.fill")
                                        .foregroundStyle(.blue)
                                }
                            }
                        }
                    }
                    .listStyle(.insetGrouped)
                }
            }
            .navigationTitle(AppLanguage.localized("Notionの保存先"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(AppLanguage.localized("閉じる")) { dismiss() }
                }
            }
            .searchable(text: $query, prompt: AppLanguage.localized("ページを検索"))
            .onSubmit(of: .search) {
                Task { await store.loadSearch(query: query.isEmpty ? nil : query) }
            }
            .task {
                await store.loadSearch()
            }
        }
    }
}

private struct DestinationIcon: View {
    let destination: ExportDestination

    var body: some View {
        ZStack {
            Circle()
                .fill(Color(uiColor: .systemBackground))
            switch destination {
            case .obsidian:
                Image("ObsidianLogo")
                    .resizable()
                    .scaledToFit()
                    .padding(13)
                    .accessibilityHidden(true)
            case .notion:
                Image("NotionLogo")
                    .resizable()
                    .scaledToFit()
                    .padding(13)
                    .accessibilityHidden(true)
            }
        }
        .overlay {
            Circle().stroke(Color(uiColor: .separator).opacity(0.22), lineWidth: 1)
        }
    }
}

private struct CardSurface: ViewModifier {
    func body(content: Content) -> some View {
        content
            .background(Color(uiColor: .secondarySystemBackground), in: RoundedRectangle(cornerRadius: 16, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: 16, style: .continuous)
                    .stroke(Color(uiColor: .separator).opacity(0.32), lineWidth: 1)
            }
    }
}

private extension View {
    func cardSurface() -> some View {
        modifier(CardSurface())
    }
}

private struct PressedCardButtonStyle: ButtonStyle {
    var scale: CGFloat = 0.99

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed ? scale : 1)
            .opacity(configuration.isPressed ? 0.82 : 1)
            .animation(.easeOut(duration: 0.16), value: configuration.isPressed)
    }
}
