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
    @Environment(\.scenePhase) private var scenePhase

    /// nil = still loading; empty = nothing to sell, with `loadFailure`
    /// saying which flavour — show retry, never a dead end.
    @State private var products: [Product]?
    /// Why the plan cards aren't on screen. nil while loading or loaded.
    @State private var loadFailure: LoadFailure?
    /// The manual/foreground retry, held so it dies with the sheet.
    @State private var reloadTask: Task<Void, Never>?
    @State private var purchasing = false
    @State private var unlocked = ProEntitlement.isUnlocked
    @State private var errorMessage: String?
    /// Whether `errorMessage` is actually a failure. "Pending approval" and
    /// "unlocking in a moment" are not — drawn in destructive red they told
    /// people something had gone wrong when nothing had.
    @State private var messageIsFailure = true
    /// Live entitlement observation, held for the sheet's lifetime.
    @State private var entitlementToken: MeetupSyncToken?
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
        // Pro can be granted while this sheet sits open, with the app never
        // leaving the foreground: an Ask-to-Buy approval landing on a parent's
        // device, an Offer Code redeemed elsewhere, a purchase on another
        // device. ProEntitlement's app-level Transaction.updates listener posts
        // on MeetupSync whenever the flag actually changes, so observing it is
        // the only thing that catches those — scenePhase never fires.
        .onAppear { entitlementToken = MeetupSync.observe { syncEntitlement() } }
        .onChange(of: scenePhase) { _, phase in
            guard phase == .active else { return }
            // Deliberately NOT the cached flag. On the exact round trip this
            // exists for — leave to redeem a code, come back — `.active` fires
            // while ProEntitlement.refresh() is still awaiting
            // currentEntitlements, so the cache still holds the OLD value and
            // there would be no second read. Ask StoreKit itself.
            Task {
                unlocked = await ProEntitlement.refresh()
                if unlocked { errorMessage = nil }
            }
            // Someone who leaves to sign into the App Store — or to accept a
            // pending agreement — and comes back should find the plans, not the
            // failure they left behind. Only ever re-runs from a failed load.
            if products?.isEmpty == true { reload() }
        }
        .onDisappear {
            reloadTask?.cancel()
            // Releases the observer. The handler captures this view, whose
            // @State box holds the token, so leaving it set would be a cycle
            // and the Darwin observer would outlive the sheet.
            entitlementToken = nil
        }
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
    /// plan. The group panel that shows everyone's ETA renders for free users,
    /// so it appears in the FREE column ("See everyone's travel time") —
    /// claiming it as Pro would be selling something they already have.
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
        // "Fair spots between everyone", NOT "by everyone's drive time". The
        // old wording said "drive" one row above a Pro row selling transit and
        // walking, and it overlapped with the "see everyone's travel time" row
        // below it. This row is about the RANKING; that one is about the
        // DISPLAY. Free ranks by driving only — the "Transit and walking" row
        // is what marks that as the Pro upgrade, so neither column overclaims.
        .init(title: "Fair spots between everyone", free: true),
        .init(title: "Share and agree right in your chat", free: true),
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
            unavailableSection
        case .some(let loaded):
            planPicker(planOptions(loaded))
                .disabled(purchasing)
        }
    }

    /// The no-products state. Two causes, two sentences: a thrown StoreKit
    /// error is the network's fault and worth retrying; an empty-but-successful
    /// answer is the store saying these products aren't purchasable from this
    /// account yet, which no amount of retrying fixes on the device.
    ///
    /// Saying "isn't reachable" for the second case is how "the Tween Pro page
    /// did not load properly" reached an App Review rejection (2026-08-31) —
    /// the page rendered fine and the store answered fine; the copy blamed the
    /// wrong thing and read as a broken screen.
    private var unavailableSection: some View {
        VStack(spacing: Tokens.Spacing.s3) {
            Text(loadFailure == .unreachable
                 ? "The App Store isn't reachable right now."
                 : "Pro plans aren't available from this App Store account yet.")
                .font(Tokens.Typography.subheadline)
                .foregroundStyle(Tokens.Palette.textSecondary)
                .multilineTextAlignment(.center)
            Button {
                reload()
            } label: {
                Label("Try Again", systemImage: "arrow.clockwise")
            }
            .buttonStyle(.tweenPrimary(.subtle))
        }
        .frame(maxWidth: .infinity)
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
                .foregroundStyle(messageIsFailure ? Tokens.Palette.destructive
                                                  : Tokens.Palette.textSecondary)
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

    /// Why the plan cards aren't on screen.
    private enum LoadFailure {
        /// `Product.products` threw: offline, or the App Store is down.
        case unreachable
        /// It succeeded and returned nothing — the shape of products that
        /// aren't purchasable for this account yet (an agreement not in
        /// effect, an IAP still in Missing Metadata, or one created minutes
        /// ago and not yet propagated).
        case unavailable
    }

    /// Backoff between product-load attempts. StoreKit's FIRST answer after a
    /// cold launch is routinely a throw or an empty set while the account and
    /// storefront resolve, so one attempt is not evidence of anything — and the
    /// old single-shot load turned that ordinary race into a screen that said
    /// the App Store was unreachable (App Review, iPad Air M3, 2026-08-31).
    private static let loadRetryDelays: [Duration] = [.seconds(1), .seconds(3)]

    /// Manual and foreground retry. Cancels any in-flight attempt so a
    /// double-tap can't race two loaders into the same state.
    @MainActor
    private func reload() {
        reloadTask?.cancel()
        products = nil
        loadFailure = nil
        reloadTask = Task { await loadProducts() }
    }

    @MainActor
    private func loadProducts() async {
        // Assume the quiet failure until StoreKit throws: an empty answer is
        // the more common of the two and the one worth naming precisely.
        var failure = LoadFailure.unavailable
        for attempt in 0...Self.loadRetryDelays.count {
            if attempt > 0 {
                // Sleep throws on cancellation — the sheet closed mid-wait, so
                // leave the state exactly as the user last saw it.
                do { try await Task.sleep(for: Self.loadRetryDelays[attempt - 1]) }
                catch { return }
            }
            do {
                let loaded = try await Product.products(for: ProEntitlement.productIDs)
                if !loaded.isEmpty {
                    show(loaded)
                    return
                }
                failure = .unavailable
            } catch {
                failure = .unreachable
            }
        }
        products = []
        loadFailure = failure
    }

    @MainActor
    private func show(_ loaded: [Product]) {
        // Lifetime first in display order regardless of store return order.
        // The predicate ignores its second argument, which is NOT a valid strict
        // weak ordering (it reports lifetime < lifetime). Harmless at two
        // elements, undefined at three — so compare both sides.
        let ordered = loaded.sorted { a, b in
            a.id == ProEntitlement.lifetimeProductID && b.id != ProEntitlement.lifetimeProductID
        }
        products = ordered
        loadFailure = nil
        // Clamp the selection to something that actually loaded. If the lifetime
        // product were ever unapproved in App Store Connect, selectedProductID
        // kept pointing at it: the monthly card rendered UNSELECTED and
        // continueButton's `if let` failed, so the sheet showed a price card and
        // then no buy button at all — no error, no explanation, and the only way
        // out was tapping a card that gave no sign it was tappable
        // (audit 2026-08-05).
        if !ordered.contains(where: { $0.id == selectedProductID }),
           let first = ordered.first {
            selectedProductID = first.id
        }
    }

    /// Re-reads the cached verdict after StoreKit has already settled it.
    /// Cheap enough to run on every cross-process post.
    @MainActor
    private func syncEntitlement() {
        let current = ProEntitlement.isUnlocked
        guard current != unlocked else { return }
        unlocked = current
        if current { errorMessage = nil }
    }

    @MainActor
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
                    if !unlocked {
                        // Verified and finished, but not yet in
                        // currentEntitlements. Saying nothing dropped the user
                        // back onto the plan cards as if the purchase hadn't
                        // happened. The MeetupSync observer above clears this
                        // the moment the entitlement lands.
                        messageIsFailure = false
                        errorMessage = "Purchase complete — Pro unlocks in a moment."
                    }
                case .unverified(let transaction, _):
                    // Charged, but StoreKit could not verify the signature.
                    // Finish it anyway — an unfinished transaction is
                    // re-delivered on EVERY launch forever — and say something.
                    // This used to fall through silently, leaving the user
                    // billed and staring at a sheet that did nothing
                    // (audit 2026-08-04).
                    await transaction.finish()
                    messageIsFailure = true
                    errorMessage = "That purchase couldn't be verified. If you were charged, tap Restore Purchases."
                }
            case .pending:
                // Ask-to-Buy etc. — the Transaction.updates listener started
                // at app launch unlocks whenever approval lands.
                messageIsFailure = false
                errorMessage = "Purchase pending approval — Pro unlocks automatically once it's approved."
            case .userCancelled:
                break
            @unknown default:
                break
            }
        } catch {
            messageIsFailure = true
            errorMessage = "The purchase didn't go through. Nothing was charged — try again."
        }
    }

    @MainActor
    private func restore() async {
        purchasing = true
        defer { purchasing = false }
        // Same first move as buy(). Without it the previous attempt's red text
        // outlives this one and ends up sitting under the "You have Tween Pro"
        // badge — the screen contradicting itself.
        errorMessage = nil
        try? await AppStore.sync()
        // StoreKit is the only source now that redeem codes are gone, so its
        // verdict IS the gate; the old `|| isUnlocked` existed to stop Restore
        // telling a code-redeemer their Pro had vanished and can no longer
        // contribute (audit 2026-08-06).
        let purchased = await ProEntitlement.refresh()
        unlocked = purchased
        if !unlocked {
            messageIsFailure = true
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
