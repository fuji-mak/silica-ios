import Combine
import Foundation
import RevenueCat

enum SilicaSubscriptionPlan: String, CaseIterable, Identifiable, Sendable {
    case monthly
    case yearly
    case lifetime

    var id: String { rawValue }

    var title: String {
        switch self {
        case .monthly: "月額"
        case .yearly: "年額"
        case .lifetime: "買い切り"
        }
    }

    var unit: String {
        switch self {
        case .monthly: "/ 月"
        case .yearly: "/ 年"
        case .lifetime: ""
        }
    }

    /// Supports the current product IDs and the shorter IDs already created in App Store Connect.
    var productIdentifiers: [String] {
        switch self {
        case .monthly:
            ["silica.pro.monthly", "monthly"]
        case .yearly:
            ["silica.pro.yearly", "yearly"]
        case .lifetime:
            ["silica_pro_lifetime", "lifetime"]
        }
    }

    var isRecommended: Bool { self == .yearly }
}

@MainActor
final class SubscriptionManager: NSObject, ObservableObject {
    static let entitlementIdentifier = "Silica Pro"

    private enum ProTrialStorage {
        static let startedAtKey = "silica.proTrial.startedAt.v1"
        static let expirationAcknowledgedKey =
            "silica.proTrial.expirationAcknowledged.v1"
    }

    private enum ErrorContext {
        case purchase
        case restore
    }

    // This is a RevenueCat public SDK key. It is safe to ship in the client app.
    private static let publicSDKKey = "appl_TvngDOEcicbUtDWbTwTpOFSviKV"

    private var purchaseFailureMessage: String {
        AppLanguage.localized(
            "購入に失敗しました。もう一度お試しいただくか、別の方法でのお支払いをお願いします。"
        )
    }

    private var restoreFailureMessage: String {
        AppLanguage.localized(
            "購入情報を復元できませんでした。もう一度お試しください。"
        )
    }

    @Published private(set) var customerInfo: CustomerInfo?
    @Published private(set) var currentOffering: Offering?
    @Published private(set) var isConfigured = false
    @Published private(set) var isLoading = false
    @Published private(set) var isPurchasing = false
    @Published private(set) var isRestoring = false
    @Published private(set) var proTrialStatus: ProTrialStatus
    @Published var errorMessage: String?
    @Published private var errorContext = ErrorContext.purchase
    private var refreshTask: Task<Void, Never>?

    override init() {
        let defaults = UserDefaults.standard
        let startedAt = defaults.object(
            forKey: ProTrialStorage.startedAtKey
        ) as? Date
        proTrialStatus = ProTrialAccessPolicy.status(
            startedAt: startedAt,
            relativeTo: Date()
        )
        super.init()
    }

    var errorTitle: String {
        switch errorContext {
        case .purchase:
            AppLanguage.localized("購入エラー")
        case .restore:
            AppLanguage.localized("復元エラー")
        }
    }

    var isSilicaProActive: Bool {
        customerInfo?.entitlements.active[Self.entitlementIdentifier] != nil
    }

    var isProTrialActive: Bool {
        proTrialStatus.isActive
    }

    var hasProAccess: Bool {
        isSilicaProActive || isProTrialActive
    }

    func requiresProForNewPlace(existingPlaceCount: Int) -> Bool {
        SavedPlaceAccessPolicy.requiresPro(
            existingPlaceCount: existingPlaceCount,
            isProActive: hasProAccessForPlaceCreation
        )
    }

    func isPlaceCreationAccessLoading(existingPlaceCount: Int) -> Bool {
        guard requiresProForNewPlace(existingPlaceCount: existingPlaceCount) else {
            return false
        }
        return isConfigured == false || (isLoading && customerInfo == nil)
    }

    private var hasProAccessForPlaceCreation: Bool {
        #if DEBUG
        DebugLaunchConfiguration.forcesFreeSubscription == false
            && (DebugLaunchConfiguration.forcesProSubscription || hasProAccess)
        #else
        hasProAccess
        #endif
    }

    var proTrialExpirationDate: Date? {
        proTrialStatus.expirationDate
    }

    var shouldPresentProTrialExpirationPaywall: Bool {
        guard case .expired = proTrialStatus else {
            return false
        }
        return UserDefaults.standard.bool(
            forKey: ProTrialStorage.expirationAcknowledgedKey
        ) == false
    }

    @discardableResult
    func startProTrialIfNeeded(relativeTo referenceDate: Date = Date()) -> Bool {
        let defaults = UserDefaults.standard
        guard defaults.object(forKey: ProTrialStorage.startedAtKey) == nil else {
            refreshProTrialStatus(relativeTo: referenceDate)
            return false
        }

        defaults.set(referenceDate, forKey: ProTrialStorage.startedAtKey)
        defaults.set(false, forKey: ProTrialStorage.expirationAcknowledgedKey)
        refreshProTrialStatus(relativeTo: referenceDate)
        return true
    }

    func refreshProTrialStatus(relativeTo referenceDate: Date = Date()) {
        let startedAt = UserDefaults.standard.object(
            forKey: ProTrialStorage.startedAtKey
        ) as? Date
        proTrialStatus = ProTrialAccessPolicy.status(
            startedAt: startedAt,
            relativeTo: referenceDate
        )
    }

    func acknowledgeProTrialExpiration() {
        UserDefaults.standard.set(
            true,
            forKey: ProTrialStorage.expirationAcknowledgedKey
        )
    }

    func configure() {
        guard isConfigured == false else { return }

        #if DEBUG
        Purchases.logLevel = .debug
        #endif
        Purchases.configure(withAPIKey: Self.publicSDKKey)
        Purchases.shared.delegate = self
        isConfigured = true

        Task { [weak self] in
            await self?.refresh()
        }
    }

    func refresh() async {
        guard isConfigured else { return }

        if let refreshTask {
            await refreshTask.value
            return
        }

        let task = Task { @MainActor [weak self] in
            guard let self else {
                return
            }
            await self.performRefresh()
        }
        refreshTask = task
        await task.value
        refreshTask = nil
    }

    func loadPaywallProducts() async {
        guard arePaywallProductsAvailable == false else {
            return
        }
        await refresh()
    }

    func hasPackage(for plan: SilicaSubscriptionPlan) -> Bool {
        package(for: plan) != nil
    }

    var arePaywallProductsAvailable: Bool {
        SilicaSubscriptionPlan.allCases.allSatisfy {
            package(for: $0) != nil
        }
    }

    private func performRefresh() async {
        isLoading = true
        defer { isLoading = false }

        do {
            customerInfo = try await Purchases.shared.customerInfo()
            startTrialForExistingFreeUserIfNeeded()
        } catch {
            #if DEBUG
            print(
                "[Silica][RevenueCat] Customer info refresh failed: "
                    + String(reflecting: error)
            )
            #endif
        }

        do {
            let offerings = try await Purchases.shared.offerings()
            currentOffering = offerings.current
            #if DEBUG
            let packageSummary = offerings.current?.availablePackages.map {
                "\($0.identifier)=\($0.storeProduct.productIdentifier)"
            } ?? []
            print("[Silica][RevenueCat] Current offering packages: \(packageSummary)")
            #endif
            errorMessage = nil
        } catch {
            #if DEBUG
            print(
                "[Silica][RevenueCat] Offering refresh failed: "
                    + String(reflecting: error)
            )
            #endif
            currentOffering = nil
        }
    }

    private func startTrialForExistingFreeUserIfNeeded() {
        guard isSilicaProActive == false,
              UserDefaults.standard.bool(
                forKey: SilicaOnboardingStorage.hasCompletedOnboardingKey
              ) else {
            return
        }
        startProTrialIfNeeded()
    }

    func price(for plan: SilicaSubscriptionPlan) -> String? {
        package(for: plan)?.storeProduct.localizedPriceString
    }

    func productIdentifier(for plan: SilicaSubscriptionPlan) -> String? {
        package(for: plan)?.storeProduct.productIdentifier
    }

    func purchase(_ plan: SilicaSubscriptionPlan) async {
        guard let package = package(for: plan) else {
            errorContext = .purchase
            errorMessage = purchaseFailureMessage
            return
        }

        isPurchasing = true
        defer { isPurchasing = false }

        do {
            let (_, customerInfo, userCancelled) = try await Purchases.shared.purchase(package: package)
            guard userCancelled == false else {
                errorMessage = nil
                return
            }
            self.customerInfo = customerInfo
            errorMessage = nil
        } catch ErrorCode.purchaseCancelledError {
            errorMessage = nil
        } catch {
            errorContext = .purchase
            errorMessage = purchaseFailureMessage
        }
    }

    func restorePurchases() async {
        isRestoring = true
        defer { isRestoring = false }

        do {
            let customerInfo = try await Purchases.shared.restorePurchases()
            self.customerInfo = customerInfo
            errorMessage = nil
        } catch {
            errorContext = .restore
            errorMessage = restoreFailureMessage
        }
    }

    func clearError() {
        errorMessage = nil
    }

    private func package(for plan: SilicaSubscriptionPlan) -> Package? {
        guard let currentOffering else { return nil }

        // Prefer the `silica.pro.*` IDs, while keeping compatibility with the
        // shorter IDs that may already exist in App Store Connect.
        for productIdentifier in plan.productIdentifiers {
            if let package = currentOffering.availablePackages.first(where: {
                $0.storeProduct.productIdentifier == productIdentifier
            }) {
                return package
            }
        }

        return nil
    }
}

extension SubscriptionManager: PurchasesDelegate {
    nonisolated func purchases(
        _ purchases: Purchases,
        receivedUpdated customerInfo: CustomerInfo
    ) {
        Task { @MainActor [weak self] in
            self?.customerInfo = customerInfo
        }
    }
}
