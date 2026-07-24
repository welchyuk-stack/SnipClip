import StoreKit
import Foundation

/// Manages the 24-hour free trial and the one-time unlock IAP.
final class PurchaseManager {
    static let shared = PurchaseManager()

    let productID = "com.snipclip.mac.unlock"
    private let trialStartKey = "snipclip_trial_start"
    private let trialDuration: TimeInterval = 24 * 60 * 60   // 24 hours

    private(set) var isUnlocked = false
    private(set) var product: Product?
    private var updateListenerTask: Task<Void, Never>?

    private init() {}

    // MARK: - Access

    var canUse: Bool { isUnlocked || trialActive }

    var trialActive: Bool {
        guard !isUnlocked else { return true }
        return Date().timeIntervalSince(trialStart) < trialDuration
    }

    var trialSecondsRemaining: TimeInterval {
        max(0, trialDuration - Date().timeIntervalSince(trialStart))
    }

    /// Formatted hours remaining, e.g. "23h 14m"
    var trialTimeString: String {
        let s = Int(trialSecondsRemaining)
        let h = s / 3600; let m = (s % 3600) / 60
        if h > 0 { return "\(h)h \(m)m" }
        return "\(m)m"
    }

    private var trialStart: Date {
        if let d = UserDefaults.standard.object(forKey: trialStartKey) as? Date { return d }
        let d = Date()
        UserDefaults.standard.set(d, forKey: trialStartKey)
        return d
    }

    // MARK: - Lifecycle

    func start() {
        // `isUnlocked`/`product` are only ever mutated on the main actor —
        // both listeners below hop there explicitly — while the UI (AppDelegate,
        // PaywallWindow) reads them synchronously from the main thread. Keeping
        // all writes on @MainActor avoids a real data race without requiring
        // every call site in this file to become actor-isolated.
        updateListenerTask = Task { @MainActor in
            for await result in Transaction.updates {
                await self.handle(result)
            }
        }
        Task { @MainActor in
            await checkCurrentEntitlements()
            await fetchProduct()
        }
    }

    // MARK: - StoreKit

    @MainActor
    private func checkCurrentEntitlements() async {
        for await result in Transaction.currentEntitlements {
            await handle(result)
        }
    }

    @MainActor
    private func fetchProduct() async {
        do {
            let products = try await Product.products(for: [productID])
            product = products.first
        } catch {
            print("[PurchaseManager] product fetch error: \(error)")
        }
    }

    @MainActor
    private func handle(_ result: VerificationResult<Transaction>) async {
        guard case .verified(let tx) = result else { return }
        if tx.productID == productID && tx.revocationDate == nil {
            isUnlocked = true
        }
        await tx.finish()
    }

    // MARK: - Actions

    func purchase() async throws -> Bool {
        guard let product else { throw PurchaseError.productNotLoaded }
        let result = try await product.purchase()
        switch result {
        case .success(let verification):
            await handle(verification)
            return isUnlocked
        case .userCancelled:
            return false
        case .pending:
            return false
        @unknown default:
            return false
        }
    }

    func restore() async {
        do {
            try await AppStore.sync()
            await checkCurrentEntitlements()
        } catch {
            print("[PurchaseManager] restore error: \(error)")
        }
    }

    var displayPrice: String { product?.displayPrice ?? "£1.99" }

    enum PurchaseError: Error {
        case productNotLoaded
    }
}
