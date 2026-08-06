import SwiftUI
import StoreKit

/// The Tween Pro paywall: the plan-ahead bundle pitch, the two products
/// (lifetime unlock + monthly), restore, and a graceful offline/unavailable
/// state. Custom-drawn through Tokens (repo rule) rather than StoreKit's
/// ProductView so it reads as Tween, not as a system insert.
///
/// Free stays free by design: the paywall is only ever reachable from
/// sender-side power features — nothing a bubble RECIPIENT sees is gated.
struct PaywallSheet: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.purchase) private var purchase

    /// nil = still loading; empty = store unreachable (offline, or no
    /// StoreKit configuration in a dev run) — show retry, never a dead end.
    @State private var products: [Product]?
    @State private var purchasing = false
    @State private var unlocked = ProEntitlement.isUnlocked
    @State private var errorMessage: String?
    /// Which plan the CTA buys. Lifetime by default: at five months it costs
    /// less than the monthly, so it is the honest recommendation rather than
    /// the one that maximises revenue.
    @State private var selectedProductID = ProEntitlement.lifetimeProductID

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: Tokens.Spacing.s6) {
                    header
                    comparisonTable
                    if unlocked {
                        unlockedBadge
                    } else {
                        purchaseSection
                    }
                    // OUTSIDE the unlocked/purchase branches on purpose. Nested
                    // in the loaded-products arm, the renewal terms and both
                    // links vanished whenever the store was unreachable — and
                    // vanished permanently once Pro was owned, leaving the app
                    // with no path to Terms or Privacy at all. An App Review
                    // device on a flaky network saw the link-free state
                    // (audit 2026-08-03).
                    restoreAndErrors
                    subscriptionDisclosure
                }
                .padding(Tokens.Spacing.s5)
            }
            .navigationTitle("Tween Pro")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Close") { dismiss() }
                }
            }
        }
        .presentationDetents([.large])
        .presentationDragIndicator(.visible)
        .task { await loadProducts() }
    }

    // MARK: - Pitch

    private var header: some View {
        VStack(alignment: .leading, spacing: Tokens.Spacing.s2) {
            Image(systemName: "sparkles")
                .font(Tokens.Typography.heroIcon)
                .foregroundStyle(Tokens.Palette.brand)
            Text("Plan meetups ahead")
                .font(Tokens.Typography.display)
            Text("Meeting right now stays free, forever. Pro adds planning power for the meetups you set up in advance.")
                .font(Tokens.Typography.subheadline)
                .foregroundStyle(Tokens.Palette.textSecondary)
        }
    }

    /// What Free already does versus what Pro adds.
    ///
    /// EVERY Pro row is a real `ProEntitlement.isUnlocked` gate in the code —
    /// groups and saved addresses (OnboardingView+FriendsPanel), the plan sheet
    /// (OnboardingView+SpotSheet), per-person travel modes
    /// (OnboardingView+GroupBar), and the reminder/calendar actions inside the
    /// plan. The group panel that shows everyone's ETA is deliberately NOT
    /// listed: it renders for free users too, and claiming it would be selling
    /// something they already have.
    private var comparisonTable: some View {
        VStack(spacing: 0) {
            comparisonHeader
            ForEach(Array(Self.comparisonRows.enumerated()), id: \.offset) { index, row in
                if index > 0 {
                    Rectangle()
                        .fill(Tokens.Palette.textPrimary.opacity(0.08))
                        .frame(height: 0.5)
                }
                comparisonRow(row)
            }
        }
        .background(Tokens.Palette.elevated,
                    in: RoundedRectangle(cornerRadius: Tokens.Radius.group, style: .continuous))
    }

    private var comparisonHeader: some View {
        HStack(spacing: Tokens.Spacing.s2) {
            Spacer(minLength: 0)
            Text("Free")
                .frame(width: 52)
            Text("Pro")
                .foregroundStyle(Tokens.Palette.accent)
                .frame(width: 52)
        }
        .font(Tokens.Typography.captionBold)
        .foregroundStyle(Tokens.Palette.textSecondary)
        .padding(.horizontal, Tokens.Spacing.s4)
        .padding(.top, Tokens.Spacing.s3)
        .padding(.bottom, Tokens.Spacing.s2)
    }

    private func comparisonRow(_ row: ComparisonRow) -> some View {
        HStack(spacing: Tokens.Spacing.s2) {
            Text(row.title)
                .font(Tokens.Typography.subheadline)
                .foregroundStyle(Tokens.Palette.textPrimary)
                .frame(maxWidth: .infinity, alignment: .leading)
            mark(included: row.free, isPro: false)
                .frame(width: 52)
            mark(included: true, isPro: true)
                .frame(width: 52)
        }
        .padding(.horizontal, Tokens.Spacing.s4)
        .padding(.vertical, Tokens.Spacing.s3)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(row.free
                            ? "\(row.title), included in Free and Pro"
                            : "\(row.title), Pro only")
    }

    @ViewBuilder
    private func mark(included: Bool, isPro: Bool) -> some View {
        if included {
            Image(systemName: "checkmark")
                .font(Tokens.Typography.captionBold)
                .foregroundStyle(isPro ? Tokens.Palette.accent : Tokens.Palette.textSecondary)
        } else {
            // An em dash, not a red cross: Free isn't broken, it just stops here.
            Text("—")
                .font(Tokens.Typography.caption)
                .foregroundStyle(Tokens.Palette.textTertiary)
        }
    }

    struct ComparisonRow {
        let title: String
        /// Whether the FREE tier includes it. Pro includes every row.
        let free: Bool
    }

    static let comparisonRows: [ComparisonRow] = [
        .init(title: "Fair spots by everyone's drive time", free: true),
        .init(title: "Share and agree inside iMessage", free: true),
        .init(title: "See everyone's travel time", free: true),
        .init(title: "Groups and saved addresses", free: false),
        .init(title: "Pick a day and time", free: false),
        .init(title: "Transit and walking per person", free: false),
        .init(title: "Leave-by reminders", free: false),
        .init(title: "Add the meetup to your calendar", free: false),
    ]

    // MARK: - Purchase

    private var unlockedBadge: some View {
        Label("You have Tween Pro", systemImage: "checkmark.seal.fill")
            .font(Tokens.Typography.headline)
            .foregroundStyle(Tokens.Palette.success)
            .frame(maxWidth: .infinity, minHeight: Tokens.Layout.primaryControlHeight)
            .background(Tokens.Palette.brandLight,
                        in: RoundedRectangle(cornerRadius: Tokens.Radius.card, style: .continuous))
    }

    @ViewBuilder
    private var purchaseSection: some View {
        #if DEBUG
        // -DEMO_PAYWALL_PRICES draws the plan cards from the SAME prices as
        // TweenPro.storekit, with no live store. simctl cannot carry a StoreKit
        // configuration, so without this the only way to see or screenshot this
        // screen is Xcode's Run action on a developer's own machine — and App
        // Review's subscription slot needs exactly this screenshot.
        // Purchases are inert: there is no Product behind these cards.
        if CommandLine.arguments.contains("-DEMO_PAYWALL_PRICES") {
            planPicker(Self.previewPlans)
        } else {
            storeBackedSection
        }
        #else
        storeBackedSection
        #endif
    }

    @ViewBuilder
    private var storeBackedSection: some View {
        switch products {
        case nil:
            ProgressView()
                .frame(maxWidth: .infinity, minHeight: Tokens.Layout.primaryControlHeight)
        case .some(let loaded) where loaded.isEmpty:
            VStack(spacing: Tokens.Spacing.s3) {
                Text("The App Store isn't reachable right now.")
                    .font(Tokens.Typography.subheadline)
                    .foregroundStyle(Tokens.Palette.textSecondary)
                Button {
                    products = nil
                    Task { await loadProducts() }
                } label: {
                    Label("Try Again", systemImage: "arrow.clockwise")
                }
                .buttonStyle(.tweenPrimary(.subtle))
            }
            .frame(maxWidth: .infinity)
        case .some(let loaded):
            planPicker(planOptions(loaded))
                .disabled(purchasing)
        }
    }

    private func planPicker(_ plans: [PlanOption]) -> some View {
        VStack(spacing: Tokens.Spacing.s3) {
            HStack(spacing: Tokens.Spacing.s3) {
                ForEach(plans) { planCard($0) }
            }
            continueButton(plans)
            Text("One purchase unlocks Pro on every device signed into your App Store account. No account, no tracking — Tween stays serverless.")
                .font(Tokens.Typography.caption)
                .foregroundStyle(Tokens.Palette.textTertiary)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private func planCard(_ plan: PlanOption) -> some View {
        let isLifetime = plan.isLifetime
        let isSelected = plan.id == selectedProductID
        return Button {
            selectedProductID = plan.id
        } label: {
            VStack(spacing: Tokens.Spacing.s1) {
                Text(isLifetime ? "Lifetime" : "Monthly")
                    .font(Tokens.Typography.captionBold)
                    .foregroundStyle(Tokens.Palette.textSecondary)
                Text(plan.displayPrice)
                    .font(Tokens.Typography.title2)
                    .foregroundStyle(Tokens.Palette.textPrimary)
                Text(isLifetime ? "pay once" : "per month")
                    .font(Tokens.Typography.caption)
                    .foregroundStyle(Tokens.Palette.textTertiary)
                if isLifetime {
                    Text("Best value")
                        .font(Tokens.Typography.caption2Bold)
                        .foregroundStyle(Tokens.Palette.onBrand)
                        .padding(.horizontal, Tokens.Spacing.s2)
                        .padding(.vertical, 2)
                        .background(Tokens.Palette.brand, in: Capsule())
                }
            }
            .padding(.vertical, Tokens.Spacing.s3)
            // AFTER the padding, so the background stretches to the taller
            // sibling. Before it, the frame sized the content and the "Best
            // value" badge made the Lifetime card visibly taller.
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(isSelected ? Tokens.Palette.brandLight : Tokens.Palette.elevated,
                        in: RoundedRectangle(cornerRadius: Tokens.Radius.card, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: Tokens.Radius.card, style: .continuous)
                    .strokeBorder(isSelected ? Tokens.Palette.accent : .clear, lineWidth: 2)
            )
            .contentShape(RoundedRectangle(cornerRadius: Tokens.Radius.card, style: .continuous))
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(isSelected ? [.isButton, .isSelected] : .isButton)
        .accessibilityLabel(isLifetime
                            ? "Lifetime, \(plan.displayPrice) once, best value"
                            : "Monthly, \(plan.displayPrice) per month")
    }

    @ViewBuilder
    private func continueButton(_ plans: [PlanOption]) -> some View {
        // No `?? plans.first` fallback. Buying a plan the user cannot see
        // selected is worse than a disabled button: if the lifetime product
        // were ever unapproved in App Store Connect, the old fallback would
        // have charged them for the monthly under a Lifetime-shaped default.
        if let plan = plans.first(where: { $0.id == selectedProductID }) {
            Button {
                guard let product = products?.first(where: { $0.id == plan.id }) else { return }
                Task { await buy(product) }
            } label: {
                Text(plan.isLifetime
                     ? "Unlock Pro — \(plan.priceWithPeriod)"
                     : "Subscribe — \(plan.priceWithPeriod)")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.tweenPrimary())
        }
    }

    /// A plan as the cards render it. Decoupled from StoreKit's `Product` so
    /// the DEBUG preview below can draw the real layout without a live store —
    /// `simctl` cannot carry a StoreKit configuration, so this is the only way
    /// to screenshot this screen outside Xcode's Run action.
    struct PlanOption: Identifiable {
        let id: String
        /// Bare price for the card ("$1.99") — the card's own subtitle says
        /// "per month", so repeating the period here read as "$1.99/mo per
        /// month".
        let displayPrice: String
        /// Price WITH period for the button ("$1.99/mo"), where there is no
        /// subtitle to carry it.
        let priceWithPeriod: String
        var isLifetime: Bool { id == ProEntitlement.lifetimeProductID }
    }

    #if DEBUG
    /// Mirrors TweenPro.storekit exactly. If those prices change, change these
    /// — a preview showing a price the store does not charge is worse than no
    /// preview at all.
    static let previewPlans: [PlanOption] = [
        .init(id: ProEntitlement.lifetimeProductID, displayPrice: "$9.99", priceWithPeriod: "$9.99"),
        .init(id: ProEntitlement.monthlyProductID, displayPrice: "$1.99", priceWithPeriod: "$1.99/mo"),
    ]
    #endif

    private func planOptions(_ loaded: [Product]) -> [PlanOption] {
        // Lifetime first regardless of the order StoreKit returns.
        loaded.map { PlanOption(id: $0.id,
                                displayPrice: $0.displayPrice,
                                priceWithPeriod: $0.displayPriceWithPeriod) }
            .sorted { $0.isLifetime && !$1.isLifetime }
    }

    /// Restore and any error, OUTSIDE the products-loaded branch. Nested in it,
    /// a user whose App Store was unreachable had no Restore button and saw no
    /// error text — the two things they need most in exactly that state
    /// (audit 2026-08-04).
    @ViewBuilder
    private var restoreAndErrors: some View {
        if let errorMessage {
            Text(errorMessage)
                .font(Tokens.Typography.caption)
                .foregroundStyle(Tokens.Palette.destructive)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        Button("Restore Purchases") {
            Task { await restore() }
        }
        .font(Tokens.Typography.subheadline)
        .foregroundStyle(Tokens.Palette.accent)
        .disabled(purchasing)
    }

    /// Required for the auto-renewable monthly product. App Review guideline
    /// 3.1.2 wants the renewal terms stated in the purchase flow AND functional
    /// links to a Terms of Use (EULA) and a Privacy Policy — their absence is a
    /// rejection, and both were missing (audit 2026-08-02).
    ///
    /// Apple's standard EULA is used, which is the correct link when an app
    /// ships no custom licence agreement.
    ///
    /// Rendered in EVERY paywall state — loading, store-unreachable, purchasing,
    /// and already-unlocked — because 3.1.2 expects the links reachable in the
    /// app, not contingent on a network call succeeding.
    private var subscriptionDisclosure: some View {
        VStack(alignment: .leading, spacing: Tokens.Spacing.s2) {
            Text("Monthly renews automatically unless cancelled at least 24 hours before the period ends. Manage or cancel in your App Store account settings. Lifetime is a one-time purchase and never renews.")
                .font(Tokens.Typography.caption)
                .foregroundStyle(Tokens.Palette.textTertiary)
                .frame(maxWidth: .infinity, alignment: .leading)

            HStack(spacing: Tokens.Spacing.s3) {
                Link("Terms of Use", destination: Self.termsURL)
                Link("Privacy Policy", destination: Self.privacyURL)
            }
            .font(Tokens.Typography.caption)
            .foregroundStyle(Tokens.Palette.accent)
        }
    }

    /// Apple's standard EULA — the correct Terms link for an app with no
    /// custom licence agreement.
    static let termsURL = URL(string: "https://www.apple.com/legal/internet-services/itunes/dev/stdeula/")!

    /// LIVE, and deliberately NOT in the main source repo.
    ///
    /// This used to point at `kavigandham/tween/blob/main/docs/privacy.md`,
    /// which works only while that repo stays public — a setting owned by
    /// someone who isn't shipping this app. The moment it flips private, the
    /// only privacy link in the purchase flow 404s, which is a guideline 3.1.2
    /// rejection on a LIVE listing (2026-08-04).
    ///
    /// `N1tr029/tween-legal` exists to hold these two pages and nothing else,
    /// served by GitHub Pages as plain HTML (`.nojekyll`, no build step). Keep
    /// it public. `support.html` in the same repo is the App Store support URL.
    static let privacyURL = URL(string: "https://n1tr029.github.io/tween-legal/privacy.html")!

    /// The App Store support URL, same host and same reasoning.
    static let supportURL = URL(string: "https://n1tr029.github.io/tween-legal/support.html")!

    // MARK: - StoreKit

    private func loadProducts() async {
        // Lifetime first in display order regardless of store return order.
        let loaded = (try? await Product.products(for: ProEntitlement.productIDs)) ?? []
        products = loaded.sorted { a, _ in a.id == ProEntitlement.lifetimeProductID }
    }

    private func buy(_ product: Product) async {
        purchasing = true
        defer { purchasing = false }
        errorMessage = nil
        do {
            switch try await purchase(product) {
            case .success(let verification):
                switch verification {
                case .verified(let transaction):
                    await transaction.finish()
                    unlocked = await ProEntitlement.refresh()
                case .unverified(let transaction, _):
                    // Charged, but StoreKit could not verify the signature.
                    // Finish it anyway — an unfinished transaction is
                    // re-delivered on EVERY launch forever — and say something.
                    // This used to fall through silently, leaving the user
                    // billed and staring at a sheet that did nothing
                    // (audit 2026-08-04).
                    await transaction.finish()
                    errorMessage = "That purchase couldn't be verified. If you were charged, tap Restore Purchases."
                }
            case .pending:
                // Ask-to-Buy etc. — the Transaction.updates listener started
                // at app launch unlocks whenever approval lands.
                errorMessage = "Purchase pending approval — Pro unlocks automatically once it's approved."
            case .userCancelled:
                break
            @unknown default:
                break
            }
        } catch {
            errorMessage = "The purchase didn't go through. Nothing was charged — try again."
        }
    }

    private func restore() async {
        purchasing = true
        defer { purchasing = false }
        try? await AppStore.sync()
        // `refresh()` returns STOREKIT's verdict alone, not the effective gate.
        // Someone unlocked by redeem code owns no App Store product, so
        // restoring told them Pro was gone and re-showed the purchase buttons
        // for something they already have — and the App Review notes send a
        // reviewer down exactly that path (audit 2026-08-04).
        let purchased = await ProEntitlement.refresh()
        unlocked = purchased || ProEntitlement.isUnlocked
        if !unlocked {
            errorMessage = "No previous purchase found for this App Store account."
        }
    }
}

#Preview {
    PaywallSheet()
}

private extension Product {
    /// "$1.99/mo" for a subscription, "$9.99" for the one-time unlock.
    ///
    /// The unit comes from the product's OWN subscription period rather than a
    /// hardcoded "/mo", so adding an annual plan later cannot silently label it
    /// per-month. `displayPrice` is already localised by StoreKit.
    var displayPriceWithPeriod: String {
        guard let period = subscription?.subscriptionPeriod else { return displayPrice }
        let unit: String
        switch period.unit {
        case .day: unit = "day"
        case .week: unit = "wk"
        case .month: unit = "mo"
        case .year: unit = "yr"
        @unknown default: return displayPrice
        }
        return "\(displayPrice)/\(unit)"
    }
}
