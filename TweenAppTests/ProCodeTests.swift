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
        // People retype these out of a text message.
        XCTAssertTrue(ProCode.isValid("halfway2026"))
        XCTAssertTrue(ProCode.isValid("HALFWAY-2026"))
        XCTAssertTrue(ProCode.isValid("  halfway 2026  "))
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
    }

    func testClearingRedemptionRelocksWhenNothingWasPurchased() {
        XCTAssertTrue(ProCode.redeem("TWEENFOUNDER"))
        XCTAssertTrue(ProEntitlement.isUnlocked)
        ProCode.clearRedemption()
        XCTAssertFalse(ProEntitlement.isUnlocked)
    }
}
