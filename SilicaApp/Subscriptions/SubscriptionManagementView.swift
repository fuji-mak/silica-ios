import Photos
import RevenueCat
import RevenueCatUI
import SwiftUI
import UIKit

struct SubscriptionManagementView: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.accessibilityVoiceOverEnabled) private var voiceOverEnabled
    @EnvironmentObject private var subscriptionManager: SubscriptionManager
    @AppStorage(SubscriptionCardPreferences.engravingKey) private var engravingText = ""
    @AppStorage(SubscriptionCardPreferences.paletteKey)
    private var cardPaletteRawValue = SubscriptionCardPalette.blue.rawValue
    @AppStorage("subscriptionCardStudioBackground")
    private var cardStudioBackgroundRawValue =
        CardStudioBackgroundStyle.adaptiveColor.rawValue
    @State private var isPaywallPresented = false
    @State private var isCustomerCenterPresented = false
    @State private var isCardFocused = false
    @State private var areCardStudioControlsVisible = false
    @State private var cardStudioControlsGeneration = 0
    @State private var cardImageSaveState: CardImageSaveState = .idle
    @State private var cardImageSaveErrorMessage: String?
    @FocusState private var isEngravingFocused: Bool
    @Namespace private var cardTransition

    var body: some View {
        ZStack {
            Color(uiColor: isCardFocused ? .systemBackground : .systemGroupedBackground)
                .ignoresSafeArea()

            if isCardFocused {
                focusedCardScreen
                    .transition(.opacity)
            } else {
                subscriptionContent
                    .transition(.opacity)
            }
        }
        .navigationTitle(AppLanguage.localized("サブスクリプション"))
        .navigationBarTitleDisplayMode(.inline)
        .toolbar(isCardFocused ? .hidden : .visible, for: .navigationBar)
        .toolbar(isCardFocused ? .hidden : .visible, for: .tabBar)
        .statusBarHidden(isCardFocused)
        .task {
            await subscriptionManager.refresh()
        }
        .sheet(isPresented: $isPaywallPresented) {
            SilicaCustomPaywallView()
        }
        .sheet(isPresented: $isCustomerCenterPresented) {
            CustomerCenterView()
        }
        .alert(
            subscriptionManager.errorTitle,
            isPresented: Binding(
                get: { subscriptionManager.errorMessage != nil },
                set: { isPresented in
                    if isPresented == false { subscriptionManager.clearError() }
                }
            )
        ) {
            Button(AppLanguage.localized("OK"), role: .cancel) {
                subscriptionManager.clearError()
            }
        } message: {
            Text(
                subscriptionManager.errorMessage
                    ?? AppLanguage.localized(
                        "購入に失敗しました。もう一度お試しいただくか、別の方法でのお支払いをお願いします。"
                )
            )
        }
        .alert(
            AppLanguage.localized("カード画像を保存できません"),
            isPresented: Binding(
                get: { cardImageSaveErrorMessage != nil },
                set: { isPresented in
                    if isPresented == false {
                        cardImageSaveErrorMessage = nil
                    }
                }
            )
        ) {
            Button(AppLanguage.localized("OK"), role: .cancel) {
                cardImageSaveErrorMessage = nil
            }
        } message: {
            Text(
                cardImageSaveErrorMessage
                    ?? AppLanguage.localized(
                        "カード画像を写真に保存できませんでした。"
                    )
            )
        }
        .onChange(of: engravingText, initial: true) { _, newValue in
            let limitedValue = String(
                newValue.prefix(SubscriptionCardPreferences.engravingCharacterLimit)
            )
            if limitedValue != newValue {
                engravingText = limitedValue
            }
        }
    }

    private var subscriptionContent: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 22) {
                VStack(alignment: .leading, spacing: 14) {
                    subscriptionCardPreview
                    engravingEditor
                    if isProActive {
                        cardColorPicker
                    }
                }
                planSummaryCard
                primaryAction
                benefitsSection
                restoreSection
            }
            .padding(.horizontal, 18)
            .padding(.top, 14)
            .padding(.bottom, 36)
        }
        .refreshable {
            await subscriptionManager.refresh()
        }
    }

    private var subscriptionCardPreview: some View {
        Button {
            guard isInitialLoading == false else { return }
            if isProActive {
                setCardFocused(true)
            } else {
                isPaywallPresented = true
            }
        } label: {
            subscriptionCard
                .matchedGeometryEffect(id: "subscription-card", in: cardTransition)
        }
        .buttonStyle(.plain)
        .disabled(isInitialLoading)
        .opacity(isInitialLoading ? 0.72 : 1)
        .accessibilityIdentifier("subscription-card-preview")
        .accessibilityHint(
            isInitialLoading
                ? AppLanguage.localized("Silicaのサブスクリプションを確認中")
                : isProActive
                    ? AppLanguage.localized("カードを画面中央に表示します")
                    : AppLanguage.localized("Proプランの選択画面を開きます")
        )
    }

    private var focusedCardScreen: some View {
        ZStack {
            CardStudioBackgroundView(
                style: selectedCardStudioBackground,
                palette: selectedCardPalette
            )
                .ignoresSafeArea()
                .contentShape(Rectangle())
                .onTapGesture {
                    setCardFocused(false)
                }

            Button {
                setCardFocused(false)
            } label: {
                subscriptionCard
                    .matchedGeometryEffect(id: "subscription-card", in: cardTransition)
            }
            .buttonStyle(.plain)
            .padding(.horizontal, 24)
            .offset(y: -14)
            .accessibilityLabel(AppLanguage.localized("カード表示を閉じる"))
            .accessibilityHint(
                AppLanguage.localized("サブスクリプション画面に戻ります")
            )

            VStack(spacing: 0) {
                Spacer()

                Color.clear
                    .frame(height: 176)
                    .contentShape(Rectangle())
                    .gesture(
                        DragGesture(minimumDistance: 0)
                            .onChanged { _ in
                                revealCardStudioControls()
                            }
                    )
                    .accessibilityHidden(true)
            }
            .ignoresSafeArea(edges: .bottom)

            if areCardStudioControlsVisible {
                cardStudioControls
                    .frame(maxHeight: .infinity, alignment: .bottom)
                    .padding(.bottom, 24)
                    .transition(
                        .move(edge: .bottom)
                            .combined(with: .opacity)
                    )
                    .zIndex(2)
            }
        }
        .onAppear {
            revealCardStudioControls()
        }
        .onDisappear {
            cardStudioControlsGeneration += 1
            areCardStudioControlsVisible = false
            cardImageSaveState = .idle
        }
        .onChange(of: voiceOverEnabled) { _, isEnabled in
            if isEnabled {
                revealCardStudioControls()
            }
        }
    }

    private var subscriptionCard: some View {
        SubscriptionCardView(
            isPro: isProActive,
            isLoading: isInitialLoading,
            engravingText: engravingText,
            palette: selectedCardPalette,
            showsNavigationCue: false,
            emphasizesShadow: isCardFocused
        )
    }

    private var selectedCardPalette: SubscriptionCardPalette {
        SubscriptionCardPalette(rawValue: cardPaletteRawValue) ?? .blue
    }

    private var selectedCardStudioBackground: CardStudioBackgroundStyle {
        CardStudioBackgroundStyle(rawValue: cardStudioBackgroundRawValue)
            ?? .adaptiveColor
    }

    private var cardStudioControlForeground: Color {
        selectedCardStudioBackground == .white ? .black : .white
    }

    private var cardStudioControlButtonWidth: CGFloat {
        AppLanguage.current == .english ? 124 : 108
    }

    @ViewBuilder
    private var cardStudioControls: some View {
        if #available(iOS 26.0, *) {
            cardStudioControlButtons
                .padding(6)
                .glassEffect(
                    .regular.interactive(),
                    in: Capsule()
                )
        } else {
            cardStudioControlButtons
                .padding(6)
                .background(.ultraThinMaterial, in: Capsule())
                .overlay {
                    Capsule()
                        .stroke(.white.opacity(0.18), lineWidth: 0.7)
                }
                .shadow(color: .black.opacity(0.20), radius: 18, y: 10)
        }
    }

    private var cardStudioControlButtons: some View {
        HStack(spacing: 0) {
            Button {
                cycleCardStudioBackground()
            } label: {
                Label(
                    AppLanguage.localized("背景"),
                    systemImage: "circle.lefthalf.filled"
                )
                .frame(width: cardStudioControlButtonWidth, height: 48)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityIdentifier("card-studio-background")
            .accessibilityLabel(AppLanguage.localized("カードの背景を変更"))
            .accessibilityValue(selectedCardStudioBackground.displayName)
            .accessibilityHint(
                AppLanguage.localized("次のカード背景へ切り替えます")
            )

            Rectangle()
                .fill(cardStudioControlForeground.opacity(0.18))
                .frame(width: 0.5, height: 24)
                .accessibilityHidden(true)

            Button {
                Task {
                    await saveCardArtwork()
                }
            } label: {
                HStack(spacing: 7) {
                    switch cardImageSaveState {
                    case .idle:
                        Image(systemName: "arrow.down.to.line")
                    case .saving:
                        ProgressView()
                            .controlSize(.small)
                            .tint(cardStudioControlForeground)
                    case .saved:
                        Image(systemName: "checkmark")
                    }

                    Text(cardImageSaveState.buttonTitle)
                }
                .frame(width: cardStudioControlButtonWidth, height: 48)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .disabled(cardImageSaveState == .saving)
            .accessibilityIdentifier("card-studio-save")
            .accessibilityLabel(
                AppLanguage.localized("カード画像を写真に保存")
            )
            .accessibilityValue(cardImageSaveState.buttonTitle)
        }
        .font(.subheadline.weight(.semibold))
        .foregroundStyle(cardStudioControlForeground)
    }

    private func setCardFocused(_ isFocused: Bool) {
        isEngravingFocused = false
        if isFocused == false {
            cardStudioControlsGeneration += 1
            areCardStudioControlsVisible = false
        }
        withAnimation(
            reduceMotion
                ? nil
                : .spring(response: 0.48, dampingFraction: 0.86)
        ) {
            isCardFocused = isFocused
        }
    }

    private func revealCardStudioControls() {
        guard isCardFocused else { return }

        cardStudioControlsGeneration += 1
        let generation = cardStudioControlsGeneration

        if areCardStudioControlsVisible == false {
            withAnimation(
                reduceMotion
                    ? nil
                    : .easeOut(duration: 0.24)
            ) {
                areCardStudioControlsVisible = true
            }
        }

        guard voiceOverEnabled == false else {
            return
        }

        Task { @MainActor in
            do {
                try await Task.sleep(nanoseconds: 4_500_000_000)
            } catch {
                return
            }

            guard generation == cardStudioControlsGeneration,
                  isCardFocused else {
                return
            }

            withAnimation(
                reduceMotion
                    ? nil
                    : .easeInOut(duration: 0.22)
            ) {
                areCardStudioControlsVisible = false
            }
            if cardImageSaveState == .saved {
                cardImageSaveState = .idle
            }
        }
    }

    private func cycleCardStudioBackground() {
        let styles = CardStudioBackgroundStyle.allCases
        let currentIndex = styles.firstIndex(
            of: selectedCardStudioBackground
        ) ?? 0
        let nextIndex = styles.index(
            after: currentIndex
        ) == styles.endIndex
            ? styles.startIndex
            : styles.index(after: currentIndex)
        let nextStyle = styles[nextIndex]

        withAnimation(
            reduceMotion
                ? nil
                : .easeInOut(duration: 0.24)
        ) {
            cardStudioBackgroundRawValue = nextStyle.rawValue
        }
        UISelectionFeedbackGenerator().selectionChanged()
        revealCardStudioControls()
    }

    @MainActor
    private func saveCardArtwork() async {
        guard cardImageSaveState != .saving else { return }

        cardImageSaveState = .saving
        revealCardStudioControls()

        var authorizationStatus = PHPhotoLibrary.authorizationStatus(
            for: .addOnly
        )
        if authorizationStatus == .notDetermined {
            authorizationStatus = await PHPhotoLibrary.requestAuthorization(
                for: .addOnly
            )
        }

        guard authorizationStatus == .authorized
                || authorizationStatus == .limited else {
            cardImageSaveState = .idle
            cardImageSaveErrorMessage = AppLanguage.localized(
                "写真への追加を許可してから、もう一度お試しください。"
            )
            UINotificationFeedbackGenerator().notificationOccurred(.error)
            revealCardStudioControls()
            return
        }

        let artwork = CardStudioExportArtwork(
            style: selectedCardStudioBackground,
            palette: selectedCardPalette,
            engravingText: engravingText
        )
        .frame(width: 360, height: 360)

        let renderer = ImageRenderer(content: artwork)
        renderer.scale = 3
        renderer.isOpaque = true

        guard let image = renderer.uiImage else {
            cardImageSaveState = .idle
            cardImageSaveErrorMessage = AppLanguage.localized(
                "カード画像の作成に失敗しました。"
            )
            UINotificationFeedbackGenerator().notificationOccurred(.error)
            revealCardStudioControls()
            return
        }

        guard let imageData = image.pngData() else {
            cardImageSaveState = .idle
            cardImageSaveErrorMessage = AppLanguage.localized(
                "カード画像の作成に失敗しました。"
            )
            UINotificationFeedbackGenerator().notificationOccurred(.error)
            revealCardStudioControls()
            return
        }

        let temporaryImageURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("silica-pro-card-\(UUID().uuidString)")
            .appendingPathExtension("png")

        do {
            try imageData.write(to: temporaryImageURL, options: .atomic)
            defer {
                try? FileManager.default.removeItem(at: temporaryImageURL)
            }

            try await Self.addCardArtworkToPhotoLibrary(
                at: temporaryImageURL
            )
            cardImageSaveState = .saved
            UINotificationFeedbackGenerator().notificationOccurred(.success)
            revealCardStudioControls()
        } catch {
            cardImageSaveState = .idle
            cardImageSaveErrorMessage = AppLanguage.localized(
                "カード画像を写真に保存できませんでした。"
            )
            UINotificationFeedbackGenerator().notificationOccurred(.error)
            revealCardStudioControls()
        }
    }

    nonisolated private static func addCardArtworkToPhotoLibrary(
        at fileURL: URL
    ) async throws {
        try await PHPhotoLibrary.shared().performChanges {
            PHAssetChangeRequest.creationRequestForAssetFromImage(
                atFileURL: fileURL
            )
        }
    }

    private var engravingEditor: some View {
        VStack(alignment: .leading, spacing: 9) {
            HStack(alignment: .firstTextBaseline) {
                Text(AppLanguage.localized("カードの刻印"))
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(.primary)

                Spacer()

                Text(
                    "\(engravingText.count)/\(SubscriptionCardPreferences.engravingCharacterLimit)"
                )
                .font(.caption.monospacedDigit())
                .foregroundStyle(.secondary)
                .accessibilityLabel(
                    String(
                        format: AppLanguage.localized("%1$ld / %2$ld文字"),
                        locale: AppLanguage.currentLocale,
                        engravingText.count,
                        SubscriptionCardPreferences.engravingCharacterLimit
                    )
                )
            }
            .padding(.horizontal, 4)

            HStack(spacing: 11) {
                Image(systemName: "signature")
                    .font(.system(size: 17, weight: .semibold))
                    .foregroundStyle(.blue)
                    .frame(width: 24, height: 24)
                    .accessibilityHidden(true)

                TextField(
                    AppLanguage.localized("刻印する文字"),
                    text: $engravingText
                )
                .font(.body)
                .textInputAutocapitalization(.words)
                .autocorrectionDisabled()
                .submitLabel(.done)
                .focused($isEngravingFocused)
                .accessibilityLabel(AppLanguage.localized("刻印する文字"))

                if engravingText.isEmpty == false {
                    Button {
                        engravingText = ""
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                            .font(.system(size: 18))
                            .foregroundStyle(.tertiary)
                            .frame(width: 32, height: 32)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel(AppLanguage.localized("刻印を消去"))
                }
            }
            .padding(.leading, 14)
            .padding(.trailing, 9)
            .frame(minHeight: 52)
            .background(
                Color(uiColor: .secondarySystemGroupedBackground),
                in: RoundedRectangle(cornerRadius: 15, style: .continuous)
            )
            .overlay {
                if isEngravingFocused {
                    RoundedRectangle(cornerRadius: 15, style: .continuous)
                        .stroke(Color.blue.opacity(0.72), lineWidth: 1.2)
                }
            }
            .animation(.easeOut(duration: 0.18), value: isEngravingFocused)
        }
    }

    private var cardColorPicker: some View {
        VStack(alignment: .leading, spacing: 11) {
            HStack(alignment: .firstTextBaseline) {
                Text(AppLanguage.localized("カードカラー"))
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(.primary)

                Spacer()

                Text(selectedCardPalette.displayName)
                    .font(.caption.weight(.medium))
                    .foregroundStyle(.secondary)
            }
            .padding(.horizontal, 4)

            HStack(spacing: 7) {
                ForEach(SubscriptionCardPalette.allCases) { palette in
                    cardColorButton(palette)
                }
            }
            .sensoryFeedback(.selection, trigger: cardPaletteRawValue)
        }
    }

    private func cardColorButton(_ palette: SubscriptionCardPalette) -> some View {
        let isSelected = selectedCardPalette == palette

        return Button {
            guard isSelected == false else { return }
            withAnimation(reduceMotion ? nil : .easeInOut(duration: 0.24)) {
                cardPaletteRawValue = palette.rawValue
            }
        } label: {
            VStack(spacing: 6) {
                palette.gradient
                    .frame(height: 36)
                    .clipShape(RoundedRectangle(cornerRadius: 11, style: .continuous))
                    .overlay {
                        RoundedRectangle(cornerRadius: 11, style: .continuous)
                            .stroke(
                                isSelected
                                    ? Color.primary.opacity(0.84)
                                    : Color(uiColor: .separator).opacity(0.34),
                                lineWidth: isSelected ? 2 : 0.7
                            )
                    }
                    .overlay {
                        if isSelected {
                            Image(systemName: "checkmark")
                                .font(.system(size: 11, weight: .bold))
                                .foregroundStyle(.white)
                                .frame(width: 20, height: 20)
                                .background(.black.opacity(0.30), in: Circle())
                        }
                    }

                Text(palette.displayName)
                    .font(.system(size: 10, weight: isSelected ? .semibold : .regular))
                    .foregroundStyle(isSelected ? .primary : .secondary)
                    .lineLimit(1)
                    .minimumScaleFactor(0.72)
            }
            .frame(maxWidth: .infinity)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(palette.displayName)
        .accessibilityValue(
            AppLanguage.localized(isSelected ? "選択中" : "未選択")
        )
        .accessibilityHint(AppLanguage.localized("カードカラーを変更します"))
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }

    private var planSummaryCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .firstTextBaseline, spacing: 12) {
                VStack(alignment: .leading, spacing: 4) {
                    Text(AppLanguage.localized("現在のプラン"))
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.secondary)
                        .textCase(.uppercase)
                        .tracking(0.5)

                    Text(currentPlanTitle)
                        .font(.title3.weight(.semibold))
                        .foregroundStyle(.primary)
                }

                if isProTrialActive == false {
                    Spacer(minLength: 12)
                    statusPill
                }
            }

            Text(currentPlanDetail)
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(18)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            Color(uiColor: .secondarySystemGroupedBackground),
            in: RoundedRectangle(cornerRadius: 18, style: .continuous)
        )
        .accessibilityElement(children: .contain)
    }

    private var statusPill: some View {
        HStack(spacing: 6) {
            if isInitialLoading {
                ProgressView()
                    .controlSize(.mini)
                    .tint(statusTint)
            } else {
                Image(systemName: isProActive ? "checkmark" : "circle.fill")
                    .font(.caption2.weight(.bold))
            }

            Text(statusTitle)
                .font(.caption.weight(.semibold))
        }
        .foregroundStyle(statusTint)
        .padding(.horizontal, 10)
        .frame(minHeight: 28)
        .background(statusTint.opacity(0.11), in: Capsule())
        .accessibilityElement(children: .combine)
    }

    private var primaryAction: some View {
        Button {
            if isPaidProActive {
                isCustomerCenterPresented = true
            } else {
                isPaywallPresented = true
            }
        } label: {
            HStack(spacing: 10) {
                if isInitialLoading {
                    ProgressView()
                        .controlSize(.small)
                        .tint(.white)
                    Text(AppLanguage.localized("確認中"))
                } else {
                    Image(systemName: isPaidProActive ? "slider.horizontal.3" : "sparkles")
                        .accessibilityHidden(true)
                    Text(
                        isPaidProActive
                            ? AppLanguage.localized("契約内容を管理")
                            : AppLanguage.localized("Proプランを見る")
                    )
                }

                Spacer()

                if isInitialLoading == false {
                    Image(systemName: "chevron.right")
                        .font(.caption.weight(.bold))
                        .accessibilityHidden(true)
                }
            }
            .font(.headline)
            .foregroundStyle(.white)
            .padding(.horizontal, 18)
            .frame(maxWidth: .infinity)
            .frame(minHeight: 54)
            .background(
                LinearGradient(
                    colors: [
                        Color(red: 0.04, green: 0.25, blue: 0.72),
                        Color(red: 0.0, green: 0.43, blue: 1.0),
                    ],
                    startPoint: .leading,
                    endPoint: .trailing
                ),
                in: RoundedRectangle(cornerRadius: 16, style: .continuous)
            )
            .contentShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
        }
        .buttonStyle(.plain)
        .disabled(isInitialLoading)
        .opacity(isInitialLoading ? 0.72 : 1)
    }

    private var benefitsSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            sectionTitle(AppLanguage.localized("Proでできること"))
                .padding(.horizontal, 4)

            VStack(spacing: 0) {
                benefitRow(
                    symbol: "clock.arrow.circlepath",
                    tint: .green,
                    title: AppLanguage.localized("すべての履歴を見返す"),
                    detail: AppLanguage.localized("期間を気にせず、過去の記録へアクセス")
                )
                benefitDivider
                benefitRow(
                    symbol: "square.and.arrow.down",
                    tint: .orange,
                    title: AppLanguage.localized("滞在履歴を自動出力"),
                    detail: AppLanguage.localized("出力後はAIエージェントとの連携も可能")
                )
                benefitDivider
                benefitRow(
                    symbol: "mappin.and.ellipse",
                    tint: .orange,
                    title: AppLanguage.localized("登録場所を無制限に"),
                    detail: AppLanguage.localized("よく行く場所を無制限に管理")
                )
            }
            .background(
                Color(uiColor: .secondarySystemGroupedBackground),
                in: RoundedRectangle(cornerRadius: 20, style: .continuous)
            )
        }
    }

    private var restoreSection: some View {
        VStack(spacing: 10) {
            Button {
                Task { await subscriptionManager.restorePurchases() }
            } label: {
                HStack(spacing: 8) {
                    if subscriptionManager.isRestoring {
                        ProgressView()
                            .controlSize(.small)
                    } else {
                        Image(systemName: "arrow.clockwise")
                            .accessibilityHidden(true)
                    }

                    Text(AppLanguage.localized("購入を復元"))
                }
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(.blue)
                .frame(maxWidth: .infinity)
                .frame(minHeight: 44)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .disabled(subscriptionManager.isRestoring)

            Text(
                AppLanguage.localized(
                    "購入と契約の管理はApple IDを通じて安全に行われます。"
                )
            )
            .font(.footnote)
            .foregroundStyle(.secondary)
            .multilineTextAlignment(.center)
            .padding(.horizontal, 20)
        }
    }

    private var isProActive: Bool {
        #if DEBUG
        DebugLaunchConfiguration.forcesProSubscription || subscriptionManager.hasProAccess
        #else
        subscriptionManager.hasProAccess
        #endif
    }

    private var isPaidProActive: Bool {
        #if DEBUG
        DebugLaunchConfiguration.forcesProSubscription
            || subscriptionManager.isSilicaProActive
        #else
        subscriptionManager.isSilicaProActive
        #endif
    }

    private var isProTrialActive: Bool {
        subscriptionManager.isProTrialActive && isPaidProActive == false
    }

    private var isInitialLoading: Bool {
        #if DEBUG
        if DebugLaunchConfiguration.forcesProSubscription
            || DebugLaunchConfiguration.forcesFreeSubscription {
            return false
        }
        #endif
        return isProTrialActive == false
            && subscriptionManager.isLoading
            && subscriptionManager.customerInfo == nil
    }

    private var statusTitle: String {
        if isInitialLoading {
            return AppLanguage.localized("確認中")
        }
        if isProTrialActive {
            return AppLanguage.localized("体験中")
        }
        return isProActive
            ? AppLanguage.localized("有効")
            : AppLanguage.localized("利用中")
    }

    private var statusTint: Color {
        if isInitialLoading { return .secondary }
        return isProActive ? .blue : .secondary
    }

    private var currentPlanTitle: String {
        guard let entitlement = activeEntitlement else {
            if isProTrialActive {
                return AppLanguage.localized("Silica Pro体験")
            }
            return isProActive
                ? AppLanguage.localized("Silica Pro")
                : AppLanguage.localized("無料プラン")
        }

        let plan = SilicaSubscriptionPlan.allCases.first {
            $0.productIdentifiers.contains(entitlement.productIdentifier)
        }
        return plan.map { AppLanguage.localized($0.title) }
            ?? AppLanguage.localized("Silica Pro")
    }

    private var currentPlanDetail: String {
        guard let entitlement = activeEntitlement else {
            if isProTrialActive,
               let expirationDate = subscriptionManager.proTrialExpirationDate {
                let formattedDate = Self.planDateFormatter.string(from: expirationDate)
                return String(
                    format: AppLanguage.localized("%@まで、すべてのPro機能を利用できます"),
                    locale: AppLanguage.currentLocale,
                    formattedDate
                )
            }
            return isProActive
                ? AppLanguage.localized("すべてのPro機能を利用できます")
                : AppLanguage.localized("Silicaの基本機能を利用中")
        }
        guard let expirationDate = entitlement.expirationDate else {
            return AppLanguage.localized("期限なしで利用できます")
        }

        let formattedDate = Self.planDateFormatter.string(from: expirationDate)
        let format = entitlement.willRenew
            ? AppLanguage.localized("%@に自動更新")
            : AppLanguage.localized("%@まで利用できます")
        return String(format: format, locale: AppLanguage.currentLocale, formattedDate)
    }

    private var activeEntitlement: EntitlementInfo? {
        subscriptionManager.customerInfo?
            .entitlements
            .active[SubscriptionManager.entitlementIdentifier]
    }

    private static var planDateFormatter: DateFormatter {
        let formatter = DateFormatter()
        formatter.locale = AppLanguage.currentLocale
        formatter.dateStyle = .medium
        formatter.timeStyle = .none
        return formatter
    }

    private func sectionTitle(_ title: String) -> some View {
        Text(title)
            .font(.caption.weight(.semibold))
            .foregroundStyle(.secondary)
            .textCase(.uppercase)
            .tracking(0.5)
    }

    private func benefitRow(
        symbol: String,
        tint: Color,
        title: String,
        detail: String
    ) -> some View {
        HStack(alignment: .top, spacing: 14) {
            SettingsIcon(symbol: symbol, tint: tint)

            VStack(alignment: .leading, spacing: 3) {
                Text(title)
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(.primary)
                Text(detail)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Spacer(minLength: 0)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 14)
        .accessibilityElement(children: .combine)
    }

    private var benefitDivider: some View {
        Rectangle()
            .fill(Color(uiColor: .separator).opacity(0.24))
            .frame(height: 0.5)
            .padding(.leading, 60)
    }
}

private enum CardImageSaveState: Equatable {
    case idle
    case saving
    case saved

    var buttonTitle: String {
        switch self {
        case .idle:
            AppLanguage.localized("保存")
        case .saving:
            AppLanguage.localized("保存中")
        case .saved:
            AppLanguage.localized("保存済み")
        }
    }
}

private enum CardStudioBackgroundStyle: String, CaseIterable, Identifiable {
    case black
    case white
    case adaptiveColor
    case animatedMeshGradient
    case starNest
    case plasma

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .black:
            AppLanguage.localized("真っ黒")
        case .white:
            AppLanguage.localized("真っ白")
        case .adaptiveColor:
            AppLanguage.localized("カードカラー")
        case .animatedMeshGradient:
            AppLanguage.localized("メッシュグラデーション")
        case .starNest:
            AppLanguage.localized("スターネスト")
        case .plasma:
            AppLanguage.localized("プラズマ")
        }
    }
}

private struct CardStudioExportArtwork: View {
    let style: CardStudioBackgroundStyle
    let palette: SubscriptionCardPalette
    let engravingText: String

    var body: some View {
        ZStack {
            CardStudioBackgroundView(style: style, palette: palette)

            SubscriptionCardView(
                isPro: true,
                isLoading: false,
                engravingText: engravingText,
                palette: palette,
                showsNavigationCue: false
            )
            .padding(.horizontal, 26)
            .offset(y: -12)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .clipped()
        .environment(\.colorScheme, .dark)
    }
}

private struct CardStudioBackgroundView: View {
    let style: CardStudioBackgroundStyle
    let palette: SubscriptionCardPalette

    private var accent: Color {
        palette.rimLightColor
    }

    var body: some View {
        GeometryReader { proxy in
            Group {
                switch style {
                case .black:
                    Color.black
                case .white:
                    Color.white
                case .adaptiveColor:
                    adaptiveColorBackground
                case .animatedMeshGradient:
                    SWCardStudioAnimatedMeshGradient()
                case .starNest:
                    SWCardStudioStarNest()
                case .plasma:
                    SWCardStudioPlasma()
                }
            }
            .frame(width: proxy.size.width, height: proxy.size.height)
        }
        .clipped()
        .accessibilityHidden(true)
    }

    private var adaptiveColorBackground: some View {
        LinearGradient(
            stops: [
                .init(color: .black, location: 0),
                .init(color: accent.opacity(0.34), location: 0.58),
                .init(color: accent.opacity(0.92), location: 1),
            ],
            startPoint: .topLeading,
            endPoint: .bottomTrailing
        )
    }
}
