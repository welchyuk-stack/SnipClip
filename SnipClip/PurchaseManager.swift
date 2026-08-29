import Foundation

/// Manages the 24-hour free trial. There is no purchase path any more —
/// SnipClip is sold as a paid-up-front app on the Store, and the trial
/// simply gates existing installs that predate that change.
final class PurchaseManager {
    static let shared = PurchaseManager()

    // Legacy key — only used once to migrate existing users from UserDefaults to Keychain.
    private let legacyTrialStartKey = "snipclip_trial_start"
    private let trialDuration: TimeInterval = 24 * 60 * 60   // 24 hours

    // Keychain coordinates for the trial start timestamp.
    private let keychainService = "com.snipclip.mac"
    private let keychainAccount = "trial_start"

    private init() {}

    // MARK: - Access

    var canUse: Bool { trialActive }

    var trialActive: Bool {
        Date().timeIntervalSince(trialStart) < trialDuration
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

    // Cached after first resolution — avoids repeated Keychain IPC on every property read.
    private lazy var trialStart: Date = resolveTrialStart()

    private func resolveTrialStart() -> Date {
        var status = errSecSuccess
        if let d = keychainLoadDate(status: &status) { return d }

        // Only write a new date when the item is definitively absent — not on a
        // transient error (locked keychain, auth failure, etc.) where the real
        // date might still be there but temporarily unreadable.
        guard status == errSecItemNotFound else { return Date() }

        // One-time migration: honour an existing UserDefaults timestamp so users
        // who already started their trial don't get a free reset after updating.
        // Only delete the legacy value once the Keychain write is confirmed.
        if let d = UserDefaults.standard.object(forKey: legacyTrialStartKey) as? Date {
            if keychainSaveDate(d) {
                UserDefaults.standard.removeObject(forKey: legacyTrialStartKey)
            }
            return d
        }

        // Fresh install — start the clock now.
        let d = Date()
        keychainSaveDate(d)
        return d
    }

    // MARK: - Keychain helpers

    private func keychainLoadDate(status statusOut: inout OSStatus) -> Date? {
        let query: [CFString: Any] = [
            kSecClass: kSecClassGenericPassword,
            kSecAttrService: keychainService,
            kSecAttrAccount: keychainAccount,
            kSecReturnData: true,
            kSecMatchLimit: kSecMatchLimitOne
        ]
        var result: AnyObject?
        statusOut = SecItemCopyMatching(query as CFDictionary, &result)
        guard statusOut == errSecSuccess,
              let data = result as? Data, data.count == 8 else { return nil }
        // loadUnaligned: Keychain data is not guaranteed to be Double-aligned.
        let ti = data.withUnsafeBytes { $0.loadUnaligned(as: Double.self) }
        return Date(timeIntervalSince1970: ti)
    }

    @discardableResult
    private func keychainSaveDate(_ date: Date) -> Bool {
        var ti = date.timeIntervalSince1970
        let data = Data(bytes: &ti, count: 8)
        // Search dict contains only identifying attributes — kSecAttrAccessible is an
        // item attribute and belongs in the update/add payload, not the search predicate.
        let search: [CFString: Any] = [
            kSecClass: kSecClassGenericPassword,
            kSecAttrService: keychainService,
            kSecAttrAccount: keychainAccount
        ]
        let attrs: [CFString: Any] = [
            kSecValueData: data,
            // Not backed up / not synced to iCloud — makes clock-rollback attacks harder.
            kSecAttrAccessible: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        ]
        let updateStatus = SecItemUpdate(search as CFDictionary, attrs as CFDictionary)
        if updateStatus == errSecSuccess { return true }
        if updateStatus == errSecItemNotFound {
            var addQuery = search
            addQuery[kSecValueData] = data
            addQuery[kSecAttrAccessible] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
            return SecItemAdd(addQuery as CFDictionary, nil) == errSecSuccess
        }
        return false
    }
}
