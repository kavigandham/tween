import XCTest
@testable import TweenApp

final class ProCodeTests: XCTestCase {
    override func setUp() {
        super.setUp()
        UserDefaults(suiteName: LocationCache.appGroup)?
            .removePersistentDomain(forName: LocationCache.appGroup)
    }

    override func tearDown() {
        ProCode.clearRedemption()
        ProEntitlement.setUnlocked(false)
        super.tearDown()
    }

    func testValidCodeRedeems() {
        XCTAssertTrue(ProCode.redeem("HALFWAY2026"))
        XCTAssertTrue(ProCode.hasRedeemed)
        XCTAssertTrue(ProEntitlement.isUnlocked)
    }

    func testRedemptionIsCaseAndSeparatorInsensitive() {
        // Drive redeem(), not just isValid — the old version of this test would
        // have passed with redeem() completely broken.
        XCTAssertTrue(ProCode.redeem("halfway2026"))
        XCTAssertTrue(ProEntitlement.isUnlocked)
        ProCode.clearRedemption()

        XCTAssertTrue(ProCode.redeem("HALFWAY-2026"))
        ProCode.clearRedemption()

        XCTAssertTrue(ProCode.redeem("  halfway 2026  "))
        XCTAssertTrue(ProEntitlement.isUnlocked)
    }

    func testInvalidCodeChangesNothing() {
        XCTAssertFalse(ProCode.redeem("NOPE"))
        XCTAssertFalse(ProCode.redeem(""))
        XCTAssertFalse(ProCode.hasRedeemed)
        XCTAssertFalse(ProEntitlement.isUnlocked)
    }

    // MARK: The regression this design exists to prevent

    func testStoreKitRefreshDoesNotWipeARedeemedCode() {
        XCTAssertTrue(ProCode.redeem("HALFWAY2026"))
        // Simulates the launch refresh computing "this device bought nothing",
        // which previously stamped the single unlocked flag straight back off.
        ProEntitlement.setUnlocked(false)
        XCTAssertTrue(ProEntitlement.isUnlocked, "redeemed Pro must survive a StoreKit refresh")
    }

    func testPurchaseAndRedemptionAreIndependent() {
        ProEntitlement.setUnlocked(true)
        XCTAssertTrue(ProEntitlement.isPurchased)
        XCTAssertTrue(ProEntitlement.isUnlocked)
        XCTAssertFalse(ProCode.hasRedeemed)

        // Losing the purchase (refund) with no code redeemed does lock again.
        ProEntitlement.setUnlocked(false)
        XCTAssertFalse(ProEntitlement.isUnlocked)

        // Now actually exercise BOTH sources together, which is what the name
        // claims: each one alone holds the gate open, and it only closes when
        // neither is present.
        ProCode.redeem("HALFWAY2026")
        ProEntitlement.setUnlocked(true)
        XCTAssertTrue(ProEntitlement.isUnlocked)

        ProEntitlement.setUnlocked(false)          // refunded, still redeemed
        XCTAssertTrue(ProEntitlement.isUnlocked)
        XCTAssertFalse(ProEntitlement.isPurchased)

        ProCode.clearRedemption()                  // neither → locked
        XCTAssertFalse(ProEntitlement.isUnlocked)
    }

    func testClearingRedemptionRelocksWhenNothingWasPurchased() {
        XCTAssertTrue(ProCode.redeem("TWEENFOUNDER"))
        XCTAssertTrue(ProEntitlement.isUnlocked)
        ProCode.clearRedemption()
        XCTAssertFalse(ProEntitlement.isUnlocked)
    }
}
