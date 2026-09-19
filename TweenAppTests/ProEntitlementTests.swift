import XCTest
import StoreKitTest
@testable import TweenApp

/// Tween Pro entitlement coverage: the App Group cache both processes gate
/// on, and the real StoreKit path via a local `SKTestSession` (no network,
/// no App Store Connect) — a test purchase must flip the cache through
/// `ProEntitlement.refresh()`, and a session with no purchases must clear a
/// stale unlocked flag.
final class ProEntitlementTests: XCTestCase {

    override func setUp() {
        super.setUp()
        // Start every test from a clean App Group suite.
        if let defaults = UserDefaults(suiteName: LocationCache.appGroup) {
            for key in defaults.dictionaryRepresentation().keys {
                defaults.removeObject(forKey: key)
            }
        }
    }

    // 1. The cached flag round-trips and defaults to locked.
    func testCacheRoundTrip() {
        XCTAssertFalse(ProEntitlement.isUnlocked)
        ProEntitlement.setUnlocked(true)
        XCTAssertTrue(ProEntitlement.isUnlocked)
        ProEntitlement.setUnlocked(false)
        XCTAssertFalse(ProEntitlement.isUnlocked)
    }

    // 2. The RETIRED lifetime unlock still grants Pro.
    //
    //    It left the paywall in the 2026-09-19 lifetime → yearly change, and
    //    it must never leave the entitlement: those buyers paid once for
    //    "forever" and there is no server to re-grant them from (constraint 8).
    //    If this test ever goes red because the ID was tidied out of
    //    `productIDs`, the fix is to put the ID back, not to update the test.
    func testRetiredLifetimePurchaseStillUnlocksPro() async throws {
        let session = try startSession()
        try await buy(ProEntitlement.lifetimeProductID, in: session)
        let unlocked = await refreshUntilUnlocked()
        XCTAssertTrue(unlocked)
        XCTAssertTrue(ProEntitlement.isUnlocked)
    }

    // 2b. …and the paywall must not be able to OFFER it again. The two sets
    //     answer different questions; this pins them apart.
    func testRetiredLifetimeIsHonouredButNotPurchasable() {
        XCTAssertTrue(ProEntitlement.productIDs.contains(ProEntitlement.lifetimeProductID))
        XCTAssertFalse(ProEntitlement.purchasableProductIDs.contains(ProEntitlement.lifetimeProductID))
        XCTAssertTrue(ProEntitlement.purchasableProductIDs.isSubset(of: ProEntitlement.productIDs))
        XCTAssertEqual(ProEntitlement.purchasableProductIDs,
                       [ProEntitlement.yearlyProductID, ProEntitlement.monthlyProductID])
    }

    // 3. The monthly subscription unlocks Pro too — either product grants it.
    func testMonthlySubscriptionUnlocksPro() async throws {
        let session = try startSession()
        try await buy(ProEntitlement.monthlyProductID, in: session)
        let unlocked = await refreshUntilUnlocked()
        XCTAssertTrue(unlocked)
        // Assert the App Group write, not just the return value: the cache is
        // the only thing the extension can read, and it is what the two
        // processes actually disagree about.
        XCTAssertTrue(ProEntitlement.isUnlocked)
    }

    // 3b. The yearly subscription unlocks Pro through the same path.
    func testYearlySubscriptionUnlocksPro() async throws {
        let session = try startSession()
        try await buy(ProEntitlement.yearlyProductID, in: session)
        let unlocked = await refreshUntilUnlocked()
        XCTAssertTrue(unlocked)
        XCTAssertTrue(ProEntitlement.isUnlocked)
    }

    // 4. A CANCELLED refresh must not clear an existing unlock.
    //
    // `Transaction.currentEntitlements` is a non-throwing AsyncSequence, so
    // cancellation ends the loop rather than throwing and `refresh()` reaches
    // its write with a PARTIAL read. Without a guard it stamps "locked" into
    // the App Group — cross-process, and the extension can never recompute it
    // — so dismissing a view whose task owns the refresh could revoke Pro from
    // someone who paid. That regression shipped once; this pins it.
    func testCancelledRefreshLeavesAnExistingUnlockAlone() async {
        ProEntitlement.setUnlocked(true)
        let task = Task { await ProEntitlement.refresh() }
        task.cancel()
        let result = await task.value
        XCTAssertTrue(result, "a cancelled refresh must report the last known verdict")
        XCTAssertTrue(ProEntitlement.isUnlocked, "a cancelled refresh must not write a partial read")
    }

    /// Purchases through the session's synchronous test-daemon API — the
    /// StoreKit 2 `buyProduct(identifier:)` variant throws `notEntitled` in
    /// unit-test hosts (known StoreKitTest issue). If even the daemon path is
    /// refused in this runner, skip rather than fail: the entitlement logic
    /// itself is covered by tests 1 and 4.
    private func buy(_ productID: String, in session: SKTestSession) async throws {
        do {
            _ = try session.buyProduct(productIdentifier: productID)
        } catch {
            throw XCTSkip("StoreKit test purchases unavailable in this runner: \(error)")
        }
    }

    /// `Transaction.currentEntitlements` picks up a test purchase
    /// asynchronously — poll refresh() briefly instead of asserting on the
    /// first read.
    private func refreshUntilUnlocked() async -> Bool {
        for _ in 0..<20 {
            if await ProEntitlement.refresh() { return true }
            try? await Task.sleep(nanoseconds: 100_000_000)
        }
        return false
    }

    // 4. refresh() with no purchases CLEARS a stale unlocked cache — the flag
    //    is a mirror of StoreKit, never a one-way latch.
    func testRefreshWithoutPurchaseClearsStaleUnlock() async throws {
        _ = try startSession()
        ProEntitlement.setUnlocked(true)
        let unlocked = await ProEntitlement.refresh()
        XCTAssertFalse(unlocked)
        XCTAssertFalse(ProEntitlement.isUnlocked)
    }

    /// Fresh local StoreKit session on the bundled configuration, dialogs off,
    /// transaction history wiped so tests can't bleed into each other.
    private func startSession() throws -> SKTestSession {
        let url = try XCTUnwrap(
            Bundle(for: Self.self).url(forResource: "TweenPro", withExtension: "storekit"),
            "TweenPro.storekit missing from the test bundle — check project.yml resources")
        let session = try SKTestSession(contentsOf: url)
        session.disableDialogs = true
        session.clearTransactions()
        return session
    }
}
