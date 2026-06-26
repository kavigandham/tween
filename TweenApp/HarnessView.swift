#if DEBUG
import SwiftUI
import CoreLocation

/// A DEBUG-only screenshot harness for the Messages extension surfaces.
///
/// The extension's `CompactView` and `ExpandedView` live behind
/// `MSMessagesAppViewController`, which can't be hosted in a XCUITest target.
/// This view renders both inside the host app with seeded coordinates (SF + San
/// Jose) and a sample ranking, so a collaborator can launch the app with the
/// `-HARNESS` argument and screenshot-verify the extension UI on a real device.
///
/// Reached only from `ContentView` when `-HARNESS` is present, and the whole
/// file is excluded from release builds by the surrounding `#if DEBUG`.
struct HarnessView: View {
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: Tokens.Spacing.s5) {
                section("Compact View") {
                    CompactView(
                        received: DebugLaunchSeed.received,
                        isUserIn: false,
                        onImIn: {},
                        onExpand: {}
                    )
                    .frame(height: 120)
                    .background(Tokens.Palette.surface, in: RoundedRectangle(cornerRadius: Tokens.Radius.card))
                }

                section("Expanded View") {
                    ExpandedView(
                        received: DebugLaunchSeed.received,
                        selfCoord: DebugLaunchSeed.selfCoordinate,
                        rankedSpots: DebugLaunchSeed.rankedSpots,
                        isUserIn: true,
                        onImIn: {},
                        onSelectSpot: { _ in }
                    )
                    .frame(height: 520)
                    .background(Tokens.Palette.surface, in: RoundedRectangle(cornerRadius: Tokens.Radius.card))
                }

                section("Meetup Set View") {
                    ExpandedView(
                        received: DebugLaunchSeed.agreed,
                        selfCoord: DebugLaunchSeed.selfCoordinate,
                        rankedSpots: [],
                        isUserIn: true,
                        onImIn: {},
                        onImOut: {},
                        onSelectSpot: { _ in },
                        onOpenFullApp: {},
                        onOpenAppleMaps: { _ in },
                        onOpenGoogleMaps: { _ in }
                    )
                    .frame(height: 620)
                    .background(Tokens.Palette.surface, in: RoundedRectangle(cornerRadius: Tokens.Radius.card))
                }
            }
            .padding(Tokens.Spacing.s4)
        }
        .background(Tokens.Palette.surfaceSecondary)
    }

    /// A labeled card. The label text is what `TweenAppUITests` waits on.
    @ViewBuilder
    private func section(_ title: String, @ViewBuilder content: () -> some View) -> some View {
        VStack(alignment: .leading, spacing: Tokens.Spacing.s2) {
            Text(title)
                .font(Tokens.Typography.headline)
                .accessibilityAddTraits(.isHeader)
            content()
        }
    }
}

/// Hardcoded fixtures that drive the harness. Kept separate from the view so the
/// seed is easy to reuse and obviously test-only. DEBUG builds only.
enum DebugLaunchSeed {
    /// Downtown San Francisco — stands in for the friend's shared spot.
    static let friendCoordinate = CLLocationCoordinate2D(latitude: 37.7749, longitude: -122.4194)
    /// San Jose — stands in for our own shared location.
    static let selfCoordinate = CLLocationCoordinate2D(latitude: 37.3382, longitude: -121.8863)

    static let received = TweenState(
        text: "Blue Bottle Coffee",
        latitude: friendCoordinate.latitude,
        longitude: friendCoordinate.longitude
    )

    static let agreed = TweenState(
        text: "Shell",
        latitude: 33.8536,
        longitude: -79.4812,
        senderName: "You",
        kind: .place,
        senderCoordinate: selfCoordinate,
        action: .agree,
        messageType: .agree,
        participants: [
            Participant(id: "You", name: "You", coordinate: selfCoordinate),
            Participant(id: "Friend", name: "Friend", coordinate: friendCoordinate)
        ],
        agreedNames: ["Friend"]
    )

    static let rankedSpots: [RankedSpot] = [
        RankedSpot(etaFromA: 1_320, etaFromB: 1_380, confidence: 1.0),
        RankedSpot(etaFromA: 1_020, etaFromB: 1_740, confidence: 1.0),
        RankedSpot(etaFromA: 900, etaFromB: 2_100, confidence: 0.5)
    ]
}

#Preview {
    HarnessView()
}
#endif
