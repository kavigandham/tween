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

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: Tokens.Spacing.s6) {
                    header
                    featureList
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

    private var featureList: some View {
        VStack(alignment: .leading, spacing: Tokens.Spacing.s4) {
            featureRow(icon: "person.3.fill", title: "Groups & home bases",
                       detail: "Save where friends usually start from, then open a group for instant fair spots — no live locations needed.")
            featureRow(icon: "calendar.badge.clock", title: "Pick a day and time",
                       detail: "Fair spots ranked by predicted traffic for when you'll actually meet.")
            featureRow(icon: "tram.fill", title: "Any way you travel",
                       detail: "Fairness by driving, transit, or walking — even mixed per person.")
            featureRow(icon: "bell.badge.fill", title: "Leave-by reminders",
                       detail: "A nudge when it's time to head out, based on live drive time.")
            featureRow(icon: "calendar.badge.plus", title: "Calendar sync",
                       detail: "Drop the meetup — spot, time, and friends — into your calendar.")
        }
    }

    private func featureRow(icon: String, title: String, detail: String) -> some View {
        HStack(alignment: .top, spacing: Tokens.Spacing.s3) {
            Image(systemName: icon)
                .font(Tokens.Typography.title2)
                .foregroundStyle(Tokens.Palette.accent)
                .frame(width: 32)
            VStack(alignment: .leading, spacing: Tokens.Spacing.s1) {
                Text(title)
                    .font(Tokens.Typography.headline)
                Text(detail)
                    .font(Tokens.Typography.subheadline)
                    .foregroundStyle(Tokens.Palette.textSecondary)
            }
        }
    }

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
            VStack(spacing: Tokens.Spacing.s3) {
                // Lifetime leads — the recommended buy for a serverless app
                // with no recurring cost to justify a subscription.
                ForEach(loaded, id: \.id) { product in
                    productButton(product)
                }
                Text("One purchase unlocks Pro on every device signed into your App Store account. No account, no tracking — Tween stays serverless.")
                    .font(Tokens.Typography.caption)
                    .foregroundStyle(Tokens.Palette.textTertiary)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .disabled(purchasing)
        }
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

    /// LIVE. GitHub renders `docs/privacy.md` as a readable page at this URL
    /// with no setup — no GitHub Pages, no admin rights, no hosting to
    /// maintain. Apple accepts any publicly reachable URL, and this one is
    /// owned by the same account that owns the app.
    ///
    /// This deliberately does NOT point at a GitHub Pages URL: enabling Pages
    /// needs repo-admin, which the build tooling doesn't have, and a link that
    /// 404s in the purchase flow is a worse App Review outcome than no link.
    /// If Pages is turned on later, add Jekyll front matter to the Markdown and
    /// change this ONE constant.
    static let privacyURL = URL(string: "https://github.com/kavigandham/tween/blob/main/docs/privacy.md")!

    private func productButton(_ product: Product) -> some View {
        let isLifetime = product.id == ProEntitlement.lifetimeProductID
        return Button {
            Task { await buy(product) }
        } label: {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text(isLifetime ? "Lifetime" : "Monthly")
                        .font(Tokens.Typography.headline)
                    Text(isLifetime ? "Pay once, keep forever" : "Cancel anytime")
                        .font(Tokens.Typography.caption)
                        .opacity(0.8)
                }
                Spacer()
                Text(isLifetime ? product.displayPrice : "\(product.displayPrice)/mo")
                    .font(Tokens.Typography.headline)
            }
            .padding(.horizontal, Tokens.Spacing.s4)
            .frame(maxWidth: .infinity, minHeight: Tokens.Layout.primaryControlHeight)
            .background(
                isLifetime ? AnyShapeStyle(Tokens.Palette.brand) : AnyShapeStyle(Tokens.Palette.neutralAction),
                in: RoundedRectangle(cornerRadius: Tokens.Radius.card, style: .continuous))
            .foregroundStyle(isLifetime ? Tokens.Palette.onBrand : Tokens.Palette.accent)
        }
        .buttonStyle(.plain)
        .accessibilityLabel(isLifetime
                            ? "Tween Pro lifetime, \(product.displayPrice) once"
                            : "Tween Pro monthly, \(product.displayPrice) per month")
    }

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
        unlocked = await ProEntitlement.refresh()
        if !unlocked {
            errorMessage = "No previous purchase found for this App Store account."
        }
    }
}

#Preview {
    PaywallSheet()
}
