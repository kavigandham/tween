import SwiftUI

/// App settings. One preference today: which maps app "Open in Maps"
/// launches — Apple or Google — shared with the iMessage extension through
/// the App Group (`MapsPreference`), so every directions button in both
/// surfaces obeys the same choice.
struct SettingsSheet: View {
    @Environment(\.dismiss) private var dismiss
    @State private var mapsApp = MapsPreference.current
    /// Child sheet, NOT a swap of this one — swapping `.sheet(item:)` from
    /// inside the presented sheet leaves dead buttons (2026-07 lesson).
    @State private var showPaywall = false
    /// The guide is reachable here as well as on first run: the people who ask
    /// "how do you use it?" are exactly the ones who dismissed it at launch and
    /// had no way back (product decision 2026-08-02).
    @State private var showGuide = false
    @State private var proUnlocked = ProEntitlement.isUnlocked
    @State private var maxDriveMinutes = DriveTimePreference.maxMinutes

    /// Preset capsules rather than a slider or stepper: this is a coarse
    /// choice, and Maps uses exactly this control for its own coarse filters
    /// (Open Now / Drive-Thru). One tap, readable at a glance.
    private var driveTimeChips: some View {
        HStack(spacing: Tokens.Spacing.s2) {
            ForEach(DriveTimePreference.options, id: \.self) { minutes in
                driveTimeChip(label: "\(minutes)m", value: minutes)
            }
            driveTimeChip(label: "Any", value: nil)
        }
        .padding(.vertical, Tokens.Spacing.s1)
    }

    private func driveTimeChip(label: String, value: Int?) -> some View {
        let isSelected = maxDriveMinutes == value
        return Button {
            maxDriveMinutes = value
            DriveTimePreference.maxMinutes = value
        } label: {
            Text(label)
                .font(Tokens.Typography.subheadline.weight(.semibold))
                .foregroundStyle(isSelected ? Tokens.Palette.onBrand : Tokens.Palette.accent)
                .lineLimit(1)
                .frame(maxWidth: .infinity, minHeight: Tokens.Layout.minTapTarget)
                .background(isSelected ? AnyShapeStyle(Tokens.Palette.brand)
                                       : AnyShapeStyle(Tokens.Palette.neutralAction),
                            in: Capsule())
                .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(value.map { "Maximum \($0) minutes" } ?? "No maximum drive time")
        .accessibilityAddTraits(isSelected ? [.isButton, .isSelected] : .isButton)
    }

    var body: some View {
        NavigationStack {
            List {
                Section {
                    if proUnlocked {
                        Label {
                            Text("Tween Pro — unlocked")
                                .foregroundStyle(Tokens.Palette.textPrimary)
                        } icon: {
                            Image(systemName: "checkmark.seal.fill")
                                .foregroundStyle(Tokens.Palette.success)
                        }
                    }
                    // ALWAYS present, unlocked or not. The paywall holds the
                    // app's only Restore Purchases button and its only Terms
                    // and Privacy links, and every route to it used to be
                    // gated on NOT being unlocked — so unlocking Pro removed
                    // them permanently (audit 2026-08-04). Still required with
                    // the redeem field gone: an Apple Offer Code unlocks Pro
                    // outside the app entirely, so those users arrive already
                    // unlocked and would otherwise never see Restore or the
                    // legal links.
                    Button {
                        showPaywall = true
                    } label: {
                            HStack {
                                Label {
                                    VStack(alignment: .leading, spacing: 2) {
                                        Text(proUnlocked ? "Manage Tween Pro" : "Tween Pro")
                                            .foregroundStyle(Tokens.Palette.textPrimary)
                                        Text(proUnlocked
                                             ? "Restore purchases, Terms, Privacy Policy"
                                             : "Plan-ahead meetups, transit fairness, reminders")
                                            .font(Tokens.Typography.caption)
                                            .foregroundStyle(Tokens.Palette.textSecondary)
                                    }
                                } icon: {
                                    Image(systemName: "sparkles")
                                        .foregroundStyle(Tokens.Palette.brand)
                                }
                                Spacer()
                                Image(systemName: "chevron.right")
                                    .font(Tokens.Typography.caption)
                                    .foregroundStyle(Tokens.Palette.textTertiary)
                            }
                    }
                }
                Section {
                    ForEach(PreferredMapsApp.allCases) { app in
                        Button {
                            mapsApp = app
                            MapsPreference.current = app
                        } label: {
                            HStack {
                                Label(app.title, systemImage: app.icon)
                                    .foregroundStyle(Tokens.Palette.textPrimary)
                                Spacer()
                                if mapsApp == app {
                                    Image(systemName: "checkmark")
                                        .fontWeight(.semibold)
                                        .foregroundStyle(Tokens.Palette.accent)
                                }
                            }
                        }
                        .accessibilityAddTraits(mapsApp == app ? .isSelected : [])
                    }
                } header: {
                    Text("Directions open in")
                } footer: {
                    Text("Every Open in Maps button — in Tween and in iMessage — uses this app. Google Maps opens on the web if the app isn't installed.")
                }

                Section {
                    // Child sheet, NOT a swap of this one (2026-07 lesson).
                    Button {
                        showGuide = true
                    } label: {
                        HStack {
                            Label {
                                Text("How to use Tween")
                                    .foregroundStyle(Tokens.Palette.textPrimary)
                            } icon: {
                                Image(systemName: "questionmark.circle.fill")
                                    .foregroundStyle(Tokens.Palette.brand)
                            }
                            Spacer()
                            Image(systemName: "chevron.right")
                                .font(Tokens.Typography.caption)
                                .foregroundStyle(Tokens.Palette.textTertiary)
                        }
                    }
                } footer: {
                    Text("The five-step guide, including where to find Tween inside Messages.")
                }

                Section {
                    driveTimeChips
                } header: {
                    Text("Max drive time")
                } footer: {
                    Text("Spots that ask someone to drive longer than this still show up — they just rank lower, so you always see something even when the area is quiet.")
                }
            }
            .navigationTitle("Settings")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Close") { dismiss() }
                }
            }
        }
        .presentationDetents([.medium, .large])
        .presentationDragIndicator(.visible)
        .sheet(isPresented: $showPaywall) {
            PaywallSheet()
        }
        .sheet(isPresented: $showGuide) {
            OnboardingTutorialView { showGuide = false }
        }
        .onChange(of: showPaywall) { _, presented in
            if !presented { proUnlocked = ProEntitlement.isUnlocked }
        }
        #if DEBUG
        // -DEMO_PAYWALL (with -DEMO_SETTINGS): opens the paywall once the
        // settings sheet has settled — screenshot hook for the Pro flow.
        .task {
            guard CommandLine.arguments.contains("-DEMO_PAYWALL") else { return }
            try? await Task.sleep(nanoseconds: 700_000_000)
            showPaywall = true
        }
        #endif
    }
}

#Preview {
    SettingsSheet()
}
