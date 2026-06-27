import SwiftUI

struct ContentView: View {
    var body: some View {
        content
            // Brand teal flows to every system control (segmented picker,
            // selection, ContentUnavailableView) that reads the tint.
            .tint(Tokens.Palette.brand)
    }

    @ViewBuilder
    private var content: some View {
        #if DEBUG
        // A UI-test entry point: `-HARNESS` renders the extension surfaces inside
        // the host app so the collaborator can screenshot-verify them without
        // booting the Messages extension. Never compiled into a release build.
        if CommandLine.arguments.contains("-HARNESS") {
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
