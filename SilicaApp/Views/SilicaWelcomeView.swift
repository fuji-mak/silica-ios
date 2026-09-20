import CoreLocation
import CoreMotion
import SwiftUI
import UIKit

struct SilicaWelcomeView: View {
    let onContinue: () -> Void

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    private let pageCount = 5
    private let onboardingPhoneWidth: CGFloat = 250
    private let onboardingPhoneHeight: CGFloat = 544
    @State private var currentPage = 0
    @State private var isPreparingSetup = false
    @State private var didPlayWelcomeHaptic = false

    init(initialPage: Int = 0, onContinue: @escaping () -> Void) {
        self.onContinue = onContinue
        _currentPage = State(initialValue: min(max(initialPage, 0), 4))
    }

    var body: some View {
        ZStack {
            Color.black
                .ignoresSafeArea()

            VStack(spacing: 0) {
                TabView(selection: $currentPage) {
                    ForEach(0..<pageCount, id: \.self) { index in
                        onboardingPage(at: index)
                            .tag(index)
                    }
                }
                .tabViewStyle(.page(indexDisplayMode: .never))

                pageIndicator
                    .padding(.top, 10)
                    .padding(.bottom, 6)

                continueButton
                    .padding(.horizontal, 24)
                    .padding(.top, 8)
                    .padding(.bottom, 18)
            }
        }
        .task {
            guard didPlayWelcomeHaptic == false else {
                return
            }
            didPlayWelcomeHaptic = true

            await playWelcomeSuccessHaptic()
        }
    }

    private func playWelcomeSuccessHaptic() async {
        try? await Task.sleep(for: .milliseconds(70))
        guard Task.isCancelled == false else {
            return
        }

        let generator = UINotificationFeedbackGenerator()
        generator.prepare()
        generator.notificationOccurred(.success)
    }

    @ViewBuilder
    private func onboardingPage(at index: Int) -> some View {
        if index == 0 {
            VStack(spacing: 0) {
                Spacer(minLength: 0)

                Image("SilicaSplashLogo")
                    .resizable()
                    .scaledToFit()
                    .frame(width: 96, height: 96)
                    .grayscale(1)
                    .accessibilityHidden(true)

                Spacer()

                SWGlowSweepOnce(
                    baseColor: .gray,
                    glowColor: .white,
                    duration: 1.6,
                    bandWidth: 120,
                    startDelay: 0.5
                ) {
                    Text(AppLanguage.localized("Silicaへようこそ"))
                        .font(.system(size: 40, weight: .semibold))
                        .lineLimit(1)
                        .minimumScaleFactor(0.76)
                        .foregroundStyle(.white)
                }
                .accessibilityAddTraits(.isHeader)
                .offset(y: -48)

                Spacer(minLength: 0)
            }
            .padding(.horizontal, 24)
        } else if index == 1 {
            onboardingScreenshotPage(
                title: AppLanguage.localized("訪れた場所を記録"),
                imageName: onboardingImageName("SilicaMapOnboarding"),
                accessibilityLabel: AppLanguage.localized(
                    "東京周辺の訪問記録を表示したSilicaのマップ"
                )
            )
        } else if index == 2 {
            onboardingScreenshotPage(
                title: AppLanguage.localized("何もしなくても記録が溜まる"),
                imageName: onboardingImageName("SilicaLogOnboarding"),
                accessibilityLabel: AppLanguage.localized(
                    "訪問記録が並ぶSilicaのログ画面"
                )
            )
        } else if index == 3 {
            onboardingScreenshotPage(
                title: AppLanguage.localized("訪問をいつでも見返し"),
                imageName: onboardingImageName("SilicaHistoryOnboarding"),
                accessibilityLabel: AppLanguage.localized(
                    "過去の訪問記録を表示したSilicaのログ画面"
                )
            )
        } else if index == 4 {
            onboardingScreenshotPage(
                title: AppLanguage.localized("データを自動で書き出し"),
                imageName: onboardingImageName("SilicaExportOnboarding"),
                accessibilityLabel: AppLanguage.localized(
                    "自動出力を設定したSilicaの出力画面"
                )
            )
        } else {
            Color.clear
                .accessibilityHidden(true)
        }
    }

    private func onboardingScreenshotPage(
        title: String,
        imageName: String,
        accessibilityLabel: String
    ) -> some View {
        VStack(spacing: 0) {
            Text(title)
                .font(.system(size: 34, weight: .semibold))
                .lineLimit(1)
                .minimumScaleFactor(0.66)
                .foregroundStyle(.white)
                .frame(maxWidth: .infinity)
                .frame(height: 42)
                .padding(.top, 28)

            Spacer(minLength: 18)

            Image(imageName)
                .resizable()
                .scaledToFit()
                .clipShape(RoundedRectangle(cornerRadius: 31, style: .continuous))
                .frame(width: onboardingPhoneWidth, height: onboardingPhoneHeight)
                .padding(8)
                .background(.black, in: RoundedRectangle(cornerRadius: 39, style: .continuous))
                .overlay {
                    RoundedRectangle(cornerRadius: 39, style: .continuous)
                        .stroke(.white.opacity(0.16), lineWidth: 1)
                }
                .shadow(color: .black.opacity(0.55), radius: 22, y: 12)
                .accessibilityLabel(accessibilityLabel)

            Spacer(minLength: 0)
        }
        .padding(.horizontal, 24)
    }

    private func onboardingImageName(_ baseName: String) -> String {
        AppLanguage.current == .english ? "\(baseName)EN" : baseName
    }

    private var pageProgressValue: String {
        String(
            format: AppLanguage.localized("オンボーディングページ %1$@ / %2$@"),
            "\(currentPage + 1)",
            "\(pageCount)"
        )
    }

    @ViewBuilder
    private var pageIndicator: some View {
        let indicator = HStack(spacing: 7) {
            ForEach(0..<pageCount, id: \.self) { index in
                Capsule()
                    .fill(index == currentPage ? .white : .white.opacity(0.28))
                    .frame(width: index == currentPage ? 22 : 6, height: 6)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 9)
        .animation(.easeInOut(duration: 0.28), value: currentPage)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(AppLanguage.localized("オンボーディングの進行状況"))
        .accessibilityValue(pageProgressValue)

        if #available(iOS 26.0, *) {
            indicator
                .glassEffect(.regular, in: Capsule())
        } else {
            indicator
                .background(.ultraThinMaterial, in: Capsule())
                .overlay {
                    Capsule()
                        .stroke(.white.opacity(0.18), lineWidth: 0.8)
                }
        }
    }

    @ViewBuilder
    private var continueButton: some View {
        let label = Button {
            triggerNextButtonHaptic()
            if currentPage < pageCount - 1 {
                withAnimation(.easeInOut(duration: 0.28)) {
                    currentPage += 1
                }
            } else {
                prepareSetupOnboarding()
            }
        } label: {
            HStack(spacing: 10) {
                if isPreparingSetup {
                    ProgressView()
                        .controlSize(.small)
                        .tint(.white)
                    Text(AppLanguage.localized("準備しています…"))
                        .font(.body.weight(.semibold))
                } else {
                    Text(AppLanguage.localized("次へ"))
                        .font(.body.weight(.semibold))

                    Image(systemName: "arrow.right")
                        .font(.body.weight(.semibold))
                }
            }
            .foregroundStyle(.white)
            .frame(maxWidth: .infinity)
            .frame(height: 56)
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .disabled(isPreparingSetup)
        .accessibilityLabel(AppLanguage.localized("次へ"))
        .accessibilityValue(
            isPreparingSetup
                ? AppLanguage.localized("準備しています")
                : pageProgressValue
        )

        if #available(iOS 26.0, *) {
            label
                .glassEffect(.regular.interactive(), in: Capsule())
        } else {
            label
                .background(.ultraThinMaterial, in: Capsule())
                .overlay {
                    Capsule()
                        .stroke(.white.opacity(0.18), lineWidth: 0.8)
                }
        }
    }

    private func triggerNextButtonHaptic() {
        let generator = UIImpactFeedbackGenerator(style: .light)
        generator.prepare()
        generator.impactOccurred(intensity: 0.72)
    }

    private func prepareSetupOnboarding() {
        guard isPreparingSetup == false else { return }
        isPreparingSetup = true

        Task { @MainActor in
            let delayMilliseconds = Int.random(
                in: reduceMotion ? 1_150...1_400 : 1_350...1_750
            )
            try? await Task.sleep(for: .milliseconds(delayMilliseconds))
            guard Task.isCancelled == false else { return }
            onContinue()
        }
    }
}

struct SilicaInitialSetupOnboardingView: View {
    let onFinish: () -> Void

    @Environment(\.openURL) private var openURL
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @EnvironmentObject private var locationRecorder: LocationRecorder
    @EnvironmentObject private var subscriptionManager: SubscriptionManager
    @AppStorage(SubscriptionCardPreferences.engravingKey)
    private var subscriptionCardEngraving = ""
    @AppStorage(SubscriptionCardPreferences.paletteKey)
    private var subscriptionCardPaletteRawValue = SubscriptionCardPalette.blue.rawValue
    private let motionActivityManager = CMMotionActivityManager()
    @State private var currentPage: Int
    @State private var motionAuthorizationStatus = CMMotionActivityManager.authorizationStatus()
    @State private var isCheckingPermissions = false
    @State private var selectedBillingPlan: PaywallBillingPlan = .annual
    @State private var isPaywallRevealed = false
    @State private var isFinishingOnboarding = false
    @State private var isPurchaseSuccessPresented = false
    @State private var selectedLegalDocument: LegalDocument?
    @State private var isPreparingPurchaseShare = false
    @State private var purchaseShareImage: UIImage?
    @State private var isPurchaseShareSheetPresented = false
    @State private var shouldRequestAlwaysAfterWhenInUse = false
    @State private var purchaseCardVerticalTranslation: CGFloat = 0
    @FocusState private var isPurchaseEngravingFocused: Bool

    private let pageCount = 3
    private let paywallBlue = Color(red: 0.20, green: 0.46, blue: 0.96)
    private let startsAtProPage: Bool
    private let paywallPresentation: SilicaPaywallPresentation
    private static let freePlanFinishDelayNanoseconds: UInt64 = 700_000_000

    private enum PaywallBillingPlan: String, CaseIterable, Identifiable {
        case monthly
        case annual
        case lifetime

        var id: String { rawValue }

        var title: String {
            switch self {
            case .monthly: AppLanguage.localized("月額")
            case .annual: AppLanguage.localized("年額")
            case .lifetime: AppLanguage.localized("買い切り")
            }
        }

        var subscriptionPlan: SilicaSubscriptionPlan {
            switch self {
            case .monthly: .monthly
            case .annual: .yearly
            case .lifetime: .lifetime
            }
        }

        var unit: String {
            switch self {
            case .monthly: AppLanguage.localized("/ 月")
            case .annual: AppLanguage.localized("/ 年")
            case .lifetime: ""
            }
        }

        var isRecommended: Bool {
            self == .annual
        }
    }

    init(
        onFinish: @escaping () -> Void,
        startsAtProPage: Bool = false,
        paywallPresentation: SilicaPaywallPresentation = .standard
    ) {
        self.onFinish = onFinish
        self.startsAtProPage = startsAtProPage
        self.paywallPresentation = paywallPresentation
        if startsAtProPage {
            _currentPage = State(initialValue: 3)
            return
        }

        let shouldResume = UserDefaults.standard.bool(
            forKey: SilicaOnboardingStorage.resumeInitialSetupAfterSettingsKey
        )
        let savedPage = shouldResume
            ? UserDefaults.standard.integer(forKey: SilicaOnboardingStorage.initialSetupResumePageKey)
            : 0
        _currentPage = State(initialValue: min(max(savedPage, 0), 2))
    }

    var body: some View {
        ZStack {
            Color.black
                .ignoresSafeArea()

            VStack(spacing: 0) {
                ZStack {
                    if isPurchaseSuccessPresented {
                        purchaseSuccessPage
                    } else if currentPage == 3 {
                        proPage
                    } else {
                        setupPageContent
                            .id(currentPage)
                            .transition(.opacity)
                    }
                }

                if currentPage != 3 && isPurchaseSuccessPresented == false {
                    setupPageIndicator
                        .padding(.top, 10)
                        .padding(.bottom, 6)

                    setupContinueButton
                        .padding(.horizontal, 24)
                        .padding(.top, 8)
                        .padding(.bottom, 18)
                }
            }
        }
        .onAppear(perform: refreshPermissionState)
        .onReceive(
            NotificationCenter.default.publisher(
                for: UIApplication.didBecomeActiveNotification
            )
        ) { _ in
            refreshPermissionState()
            if currentPage == 2 {
                startPermissionCheck()
            }
            clearSettingsResumeState()
        }
        .onChange(of: locationRecorder.authorizationStatus) {
            continueLocationAuthorizationFlowIfNeeded()
        }
        .onChange(of: currentPage) {
            if currentPage == 2 {
                startPermissionCheck()
            }
        }
        .task(id: currentPage) {
            guard currentPage == 3 else {
                isPaywallRevealed = false
                return
            }

            if reduceMotion {
                isPaywallRevealed = true
                return
            }

            isPaywallRevealed = false
            try? await Task.sleep(for: .milliseconds(160))
            guard Task.isCancelled == false, currentPage == 3 else { return }

            withAnimation(.spring(response: 0.55, dampingFraction: 0.88)) {
                isPaywallRevealed = true
            }
        }
        .task(id: currentPage) {
            guard currentPage == 3 else {
                return
            }
            await subscriptionManager.loadPaywallProducts()
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
        .sheet(item: $selectedLegalDocument) { document in
            NavigationStack {
                LegalDocumentView(document: document)
            }
        }
        .sheet(
            isPresented: $isPurchaseShareSheetPresented,
            onDismiss: { purchaseShareImage = nil }
        ) {
            if let purchaseShareImage {
                SilicaActivityViewController(
                    activityItems: [
                        AppLanguage.localized("Silica Proを始めました！"),
                        purchaseShareImage
                    ]
                )
            }
        }
    }

    @ViewBuilder
    private var setupPageContent: some View {
        switch currentPage {
        case 0:
            locationPermissionPage
        case 1:
            motionPermissionPage
        default:
            checkingPage
        }
    }

    private var locationPermissionPage: some View {
        setupPermissionPage(
            symbol: "location.fill",
            tint: .blue,
            title: AppLanguage.localized("位置情報を許可"),
            message: AppLanguage.localized("訪れた場所を記録するために、位置情報を「常に許可」にします。常時GPSで追跡し続けるのではなく、滞在の記録に必要な範囲で使うため、通常はバッテリーへの影響は小さめです。"),
            requirements: [
                (AppLanguage.localized("位置情報"), locationAuthorizationText, "location.fill"),
                (AppLanguage.localized("正確な位置情報"), AppLanguage.localized(locationRecorder.accuracyAuthorization == .fullAccuracy ? "オン" : "オフ"), "scope")
            ],
            shouldShakeIcon: true
        )
    }

    private var motionPermissionPage: some View {
        setupPermissionPage(
            symbol: "figure.walk.motion",
            tint: .green,
            title: AppLanguage.localized("モーションとフィットネスを許可"),
            message: AppLanguage.localized("滞在と通過を正確に見分け、徒歩・自転車・車などの移動方法を記録するために必要です。Silicaを使い始めるには許可してください。"),
            requirements: [
                (AppLanguage.localized("モーションとフィットネス"), motionAuthorizationText, "figure.walk.motion")
            ]
        )
    }

    private var checkingPage: some View {
        ScrollView {
            VStack(spacing: 30) {
                Spacer(minLength: 36)

                ZStack {
                    ProgressView()
                        .controlSize(.large)
                        .tint(.white)
                        .opacity(isCheckingPermissions ? 1 : 0)

                    Image(systemName: permissionsAreReady ? "checkmark.circle.fill" : "pause.circle.fill")
                        .font(.system(size: 58, weight: .medium))
                        .foregroundStyle(permissionsAreReady ? .green : .orange)
                        .opacity(isCheckingPermissions ? 0 : 1)
                        .accessibilityLabel(permissionCheckTitle)
                }
                .frame(width: 64, height: 64)
                .animation(
                    reduceMotion ? nil : .easeInOut(duration: 0.22),
                    value: isCheckingPermissions
                )

                VStack(spacing: 16) {
                    Text(
                        isCheckingPermissions
                            ? AppLanguage.localized("設定を確認しています")
                            : permissionCheckTitle
                    )
                        .font(.system(size: 32, weight: .semibold))
                        .foregroundStyle(.white)
                        .multilineTextAlignment(.center)
                        .fixedSize(horizontal: false, vertical: true)

                    Text(
                        isCheckingPermissions
                            ? AppLanguage.localized("Silicaが記録を始められる状態か確認しています。")
                            : permissionCheckDescription
                    )
                        .font(.body)
                        .foregroundStyle(.white.opacity(0.62))
                        .multilineTextAlignment(.center)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .padding(.horizontal, 24)

                if isCheckingPermissions == false && permissionsAreReady == false {
                    VStack(spacing: 12) {
                        HStack(alignment: .top, spacing: 12) {
                            Image(systemName: "exclamationmark.triangle.fill")
                                .font(.body.weight(.semibold))
                                .accessibilityHidden(true)

                            Text(permissionWarningText)
                                .font(.body.weight(.semibold))
                                .fixedSize(horizontal: false, vertical: true)
                        }
                        .foregroundStyle(.orange)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(16)
                        .background(
                            .orange.opacity(0.12),
                            in: RoundedRectangle(cornerRadius: 18, style: .continuous)
                        )
                        .overlay {
                            RoundedRectangle(cornerRadius: 18, style: .continuous)
                                .stroke(.orange.opacity(0.32), lineWidth: 1)
                        }
                        .accessibilityElement(children: .combine)
                        .accessibilityIdentifier(permissionWarningIdentifier)

                    }
                    .padding(.horizontal, 24)
                }

                VStack(spacing: 0) {
                    setupStatusRow(
                        title: AppLanguage.localized("位置情報：常に許可"),
                        isReady: locationAlwaysPermissionIsReady,
                        isChecking: isCheckingPermissions
                    )
                    setupStatusRow(
                        title: AppLanguage.localized("正確な位置情報：オン"),
                        isReady: preciseLocationPermissionIsReady,
                        isChecking: isCheckingPermissions
                    )
                    setupStatusRow(
                        title: AppLanguage.localized("モーションとフィットネス"),
                        isReady: motionPermissionIsReady,
                        statusText: motionActivityIsAvailable
                            ? nil
                            : AppLanguage.localized("利用不可"),
                        isChecking: isCheckingPermissions
                    )
                }
                .background(.white.opacity(0.07), in: RoundedRectangle(cornerRadius: 22, style: .continuous))
                .overlay {
                    RoundedRectangle(cornerRadius: 22, style: .continuous)
                        .stroke(.white.opacity(0.12), lineWidth: 1)
                }
                .padding(.horizontal, 24)

                Spacer(minLength: 36)
            }
            .frame(maxWidth: .infinity, minHeight: 560)
        }
        .scrollIndicators(.hidden)
        .scrollBounceBehavior(.basedOnSize)
        .onAppear(perform: startPermissionCheck)
    }

    private var proPage: some View {
        GeometryReader { proxy in
            let compact = proxy.size.height < 700
            let headerHeight: CGFloat = paywallPresentation == .trialExpired ? 112 : 96
            let tableHeight: CGFloat = compact ? 232 : 284
            let billingHeight: CGFloat = compact ? 78 : 92
            let continueHeight: CGFloat = 136
            let remainingHeight = max(
                proxy.size.height - headerHeight - tableHeight - billingHeight - continueHeight,
                0
            )
            let topSpace = remainingHeight * 0.26
            let headerSpace = remainingHeight * 0.16
            let tableSpace = remainingHeight * 0.15
            let actionSpace = remainingHeight * 0.35
            let bottomSpace = remainingHeight * 0.08

            VStack(spacing: 0) {
                Spacer()
                    .frame(height: topSpace)

                paywallHeader
                    .frame(height: headerHeight)

                Spacer()
                    .frame(height: headerSpace)

                paywallComparisonTable
                    .frame(height: tableHeight)

                Spacer()
                    .frame(height: tableSpace)

                HStack(spacing: 8) {
                    ForEach(PaywallBillingPlan.allCases) { plan in
                        paywallBillingPlanCard(plan, compact: compact)
                    }
                }
                .frame(height: billingHeight)
                .sensoryFeedback(.selection, trigger: selectedBillingPlan)

                Spacer()
                    .frame(height: actionSpace)

                paywallContinueArea
                    .frame(height: continueHeight)

                Spacer()
                    .frame(height: bottomSpace)
            }
            .padding(.horizontal, 16)
            .frame(height: proxy.size.height, alignment: .top)
            .opacity(reduceMotion || isPaywallRevealed ? 1 : 0)
            .scaleEffect(
                reduceMotion || isPaywallRevealed ? 1 : 0.975,
                anchor: .bottom
            )
            .offset(y: reduceMotion || isPaywallRevealed ? 0 : 18)
        }
        .frame(maxWidth: .infinity, minHeight: 560)
        .frame(maxHeight: .infinity)
    }

    @ViewBuilder
    private var purchaseSuccessPage: some View {
        if reduceMotion {
            purchaseSuccessContent
        } else {
            SWConfetti(
                isActive: $isPurchaseSuccessPresented,
                particleCount: 120,
                duration: 3.0
            ) {
                purchaseSuccessContent
            }
        }
    }

    private var purchaseSuccessContent: some View {
        VStack(spacing: 0) {
            purchaseSuccessSpacer(minLength: 24, editingLength: 12)

            VStack(spacing: 0) {
                Image(systemName: "checkmark.circle.fill")
                    .font(.system(size: 52, weight: .medium))
                    .foregroundStyle(.green)
                    .accessibilityHidden(true)

                Text(AppLanguage.localized("ご購入ありがとうございます"))
                    .font(.system(size: 30, weight: .semibold))
                    .foregroundStyle(.white)
                    .multilineTextAlignment(.center)
                    .lineLimit(1)
                    .minimumScaleFactor(0.70)
                    .allowsTightening(true)
                    .frame(maxWidth: .infinity)
                    .padding(.top, 22)

                Text(AppLanguage.localized("Silica Proが有効になりました"))
                    .font(.body.weight(.medium))
                    .foregroundStyle(.white.opacity(0.62))
                    .multilineTextAlignment(.center)
                    .padding(.top, 9)
            }
            .opacity(isPurchaseEngravingFocused ? 0 : 1)
            .frame(height: isPurchaseEngravingFocused ? 0 : nil)
            .clipped()
            .accessibilityHidden(isPurchaseEngravingFocused)

            purchaseSuccessSpacer(minLength: 24, editingLength: 8)

            purchaseCardCarousel
                .padding(.horizontal, -24)
                .layoutPriority(2)

            purchaseSuccessSpacer(minLength: 6, editingLength: 6)
            purchaseCardCustomization

            VStack(spacing: 0) {
                Spacer(minLength: 14)

                Text(AppLanguage.localized("Proカードを受け取りました"))
                    .font(.subheadline.weight(.medium))
                    .foregroundStyle(.white.opacity(0.48))

                Spacer(minLength: 16)

                Button(action: sharePurchase) {
                    HStack(spacing: 8) {
                        if isPreparingPurchaseShare {
                            ProgressView()
                                .controlSize(.small)
                                .tint(.white.opacity(0.82))
                        }

                        Label(
                            AppLanguage.localized(
                                isPreparingPurchaseShare ? "共有画像を準備中…" : "共有する"
                            ),
                            systemImage: "square.and.arrow.up"
                        )
                    }
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(.white)
                    .frame(maxWidth: .infinity)
                    .frame(height: 48)
                    .contentShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
                }
                .buttonStyle(.plain)
                .background(
                    .white.opacity(0.10),
                    in: RoundedRectangle(cornerRadius: 18, style: .continuous)
                )
                .overlay {
                    RoundedRectangle(cornerRadius: 18, style: .continuous)
                        .stroke(.white.opacity(0.22), lineWidth: 1)
                }
                .disabled(isPreparingPurchaseShare)
                .accessibilityHint(AppLanguage.localized("共有先を選択します"))

                Button(action: onFinish) {
                    Text(
                        AppLanguage.localized(
                            startsAtProPage ? "完了" : "Silicaをはじめる"
                        )
                    )
                    .font(.body.weight(.semibold))
                    .foregroundStyle(.black)
                    .frame(maxWidth: .infinity)
                    .frame(height: 56)
                    .contentShape(RoundedRectangle(cornerRadius: 22, style: .continuous))
                }
                .buttonStyle(.plain)
                .background(.white, in: RoundedRectangle(cornerRadius: 22, style: .continuous))
                .accessibilityHint(
                    startsAtProPage
                        ? AppLanguage.localized("サブスクリプション画面を閉じます")
                        : AppLanguage.localized("Silicaを使い始めます")
                )
                .padding(.top, 12)
            }
            .opacity(isPurchaseEngravingFocused ? 0 : 1)
            .frame(height: isPurchaseEngravingFocused ? 0 : nil)
            .clipped()
            .accessibilityHidden(isPurchaseEngravingFocused)

            Spacer(minLength: 24)
        }
        .padding(.horizontal, 24)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .ignoresSafeArea(.keyboard, edges: .bottom)
        .animation(
            reduceMotion ? nil : .easeOut(duration: 0.22),
            value: isPurchaseEngravingFocused
        )
        .accessibilityElement(children: .contain)
    }

    @ViewBuilder
    private func purchaseSuccessSpacer(
        minLength: CGFloat,
        editingLength: CGFloat? = nil
    ) -> some View {
        if isPurchaseEngravingFocused, let editingLength {
            Color.clear
                .frame(height: editingLength)
                .accessibilityHidden(true)
        } else {
            Spacer(minLength: minLength)
        }
    }

    private var subscriptionCardPalette: SubscriptionCardPalette {
        SubscriptionCardPalette(rawValue: subscriptionCardPaletteRawValue) ?? .blue
    }

    private var purchaseCardEngravingBinding: Binding<String> {
        Binding(
            get: { subscriptionCardEngraving },
            set: { newValue in
                subscriptionCardEngraving = String(
                    newValue.prefix(SubscriptionCardPreferences.engravingCharacterLimit)
                )
            }
        )
    }

    private var purchaseCardCarousel: some View {
        TabView(selection: $subscriptionCardPaletteRawValue) {
            ForEach(SubscriptionCardPalette.allCases) { palette in
                let isSelected = palette.rawValue == subscriptionCardPaletteRawValue

                SubscriptionCardView(
                    isPro: true,
                    isLoading: false,
                    engravingText: subscriptionCardEngraving,
                    palette: palette,
                    showsNavigationCue: false,
                    allowsTiltGesture: false,
                    interactionTranslation: isSelected
                        ? CGSize(width: 0, height: purchaseCardVerticalTranslation)
                        : .zero
                )
                .overlay {
                    if isSelected {
                        VerticalCardTiltGestureOverlay(
                            translation: $purchaseCardVerticalTranslation
                        )
                        .accessibilityHidden(true)
                    }
                }
                .padding(.horizontal, 18)
                .tag(palette.rawValue)
                .accessibilityLabel(AppLanguage.localized("Silica Proカード"))
            }
        }
        .tabViewStyle(.page(indexDisplayMode: .never))
        .frame(maxWidth: .infinity)
        .aspectRatio(1.586, contentMode: .fit)
        .onChange(of: subscriptionCardPaletteRawValue) {
            purchaseCardVerticalTranslation = 0
        }
    }

    private var purchaseCardCustomization: some View {
        VStack(spacing: 0) {
            HStack(spacing: 10) {
                Image(systemName: "signature")
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundStyle(.white.opacity(0.72))
                    .frame(width: 22, height: 22)
                    .accessibilityHidden(true)

                TextField(
                    AppLanguage.localized("刻印する文字"),
                    text: purchaseCardEngravingBinding
                )
                .font(.subheadline)
                .foregroundStyle(.white)
                .textInputAutocapitalization(.words)
                .autocorrectionDisabled()
                .submitLabel(.done)
                .focused($isPurchaseEngravingFocused)
                .onSubmit {
                    isPurchaseEngravingFocused = false
                }
                .accessibilityLabel(AppLanguage.localized("刻印する文字"))

                Text(
                    "\(subscriptionCardEngraving.count)/\(SubscriptionCardPreferences.engravingCharacterLimit)"
                )
                .font(.caption.monospacedDigit())
                .foregroundStyle(.white.opacity(0.42))

                if subscriptionCardEngraving.isEmpty == false {
                    Button {
                        subscriptionCardEngraving = ""
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                            .font(.system(size: 17))
                            .foregroundStyle(.white.opacity(0.44))
                            .frame(width: 28, height: 28)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel(AppLanguage.localized("刻印を消去"))
                }
            }
            .padding(.leading, 13)
            .padding(.trailing, 8)
            .frame(minHeight: 48)
            .background(
                .white.opacity(0.08),
                in: RoundedRectangle(cornerRadius: 15, style: .continuous)
            )
            .overlay {
                RoundedRectangle(cornerRadius: 15, style: .continuous)
                    .stroke(
                        isPurchaseEngravingFocused
                            ? .white.opacity(0.62)
                            : .white.opacity(0.14),
                        lineWidth: isPurchaseEngravingFocused ? 1.2 : 1
                    )
            }

        }
        .accessibilityElement(children: .contain)
    }

    private var paywallHeader: some View {
        VStack(spacing: 2) {
            Image("SilicaSplashLogo")
                .resizable()
                .scaledToFit()
                .frame(width: 40, height: 40)
                .grayscale(1)
                .accessibilityHidden(true)

            Text(AppLanguage.localized(
                paywallPresentation == .trialExpired
                    ? "Pro体験が終了しました"
                    : "Silica Pro"
            ))
                .font(.system(
                    size: paywallPresentation == .trialExpired ? 25 : 30,
                    weight: .semibold
                ))
                .foregroundStyle(.white)
                .multilineTextAlignment(.center)
                .minimumScaleFactor(0.82)

            Text(AppLanguage.localized(
                paywallPresentation == .trialExpired
                    ? "Proに登録して自動出力を継続しましょう"
                    : "AIのための滞在記録"
            ))
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(.white.opacity(0.46))
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
        }
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(.isHeader)
    }

    private var paywallComparisonTable: some View {
        let rows = [
            (icon: "clock", feature: AppLanguage.localized("自動滞在記録"), free: AppLanguage.localized("対応"), pro: AppLanguage.localized("対応")),
            (icon: "calendar", feature: AppLanguage.localized("記録閲覧"), free: AppLanguage.localized("31日"), pro: AppLanguage.localized("無期限")),
            (icon: "square.and.arrow.up", feature: AppLanguage.localized("書き出し"), free: AppLanguage.localized("手動"), pro: AppLanguage.localized("自動")),
            (icon: "list.bullet.rectangle", feature: AppLanguage.localized("場所登録"), free: AppLanguage.localized("3件"), pro: AppLanguage.localized("無制限"))
        ]
        let featureColumnWidth: CGFloat = 168
        let freeColumnWidth: CGFloat = 70
        let proColumnWidth: CGFloat = 82
        let tableWidth = featureColumnWidth + freeColumnWidth + proColumnWidth

        return ZStack(alignment: .trailing) {
            RoundedRectangle(cornerRadius: 20, style: .continuous)
                .fill(.white.opacity(0.045))
                .frame(width: proColumnWidth)

            VStack(spacing: 0) {
                HStack(spacing: 0) {
                    Text(AppLanguage.localized("機能"))
                        .font(.system(size: 13, weight: .medium))
                        .foregroundStyle(.white.opacity(0.34))
                        .frame(width: featureColumnWidth, alignment: .leading)

                    Text(AppLanguage.localized("無料"))
                        .font(.system(size: 16, weight: .semibold))
                        .foregroundStyle(.white.opacity(0.48))
                        .frame(width: freeColumnWidth)

                    Text("Pro")
                        .font(.system(size: 18, weight: .semibold))
                        .foregroundStyle(.white)
                        .frame(width: proColumnWidth)
                }
                .frame(height: 48)

                ForEach(Array(rows.enumerated()), id: \.offset) { item in
                    HStack(spacing: 0) {
                        HStack(spacing: 9) {
                            Image(systemName: item.element.icon)
                                .font(.system(size: 15, weight: .medium))
                                .foregroundStyle(.white.opacity(0.42))
                                .frame(width: 20)

                            Text(item.element.feature)
                                .font(.system(size: 15, weight: .medium))
                                .foregroundStyle(.white.opacity(0.84))
                                .lineLimit(2)
                                .fixedSize(horizontal: false, vertical: true)
                                .multilineTextAlignment(.leading)
                        }
                        .frame(width: featureColumnWidth, alignment: .leading)

                        Text(item.element.free)
                            .font(.system(size: 14, weight: .semibold))
                            .foregroundStyle(.white.opacity(0.46))
                            .frame(width: freeColumnWidth)

                        Text(item.element.pro)
                            .font(.system(size: 14, weight: .semibold))
                            .foregroundStyle(.white.opacity(0.92))
                            .frame(width: proColumnWidth)
                    }
                    .frame(maxHeight: .infinity)
                    .accessibilityElement(children: .ignore)
                    .accessibilityLabel(String(
                        format: AppLanguage.localized("機能比較項目 %1$@、無料は%2$@、Proは%3$@"),
                        item.element.feature,
                        item.element.free,
                        item.element.pro
                    )
                    )
                }
            }
        }
        .frame(width: tableWidth)
        .frame(maxWidth: .infinity)
    }

    private func paywallBillingPlanCard(
        _ plan: PaywallBillingPlan,
        compact: Bool
    ) -> some View {
        let isSelected = selectedBillingPlan == plan
        let price = subscriptionManager.price(for: plan.subscriptionPlan)
        let accessiblePrice = price ?? AppLanguage.localized(
            subscriptionManager.isLoading ? "料金を取得中" : "料金を再取得"
        )
        let cardTint = plan.isRecommended ? paywallBlue : Color.white
        let topFillOpacity = plan.isRecommended
            ? (isSelected ? 0.22 : 0.10)
            : (isSelected ? 0.11 : 0.045)
        let bottomFillOpacity = plan.isRecommended
            ? (isSelected ? 0.08 : 0.025)
            : (isSelected ? 0.045 : 0.014)
        let borderOpacity = plan.isRecommended
            ? (isSelected ? 0.92 : 0.38)
            : (isSelected ? 0.94 : 0.24)

        return Button {
            if price == nil {
                Task {
                    await subscriptionManager.loadPaywallProducts()
                }
            }
            withAnimation(reduceMotion ? nil : .easeInOut(duration: 0.24)) {
                selectedBillingPlan = plan
            }
        } label: {
            VStack(spacing: compact ? 6 : 8) {
                Text(plan.title)
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(.white.opacity(0.68))

                HStack(alignment: .center, spacing: 3) {
                    Group {
                        if let price {
                            Text(price)
                                .font(.system(size: compact ? 20 : 22, weight: .semibold))
                        } else if subscriptionManager.isLoading {
                            ProgressView()
                                .controlSize(.small)
                                .tint(.white.opacity(0.78))
                                .accessibilityLabel(AppLanguage.localized("料金を取得中"))
                        } else {
                            Text(AppLanguage.localized("料金を再取得"))
                                .font(.system(size: 12, weight: .semibold))
                        }
                    }
                    .foregroundStyle(.white)
                    .accessibilityIdentifier("paywall-price-\(plan.rawValue)")

                    if plan.unit.isEmpty == false {
                        Text(plan.unit)
                            .font(.system(size: 10, weight: .medium))
                            .foregroundStyle(.white.opacity(0.66))
                            .lineLimit(1)
                            .minimumScaleFactor(0.72)
                    }
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .contentShape(RoundedRectangle(cornerRadius: 22, style: .continuous))
        }
        .buttonStyle(.plain)
        .background(
            LinearGradient(
                colors: [
                    cardTint.opacity(topFillOpacity),
                    cardTint.opacity(bottomFillOpacity)
                ],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            ),
            in: RoundedRectangle(cornerRadius: 22, style: .continuous)
        )
        .overlay {
            RoundedRectangle(cornerRadius: 22, style: .continuous)
                .stroke(
                    cardTint.opacity(borderOpacity),
                    lineWidth: isSelected ? 1.4 : 1
                )
        }
        .shadow(
            color: isSelected ? cardTint.opacity(plan.isRecommended ? 0.22 : 0.08) : .clear,
            radius: plan.isRecommended ? 14 : 10
        )
        .accessibilityLabel("\(plan.title) \(accessiblePrice) \(plan.unit)")
        .accessibilityValue(AppLanguage.localized(isSelected ? "選択中" : "未選択"))
    }

    private func setupPermissionPage(
        symbol: String,
        tint: Color,
        title: String,
        message: String,
        requirements: [(String, String, String)],
        shouldShakeIcon: Bool = false
    ) -> some View {
        VStack(spacing: 0) {
            ScrollView {
                VStack(spacing: 28) {
                    Spacer(minLength: 36)

                    if shouldShakeIcon {
                        SetupShakingIcon(systemName: symbol, tint: tint)
                    } else {
                        Image(systemName: symbol)
                            .font(.system(size: 60, weight: .medium))
                            .foregroundStyle(tint)
                    }

                    VStack(spacing: 16) {
                        Text(title)
                            .font(.system(size: 32, weight: .semibold))
                            .foregroundStyle(.white)
                            .multilineTextAlignment(.center)

                        Text(message)
                            .font(.body)
                            .foregroundStyle(.white.opacity(0.62))
                            .multilineTextAlignment(.center)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    .padding(.horizontal, 28)

                    VStack(spacing: 0) {
                        ForEach(requirements.indices, id: \.self) { index in
                            let requirement = requirements[index]
                            HStack(spacing: 14) {
                                Image(systemName: requirement.2)
                                    .font(.body.weight(.semibold))
                                    .foregroundStyle(tint)
                                    .frame(width: 28)
                                Text(requirement.0)
                                    .font(.subheadline)
                                    .foregroundStyle(.white)
                                    .lineLimit(1)
                                    .minimumScaleFactor(0.78)
                                    .layoutPriority(1)
                                Spacer()
                                Text(requirement.1)
                                    .font(.footnote.weight(.medium))
                                    .foregroundStyle(.white.opacity(0.58))
                                    .lineLimit(1)
                                    .minimumScaleFactor(0.78)
                            }
                            .padding(.horizontal, 18)
                            .frame(minHeight: 58)

                            if index < requirements.count - 1 {
                                Divider()
                                    .overlay(.white.opacity(0.10))
                                    .padding(.leading, 60)
                            }
                        }
                    }
                    .background(.white.opacity(0.07), in: RoundedRectangle(cornerRadius: 22, style: .continuous))
                    .overlay {
                        RoundedRectangle(cornerRadius: 22, style: .continuous)
                            .stroke(.white.opacity(0.12), lineWidth: 1)
                    }
                    .padding(.horizontal, 24)

                    Spacer(minLength: 30)
                }
                .frame(maxWidth: .infinity, minHeight: 560)
            }
            .scrollIndicators(.hidden)
            .scrollBounceBehavior(.basedOnSize)
        }
    }

    @ViewBuilder
    private var setupPageIndicator: some View {
        let indicator = HStack(spacing: 7) {
            ForEach(0..<pageCount, id: \.self) { index in
                Capsule()
                    .fill(index == currentPage ? .white : .white.opacity(0.28))
                    .frame(width: index == currentPage ? 22 : 6, height: 6)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 9)
        .animation(.easeInOut(duration: 0.28), value: currentPage)

        if #available(iOS 26.0, *) {
            indicator.glassEffect(.regular, in: Capsule())
        } else {
            indicator
                .background(.ultraThinMaterial, in: Capsule())
                .overlay {
                    Capsule()
                        .stroke(.white.opacity(0.18), lineWidth: 0.8)
                }
        }
    }

    @ViewBuilder
    private var setupContinueButton: some View {
        let label = Button {
            guard currentPage != 2 || isCheckingPermissions == false else { return }
            switch currentPage {
            case 0:
                handleLocationPermissionContinue()
            case 1:
                handleMotionPermissionContinue()
            default:
                triggerSetupButtonHaptic()
                advance()
            }
        } label: {
            HStack(spacing: 10) {
                Text(continueButtonTitle)
                    .font(.body.weight(.semibold))
                    .lineLimit(2)
                    .minimumScaleFactor(0.75)
                    .multilineTextAlignment(.center)
                Image(systemName: continueButtonSystemImage)
                    .font(.body.weight(.semibold))
            }
            .foregroundStyle(.white)
            .frame(maxWidth: .infinity)
            .padding(.vertical, 10)
            .frame(minHeight: 56)
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier(currentPage < 2 ? "setup-permission-continue" : "setup-check-continue")
        .disabled(currentPage == 2 && isCheckingPermissions)
        .opacity(currentPage == 2 && isCheckingPermissions ? 0.46 : 1)

        if #available(iOS 26.0, *) {
            label.glassEffect(.regular.interactive(), in: Capsule())
        } else {
            label
                .background(.ultraThinMaterial, in: Capsule())
                .overlay {
                    Capsule()
                        .stroke(.white.opacity(0.18), lineWidth: 0.8)
                }
        }
    }

    private func triggerSetupButtonHaptic() {
        let generator = UIImpactFeedbackGenerator(style: .light)
        generator.prepare()
        generator.impactOccurred(intensity: 0.72)
    }

    private var continueButtonTitle: String {
        switch currentPage {
        case 0, 1: AppLanguage.localized("続ける")
        case 2:
            if isCheckingPermissions { AppLanguage.localized("確認中…") }
            else {
                permissionsAreReady
                    ? AppLanguage.localized("Silicaを始める")
                    : AppLanguage.localized("設定を開く")
            }
        case 3: AppLanguage.localized(startsAtProPage ? "無料で続ける" : "無料で始める")
        default: AppLanguage.localized("次へ")
        }
    }

    private var continueButtonSystemImage: String {
        switch currentPage {
        case 2 where isCheckingPermissions: "hourglass"
        case 2 where permissionsAreReady == false: "arrow.up.forward.app"
        case 3: "checkmark"
        default: "arrow.right"
        }
    }

    private var permissionsAreReady: Bool {
        locationPermissionsAreReady && motionPermissionIsReady
    }

    private var locationPermissionsAreReady: Bool {
        locationAlwaysPermissionIsReady && preciseLocationPermissionIsReady
    }

    private var locationAlwaysPermissionIsReady: Bool {
        #if DEBUG
        if DebugLaunchConfiguration.forcesPermissionsReady {
            return true
        }
        if DebugLaunchConfiguration.forcesMissingLocationPermission {
            return false
        }
        #endif
        return locationRecorder.authorizationStatus == .authorizedAlways
    }

    private var preciseLocationPermissionIsReady: Bool {
        #if DEBUG
        if DebugLaunchConfiguration.forcesPermissionsReady {
            return true
        }
        if DebugLaunchConfiguration.forcesMissingLocationPermission {
            return false
        }
        #endif
        return locationRecorder.accuracyAuthorization == .fullAccuracy
    }

    private var motionActivityIsAvailable: Bool {
        #if DEBUG
        if DebugLaunchConfiguration.forcesMissingMotionPermission {
            return true
        }
        #endif
        return CMMotionActivityManager.isActivityAvailable()
    }

    private var motionPermissionIsReady: Bool {
        PermissionStatusText.motionIsReady(
            motionAuthorizationStatus,
            isAvailable: motionActivityIsAvailable
        )
    }

    private var permissionCheckTitle: String {
        if permissionsAreReady {
            return AppLanguage.localized("設定を確認しました")
        }
        if locationPermissionsAreReady == false {
            return AppLanguage.localized("自動記録は停止中")
        }
        return AppLanguage.localized("記録精度が低下中")
    }

    private var permissionCheckDescription: String {
        if permissionsAreReady {
            return AppLanguage.localized("すべての設定が完了しました。")
        }
        if locationPermissionsAreReady == false {
            return AppLanguage.localized("位置情報を「常に許可」にし、正確な位置情報をオンにすると、自動記録を開始できます。設定はあとから変更できます。")
        }
        return AppLanguage.localized("モーションとフィットネスを許可すると、滞在と通過の判定精度が上がり、移動方法や歩行距離も記録できます。")
    }

    private var permissionWarningText: String {
        if locationPermissionsAreReady == false {
            return AppLanguage.localized("必要な位置情報の許可がないと、新しい訪問記録が作成されず、記録を使う大部分の機能を利用できません。")
        }
        return AppLanguage.localized("モーションとフィットネスの許可がないと、滞在と通過の判定精度が下がり、移動方法や歩行距離を記録できません。")
    }

    private var permissionWarningIdentifier: String {
        locationPermissionsAreReady
            ? "setup-motion-permission-warning"
            : "setup-location-permission-warning"
    }

    private var locationAuthorizationText: String {
        PermissionStatusText.location(locationRecorder.authorizationStatus)
    }

    private var motionAuthorizationText: String {
        PermissionStatusText.motion(
            motionAuthorizationStatus,
            isAvailable: CMMotionActivityManager.isActivityAvailable()
        )
    }

    private func setupStatusRow(
        title: String,
        isReady: Bool,
        statusText: String? = nil,
        isChecking: Bool = false
    ) -> some View {
        HStack(spacing: 12) {
            if isChecking {
                ProgressView()
                    .controlSize(.small)
                    .tint(.white.opacity(0.58))
                    .frame(width: 18, height: 18)
            } else {
                Image(systemName: isReady ? "checkmark.circle.fill" : "pause.circle.fill")
                    .foregroundStyle(isReady ? .green : .orange)
                    .frame(width: 18, height: 18)
            }
            Text(title)
                .font(.subheadline)
                .foregroundStyle(.white)
                .lineLimit(1)
                .minimumScaleFactor(0.78)
                .layoutPriority(1)
            Spacer()
            Text(AppLanguage.localized(isChecking ? "確認中" : (statusText ?? (isReady ? "設定済み" : "未設定"))))
                .font(.footnote.weight(.medium))
                .foregroundStyle(
                    isChecking
                        ? .white.opacity(0.58)
                        : (isReady ? .green : .orange.opacity(0.90))
                )
                .lineLimit(1)
                .minimumScaleFactor(0.78)
        }
        .padding(.horizontal, 18)
        .frame(minHeight: 62)
    }

    private var paywallContinueArea: some View {
        VStack(spacing: 0) {
            paywallPrimaryButton

            Spacer(minLength: 0)

            Button(action: finishWithFreePlan) {
                HStack(spacing: 8) {
                    if isFinishingOnboarding {
                        ProgressView()
                            .controlSize(.small)
                            .tint(.white.opacity(0.62))
                    }

                    Text(AppLanguage.localized(
                        isFinishingOnboarding
                            ? "準備しています…"
                            : (
                                paywallPresentation == .trialExpired
                                    ? "無料プランで続ける"
                                    : (startsAtProPage ? "無料で続ける" : "無料で始める")
                            )
                    ))
                }
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(.white.opacity(0.40))
                .frame(maxWidth: .infinity)
                .frame(height: 44)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .disabled(isFinishingOnboarding)
            .accessibilityLabel(AppLanguage.localized(
                isFinishingOnboarding
                    ? "準備しています"
                    : (
                        paywallPresentation == .trialExpired
                            ? "無料プランで続ける"
                            : (startsAtProPage ? "無料で続ける" : "無料で始める")
                    )
            ))
            .accessibilityHint(AppLanguage.localized(
                isFinishingOnboarding
                    ? "Silicaを準備しています"
                    : (startsAtProPage
                        ? "無料プランで続けてPaywallを閉じます"
                        : "無料プランでオンボーディングを完了します")
            ))
            .accessibilityIdentifier("paywall-continue-free")

            Spacer(minLength: 0)

            HStack(spacing: 14) {
                Button {
                    selectedLegalDocument = .privacyPolicy
                } label: {
                    Text(AppLanguage.localized("プライバシーポリシー"))
                }

                Button {
                    selectedLegalDocument = .termsOfUse
                } label: {
                    Text(AppLanguage.localized("利用規約"))
                }
            }
            .font(.caption2.weight(.medium))
            .foregroundStyle(.white.opacity(0.48))
            .buttonStyle(.plain)
        }
    }

    @ViewBuilder
    private var paywallPrimaryButton: some View {
        let hasSelectedPackage = subscriptionManager.hasPackage(
            for: selectedBillingPlan.subscriptionPlan
        )
        let button = Button {
            Task {
                guard hasSelectedPackage else {
                    await subscriptionManager.loadPaywallProducts()
                    return
                }
                await subscriptionManager.purchase(selectedBillingPlan.subscriptionPlan)
                guard subscriptionManager.isSilicaProActive else { return }

                triggerPurchaseSuccessHaptic()
                withAnimation(reduceMotion ? nil : .spring(response: 0.48, dampingFraction: 0.86)) {
                    isPurchaseSuccessPresented = true
                }
            }
        } label: {
            HStack(spacing: 8) {
                if subscriptionManager.isPurchasing {
                    ProgressView()
                        .tint(.white)
                }
                Text(AppLanguage.localized(
                    subscriptionManager.isPurchasing
                        ? "購入中…"
                        : (
                            hasSelectedPackage
                                ? "Proを選ぶ"
                                : (
                                    subscriptionManager.isLoading
                                        ? "料金を取得中"
                                        : "料金を再取得"
                                )
                        )
                ))
            }
                .font(.body.weight(.semibold))
                .foregroundStyle(.white)
                .frame(maxWidth: .infinity)
                .frame(height: 56)
                .contentShape(RoundedRectangle(cornerRadius: 22, style: .continuous))
        }
        .buttonStyle(.plain)
        .disabled(subscriptionManager.isPurchasing || subscriptionManager.isLoading)
        .accessibilityLabel(
            hasSelectedPackage
                ? AppLanguage.localized("Proを選ぶ")
                : AppLanguage.localized("料金を再取得")
        )
        .accessibilityHint(hasSelectedPackage
            ? String(format: AppLanguage.localized("%@をRevenueCatで購入します"), selectedBillingPlan.title)
            : AppLanguage.localized("RevenueCatから料金を再取得します")
        )

        if #available(iOS 26.0, *) {
            button
                .glassEffect(
                    .regular.interactive(),
                    in: RoundedRectangle(cornerRadius: 22, style: .continuous)
                )
        } else {
            button
                .background(
                    LinearGradient(
                        colors: [
                            .white.opacity(0.14),
                            .white.opacity(0.055)
                        ],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    ),
                    in: RoundedRectangle(cornerRadius: 22, style: .continuous)
                )
                .overlay {
                    RoundedRectangle(cornerRadius: 22, style: .continuous)
                        .stroke(.white.opacity(0.38), lineWidth: 1)
                }
            }
    }

    private func advance() {
        if currentPage == 2 {
            refreshPermissionState()
            guard isCheckingPermissions == false else { return }
            guard permissionsAreReady else {
                openSettings()
                return
            }
        }

        if currentPage < pageCount - 1 {
            withAnimation(.easeInOut(duration: 0.28)) {
                currentPage += 1
            }
        } else {
            currentPage = 0
            clearSettingsResumeState()
            onFinish()
        }
    }

    private func finishWithFreePlan() {
        if startsAtProPage {
            onFinish()
            return
        }

        guard currentPage == pageCount - 1, isFinishingOnboarding == false else {
            return
        }

        isFinishingOnboarding = true

        Task { @MainActor in
            do {
                try await Task.sleep(nanoseconds: Self.freePlanFinishDelayNanoseconds)
            } catch {
                return
            }

            guard Task.isCancelled == false else { return }
            advance()
        }
    }

    private func triggerPurchaseSuccessHaptic() {
        let generator = UINotificationFeedbackGenerator()
        generator.prepare()
        generator.notificationOccurred(.success)
    }

    private func sharePurchase() {
        guard isPreparingPurchaseShare == false else { return }
        isPreparingPurchaseShare = true

        let artwork = SilicaPurchaseShareArtwork(
            palette: subscriptionCardPalette,
            backgroundStyle: PurchaseShareBackgroundStyle.allCases.randomElement() ?? .midnight,
            engravingText: subscriptionCardEngraving
        )
        .frame(width: 1080, height: 1080)

        let renderer = ImageRenderer(content: artwork)
        renderer.scale = 1
        renderer.isOpaque = true

        guard let image = renderer.uiImage else {
            isPreparingPurchaseShare = false
            return
        }

        purchaseShareImage = image
        isPreparingPurchaseShare = false
        isPurchaseShareSheetPresented = true
    }

    private func handleLocationPermissionContinue() {
        refreshPermissionState()
        triggerSetupButtonHaptic()

        switch locationRecorder.authorizationStatus {
        case .notDetermined:
            shouldRequestAlwaysAfterWhenInUse = true
            locationRecorder.requestWhenInUseAuthorization()
        case .authorizedWhenInUse:
            requestPermanentAlwaysAuthorization()
            moveFromPermissionPage(expectedPage: 0, to: 1)
        default:
            shouldRequestAlwaysAfterWhenInUse = false
            moveFromPermissionPage(expectedPage: 0, to: 1)
        }
    }

    private func requestPermanentAlwaysAuthorization() {
        shouldRequestAlwaysAfterWhenInUse = false
        locationRecorder.requestAlwaysAuthorization()
    }

    private func continueLocationAuthorizationFlowIfNeeded() {
        guard shouldRequestAlwaysAfterWhenInUse else { return }

        switch locationRecorder.authorizationStatus {
        case .authorizedWhenInUse:
            requestPermanentAlwaysAuthorization()
            moveFromPermissionPage(expectedPage: 0, to: 1)
        case .authorizedAlways, .denied, .restricted:
            shouldRequestAlwaysAfterWhenInUse = false
            moveFromPermissionPage(expectedPage: 0, to: 1)
        case .notDetermined:
            break
        @unknown default:
            shouldRequestAlwaysAfterWhenInUse = false
        }
    }

    private func handleMotionPermissionContinue() {
        refreshPermissionState()
        triggerSetupButtonHaptic()

        guard CMMotionActivityManager.isActivityAvailable() else {
            moveFromPermissionPage(expectedPage: 1, to: 2)
            return
        }

        guard motionAuthorizationStatus == .notDetermined else {
            moveFromPermissionPage(expectedPage: 1, to: 2)
            return
        }

        motionActivityManager.queryActivityStarting(
            from: Date().addingTimeInterval(-60),
            to: Date(),
            to: .main
        ) { _, _ in
            Task { @MainActor in
                refreshPermissionState()
                moveFromPermissionPage(expectedPage: 1, to: 2)
            }
        }
    }

    private func moveFromPermissionPage(expectedPage: Int, to nextPage: Int) {
        guard currentPage == expectedPage else { return }
        withAnimation(reduceMotion ? nil : .easeInOut(duration: 0.28)) {
            currentPage = nextPage
        }
    }

    private func openSettings() {
        UserDefaults.standard.set(
            true,
            forKey: SilicaOnboardingStorage.resumeInitialSetupAfterSettingsKey
        )
        UserDefaults.standard.set(
            currentPage,
            forKey: SilicaOnboardingStorage.initialSetupResumePageKey
        )
        guard let url = URL(string: UIApplication.openSettingsURLString) else { return }
        openURL(url)
    }

    private func clearSettingsResumeState() {
        UserDefaults.standard.removeObject(
            forKey: SilicaOnboardingStorage.resumeInitialSetupAfterSettingsKey
        )
        UserDefaults.standard.removeObject(
            forKey: SilicaOnboardingStorage.initialSetupResumePageKey
        )
    }

    private func refreshPermissionState() {
        locationRecorder.refreshAuthorizationState()
        motionAuthorizationStatus = CMMotionActivityManager.authorizationStatus()
    }

    private func startPermissionCheck() {
        guard isCheckingPermissions == false else { return }
        isCheckingPermissions = true

        Task { @MainActor in
            refreshPermissionState()
            let delayMilliseconds = Int.random(in: 1_850...2_350)
            try? await Task.sleep(for: .milliseconds(delayMilliseconds))
            guard Task.isCancelled == false else { return }
            refreshPermissionState()
            isCheckingPermissions = false
            triggerPermissionCheckHaptic(isSuccess: permissionsAreReady)
        }
    }

    private func triggerPermissionCheckHaptic(isSuccess: Bool) {
        let generator = UINotificationFeedbackGenerator()
        generator.prepare()
        generator.notificationOccurred(isSuccess ? .success : .warning)
    }
}

private enum PurchaseShareBackgroundStyle: CaseIterable {
    case midnight
    case ocean
    case violet
    case mint
    case ember
    case paper
}

private struct SilicaPurchaseShareArtwork: View {
    let palette: SubscriptionCardPalette
    let backgroundStyle: PurchaseShareBackgroundStyle
    let engravingText: String

    private let sourceCardWidth: CGFloat = 342
    private let outputCardWidth: CGFloat = 820
    private let cardAspectRatio: CGFloat = 1.586

    private var cardScale: CGFloat {
        outputCardWidth / sourceCardWidth
    }

    var body: some View {
        ZStack {
            SilicaPurchaseShareBackground(
                style: backgroundStyle,
                palette: palette
            )

            SubscriptionCardView(
                isPro: true,
                isLoading: false,
                engravingText: engravingText,
                palette: palette,
                showsNavigationCue: false,
                allowsTiltGesture: false
            )
            .frame(width: sourceCardWidth)
            .scaleEffect(cardScale)
            .frame(
                width: outputCardWidth,
                height: outputCardWidth / cardAspectRatio
            )
        }
        .frame(width: 1080, height: 1080)
        .clipped()
        .environment(\.colorScheme, .dark)
    }
}

private struct SilicaPurchaseShareBackground: View {
    let style: PurchaseShareBackgroundStyle
    let palette: SubscriptionCardPalette

    var body: some View {
        Group {
            switch style {
            case .midnight:
                LinearGradient(
                    colors: [
                        Color(red: 0.005, green: 0.008, blue: 0.02),
                        Color(red: 0.025, green: 0.07, blue: 0.18),
                        Color.black
                    ],
                    startPoint: .topLeading,
                    endPoint: .bottomTrailing
                )
            case .ocean:
                LinearGradient(
                    colors: [
                        Color(red: 0.02, green: 0.19, blue: 0.34),
                        Color(red: 0.02, green: 0.48, blue: 0.60),
                        Color(red: 0.18, green: 0.78, blue: 0.80)
                    ],
                    startPoint: .topLeading,
                    endPoint: .bottomTrailing
                )
            case .violet:
                LinearGradient(
                    colors: [
                        Color(red: 0.08, green: 0.02, blue: 0.18),
                        Color(red: 0.30, green: 0.08, blue: 0.48),
                        Color(red: 0.67, green: 0.26, blue: 0.78)
                    ],
                    startPoint: .topLeading,
                    endPoint: .bottomTrailing
                )
            case .mint:
                LinearGradient(
                    colors: [
                        Color(red: 0.01, green: 0.12, blue: 0.10),
                        Color(red: 0.04, green: 0.38, blue: 0.29),
                        Color(red: 0.34, green: 0.82, blue: 0.62)
                    ],
                    startPoint: .topLeading,
                    endPoint: .bottomTrailing
                )
            case .ember:
                LinearGradient(
                    colors: [
                        Color(red: 0.14, green: 0.015, blue: 0.01),
                        Color(red: 0.48, green: 0.07, blue: 0.03),
                        Color(red: 0.92, green: 0.33, blue: 0.08)
                    ],
                    startPoint: .topLeading,
                    endPoint: .bottomTrailing
                )
            case .paper:
                RadialGradient(
                    colors: [
                        Color.white,
                        Color(red: 0.78, green: 0.82, blue: 0.88),
                        palette.rimLightColor.opacity(0.72)
                    ],
                    center: .topLeading,
                    startRadius: 40,
                    endRadius: 900
                )
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

private struct SilicaActivityViewController: UIViewControllerRepresentable {
    let activityItems: [Any]

    func makeUIViewController(context: Context) -> UIActivityViewController {
        UIActivityViewController(
            activityItems: activityItems,
            applicationActivities: nil
        )
    }

    func updateUIViewController(
        _ uiViewController: UIActivityViewController,
        context: Context
    ) {}
}

private struct SetupShakingIcon: View {
    private enum ShakePhase: CaseIterable {
        case idle
        case zoomIn
        case shake1L
        case shake1R
        case shake2L
        case shake2R
        case shake3L
        case shake3R
        case zoomOut

        var scale: CGFloat {
            switch self {
            case .idle, .zoomOut:
                1
            case .zoomIn, .shake1L, .shake1R, .shake2L, .shake2R, .shake3L, .shake3R:
                1.1
            }
        }

        var rotation: Double {
            switch self {
            case .idle, .zoomIn, .zoomOut:
                0
            case .shake1L:
                -9
            case .shake1R:
                8
            case .shake2L:
                -12
            case .shake2R:
                6
            case .shake3L:
                -9
            case .shake3R:
                7
            }
        }

        var duration: Double {
            switch self {
            case .idle:
                0.01
            case .zoomIn, .zoomOut:
                0.2
            case .shake1L, .shake1R, .shake2L, .shake2R, .shake3L, .shake3R:
                0.08
            }
        }
    }

    let systemName: String
    let tint: Color

    @State private var shouldPlay = false
    @State private var didScheduleAnimation = false

    var body: some View {
        PhaseAnimator(ShakePhase.allCases, trigger: shouldPlay) { phase in
            Image(systemName: systemName)
                .font(.system(size: 60, weight: .medium))
                .foregroundStyle(tint)
                .scaleEffect(phase.scale)
                .rotationEffect(.degrees(phase.rotation))
        } animation: { phase in
            .easeInOut(duration: phase.duration)
        }
        .accessibilityHidden(true)
            .task {
                guard didScheduleAnimation == false else { return }
                didScheduleAnimation = true
                try? await Task.sleep(for: .milliseconds(500))
                guard Task.isCancelled == false else { return }
                shouldPlay = true
            }
    }
}

/// ShipSwift's SWGlowSweep adapted to a single non-repeating pass for onboarding.
/// Source concept: signerlabs/ShipSwift/SWAnimation/SWGlowSweep.swift.
private struct SWGlowSweepOnce<Content: View>: View {
    let baseColor: Color
    let glowColor: Color
    let duration: Double
    let bandWidth: CGFloat
    let startDelay: Double
    @ViewBuilder let content: () -> Content

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var didFinishSweep = false

    var body: some View {
        let maskedContent = content()

        maskedContent
            .hidden()
            .overlay {
                GeometryReader { proxy in
                    let width = proxy.size.width
                    let startOffset = -width / 2 - bandWidth
                    let endOffset = width / 2 + bandWidth

                    Rectangle()
                        .fill(baseColor)
                        .overlay {
                            LinearGradient(
                                colors: [.clear, glowColor, .clear],
                                startPoint: .leading,
                                endPoint: .trailing
                            )
                            .frame(width: bandWidth)
                            .offset(x: didFinishSweep ? endOffset : startOffset)
                        }
                        .mask { maskedContent }
                }
            }
            .task {
                guard didFinishSweep == false else {
                    return
                }

                if reduceMotion {
                    didFinishSweep = true
                } else {
                    do {
                        try await Task.sleep(nanoseconds: UInt64(startDelay * 1_000_000_000))
                    } catch {
                        return
                    }

                    guard Task.isCancelled == false, didFinishSweep == false else {
                        return
                    }

                    withAnimation(.linear(duration: duration)) {
                        didFinishSweep = true
                    }
                }
            }
    }
}

private struct VerticalCardTiltGestureOverlay: UIViewRepresentable {
    @Binding var translation: CGFloat

    func makeCoordinator() -> Coordinator {
        Coordinator(translation: $translation)
    }

    func makeUIView(context: Context) -> UIView {
        let view = UIView()
        view.backgroundColor = .clear
        view.isAccessibilityElement = false

        let recognizer = UIPanGestureRecognizer(
            target: context.coordinator,
            action: #selector(Coordinator.handlePan(_:))
        )
        recognizer.cancelsTouchesInView = false
        recognizer.delegate = context.coordinator
        view.addGestureRecognizer(recognizer)

        return view
    }

    func updateUIView(_ uiView: UIView, context: Context) {
        context.coordinator.translation = $translation
    }

    @MainActor
    final class Coordinator: NSObject, UIGestureRecognizerDelegate {
        var translation: Binding<CGFloat>

        init(translation: Binding<CGFloat>) {
            self.translation = translation
        }

        @objc
        func handlePan(_ recognizer: UIPanGestureRecognizer) {
            switch recognizer.state {
            case .began, .changed:
                var transaction = Transaction()
                transaction.animation = nil
                withTransaction(transaction) {
                    translation.wrappedValue = recognizer.translation(in: recognizer.view).y
                }
            case .ended, .cancelled, .failed:
                withAnimation(.spring(response: 0.38, dampingFraction: 0.78)) {
                    translation.wrappedValue = 0
                }
            default:
                break
            }
        }

        func gestureRecognizerShouldBegin(_ gestureRecognizer: UIGestureRecognizer) -> Bool {
            guard let panRecognizer = gestureRecognizer as? UIPanGestureRecognizer else {
                return false
            }

            let velocity = panRecognizer.velocity(in: panRecognizer.view)
            return abs(velocity.y) > abs(velocity.x)
        }

        func gestureRecognizer(
            _ gestureRecognizer: UIGestureRecognizer,
            shouldRecognizeSimultaneouslyWith otherGestureRecognizer: UIGestureRecognizer
        ) -> Bool {
            true
        }
    }
}

#Preview {
    SilicaWelcomeView(onContinue: {})
}
