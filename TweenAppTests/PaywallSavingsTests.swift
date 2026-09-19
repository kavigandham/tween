import XCTest
@testable import TweenApp

/// The yearly-vs-monthly savings line under the plan cards.
///
/// Worth its own tests because it is the one number on the paywall that Tween
/// computes rather than quotes: `displayPrice` comes from StoreKit already
/// localised, but "Save 50%" is arithmetic, and arithmetic that overstates a
/// discount on a purchase screen is a refund request rather than a typo.
final class PaywallSavingsTests: XCTestCase {

    private func plan(_ id: String, _ price: Decimal) -> PaywallSheet.PlanOption {
        .init(id: id,
              displayPrice: "",
              priceWithPeriod: "",
              price: price,
              priceFormat: .currency(code: "USD"))
    }

    private var yearly: PaywallSheet.PlanOption { plan(ProEntitlement.yearlyProductID, 29.99) }
    private var monthly: PaywallSheet.PlanOption { plan(ProEntitlement.monthlyProductID, 4.99) }

    // 1. The shipping prices: $4.99 × 12 = $59.88 against $29.99 is 50% off.
    func testShippingPricesReadAsFiftyPercent() throws {
        let note = try XCTUnwrap(PaywallSheet.savingsNote([yearly, monthly]))
        XCTAssertTrue(note.hasPrefix("Save 50%"), note)
        // The annualised figure, not the monthly price — the whole point of
        // the line is showing what twelve renewals actually cost.
        XCTAssertTrue(note.contains("59.88"), note)
        XCTAssertFalse(note.contains("4.99"), note)
    }

    // 2. Order independent — StoreKit returns products in no guaranteed order.
    func testOrderDoesNotMatter() throws {
        let forward = try XCTUnwrap(PaywallSheet.savingsNote([yearly, monthly]))
        let reversed = try XCTUnwrap(PaywallSheet.savingsNote([monthly, yearly]))
        XCTAssertEqual(forward, reversed)
    }

    // 3. One plan on screen means there is no comparison to draw. A paywall
    //    with a half-loaded pair must show no claim rather than a wrong one.
    func testSinglePlanMakesNoClaim() {
        XCTAssertNil(PaywallSheet.savingsNote([yearly]))
        XCTAssertNil(PaywallSheet.savingsNote([monthly]))
        XCTAssertNil(PaywallSheet.savingsNote([]))
    }

    // 4. If a storefront ever prices yearly at or above twelve months of
    //    monthly, the line disappears instead of advertising a negative saving.
    func testNoClaimWhenYearlyIsNotCheaper() {
        let pricey = plan(ProEntitlement.yearlyProductID, 59.88)
        XCTAssertNil(PaywallSheet.savingsNote([pricey, monthly]))
        let worse = plan(ProEntitlement.yearlyProductID, 79.99)
        XCTAssertNil(PaywallSheet.savingsNote([worse, monthly]))
    }

    // 5. A saving too small to round up to 1% is not worth a badge either.
    func testNoClaimForATrivialSaving() {
        let barely = plan(ProEntitlement.yearlyProductID, 59.80)
        XCTAssertNil(PaywallSheet.savingsNote([barely, monthly]))
    }

    // 6. The retired lifetime unlock must never stand in for the monthly leg:
    //    it has no period, so "a year billed monthly" would be nonsense.
    func testRetiredLifetimeIsNotTreatedAsTheMonthlyPlan() {
        let retired = plan(ProEntitlement.lifetimeProductID, 9.99)
        XCTAssertNil(PaywallSheet.savingsNote([yearly, retired]))
    }
}
