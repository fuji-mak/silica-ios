import SwiftUI

enum SilicaPaywallPresentation: Equatable {
    case standard
    case trialExpired
}

/// RevenueCatの価格・購入処理だけを使い、表示はSilicaオリジナルUIで行うPaywall。
struct SilicaCustomPaywallView: View {
    @Environment(\.dismiss) private var dismiss
    let presentation: SilicaPaywallPresentation

    init(presentation: SilicaPaywallPresentation = .standard) {
        self.presentation = presentation
    }

    var body: some View {
        SilicaInitialSetupOnboardingView(
            onFinish: { dismiss() },
            startsAtProPage: true,
            paywallPresentation: presentation
        )
    }
}
