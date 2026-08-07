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

    /// The flag both processes gate on. The extension reads ONLY this.
    private static let unlockedKey = "tween.pro.unlocked"
    /// StoreKit's verdict, kept as its own key so the gate is computed in one
    /// place (`syncUnlockedFlag`) rather than every caller re-deriving it.
    private static let purchasedKey = "tween.pro.purchased"
    /// RETIRED (a9d0b5f): the on-device redeem-code flag. Named here only so
    /// it can be reaped from devices that redeemed before it was removed, and
    /// so the name is never reused — a future "second source" writing this key
    /// would silently resurrect Pro from a bool nobody remembers setting.
    private static let retiredRedeemedKey = "tween.pro.redeemedCode"

    private static var defaults: UserDefaults? {
        UserDefaults(suiteName: LocationCache.appGroup)
    }

    /// The cached verdict both processes gate on. The extension reads only
    /// this — it never touches StoreKit or CryptoKit.
    static var isUnlocked: Bool {
        defaults?.bool(forKey: unlockedKey) ?? false
    }

    /// True when StoreKit says this device owns a Pro product.
    static var isPurchased: Bool {
        defaults?.bool(forKey: purchasedKey) ?? false
    }

    /// Records StoreKit's verdict, then recomputes the gate.
    ///
    /// Kept as its own key rather than writing `unlockedKey` directly: the
    /// gate is computed in one place (`syncUnlockedFlag`) so a future second
    /// source can be OR-ed in without every caller re-deriving it.
    static func setUnlocked(_ purchased: Bool) {
        defaults?.set(purchased, forKey: purchasedKey)
        // Reap the retired redemption flag. Idempotent and free on the vast
        // majority of devices that never had one; without it the stale `true`
        // outlives the feature forever in the shared container.
        defaults?.removeObject(forKey: retiredRedeemedKey)
        syncUnlockedFlag()
    }

    /// Recomputes the gate from StoreKit's verdict. Idempotent, and only posts
    /// when the effective value actually changed.
    ///
    /// The on-device redeem-code path was REMOVED before 1.0.1 shipped: it
    /// handed App Review a way to unlock Pro without exercising either IAP
    /// (a 2.1 risk on the very submission that introduces them), and Apple's
    /// own Offer Codes (subscription) and Promo Codes (non-consumable) do the
    /// comping job properly — server-side, revocable, cross-device, and with
    /// no app update needed to issue one.
    static func syncUnlockedFlag() {
        let effective = isPurchased
        guard effective != isUnlocked else { return }
        defaults?.set(effective, forKey: unlockedKey)
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
                // Finish BOTH outcomes. `continue` on unverified left the
                // transaction unfinished, so StoreKit re-delivered it on every
                // launch for the life of the install (audit 2026-08-04).
                switch update {
                case .verified(let transaction):
                    await transaction.finish()
                    await refresh()
                case .unverified(let transaction, _):
                    await transaction.finish()
                }
            }
        }
    }

    private static var updatesTask: Task<Void, Never>?
}
