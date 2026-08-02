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
    @State private var proUnlocked = ProEntitlement.isUnlocked

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
                    } else {
                        Button {
                            showPaywall = true
                        } label: {
                            HStack {
                                Label {
                                    VStack(alignment: .leading, spacing: 2) {
                                        Text("Tween Pro")
                                            .foregroundStyle(Tokens.Palette.textPrimary)
                                        Text("Plan-ahead meetups, transit fairness, reminders")
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
