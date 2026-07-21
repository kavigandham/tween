import SwiftUI

struct ContentView: View {
    var body: some View {
        content
            // The product-wide navy tint keeps native controls aligned with
            // Tween's action hierarchy. Map pins keep their semantic colours.
            .tint(Tokens.Palette.accent)
    }

    @ViewBuilder
    private var content: some View {
        #if DEBUG
        // A UI-test entry point: `-HARNESS` renders the extension surfaces inside
        // the host app so the collaborator can screenshot-verify them without
        // booting the Messages extension. Never compiled into a release build.
        if CommandLine.arguments.contains("-HARNESS_HOST_RIDES")
            || CommandLine.arguments.contains("-HARNESS_HOST_FRIENDS")
            || CommandLine.arguments.contains("-HARNESS_HOST_RIDE_MAP") {
            OnboardingView()
        } else if CommandLine.arguments.contains("-HARNESS") {
            HarnessView(focus: HarnessFocus.current)
        } else {
            OnboardingView()
        }
        #else
        OnboardingView()
        #endif
    }
}

#Preview {
    ContentView()
}
