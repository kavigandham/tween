import Foundation
import StoreKit

/// Tween Pro entitlement — StoreKit 2, zero server (constraint 8): the host
/// app verifies `Transaction.currentEntitlements` on-device and mirrors the
/// verdict into ONE App Group boolean. The Messages extension gates on the
/// cached flag only — it never touches StoreKit, keeping purchase work out of
/// the ~120 MB extension ceiling (constraint 1). A boolean preference, no PII
/// (constraint 6).
enum ProEntitlement {
    /// Non-consumable lifetime unlock. Price lives in App Store Connect.
    static let lifetimeProductID = "com.kavigandham.TweenApp.pro.lifetime"
    /// Auto-renewable monthly alternative — either product grants Pro.
    static let monthlyProductID = "com.kavigandham.TweenApp.pro.monthly"
    static let productIDs: Set<String> = [lifetimeProductID, monthlyProductID]

    private static let unlockedKey = "tween.pro.unlocked"

    private static var defaults: UserDefaults? {
        UserDefaults(suiteName: LocationCache.appGroup)
    }

    /// The cached verdict both processes gate on.
    static var isUnlocked: Bool {
        defaults?.bool(forKey: unlockedKey) ?? false
    }

    static func setUnlocked(_ unlocked: Bool) {
        guard unlocked != isUnlocked else { return }
        defaults?.set(unlocked, forKey: unlockedKey)
        // Same contract as every other App Group writer: post so the other
        // process (extension ↔ app) picks up the change without polling.
        MeetupSync.post()
    }

    /// Recomputes Pro from StoreKit's verified current entitlements and
    /// updates the cache. HOST APP ONLY — call at launch and after every
    /// purchase or restore. Revoked (refunded) transactions don't count.
    @discardableResult
    static func refresh() async -> Bool {
        var unlocked = false
        for await result in Transaction.currentEntitlements {
            guard case .verified(let transaction) = result,
                  productIDs.contains(transaction.productID),
                  transaction.revocationDate == nil else { continue }
            unlocked = true
        }
        setUnlocked(unlocked)
        return unlocked
    }

    /// Starts the app-lifetime plumbing exactly once (host app only): an
    /// initial refresh plus the `Transaction.updates` listener, so purchases,
    /// renewals, refunds, and Family Sharing changes that land while the app
    /// runs update the cache without a relaunch.
    static func activate() {
        #if DEBUG
        // Demo-pinned entitlement: the launch refresh would immediately stamp
        // over the forced flag (simctl launches have no StoreKit environment,
        // so refresh() computes "locked"). Demo runs skip StoreKit entirely.
        if CommandLine.arguments.contains("-DEMO_PRO_UNLOCKED")
            || CommandLine.arguments.contains("-DEMO_PRO_LOCKED") { return }
        #endif
        guard updatesTask == nil else { return }
        updatesTask = Task {
            await refresh()
            for await update in Transaction.updates {
                guard case .verified(let transaction) = update else { continue }
                await transaction.finish()
                await refresh()
            }
        }
    }

    private static var updatesTask: Task<Void, Never>?
}
