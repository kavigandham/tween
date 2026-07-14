import SwiftUI

/// App settings. One preference today: which maps app "Open in Maps"
/// launches — Apple or Google — shared with the iMessage extension through
/// the App Group (`MapsPreference`), so every directions button in both
/// surfaces obeys the same choice.
struct SettingsSheet: View {
    @Environment(\.dismiss) private var dismiss
    @State private var mapsApp = MapsPreference.current

    var body: some View {
        NavigationStack {
            List {
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
                                        .foregroundStyle(Tokens.Palette.brand)
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
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
        }
        .presentationDetents([.medium, .large])
        .presentationDragIndicator(.visible)
    }
}

#Preview {
    SettingsSheet()
}
