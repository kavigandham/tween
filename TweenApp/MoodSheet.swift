import SwiftUI

/// "What's the mood?" — the bottom sheet behind the ✨ chip on the search rail.
///
/// Deliberately NOT a chat. One screen, one decision: tap a vibe or say it in
/// your own words, then Find the vibe. Nothing here talks to MapKit — the
/// sheet's entire output is a `MoodIntent`, which the home screen feeds into
/// the same search/ranking pipeline a category chip uses.
///
/// Everything visual comes from `Tokens`: the suggestion chips are the exact
/// capsule the search rail draws (subheadline type, `s4` horizontal padding,
/// `minTapTarget` height, brand fill when selected), and the CTA is the house
/// `.tweenPrimary()` button. It should read as another Tween surface, not as
/// an AI feature bolted on.
struct MoodSheet: View {
    /// Pre-selects whatever mood is already on screen, so reopening the sheet
    /// shows where you are instead of a blank slate.
    var current: MoodIntent?
    /// Hands the resolved intent up. The HOST dismisses this sheet (it nils
    /// `activeSheet` as part of starting the search) — calling `dismiss()`
    /// here as well would mean two dismissals racing one presentation, the
    /// failure mode every `ActiveSheet` comment in `OnboardingView` is about.
    /// Cancel still dismisses itself: nothing else is running then.
    let onFind: (MoodIntent, _ wasFreeText: Bool) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var selected: MoodFamily?
    @State private var text = ""
    @FocusState private var fieldFocused: Bool
    /// Opens LARGE. At `.medium` the free-text field — half the feature —
    /// sits under the pinned CTA and has to be scrolled up to, which reads as
    /// "chips only" (sim-verified 2026-09-21). `.medium` stays available so
    /// the map is one drag away.
    @State private var detent: PresentationDetent = .large

    /// Free text wins when it's there; otherwise the tapped chip. Nil is the
    /// only state where the CTA is disabled (blank input, spec §16).
    private var resolvedIntent: MoodIntent? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmed.isEmpty { return MoodIntentResolver.resolve(trimmed) }
        return selected.map { MoodIntent.suggestion($0) }
    }

    private var isFreeText: Bool {
        !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: Tokens.Spacing.s5) {
                    header
                    suggestionGrid
                    field
                }
                .padding(.horizontal, Tokens.Spacing.s4)
                .padding(.top, Tokens.Spacing.s2)
                .padding(.bottom, Tokens.Spacing.s6)
            }
            .scrollDismissesKeyboard(.interactively)
            .safeAreaInset(edge: .bottom) { cta }
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Cancel") { dismiss() }
                }
            }
        }
        .presentationDetents([.medium, .large], selection: $detent)
        .presentationDragIndicator(.visible)
        .onAppear {
            // Reopening on an active mood shows it selected rather than blank.
            selected = current?.family
            MoodAnalytics.opened()
        }
    }

    // MARK: - Pieces

    private var header: some View {
        VStack(alignment: .leading, spacing: Tokens.Spacing.s1) {
            Text("What's the mood?")
                .font(Tokens.Typography.title)
                .foregroundStyle(Tokens.Palette.textPrimary)
            Text("Tell us what you're feeling. We'll find the spot.")
                .font(Tokens.Typography.subheadline)
                .foregroundStyle(Tokens.Palette.textSecondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .combine)
    }

    /// Eight vibes, wrapped. A `Grid` rather than a horizontal rail: these are
    /// the primary choice on this screen, and a rail would hide half of them
    /// off the right edge.
    private var suggestionGrid: some View {
        MoodChipLayout(spacing: Tokens.Spacing.s2) {
            ForEach(MoodFamily.suggestions, id: \.self) { family in
                Button { select(family) } label: {
                    Text("\(family.emoji) \(family.displayName)")
                        .font(Tokens.Typography.subheadline)
                        .padding(.horizontal, Tokens.Spacing.s4)
                        .frame(minHeight: Tokens.Layout.minTapTarget)
                        .background(
                            isSelected(family) ? AnyShapeStyle(Tokens.Palette.brand)
                                               : AnyShapeStyle(Tokens.Palette.surfaceSecondary),
                            in: Capsule())
                        .foregroundStyle(isSelected(family) ? Tokens.Palette.onBrand
                                                            : Tokens.Palette.textPrimary)
                }
                .buttonStyle(.plain)
                .accessibilityLabel(family.displayName)
                .accessibilityHint("Finds \(family.displayName.lowercased()) spots near your meetup area")
                .accessibilityAddTraits(isSelected(family) ? [.isButton, .isSelected] : .isButton)
            }
        }
        .sensoryFeedback(.selection, trigger: selected)
    }

    private var field: some View {
        VStack(alignment: .leading, spacing: Tokens.Spacing.s2) {
            TextField("What are we feeling?", text: $text, axis: .vertical)
                .font(Tokens.Typography.body)
                .lineLimit(1...3)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .submitLabel(.search)
                .focused($fieldFocused)
                .padding(.horizontal, Tokens.Spacing.s3)
                .padding(.vertical, Tokens.Spacing.s3)
                .frame(minHeight: Tokens.Layout.searchBarHeight)
                .background(Tokens.Palette.inputFill,
                            in: RoundedRectangle(cornerRadius: Tokens.Radius.action, style: .continuous))
                .onChange(of: text) { _, value in
                    // Typing supersedes a tapped chip — one intent, never two
                    // competing sources.
                    if !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                        selected = nil
                    }
                }
                .onSubmit(find)
                .accessibilityLabel("Describe the mood")

            Text("Try “something fun but not food” or “dessert but not ice cream”.")
                .font(Tokens.Typography.caption)
                .foregroundStyle(Tokens.Palette.textSecondary)
        }
    }

    private var cta: some View {
        Button(action: find) {
            Label("Find the vibe", systemImage: "arrow.right")
                .labelStyle(TrailingIconLabelStyle())
        }
        .buttonStyle(.tweenPrimary())
        .disabled(resolvedIntent == nil)
        .opacity(resolvedIntent == nil ? 0.5 : 1)
        .padding(.horizontal, Tokens.Spacing.s4)
        .padding(.vertical, Tokens.Spacing.s3)
        .background(.bar)
        .accessibilityHint("Searches for places that match the mood, between everyone")
    }

    // MARK: - Actions

    private func isSelected(_ family: MoodFamily) -> Bool {
        selected == family && !isFreeText
    }

    private func select(_ family: MoodFamily) {
        // A chip is a complete answer: clear any half-typed text so the two
        // can't disagree about what "Find the vibe" means.
        text = ""
        fieldFocused = false
        selected = family
        MoodAnalytics.suggestionSelected(family)
    }

    private func find() {
        guard let intent = resolvedIntent else { return }
        MoodAnalytics.querySubmitted(intent, freeText: isFreeText)
        onFind(intent, isFreeText)
    }
}

/// Icon AFTER the text — "Find the vibe →" reads as a destination, and
/// `Label`'s default puts the glyph in front.
private struct TrailingIconLabelStyle: LabelStyle {
    func makeBody(configuration: Configuration) -> some View {
        HStack(spacing: Tokens.Spacing.s2) {
            configuration.title
            configuration.icon
                .font(Tokens.Typography.footnote.weight(.semibold))
        }
    }
}

/// A wrapping chip row.
///
/// `LazyVGrid` can't do this: the vibes are different widths ("Late night" vs
/// "Something chill"), and a fixed column grid either clips the long ones or
/// leaves a gutter beside the short ones. This places each chip at its own
/// intrinsic width and wraps when the line is full — the same behaviour the
/// search rail gets for free from its horizontal `ScrollView`.
struct MoodChipLayout: Layout {
    var spacing: CGFloat

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let width = proposal.replacingUnspecifiedDimensions().width
        let rows = layout(subviews: subviews, width: width)
        let height = rows.last.map { $0.y + $0.height } ?? 0
        return CGSize(width: width, height: height)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize,
                       subviews: Subviews, cache: inout ()) {
        for row in layout(subviews: subviews, width: bounds.width) {
            for placement in row.items {
                subviews[placement.index].place(
                    at: CGPoint(x: bounds.minX + placement.x, y: bounds.minY + row.y),
                    anchor: .topLeading,
                    proposal: ProposedViewSize(placement.size))
            }
        }
    }

    private struct Row {
        var y: CGFloat
        var height: CGFloat
        var items: [(index: Int, x: CGFloat, size: CGSize)]
    }

    private func layout(subviews: Subviews, width: CGFloat) -> [Row] {
        var rows: [Row] = []
        var current = Row(y: 0, height: 0, items: [])
        var x: CGFloat = 0

        for index in subviews.indices {
            let size = subviews[index].sizeThatFits(.unspecified)
            if x > 0, x + size.width > width {
                rows.append(current)
                current = Row(y: current.y + current.height + spacing, height: 0, items: [])
                x = 0
            }
            current.items.append((index, x, size))
            current.height = max(current.height, size.height)
            x += size.width + spacing
        }
        if !current.items.isEmpty { rows.append(current) }
        return rows
    }
}

#Preview {
    Color.clear.sheet(isPresented: .constant(true)) {
        MoodSheet(current: nil) { _, _ in }
    }
}
