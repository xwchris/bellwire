// SPDX-License-Identifier: MPL-2.0
import StoreKit
import SwiftUI

struct PaywallView: View {
    @EnvironmentObject private var purchaseManager: PurchaseManager
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.dismiss) private var dismiss
    @Environment(\.openURL) private var openURL
    @State private var selectedPlan = BellwirePurchasePlan.yearly
    @State private var appeared = false

    let appAccountToken: UUID?

    private let benefits: [(icon: String, title: LocalizedStringKey)] = [
        ("square.grid.2x2", "Up to 20 connected projects"),
        ("bolt.horizontal.circle", "50,000 Signals every month"),
        ("iphone.gen3", "Keep 3 iPhones in sync"),
        ("clock.arrow.circlepath", "90 days of Hosted history"),
        ("rectangle.3.group", "10 custom Surfaces per project"),
        ("wrench.and.screwdriver", "Advanced display, export, and diagnostics"),
    ]

    var body: some View {
        ZStack {
            paywallBackground

            ScrollView {
                VStack(spacing: 0) {
                    topBar
                        .paywallEntrance(appeared: appeared, delay: 0, reduceMotion: reduceMotion)

                    hero
                        .padding(.top, BellwireSpacing.roomy)
                        .paywallEntrance(appeared: appeared, delay: 0.06, reduceMotion: reduceMotion)

                    benefitCard
                        .padding(.top, BellwireSpacing.page)
                        .paywallEntrance(appeared: appeared, delay: 0.12, reduceMotion: reduceMotion)

                    privatePlanNote
                        .padding(.top, BellwireSpacing.small)
                        .paywallEntrance(appeared: appeared, delay: 0.15, reduceMotion: reduceMotion)

                    planOptions
                        .padding(.top, BellwireSpacing.roomy)
                        .paywallEntrance(appeared: appeared, delay: 0.18, reduceMotion: reduceMotion)

                    purchaseButton
                        .padding(.top, BellwireSpacing.roomy)
                        .paywallEntrance(appeared: appeared, delay: 0.24, reduceMotion: reduceMotion)

                    footer
                        .padding(.top, BellwireSpacing.standard)
                        .paywallEntrance(appeared: appeared, delay: 0.30, reduceMotion: reduceMotion)
                }
                .padding(.horizontal, BellwireSpacing.roomy)
                .padding(.top, BellwireSpacing.compact)
                .padding(.bottom, BellwireSpacing.large)
            }
            .scrollIndicators(.hidden)
        }
        .task {
            await purchaseManager.prepare()
            withAnimation(reduceMotion ? nil : .easeOut(duration: 0.38)) {
                appeared = true
            }
        }
        .onChange(of: purchaseManager.hasPro) { _, hasPro in
            if hasPro { dismiss() }
        }
    }

    private var paywallBackground: some View {
        ZStack {
            BellwireTheme.background.ignoresSafeArea()

            LinearGradient(
                colors: [
                    BellwireTheme.accent.opacity(0.24),
                    BellwireTheme.background.opacity(0.74),
                    BellwireTheme.background,
                ],
                startPoint: .top,
                endPoint: .center
            )
            .ignoresSafeArea()

            RadialGradient(
                colors: [
                    BellwireTheme.brandOrange.opacity(0.18),
                    .clear,
                ],
                center: UnitPoint(x: 0.86, y: 0.02),
                startRadius: 8,
                endRadius: 290
            )
            .ignoresSafeArea()
        }
    }

    private var topBar: some View {
        ZStack {
            Text("Bellwire Pro")
                .font(.headline.weight(.semibold))
                .foregroundStyle(BellwireTheme.ink)

            HStack {
                Button {
                    dismiss()
                } label: {
                    Image(systemName: "xmark")
                        .font(.system(size: 17, weight: .semibold))
                        .foregroundStyle(BellwireTheme.accent)
                        .frame(width: 46, height: 46)
                        .background(
                            BellwireTheme.accent.opacity(0.10),
                            in: Circle()
                        )
                        .overlay {
                            Circle()
                                .stroke(BellwireTheme.accent.opacity(0.42), lineWidth: 1)
                        }
                }
                .buttonStyle(PressableButtonStyle())
                .accessibilityLabel("Close")

                Spacer()
            }
        }
        .frame(minHeight: 48)
    }

    private var hero: some View {
        VStack(spacing: BellwireSpacing.small) {
            ZStack {
                Circle()
                    .fill(BellwireTheme.accent.opacity(0.13))
                    .frame(width: 76, height: 76)

                BellwireMark(size: 52)
                    .shadow(color: BellwireTheme.brandOrange.opacity(0.22), radius: 18, y: 8)
            }

            Text("More room for every signal.")
                .font(.system(.title2, design: .serif, weight: .semibold))
                .foregroundStyle(BellwireTheme.ink)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)

            Text("Upgrade capacity and history while keeping your privacy choices.")
                .font(.subheadline)
                .foregroundStyle(BellwireTheme.secondaryInk)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity)
    }

    private var privatePlanNote: some View {
        HStack(alignment: .top, spacing: BellwireSpacing.small) {
            Image(systemName: "lock.shield.fill")
                .font(.system(size: 16, weight: .semibold))
                .foregroundStyle(BellwireTheme.success)
                .frame(width: 24, height: 24)

            VStack(alignment: .leading, spacing: 3) {
                Text("Private mode stays free")
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(BellwireTheme.ink)
                Text("Private delivery and 30 days of on-device history are included in every plan.")
                    .font(.caption)
                    .foregroundStyle(BellwireTheme.secondaryInk)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(BellwireSpacing.standard)
        .background(
            BellwireTheme.success.opacity(0.08),
            in: RoundedRectangle(cornerRadius: BellwireRadius.card, style: .continuous)
        )
        .overlay {
            RoundedRectangle(cornerRadius: BellwireRadius.card, style: .continuous)
                .stroke(BellwireTheme.success.opacity(0.22), lineWidth: 1)
        }
    }

    private var benefitCard: some View {
        VStack(spacing: 0) {
            ForEach(Array(benefits.enumerated()), id: \.offset) { index, benefit in
                HStack(spacing: BellwireSpacing.small) {
                    Image(systemName: benefit.icon)
                        .font(.system(size: 17, weight: .medium))
                        .foregroundStyle(BellwireTheme.accent)
                        .frame(width: 26)

                    Text(benefit.title)
                        .font(.subheadline.weight(.medium))
                        .foregroundStyle(BellwireTheme.ink)
                        .frame(maxWidth: .infinity, alignment: .leading)

                    Image(systemName: "checkmark")
                        .font(.system(size: 12, weight: .bold))
                        .foregroundStyle(BellwireTheme.accent)
                        .accessibilityHidden(true)
                }
                .frame(minHeight: 45)

                if index < benefits.count - 1 {
                    Divider()
                        .overlay(BellwireTheme.separator)
                        .padding(.leading, 38)
                }
            }
        }
        .padding(.horizontal, BellwireSpacing.standard)
        .padding(.vertical, BellwireSpacing.compact)
        .background(
            BellwireTheme.surface.opacity(0.92),
            in: RoundedRectangle(cornerRadius: BellwireRadius.largeCard, style: .continuous)
        )
        .overlay {
            RoundedRectangle(cornerRadius: BellwireRadius.largeCard, style: .continuous)
                .stroke(Color.white.opacity(0.09), lineWidth: 1)
        }
        .shadow(color: BellwireTheme.cardShadow, radius: 18, y: 8)
    }

    private var planOptions: some View {
        VStack(spacing: BellwireSpacing.small) {
            ForEach(BellwirePurchasePlan.allCases) { plan in
                Button {
                    selectedPlan = plan
                    BellwireHaptics.selection()
                } label: {
                    PaywallPlanRow(
                        plan: plan,
                        product: purchaseManager.product(for: plan),
                        monthlyProduct: purchaseManager.product(for: .monthly),
                        isSelected: selectedPlan == plan,
                        showsTrial: purchaseManager.isTrialEligible(for: plan)
                            || (Self.isScreenshotPreview && plan == .yearly),
                        previewPrice: Self.isScreenshotPreview ? plan.previewPrice : nil,
                        previewMonthlyEquivalent: Self.isScreenshotPreview && plan == .yearly
                            ? String(localized: "¥16.50")
                            : nil,
                        previewSavings: Self.isScreenshotPreview ? 41 : nil
                    )
                }
                .buttonStyle(PressableButtonStyle())
                .accessibilityAddTraits(selectedPlan == plan ? .isSelected : [])
            }
        }
    }

    private var purchaseButton: some View {
        VStack(spacing: BellwireSpacing.small) {
            if let errorMessage = purchaseManager.errorMessage {
                Text(errorMessage)
                    .font(.caption)
                    .foregroundStyle(BellwireTheme.danger)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Button {
                guard let product = selectedProduct else {
                    Task { await purchaseManager.loadProducts() }
                    return
                }
                Task {
                    _ = await purchaseManager.purchase(
                        product,
                        appAccountToken: appAccountToken
                    )
                }
            } label: {
                HStack(spacing: BellwireSpacing.compact) {
                    if purchaseManager.isPurchasing {
                        ProgressView()
                            .tint(BellwireTheme.accentInk)
                    }
                    Text(primaryButtonTitle)
                        .font(.headline.weight(.bold))
                }
                .foregroundStyle(BellwireTheme.accentInk)
                .frame(maxWidth: .infinity)
                .frame(minHeight: 58)
                .background(
                    LinearGradient(
                        colors: [BellwireTheme.brandOrange, BellwireTheme.accent],
                        startPoint: .leading,
                        endPoint: .trailing
                    ),
                    in: Capsule()
                )
                .shadow(color: BellwireTheme.brandOrange.opacity(0.22), radius: 18, y: 8)
            }
            .buttonStyle(PressableButtonStyle())
            .disabled(purchaseManager.isPurchasing || purchaseManager.isRestoring)
        }
    }

    private var footer: some View {
        VStack(spacing: BellwireSpacing.small) {
            Button {
                Task { await purchaseManager.restorePurchases() }
            } label: {
                HStack(spacing: BellwireSpacing.compact) {
                    if purchaseManager.isRestoring {
                        ProgressView()
                            .controlSize(.small)
                            .tint(BellwireTheme.accent)
                    }
                    Text("Restore Purchases")
                        .font(.subheadline.weight(.medium))
                }
                .foregroundStyle(BellwireTheme.accent)
                .frame(minHeight: 44)
            }
            .buttonStyle(PressableButtonStyle())
            .disabled(purchaseManager.isPurchasing || purchaseManager.isRestoring)

            Text(subscriptionDisclosure)
                .font(.caption2)
                .foregroundStyle(BellwireTheme.mutedInk)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)

            HStack(spacing: BellwireSpacing.roomy) {
                Button("Terms") {
                    openURL(URL(string: "https://bellwire.app/terms")!)
                }
                Button("Privacy") {
                    openURL(URL(string: "https://bellwire.app/privacy")!)
                }
            }
            .font(.caption.weight(.medium))
            .foregroundStyle(BellwireTheme.secondaryInk)
            .buttonStyle(PressableButtonStyle())
        }
    }

    private var selectedProduct: Product? {
        purchaseManager.product(for: selectedPlan)
    }

    private var primaryButtonTitle: String {
        if purchaseManager.loadState == .loading {
            return String(localized: "Loading App Store…")
        }
        if purchaseManager.isTrialEligible(for: selectedPlan)
            || (Self.isScreenshotPreview && selectedPlan == .yearly) {
            return String(localized: "Start free trial")
        }
        if selectedProduct == nil {
            return String(localized: "Try again")
        }
        switch selectedPlan {
        case .yearly: return String(localized: "Continue with yearly")
        case .monthly: return String(localized: "Continue with monthly")
        }
    }

    private var subscriptionDisclosure: LocalizedStringKey {
        return "Subscriptions renew automatically unless canceled at least 24 hours before the current period ends. Manage or cancel in Apple ID settings."
    }

    private static var isScreenshotPreview: Bool {
#if DEBUG
        let arguments = ProcessInfo.processInfo.arguments
        guard let index = arguments.firstIndex(of: "-BellwireScreenshot"),
              arguments.indices.contains(index + 1) else {
            return false
        }
        return arguments[index + 1] == "paywall"
#else
        return false
#endif
    }
}

private struct PaywallPlanRow: View {
    let plan: BellwirePurchasePlan
    let product: Product?
    let monthlyProduct: Product?
    let isSelected: Bool
    let showsTrial: Bool
    let previewPrice: String?
    let previewMonthlyEquivalent: String?
    let previewSavings: Int?

    var body: some View {
        HStack(spacing: BellwireSpacing.standard) {
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: BellwireSpacing.compact) {
                    Text(plan.title)
                        .font(.headline.weight(.semibold))
                        .foregroundStyle(BellwireTheme.ink)

                    if plan == .yearly {
                        Text(savingsLabel)
                            .font(.system(size: 9, weight: .bold, design: .monospaced))
                            .tracking(0.6)
                            .foregroundStyle(BellwireTheme.accentInk)
                            .padding(.horizontal, 8)
                            .padding(.vertical, 4)
                            .background(BellwireTheme.accent, in: Capsule())
                    }
                }

                Text(detailText)
                    .font(.caption)
                    .foregroundStyle(BellwireTheme.secondaryInk)
                    .lineLimit(2)
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            Group {
                if let product {
                    Text(product.displayPrice)
                        .font(.system(.title3, design: .rounded, weight: .bold))
                        .monospacedDigit()
                } else if let previewPrice {
                    Text(previewPrice)
                        .font(.system(.title3, design: .rounded, weight: .bold))
                        .monospacedDigit()
                } else {
                    ProgressView()
                        .controlSize(.small)
                        .tint(BellwireTheme.accent)
                        .accessibilityLabel("Loading App Store…")
                }
            }
            .foregroundStyle(BellwireTheme.ink)

            ZStack {
                Circle()
                    .stroke(
                        isSelected ? BellwireTheme.accent : BellwireTheme.mutedInk.opacity(0.55),
                        lineWidth: isSelected ? 0 : 2
                    )
                    .frame(width: 28, height: 28)

                if isSelected {
                    Circle()
                        .fill(BellwireTheme.accent)
                        .frame(width: 28, height: 28)
                    Image(systemName: "checkmark")
                        .font(.system(size: 12, weight: .bold))
                        .foregroundStyle(BellwireTheme.accentInk)
                }
            }
            .animation(BellwireAnimation.quick, value: isSelected)
        }
        .padding(.horizontal, BellwireSpacing.standard)
        .frame(minHeight: 82)
        .background(
            isSelected ? BellwireTheme.accent.opacity(0.08) : BellwireTheme.surface.opacity(0.92),
            in: RoundedRectangle(cornerRadius: BellwireRadius.largeCard, style: .continuous)
        )
        .overlay {
            RoundedRectangle(cornerRadius: BellwireRadius.largeCard, style: .continuous)
                .stroke(
                    isSelected ? BellwireTheme.accent : BellwireTheme.strongSeparator.opacity(0.65),
                    lineWidth: isSelected ? 1.5 : 1
                )
        }
        .contentShape(RoundedRectangle(cornerRadius: BellwireRadius.largeCard, style: .continuous))
    }

    private var detailText: String {
        if showsTrial && plan == .yearly {
            return String(localized: "7-day free trial · then billed yearly")
        }
        guard plan == .yearly,
              let equivalent = previewMonthlyEquivalent
                ?? product.flatMap(monthlyEquivalent(for:)) else {
            return plan.renewalDescription
        }
        return String(
            format: String(localized: "%@ per month · billed yearly"),
            equivalent
        )
    }

    private var savingsLabel: String {
        if let previewSavings {
            return String(format: String(localized: "SAVE %d%%"), previewSavings)
        }
        guard let yearly = product,
              let monthly = monthlyProduct,
              let percentage = savingsPercentage(yearly: yearly, monthly: monthly),
              percentage > 0 else {
            return String(localized: "BEST VALUE")
        }
        return String(format: String(localized: "SAVE %d%%"), percentage)
    }

    private func monthlyEquivalent(for product: Product) -> String? {
        let value = product.price / Decimal(12)
        return value.formatted(product.priceFormatStyle)
    }

    private func savingsPercentage(yearly: Product, monthly: Product) -> Int? {
        let regularAnnualPrice = monthly.price * Decimal(12)
        guard regularAnnualPrice > 0 else { return nil }
        let ratio = NSDecimalNumber(decimal: yearly.price / regularAnnualPrice).doubleValue
        return Int(((1 - ratio) * 100).rounded())
    }
}

private extension BellwirePurchasePlan {
    var previewPrice: String {
        switch self {
        case .yearly: return String(localized: "¥198.00")
        case .monthly: return String(localized: "¥28.00")
        }
    }
}

private extension View {
    func paywallEntrance(appeared: Bool, delay: Double, reduceMotion: Bool) -> some View {
        opacity(appeared ? 1 : 0)
            .blur(radius: appeared || reduceMotion ? 0 : 4)
            .offset(y: appeared || reduceMotion ? 0 : 12)
            .animation(
                reduceMotion ? nil : .easeOut(duration: 0.34).delay(delay),
                value: appeared
            )
    }
}
