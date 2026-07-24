// SPDX-License-Identifier: MPL-2.0
import Foundation
import StoreKit

enum BellwirePurchasePlan: String, CaseIterable, Identifiable {
    case yearly
    case monthly

    var id: String { rawValue }

    var productID: String {
        switch self {
        case .yearly: return "app.bellwire.pro.yearly"
        case .monthly: return "app.bellwire.pro.monthly"
        }
    }

    var title: String {
        switch self {
        case .yearly: return String(localized: "Yearly")
        case .monthly: return String(localized: "Monthly")
        }
    }

    var renewalDescription: String {
        switch self {
        case .yearly: return String(localized: "Billed yearly · best value")
        case .monthly: return String(localized: "Renews every month")
        }
    }
}

@MainActor
final class PurchaseManager: ObservableObject {
    enum LoadState: Equatable {
        case idle
        case loading
        case loaded
        case unavailable
    }

    @Published private(set) var products: [String: Product] = [:]
    @Published private(set) var eligibleTrialProductIDs: Set<String> = []
    @Published private(set) var purchasedProductIDs: Set<String> = []
    @Published private(set) var loadState: LoadState = .idle
    @Published private(set) var isPurchasing = false
    @Published private(set) var isRestoring = false
    @Published var errorMessage: String?

    private var updatesTask: Task<Void, Never>?

    var hasPro: Bool {
        !purchasedProductIDs.isDisjoint(with: Self.productIDs)
    }

    static let productIDs = Set(BellwirePurchasePlan.allCases.map(\.productID))

    init() {
        updatesTask = Task { [weak self] in
            for await update in Transaction.updates {
                guard let self else { return }
                await self.process(update)
            }
        }
    }

    deinit {
        updatesTask?.cancel()
    }

    func prepare() async {
        async let products: Void = loadProducts()
        async let entitlements: Void = refreshEntitlements()
        _ = await (products, entitlements)
    }

    func product(for plan: BellwirePurchasePlan) -> Product? {
        products[plan.productID]
    }

    func isTrialEligible(for plan: BellwirePurchasePlan) -> Bool {
        eligibleTrialProductIDs.contains(plan.productID)
    }

    func loadProducts() async {
        guard loadState != .loading else { return }
        loadState = .loading
        errorMessage = nil

        do {
            let loaded = try await Product.products(for: Self.productIDs)
            products = Dictionary(uniqueKeysWithValues: loaded.map { ($0.id, $0) })
            loadState = loaded.isEmpty ? .unavailable : .loaded

            var eligibleTrials = Set<String>()
            for product in loaded {
                guard let subscription = product.subscription,
                      subscription.introductoryOffer?.paymentMode == .freeTrial,
                      await subscription.isEligibleForIntroOffer else {
                    continue
                }
                eligibleTrials.insert(product.id)
            }
            eligibleTrialProductIDs = eligibleTrials
        } catch {
            loadState = .unavailable
            errorMessage = String(localized: "Bellwire Pro products are temporarily unavailable. Please try again.")
        }
    }

    @discardableResult
    func purchase(_ product: Product, appAccountToken: UUID?) async -> Bool {
        guard !isPurchasing else { return false }
        isPurchasing = true
        errorMessage = nil
        defer { isPurchasing = false }

        do {
            let result: Product.PurchaseResult
            if let appAccountToken {
                result = try await product.purchase(options: [.appAccountToken(appAccountToken)])
            } else {
                result = try await product.purchase()
            }
            switch result {
            case .success(let verification):
                let transaction = try verified(verification)
                await transaction.finish()
                await refreshEntitlements()
                BellwireHaptics.success()
                return true
            case .pending:
                errorMessage = String(localized: "Your purchase is pending approval.")
            case .userCancelled:
                break
            @unknown default:
                errorMessage = String(localized: "The purchase could not be completed.")
            }
        } catch {
            errorMessage = String(localized: "The purchase could not be completed. Please try again.")
            BellwireHaptics.error()
        }

        return false
    }

    func restorePurchases() async {
        guard !isRestoring else { return }
        isRestoring = true
        errorMessage = nil
        defer { isRestoring = false }

        do {
            try await AppStore.sync()
            await refreshEntitlements()
            if hasPro {
                BellwireHaptics.success()
            } else {
                errorMessage = String(localized: "No previous Bellwire Pro purchase was found.")
            }
        } catch {
            errorMessage = String(localized: "Purchases could not be restored. Please try again.")
            BellwireHaptics.error()
        }
    }

    func refreshEntitlements() async {
        var activeProductIDs = Set<String>()

        for await entitlement in Transaction.currentEntitlements {
            guard case .verified(let transaction) = entitlement,
                  Self.productIDs.contains(transaction.productID),
                  transaction.revocationDate == nil else {
                continue
            }
            activeProductIDs.insert(transaction.productID)
        }

        purchasedProductIDs = activeProductIDs
    }

    private func process(_ result: VerificationResult<Transaction>) async {
        guard case .verified(let transaction) = result else { return }
        await transaction.finish()
        await refreshEntitlements()
    }

    private func verified<T>(_ result: VerificationResult<T>) throws -> T {
        switch result {
        case .verified(let value):
            return value
        case .unverified:
            throw PurchaseVerificationError.failed
        }
    }
}

private enum PurchaseVerificationError: Error {
    case failed
}
