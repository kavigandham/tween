import SwiftUI

struct ContentView: View {
    var body: some View {
        OnboardingView()
            // Brand teal flows to every system control (segmented picker,
            // selection, ContentUnavailableView) that reads the tint.
            .tint(Tokens.Palette.brand)
    }
}

#Preview {
    ContentView()
}
