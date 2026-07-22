import SwiftUI
import MapKit
import CoreLocation
import MessageUI
import Messages
import UIKit
import Combine
import os

// Friends panel + rides UI (split from OnboardingView.swift — structure plan R2).
extension OnboardingView {
    // MARK: - Friends panel

    @ViewBuilder
    var friendsPanel: some View {
        VStack(spacing: Tokens.Spacing.s3) {
            Picker("Friends section", selection: $friendsPanelTab) {
                ForEach(FriendsPanelTab.allCases) { tab in
                    Text(tab.title).tag(tab)
                }
            }
            .pickerStyle(.segmented)
            .padding(.horizontal)
            .frame(minHeight: Tokens.Layout.minTapTarget)
            .accessibilityHint("Switches between people and rides")

            Group {
                switch friendsPanelTab {
                case .people:
                    peoplePanel
                case .rides:
                    ridesPanel
                }
            }
            .frame(maxWidth: .infinity, alignment: .top)
        }
        // No cross-animation on tab switches — the People/Rides panels differ
        // wildly in height, so animating the swap stretched and snapped the
        // content. Apple Maps swaps segment content instantly.
    }

    /// One scrolling List for the entire People tab. The old layout stacked the
    /// header content above a nested List in a fixed VStack, so at the half
    /// detent the roster collapsed to zero height and clipped.
    var peoplePanel: some View {
        List {
            Group {
                nameFieldRow
                friendActionButtons
                meetupStatusSection
            }
            .listRowSeparator(.hidden)
            .listRowBackground(Color.clear)
            .listRowInsets(EdgeInsets(top: Tokens.Spacing.s1, leading: Tokens.Spacing.s4,
                                      bottom: Tokens.Spacing.s1, trailing: Tokens.Spacing.s4))

            if friends.isEmpty {
                ContentUnavailableView(
                    "No Saved Friends",
                    systemImage: "person.2",
                    description: Text("Add contacts here, or open a Tween iMessage to see the live meetup roster above."))
                    .listRowSeparator(.hidden)
                    .listRowBackground(Color.clear)
            } else {
                ForEach(friends) { friend in
                    FriendRow(friend: friend, pingTick: pingTick)
                        .contentShape(Rectangle())
                        .onTapGesture { pingFriend(friend) }
                        .accessibilityAddTraits(.isButton)
                        .accessibilityHint("Pings \(friend.name) to meet up")
                        .swipeActions(edge: .trailing) {
                            Button(role: .destructive) {
                                deleteFriend(friend)
                            } label: {
                                Label("Delete", systemImage: "trash")
                            }
                            Button { startRename(friend) } label: {
                                Label("Rename", systemImage: "pencil")
                            }
                            .tint(Tokens.Palette.pinSelf)
                        }
                }
            }
        }
        .listStyle(.plain)
    }

    /// The profile-name field as a form row — icon badge, caption label, and an
    /// opaque secondary surface — so it can't be mistaken for the place-search
    /// bar. Persists on submit or when focus leaves the field, not per keystroke
    /// (every write fans out through the App Group change publisher).
    var nameFieldRow: some View {
        HStack(spacing: Tokens.Spacing.s3) {
            Image(systemName: "person.text.rectangle")
                .font(Tokens.Typography.headline)
                .foregroundStyle(Tokens.Palette.accent)
                .frame(width: 36, height: 36)
                .background(Tokens.Palette.brandLight, in: RoundedRectangle(cornerRadius: Tokens.Radius.chip, style: .continuous))
            VStack(alignment: .leading, spacing: 2) {
                Text("Your name")
                    .font(Tokens.Typography.caption)
                    .foregroundStyle(Tokens.Palette.textSecondary)
                TextField("Add your name", text: $profileName)
                    .textFieldStyle(.plain)
                    .focused($nameFieldFocused)
                    .submitLabel(.done)
                    .onSubmit(saveProfileName)
                    .accessibilityLabel("Your name")
                    .accessibilityHint("Shown to friends when you invite them")
            }
        }
        .padding(Tokens.Spacing.s3)
        .background(Tokens.Palette.surfaceSecondary, in: RoundedRectangle(cornerRadius: Tokens.Radius.card, style: .continuous))
        .onChange(of: nameFieldFocused) { _, focused in
            if !focused { saveProfileName() }
        }
    }

    var friendActionButtons: some View {
        HStack(spacing: Tokens.Spacing.s2) {
            Button { activeSheet = .contacts } label: {
                Label("Add Friend", systemImage: "person.badge.plus")
            }
            .buttonStyle(.tweenPrimary())
            .accessibilityHint("Picks someone from your contacts")

            Button { activeSheet = .invite } label: {
                Label("Invite", systemImage: "square.and.arrow.up")
            }
            .buttonStyle(.tweenPrimary(.subtle))
            .accessibilityHint("Shares an invite link to Tween")
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    var meetupStatusSection: some View {
        VStack(alignment: .leading, spacing: Tokens.Spacing.s2) {
            HStack {
                Label("Current meetup", systemImage: "person.2.fill")
                    .font(Tokens.Typography.captionBold)
                    .foregroundStyle(Tokens.Palette.textSecondary)
                    .textCase(.uppercase)
                Spacer(minLength: 0)
                Text(pendingInvitesForDisplay.isEmpty
                     ? "\(activeParticipantsForDisplay.count) in"
                     : "\(activeParticipantsForDisplay.count) in · \(pendingInvitePersonCount) pending")
                    .font(Tokens.Typography.captionBold)
                    .foregroundStyle(Tokens.Palette.accent)
            }

            if activeParticipantsForDisplay.isEmpty, pendingInvitesForDisplay.isEmpty {
                Text("No one is in yet. People invited from Messages appear here as pending once you send the invite.")
                    .font(Tokens.Typography.footnote)
                    .foregroundStyle(Tokens.Palette.textSecondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(Tokens.Spacing.s3)
                    .background(Tokens.Palette.surfaceSecondary, in: RoundedRectangle(cornerRadius: Tokens.Radius.card, style: .continuous))
            } else {
                VStack(spacing: 0) {
                    ForEach(Array(activeParticipantsForDisplay.enumerated()), id: \.element.id) { index, participant in
                        participantStatusRow(participant)
                        if index < activeParticipantsForDisplay.count - 1 || !pendingInvitesForDisplay.isEmpty {
                            Divider().padding(.leading, 48)
                        }
                    }
                    ForEach(Array(pendingInvitesForDisplay.enumerated()), id: \.element.id) { index, invite in
                        pendingInviteStatusRow(invite)
                        if index < pendingInvitesForDisplay.count - 1 {
                            Divider().padding(.leading, 48)
                        }
                    }
                }
                .background(Tokens.Palette.surfaceSecondary, in: RoundedRectangle(cornerRadius: Tokens.Radius.card, style: .continuous))
            }
        }
    }

    /// Identity-based "is this the local user" test (audit F2 step 4). The old
    /// `participant.name == (displayName ?? "You")` string compare misclassified
    /// a REMOTE participant literally named "You" as the local user; matching on
    /// the stable ID (name fallback only for id-less legacy entries) fixes it.
    func isLocalParticipant(_ participant: Participant) -> Bool {
        participant.matches(LocalParticipantContext(
            id: TweenIdentity.stableID,
            name: UserProfile.displayName ?? UserName.fallback))
    }

    /// A participant row label: "You" for the local user, otherwise the peer's
    /// name sanitised so an unnamed sender reads "Friend", never "You".
    func participantLabel(_ participant: Participant) -> String {
        isLocalParticipant(participant) ? "You" : UserName.peerDisplayName(participant.name)
    }

    func participantStatusRow(_ participant: Participant) -> some View {
        let isLocal = isLocalParticipant(participant)
        return HStack(spacing: Tokens.Spacing.s3) {
            Image(systemName: participant.needsRide ? "figure.wave" : "checkmark.circle.fill")
                .font(Tokens.Typography.headline)
                .foregroundStyle(participant.needsRide ? Tokens.Palette.pinRideNeeded : Tokens.Palette.success)
                .frame(width: 36, height: 36)
                .background((participant.needsRide ? Tokens.Palette.pinRideNeeded : Tokens.Palette.success).opacity(0.14),
                            in: RoundedRectangle(cornerRadius: Tokens.Radius.chip, style: .continuous))

            VStack(alignment: .leading, spacing: 2) {
                Text(participantLabel(participant))
                    .font(Tokens.Typography.headline)
                    .foregroundStyle(Tokens.Palette.textPrimary)
                    .lineLimit(1)
                Text(participant.needsRide ? "Needs pickup" : "Can meet there")
                    .font(Tokens.Typography.caption)
                    .foregroundStyle(Tokens.Palette.textSecondary)
            }
            Spacer(minLength: 0)
            Text(isLocal ? "You" : "In")
                .font(Tokens.Typography.captionBold)
                .foregroundStyle(Tokens.Palette.textSecondary)
        }
        .padding(Tokens.Spacing.s3)
        .accessibilityElement(children: .combine)
    }

    func pendingInviteStatusRow(_ invite: PendingInviteRow) -> some View {
        HStack(spacing: Tokens.Spacing.s3) {
            Image(systemName: invite.isGeneric ? "paperplane.circle.fill" : "hourglass.circle.fill")
                .font(Tokens.Typography.headline)
                .foregroundStyle(Tokens.Palette.warning)
                .frame(width: 36, height: 36)
                .background(Tokens.Palette.warning.opacity(0.14),
                            in: RoundedRectangle(cornerRadius: Tokens.Radius.chip, style: .continuous))

            VStack(alignment: .leading, spacing: 2) {
                Text(invite.name)
                    .font(Tokens.Typography.headline)
                    .foregroundStyle(Tokens.Palette.textPrimary)
                    .lineLimit(1)
                Text(invite.isGeneric
                     ? "Sent from iMessage - waiting for them to tap I'm in"
                     : "Invite sent \(RelativeTime.string(from: invite.sentAt))")
                    .font(Tokens.Typography.caption)
                    .foregroundStyle(Tokens.Palette.textSecondary)
                    .lineLimit(1)
            }
            Spacer(minLength: 0)
            Text("Pending")
                .font(Tokens.Typography.captionBold)
                .foregroundStyle(Tokens.Palette.warning)
        }
        .padding(Tokens.Spacing.s3)
        .accessibilityElement(children: .combine)
    }

    var ridesPanel: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: Tokens.Spacing.s3) {
                rideRequestCard

                if activeParticipantsForDisplay.isEmpty {
                    ContentUnavailableView(
                        "No Meetup Yet",
                        systemImage: "car.2",
                        description: Text("Tap I'm in or open a Tween iMessage so ride planning has people to work with."))
                        .frame(maxWidth: .infinity, minHeight: 180)
                } else if pickupRiders.isEmpty {
                    ContentUnavailableView(
                        "No Pickup Requests",
                        systemImage: "checkmark.circle",
                        description: Text("Everyone in the meetup can get to the spot for now."))
                        .frame(maxWidth: .infinity, minHeight: 180)
                } else {
                    rideSection(title: "Needs pickup", participants: pickupRiders, emptyText: nil)
                    rideSection(title: "Can drive or meet there", participants: rideDrivers, emptyText: "No available drivers yet.")
                }
            }
            .padding(.horizontal)
            .padding(.bottom)
        }
    }

    var rideRequestCard: some View {
        VStack(alignment: .leading, spacing: Tokens.Spacing.s3) {
            HStack(alignment: .top, spacing: Tokens.Spacing.s3) {
                Image(systemName: localNeedsRide ? "figure.wave" : "car.fill")
                    .font(Tokens.Typography.headline)
                    .foregroundStyle(localNeedsRide ? Tokens.Palette.pinRideNeeded : Tokens.Palette.accent)
                    .frame(width: 40, height: 40)
                    .background((localNeedsRide ? Tokens.Palette.pinRideNeeded : Tokens.Palette.brand).opacity(0.14),
                                in: RoundedRectangle(cornerRadius: Tokens.Radius.chip, style: .continuous))
                VStack(alignment: .leading, spacing: Tokens.Spacing.s1) {
                    Text(localNeedsRide ? "You need a ride" : "Ride status")
                        .font(Tokens.Typography.headline)
                    Text(localNeedsRide ? "Your map pin is green so friends know to pick you up." : "Mark yourself if someone should pick you up before the meetup.")
                        .font(Tokens.Typography.caption)
                        .foregroundStyle(Tokens.Palette.textSecondary)
                }
                Spacer(minLength: 0)
            }

            Button {
                setNeedsRide(!localNeedsRide)
            } label: {
                Label(localNeedsRide ? "I don't need a ride" : "I need a ride",
                      systemImage: localNeedsRide ? "checkmark.circle" : "figure.wave")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(localNeedsRide ? .tweenPrimary(.subtle) : .tweenPrimary())
            .disabled(savedCoordinate == nil && !isUserIn)
            .accessibilityHint("Updates your meetup pin and ride status")
        }
        .padding(Tokens.Spacing.s3)
        .background(Tokens.Palette.surfaceSecondary, in: RoundedRectangle(cornerRadius: Tokens.Radius.card, style: .continuous))
    }

    func rideSection(title: String, participants: [Participant], emptyText: String?) -> some View {
        VStack(alignment: .leading, spacing: Tokens.Spacing.s2) {
            Text(title)
                .font(Tokens.Typography.captionBold)
                .foregroundStyle(Tokens.Palette.textSecondary)
                .textCase(.uppercase)

            if participants.isEmpty, let emptyText {
                Text(emptyText)
                    .font(Tokens.Typography.footnote)
                    .foregroundStyle(Tokens.Palette.textSecondary)
                    .padding(Tokens.Spacing.s3)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(Tokens.Palette.surfaceSecondary, in: RoundedRectangle(cornerRadius: Tokens.Radius.card, style: .continuous))
            } else {
                VStack(spacing: 0) {
                    ForEach(Array(participants.enumerated()), id: \.element.id) { index, participant in
                        rideParticipantRow(participant)
                        if index < participants.count - 1 {
                            Divider().padding(.leading, 48)
                        }
                    }
                }
                .background(Tokens.Palette.surfaceSecondary, in: RoundedRectangle(cornerRadius: Tokens.Radius.card, style: .continuous))
            }
        }
    }

    func rideParticipantRow(_ participant: Participant) -> some View {
        return HStack(spacing: Tokens.Spacing.s3) {
            Image(systemName: participant.needsRide ? "figure.wave" : "car.fill")
                .font(Tokens.Typography.headline)
                .foregroundStyle(participant.needsRide ? Tokens.Palette.pinRideNeeded : Tokens.Palette.accent)
                .frame(width: 36, height: 36)
                .background((participant.needsRide ? Tokens.Palette.pinRideNeeded : Tokens.Palette.brand).opacity(0.14),
                            in: RoundedRectangle(cornerRadius: Tokens.Radius.chip, style: .continuous))
            VStack(alignment: .leading, spacing: 2) {
                Text(participantLabel(participant))
                    .font(Tokens.Typography.headline)
                    .lineLimit(1)
                Text(rideSubtitle(for: participant))
                    .font(Tokens.Typography.caption)
                    .foregroundStyle(Tokens.Palette.textSecondary)
                    .lineLimit(1)
            }
            Spacer(minLength: 0)
        }
        .padding(Tokens.Spacing.s3)
        .accessibilityElement(children: .combine)
    }

    @ViewBuilder
    var toastView: some View {
        if let toast {
            Text(toast)
                .font(Tokens.Typography.footnote.weight(.medium))
                .foregroundStyle(.white)
                .padding(.horizontal, Tokens.Spacing.s4)
                .padding(.vertical, Tokens.Spacing.s3)
                // Toasts read as a dark scrim capsule in both color schemes.
                .background(.black.opacity(0.8), in: Capsule())
                .padding(.bottom, Tokens.Spacing.s4)
                .transition(.move(edge: .bottom).combined(with: .opacity))
                .accessibilityElement(children: .combine)
        }
    }

    /// Apple-Maps search row: the NATIVE search field (bridged UISearchBar —
    /// the component family Maps itself uses) plus the circular Friends
    /// button in their avatar slot. One persistent row, every detent.
    var searchBar: some View {
        HStack(spacing: Tokens.Spacing.s2) {
            NativeSearchBar(
                text: $searchText,
                isEditing: $searchFocused,
                placeholder: "Search for a spot...",
                onSubmit: commitSearch)
                .frame(minHeight: Tokens.Layout.searchBarHeight)
                .onChange(of: searchText) { _, query in
                    if query != selectedCategory?.searchQuery { selectedCategory = nil }
                    // A new query invalidates any pin/card from the old result set.
                    selectedResult = nil
                    handleQueryChange(query)
                }

            friendsButton
        }
        .padding(.leading, Tokens.Spacing.s2)
        .padding(.trailing)
        .onChange(of: searchFocused) { _, focused in
            // Focusing the field lifts the collapsed sheet so suggestions
            // have room — the begin-editing delegate replaces the old
            // tap-gesture + @FocusState pair.
            if focused { focusSearchPanel() }
        }
    }

    /// The Friends surface lives behind this circle (where Apple Maps puts
    /// the account avatar), not in a segmented tab — the tab swap reflowed
    /// the whole sheet and never matched the Maps feel.
    var friendsButton: some View {
        Button { activeSheet = .friends } label: {
            Group {
                if let name = UserName.load() {
                    Text(Self.initials(for: name))
                        .font(Tokens.Typography.captionBold)
                        .foregroundStyle(Tokens.Palette.onBrand)
                        // The circle scales with Dynamic Type (below), but at
                        // AX sizes the initials can still outgrow it — clamp
                        // rather than overflow the capsule row.
                        .lineLimit(1)
                        .minimumScaleFactor(0.7)
                } else {
                    Image(systemName: "person.2.fill")
                        .font(Tokens.Typography.footnote.weight(.semibold))
                        .foregroundStyle(Tokens.Palette.onBrand)
                }
            }
            // @ScaledMetric, not the fixed searchBarHeight: caption-relative
            // scaling keeps the circle wrapped around its initials at AX
            // text sizes instead of letting them spill out of a 44pt frame.
            .frame(width: friendsCircleSize, height: friendsCircleSize)
            .background(Tokens.Palette.brand, in: Circle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Friends")
        .accessibilityHint("Opens your friends, meetup roster, and rides")
    }

    static func initials(for name: String) -> String {
        let letters = name.split(separator: " ").prefix(2).compactMap(\.first)
        let result = String(letters).uppercased()
        return result.isEmpty ? "?" : result
    }

    var categoryChips: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: Tokens.Spacing.s2) {
                ForEach(CategoryPreset.allCases) { preset in
                    let selected = preset == selectedCategory
                    Button { selectCategory(preset) } label: {
                        Label(preset.title, systemImage: preset.icon)
                            .font(Tokens.Typography.subheadline)
                            .padding(.horizontal, Tokens.Spacing.s4)
                            .frame(minHeight: Tokens.Layout.minTapTarget)
                            .background(
                                selected ? AnyShapeStyle(Tokens.Palette.brand) : AnyShapeStyle(Tokens.Palette.surfaceSecondary),
                                in: Capsule()
                            )
                            .foregroundStyle(selected ? Tokens.Palette.onBrand : Tokens.Palette.textPrimary)
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel(preset.title)
                    .accessibilityHint("Searches for \(preset.searchQuery.lowercased()) near the midpoint")
                    .accessibilityAddTraits(selected ? [.isButton, .isSelected] : .isButton)
                }
            }
            .padding(.horizontal)
        }
        .sensoryFeedback(.selection, trigger: selectedCategory)
    }

    var resultsScroll: some View {
        ScrollView {
            // Lazy: result cards carry shadows and action rows — rendering
            // every card during an interactive sheet resize dropped frames
            // exactly when the search bar had text (device feedback: "you
            // can feel the stops"; the empty state has light content and
            // stayed smooth).
            LazyVStack(spacing: Tokens.Spacing.s3) {
                if searchState == .idle {
                    meetupSections
                    presenceControls
                    discoverySections
                } else if searchState == .results || isSearchLoading {
                    resultsList
                }
            }
            .padding(.horizontal)
            .padding(.bottom)
        }
        // Below the top detent a live scroll view negotiates scroll-vs-
        // resize on every drag frame, which reads as mid-gesture stops.
        // Scoped to the RESULTS state (the heavy content that stuttered) —
        // the idle discovery stack must stay scrollable at the half detent
        // or its lower rows become unreachable on smaller devices
        // (post-push audit at 42fdc68).
        .scrollDisabled(searchState == .results && selectedSheetDetent != .fraction(0.90))
    }

    /// The collapsed sheet is still useful after a meetup exists: its fixed
    /// header becomes a stable plan/suggestion row instead of leaving a card
    /// detached above the sheet. Search remains one tap away on the right.
    @ViewBuilder
    var collapsedMeetupHeader: some View {
        if isMinimalDetent, let proposal = pendingProposal {
            meetupPeek(
                eyebrow: "New suggestion",
                name: proposal.text,
                systemImage: "bubble.left.fill",
                action: {
                    withAnimation(Tokens.Motion.snappy) {
                        selectedSheetDetent = .fraction(0.45)
                    }
                })
        } else if isMinimalDetent, let meetup = agreedMeetup, meetup.kind == .place {
            meetupPeek(
                eyebrow: "Meeting at",
                name: meetup.text,
                systemImage: "checkmark.circle.fill",
                action: { presentAgreedMeetup(meetup) })
        } else {
            searchBar
        }
    }

    private func meetupPeek(
        eyebrow: String,
        name: String,
        systemImage: String,
        action: @escaping () -> Void
    ) -> some View {
        HStack(spacing: Tokens.Spacing.s2) {
            Button(action: action) {
                HStack(spacing: Tokens.Spacing.s3) {
                    Image(systemName: systemImage)
                        .font(Tokens.Typography.headline)
                        .foregroundStyle(Tokens.Palette.accent)
                        .frame(width: 38, height: 38)
                        .background(Tokens.Palette.neutralAction, in: Circle())
                    VStack(alignment: .leading, spacing: 1) {
                        Text(eyebrow)
                            .font(Tokens.Typography.captionBold)
                            .foregroundStyle(Tokens.Palette.textSecondary)
                            .textCase(.uppercase)
                        Text(name)
                            .font(Tokens.Typography.headline)
                            .foregroundStyle(Tokens.Palette.textPrimary)
                            .lineLimit(1)
                    }
                    Spacer(minLength: 0)
                    Image(systemName: "chevron.up")
                        .font(Tokens.Typography.captionBold)
                        .foregroundStyle(Tokens.Palette.textTertiary)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityHint(eyebrow == "New suggestion"
                               ? "Expands the suggestion controls"
                               : "Opens full place details")

            Divider().frame(height: 36)

            Button { expandThenFocusSearch() } label: {
                Image(systemName: "magnifyingglass")
                    .font(Tokens.Typography.headline)
                    .foregroundStyle(Tokens.Palette.textPrimary)
                    .frame(width: Tokens.Layout.minTapTarget,
                           height: Tokens.Layout.minTapTarget)
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Search for another spot")
        }
        .padding(.horizontal, Tokens.Spacing.s4)
    }

    /// Meetup state lives inside the scrollable sheet, not in a second
    /// floating layer over the map. The current plan remains distinct from a
    /// newer proposal so people can review both without losing the agreement.
    @ViewBuilder
    var meetupSections: some View {
        if let meetup = agreedMeetup, meetup.kind == .place {
            currentMeetupCard(for: meetup)
        }
        if let proposal = pendingProposal {
            proposalCard(for: proposal)
        }
    }

    func currentMeetupCard(for meetup: TweenState) -> some View {
        let selection = selection(for: meetup)
        return VStack(alignment: .leading, spacing: Tokens.Spacing.s2) {
            Text("Current meetup")
                .font(Tokens.Typography.captionBold)
                .foregroundStyle(Tokens.Palette.textSecondary)
                .textCase(.uppercase)
            spotCardInner(selection: selection, isAgreedMeetup: true)
        }
        .padding(Tokens.Spacing.s4)
        .background(Tokens.Palette.surfaceSecondary, in: RoundedRectangle(cornerRadius: Tokens.Radius.card, style: .continuous))
    }

    @ViewBuilder
    var presenceControls: some View {
        if isUserIn {
            Button(role: .destructive, action: leave) {
                Label("Leave", systemImage: "xmark.circle")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.tweenPrimary(.destructive))
            .accessibilityHint("Stops sharing your location")
        } else {
            Button(action: imIn) {
                if awaitingImIn || provider.status == .requesting {
                    HStack(spacing: Tokens.Spacing.s2) {
                        ProgressView()
                        Text("Finding you...")
                    }
                    .frame(maxWidth: .infinity)
                } else {
                    Label("I'm in", systemImage: "location.fill")
                        .symbolEffect(.bounce, value: isUserIn)
                }
            }
            .buttonStyle(.tweenPrimary())
            .disabled(awaitingImIn || provider.status == .requesting)
            .accessibilityHint("Shares where you are and finds fair places to meet")

            // Join with a place you're HEADING to instead of where you are now
            // (a plan for later while you're driving).
            Button { activeSheet = .whereIllBe } label: {
                Text("or share where you'll be")
                    .font(Tokens.Typography.footnote.weight(.medium))
                    .foregroundStyle(Tokens.Palette.accent)
            }
            .buttonStyle(.plain)
            .accessibilityHint("Join with an address you're heading to instead of your current location")
        }

        Text(statusText)
            .font(Tokens.Typography.footnote)
            .foregroundStyle(Tokens.Palette.textSecondary)
            .multilineTextAlignment(.center)

        if let peerDistanceText {
            Label(peerDistanceText, systemImage: "point.topleft.down.curvedto.point.bottomright.up")
                .font(Tokens.Typography.footnote.weight(.medium))
                .foregroundStyle(Tokens.Palette.textSecondary)
                .padding(.horizontal, Tokens.Spacing.s3)
                .padding(.vertical, Tokens.Spacing.s2)
                .background(Tokens.Palette.surfaceSecondary, in: Capsule())
                .accessibilityLabel(peerDistanceText)
        }

        // Solo "A→B, see what's in between": add any address or where a friend
        // is, and get the distance + fair spots between — no ping sent.
        ForEach(manualParticipants) { point in
            routePointChip(point)
        }
        Button { activeSheet = .addPoint } label: {
            Label(manualParticipants.isEmpty ? "Add a place or person" : "Add another point",
                  systemImage: "plus.circle.fill")
                .frame(maxWidth: .infinity)
        }
        .buttonStyle(.tweenPrimary(.subtle))
        .accessibilityHint("Add an address or where a friend is to see the distance and fair spots in between — nothing is sent")
    }

    /// A removable chip for one added A→B point, with its straight-line distance.
    func routePointChip(_ point: Participant) -> some View {
        HStack(spacing: Tokens.Spacing.s2) {
            Image(systemName: "mappin.circle.fill")
                .foregroundStyle(Tokens.Palette.accent)
            Text(point.name)
                .font(Tokens.Typography.footnote.weight(.medium))
                .foregroundStyle(Tokens.Palette.textPrimary)
                .lineLimit(1)
            if let distance = manualPointDistance(point) {
                Text(distance)
                    .font(Tokens.Typography.caption.monospacedDigit())
                    .foregroundStyle(Tokens.Palette.textSecondary)
            }
            Spacer(minLength: 0)
            Button { removeManualPoint(point) } label: {
                Image(systemName: "xmark.circle.fill")
                    .foregroundStyle(Tokens.Palette.textTertiary)
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Remove \(point.name)")
        }
        .padding(.horizontal, Tokens.Spacing.s3)
        .padding(.vertical, Tokens.Spacing.s2)
        .background(Tokens.Palette.surfaceSecondary, in: Capsule())
    }

    var discoverySections: some View {
        VStack(alignment: .leading, spacing: Tokens.Spacing.s4) {
            quickSpotSection(title: "Suggested Spot", shortcuts: [Self.suggestedSpot])
            storedSpotSection(
                title: "Favorites",
                spots: favoriteSpots,
                emptyText: "Save a place from its details to keep it here.",
                emptyIcon: "star")
            storedSpotSection(
                title: "Recent Spots",
                spots: recentSpots,
                emptyText: "Places you look at will appear here.",
                emptyIcon: "clock")
        }
        .padding(.top, Tokens.Spacing.s2)
    }

    func quickSpotSection(title: String, shortcuts: [QuickSpotShortcut]) -> some View {
        VStack(alignment: .leading, spacing: Tokens.Spacing.s2) {
            Text(title)
                .font(Tokens.Typography.captionBold)
                .foregroundStyle(Tokens.Palette.textSecondary)
                .textCase(.uppercase)
                .padding(.horizontal, Tokens.Spacing.s1)

            VStack(spacing: 0) {
                ForEach(Array(shortcuts.enumerated()), id: \.element.id) { index, shortcut in
                    Button {
                        startShortcutSearch(shortcut)
                    } label: {
                        HStack(spacing: Tokens.Spacing.s3) {
                            Image(systemName: shortcut.systemImage)
                                .font(Tokens.Typography.headline)
                                .foregroundStyle(Tokens.Palette.accent)
                                .frame(width: 36, height: 36)
                                .background(Tokens.Palette.brandLight, in: RoundedRectangle(cornerRadius: Tokens.Radius.chip, style: .continuous))

                            VStack(alignment: .leading, spacing: 2) {
                                Text(shortcut.title)
                                    .font(Tokens.Typography.headline)
                                    .foregroundStyle(Tokens.Palette.textPrimary)
                                    .lineLimit(1)
                                Text(shortcut.subtitle)
                                    .font(Tokens.Typography.caption)
                                    .foregroundStyle(Tokens.Palette.textSecondary)
                                    .lineLimit(1)
                            }

                            Spacer(minLength: 0)

                            Image(systemName: "chevron.right")
                                .font(Tokens.Typography.captionBold)
                                .foregroundStyle(Tokens.Palette.textTertiary)
                        }
                        .padding(Tokens.Spacing.s3)
                        .frame(maxWidth: .infinity)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .accessibilityHint("Searches for \(shortcut.query)")

                    if index < shortcuts.count - 1 {
                        Divider()
                            .padding(.leading, 60)
                    }
                }
            }
            .background(Tokens.Palette.surfaceSecondary, in: RoundedRectangle(cornerRadius: Tokens.Radius.card, style: .continuous))
        }
    }

    func storedSpotSection(
        title: String,
        spots: [StoredSpot],
        emptyText: String,
        emptyIcon: String
    ) -> some View {
        VStack(alignment: .leading, spacing: Tokens.Spacing.s2) {
            Text(title)
                .font(Tokens.Typography.captionBold)
                .foregroundStyle(Tokens.Palette.textSecondary)
                .textCase(.uppercase)
                .padding(.horizontal, Tokens.Spacing.s1)

            VStack(spacing: 0) {
                if spots.isEmpty {
                    HStack(spacing: Tokens.Spacing.s3) {
                        Image(systemName: emptyIcon)
                            .font(Tokens.Typography.headline)
                            .foregroundStyle(Tokens.Palette.textTertiary)
                            .frame(width: 36, height: 36)
                            .background(Tokens.Palette.neutralAction, in: RoundedRectangle(cornerRadius: Tokens.Radius.chip, style: .continuous))
                        Text(emptyText)
                            .font(Tokens.Typography.subheadline)
                            .foregroundStyle(Tokens.Palette.textSecondary)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .padding(Tokens.Spacing.s3)
                } else {
                    ForEach(Array(spots.prefix(5).enumerated()), id: \.element.id) { index, spot in
                        Button { presentStoredSpot(spot) } label: {
                            HStack(spacing: Tokens.Spacing.s3) {
                                Image(systemName: title == "Favorites" ? "star.fill" : "clock.fill")
                                    .font(Tokens.Typography.headline)
                                    .foregroundStyle(title == "Favorites" ? Tokens.Palette.warning : Tokens.Palette.accent)
                                    .frame(width: 36, height: 36)
                                    .background(Tokens.Palette.neutralAction, in: RoundedRectangle(cornerRadius: Tokens.Radius.chip, style: .continuous))

                                VStack(alignment: .leading, spacing: 2) {
                                    Text(spot.name)
                                        .font(Tokens.Typography.headline)
                                        .foregroundStyle(Tokens.Palette.textPrimary)
                                        .lineLimit(1)
                                    Text(spot.address.flatMap { $0.isEmpty ? nil : $0 } ?? "View place details")
                                        .font(Tokens.Typography.caption)
                                        .foregroundStyle(Tokens.Palette.textSecondary)
                                        .lineLimit(1)
                                }

                                Spacer(minLength: 0)
                                Image(systemName: "chevron.right")
                                    .font(Tokens.Typography.captionBold)
                                    .foregroundStyle(Tokens.Palette.textTertiary)
                            }
                            .padding(Tokens.Spacing.s3)
                            .frame(maxWidth: .infinity)
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .accessibilityHint("Opens details for \(spot.name)")

                        if index < min(spots.count, 5) - 1 {
                            Divider().padding(.leading, 60)
                        }
                    }
                }
            }
            .background(Tokens.Palette.surfaceSecondary, in: RoundedRectangle(cornerRadius: Tokens.Radius.card, style: .continuous))
        }
    }

    @ViewBuilder
    var resultsList: some View {
        if displayedItems.isEmpty, isSearchLoading {
            HStack(spacing: Tokens.Spacing.s2) {
                ProgressView()
                Text("Finding places near you...")
                    .font(Tokens.Typography.footnote)
                    .foregroundStyle(Tokens.Palette.textSecondary)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.vertical, Tokens.Spacing.s3)
        } else if displayedItems.isEmpty {
            ContentUnavailableView(
                "No Places Nearby",
                systemImage: "magnifyingglass",
                description: Text("Try a broader search like coffee, food, gas, or groceries."))
                .frame(maxWidth: .infinity, minHeight: 180)
        } else {
            ForEach(displayedItems, id: \.self) { item in
                ResultCard(
                    item: item,
                    rankedSpot: rankedMatch(for: item),
                    userCoord: savedCoordinate,
                    isBest: !rankedSpots.isEmpty && rankedSpots.first?.item == item,
                    bestWorstETA: rankedSpots.map(\.worstETA).min(),
                    onDirections: { openDirections(to: item) },
                    onSendToChat: {
                        sendToChat(SpotSelection(item: item, ranked: rankedMatch(for: item)))
                    })
                    .contentShape(Rectangle())
                    // Tapping the card body (outside its buttons) highlights the
                    // pin and focuses the map, matching a pin tap.
                    .onTapGesture { selectedResult = item }
            }
        }
    }

    /// The map items currently shown in the list — ranked when both coordinates
    /// are known, otherwise the raw search hits. Source of truth for map markers.
    /// Route-backed and estimated results share one complete ranking, so every
    /// row and its matching pin can show participant times. The raw-hit suffix
    /// remains a defensive fallback for any future partial ranking source.
    var displayedItems: [MKMapItem] {
        guard !rankedSpots.isEmpty else { return searchResults }
        let ranked = rankedSpots.compactMap(\.item)
        return ranked + searchResults.filter { !ranked.contains($0) }
    }

    func mapItem(for state: TweenState) -> MKMapItem {
        if let stored = SpotLibrary.matching(name: state.text, coordinate: state.coordinate) {
            return mapItem(for: stored)
        }
        let item = MKMapItem(placemark: MKPlacemark(coordinate: state.coordinate))
        item.name = state.text
        return item
    }

    func mapItem(for stored: StoredSpot) -> MKMapItem {
        let item = MKMapItem(placemark: MKPlacemark(coordinate: stored.coordinate))
        item.name = stored.name
        item.phoneNumber = stored.phoneNumber
        if let rawURL = stored.websiteURLString {
            item.url = URL(string: rawURL)
        }
        return item
    }

    func storedSpot(for selection: SpotSelection, at date: Date = Date()) -> StoredSpot {
        StoredSpot(
            name: selection.name,
            address: selection.address,
            latitude: selection.coordinate.latitude,
            longitude: selection.coordinate.longitude,
            phoneNumber: selection.item.phoneNumber,
            websiteURLString: selection.item.url?.absoluteString,
            lastUsedAt: date)
    }

    func selection(for stored: StoredSpot) -> SpotSelection {
        SpotSelection(
            item: mapItem(for: stored),
            ranked: nil,
            addressOverride: stored.address)
    }

    func selection(for state: TweenState, asIncomingProposal: Bool = false) -> SpotSelection {
        let stored = SpotLibrary.matching(name: state.text, coordinate: state.coordinate)
        let item = stored.map { mapItem(for: $0) } ?? mapItem(for: state)
        let incoming = asIncomingProposal
            ? IncomingProposalContext(
                senderName: state.senderName,
                senderID: state.senderID,
                participants: state.participants,
                agreedNames: state.agreedNames,
                agreedIDs: state.agreedIDs,
                isCounter: state.messageType == .counter)
            : nil
        return SpotSelection(
            item: item,
            ranked: nil,
            incoming: incoming,
            addressOverride: stored?.address)
    }

    /// The single entry point for a place detail presentation. Every opened
    /// place becomes a real Recent and retains enough metadata to reopen it.
    func presentSpot(_ selection: SpotSelection) {
        recentSpots = SpotLibrary.recordRecent(storedSpot(for: selection))
        focusMap(on: selection.item)
        activeSheet = .spot(selection)
    }

    func presentStoredSpot(_ stored: StoredSpot) {
        presentSpot(selection(for: stored))
    }

    func presentAgreedMeetup(_ meetup: TweenState) {
        presentSpot(selection(for: meetup))
    }

    func isFavorite(_ selection: SpotSelection) -> Bool {
        favoriteSpots.contains { $0.id == storedSpot(for: selection).id }
    }

    func isCurrentMeetup(_ selection: SpotSelection) -> Bool {
        guard let meetup = agreedMeetup, meetup.kind == .place else { return false }
        return meetup.text.compare(
            selection.name,
            options: [.caseInsensitive, .diacriticInsensitive]) == .orderedSame
            && abs(meetup.coordinate.latitude - selection.coordinate.latitude) < 0.0002
            && abs(meetup.coordinate.longitude - selection.coordinate.longitude) < 0.0002
    }

    func toggleFavorite(_ selection: SpotSelection) {
        let spot = storedSpot(for: selection)
        let wasFavorite = isFavorite(selection)
        favoriteSpots = SpotLibrary.toggleFavorite(spot)
        recentSpots = SpotLibrary.recordRecent(spot)
        showToast(wasFavorite ? "Removed from Favorites" : "Saved to Favorites")
    }

    /// The timing model for a visible place. Normally the completed ranking
    /// already contains every result; the on-demand estimate closes the small
    /// transient gap where a user can tap a pin before route-backed rankings
    /// finish. List rows and rich MapKit detail sheets both call this boundary,
    /// so neither can silently lose participant times.
    func rankedMatch(for item: MKMapItem) -> RankedSpot? {
        if let ranked = rankedSpots.first(where: { $0.item == item }) {
            return ranked
        }
        guard let participants = searchRankingParticipants else { return nil }
        return FairnessRanker.estimatedRankings(
            candidates: [item], participants: participants).first
    }

    /// Pin role for a result:
    /// gold = best fair option, green = closest to the current user, teal = other.
    func resultRole(for item: MKMapItem) -> TweenPin.Role {
        if rankedSpots.first?.item == item {
            return .fairSpot
        }
        guard let closest = closestDisplayedItemToUser else {
            return .result
        }
        return closest == item ? .closestToUser : .result
    }

    /// Glyph for result pins — the active category's icon when a preset drove the
    /// search, otherwise the role's semantic symbol.
    func resultSymbol(for item: MKMapItem) -> String {
        let role = resultRole(for: item)
        if role == .result {
            return selectedCategory?.icon ?? role.symbol
        }
        return role.symbol
    }

    var closestDisplayedItemToUser: MKMapItem? {
        guard let me = savedCoordinate else { return nil }
        let origin = CLLocation(latitude: me.latitude, longitude: me.longitude)
        return displayedItems.min { lhs, rhs in
            let lhsCoord = lhs.placemark.coordinate
            let rhsCoord = rhs.placemark.coordinate
            let lhsDistance = origin.distance(from: CLLocation(latitude: lhsCoord.latitude, longitude: lhsCoord.longitude))
            let rhsDistance = origin.distance(from: CLLocation(latitude: rhsCoord.latitude, longitude: rhsCoord.longitude))
            return lhsDistance < rhsDistance
        }
    }

    /// Which in-flight proposal deserves its own card given the agreement
    /// state. Owner decision (audit W8): a new suggestion does NOT cancel a
    /// set meetup — both render. The exclusions are load-bearing:
    /// `saveAgreed` also writes `proposedState = state`, so without the
    /// messageType + same-spot checks every agreement would double-render
    /// as its own "new suggestion".
    static func visiblePendingProposal(proposed: TweenState?, agreed: TweenState?) -> TweenState? {
        guard let proposed, proposed.kind == .place else { return nil }
        guard let agreed else { return proposed }
        guard proposed.messageType == .propose || proposed.messageType == .counter,
              !proposed.sameSpot(as: agreed)
        else { return nil }
        return proposed
    }

    /// The in-flight negotiation, rendered with the same vocabulary the
    /// extension uses: who proposed, agreement progress, and either an
    /// "Agree & reply" CTA or a waiting state — so switching from Messages to
    /// the app never loses the thread of the meetup.
    func proposalCard(for proposal: TweenState) -> some View {
        let myName = UserProfile.displayName ?? UserName.fallback
        let myID = TweenIdentity.stableID
        let needsMyAgreement = !proposal.isProposer(participantID: myID, name: myName)
            && !proposal.hasAgreed(participantID: myID, name: myName)
        let proposer = proposal.senderName ?? "Your friend"
        return VStack(alignment: .leading, spacing: Tokens.Spacing.s2) {
            VStack(alignment: .leading, spacing: Tokens.Spacing.s1) {
                // Over a standing agreement, the header must mark this as a
                // CHANGE ("new spot") so it can't be misread as the plan.
                Text(agreedMeetup != nil
                     ? "\(proposer) suggests a new spot"
                     : (proposal.messageType == .counter ? "\(proposer) suggests instead" : "\(proposer) suggests"))
                    .font(Tokens.Typography.captionBold)
                    .foregroundStyle(Tokens.Palette.textSecondary)
                    .textCase(.uppercase)
                Text(proposal.text)
                    .font(Tokens.Typography.headline)
                    .lineLimit(1)
                if !proposal.agreedNames.isEmpty || !proposal.agreedIDs.isEmpty {
                    Text(agreementProgress(for: proposal))
                        .font(Tokens.Typography.caption)
                        .foregroundStyle(Tokens.Palette.textSecondary)
                }
            }
            ABDistanceLabel(
                selfCoord: savedCoordinate,
                peerCoord: peerCoordinate,
                target: proposal.coordinate,
                ranked: nil)
            HStack(spacing: Tokens.Spacing.s2) {
                if needsMyAgreement {
                    Button { agreeToPendingProposal(proposal) } label: {
                        Label("Agree & reply", systemImage: "checkmark.circle.fill")
                    }
                    .buttonStyle(.tweenPrimary())
                    .accessibilityHint("Opens Messages with your agreement to \(proposal.text)")
                } else {
                    Label(waitingText(for: proposal), systemImage: "hourglass")
                        .font(Tokens.Typography.captionBold)
                        .foregroundStyle(Tokens.Palette.textSecondary)
                        .lineLimit(1)
                        .frame(maxWidth: .infinity, minHeight: Tokens.Layout.primaryControlHeight)
                        .background(Tokens.Palette.surfaceSecondary, in: Capsule())
                }
                Button { openDirections(to: mapItem(for: proposal)) } label: {
                    Label("Directions", systemImage: "arrow.triangle.turn.up.right.diamond.fill")
                }
                .buttonStyle(.tweenPrimary(.subtle))
            }
        }
        .padding(Tokens.Spacing.s4)
        .background(Tokens.Palette.surfaceSecondary, in: RoundedRectangle(cornerRadius: Tokens.Radius.card, style: .continuous))
    }

    func agreementProgress(for proposal: TweenState) -> String {
        let needed = max(proposal.participants.count - 1, 1)
        let have = proposal.agreedIDs.isEmpty ? proposal.agreedNames.count : proposal.agreedIDs.count
        return "\(have) of \(needed) agreed"
    }

    func waitingText(for proposal: TweenState) -> String {
        let myName = UserProfile.displayName ?? UserName.fallback
        let missing = proposal.missingAgreementNames(excluding: TweenIdentity.stableID, name: myName)
        return missing.isEmpty ? "Waiting for replies" : "Waiting for \(missing.joined(separator: ", "))"
    }

    func agreeToPendingProposal(_ proposal: TweenState) {
        let selection = selection(for: proposal)
        let incoming = IncomingProposalContext(
            senderName: proposal.senderName,
            senderID: proposal.senderID,
            participants: proposal.participants,
            agreedNames: proposal.agreedNames,
            agreedIDs: proposal.agreedIDs,
            isCounter: false)
        sendAgreeReply(for: selection, incoming: incoming)
    }

    /// The inner card — title, address, A/B (or solo) distance, and the action
    /// buttons — wrapped in a floating glass card for the agreed-meetup /
    /// proposal states (`compactCardContent`).
    func spotCardInner(selection: SpotSelection, isAgreedMeetup: Bool) -> some View {
        let item = selection.item
        let ranked = selection.ranked
        return VStack(alignment: .leading, spacing: Tokens.Spacing.s2) {
            HStack(alignment: .top, spacing: Tokens.Spacing.s2) {
                VStack(alignment: .leading, spacing: Tokens.Spacing.s1) {
                    Text(item.name ?? "Place")
                        .font(Tokens.Typography.headline)
                        .lineLimit(1)
                    if let address = selection.address, !address.isEmpty,
                       address != item.name {
                        Text(address)
                            .font(Tokens.Typography.caption)
                            .foregroundStyle(Tokens.Palette.textSecondary)
                            .lineLimit(1)
                    }
                }
                Spacer(minLength: 0)
                if !isAgreedMeetup {
                    Button {
                        selectedResult = nil
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                            .font(Tokens.Typography.title2)
                            .foregroundStyle(Tokens.Palette.textSecondary)
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("Deselect")
                }
            }
            ABDistanceLabel(
                selfCoord: savedCoordinate,
                peerCoord: peerCoordinate,
                target: item.placemark.coordinate,
                ranked: ranked)
            HStack(spacing: Tokens.Spacing.s2) {
                if isAgreedMeetup {
                    Button { presentSpot(selection) } label: {
                        Label("Details", systemImage: "info.circle.fill")
                    }
                    .buttonStyle(.tweenPrimary(.subtle))
                } else {
                    Button { sendToChat(selection) } label: {
                        Label("Send to chat", systemImage: "paperplane.fill")
                    }
                    .buttonStyle(.tweenPrimary())
                }
                Button { openDirections(to: item) } label: {
                    Label("Directions", systemImage: "arrow.triangle.turn.up.right.diamond.fill")
                }
                .buttonStyle(isAgreedMeetup ? .tweenPrimary() : .tweenPrimary(.subtle))
            }
        }
    }

    var statusText: String {
        if !monitor.isOnline {
            return "You're offline. Reconnect to find meetup spots."
        }
        switch provider.status {
        case .denied:
            return "Location access is off. Enable it in Settings to share where you are."
        case .failed:
            return "Couldn't get your location. Try again."
        default:
            break
        }
        if isUserIn {
            if peerCoordinate != nil {
                return "You're both in. Search for a fair spot between you."
            }
            return "You're in. Waiting for your friend to share their location…"
        }
        return "Tap “I'm in” to share where you are and find fair places to meet."
    }

    var activeParticipantsForDisplay: [Participant] {
        var participants = currentParticipants
        let myName = UserProfile.displayName ?? UserName.fallback
        let localContext = LocalParticipantContext(id: TweenIdentity.stableID, name: myName)
        if isUserIn, let coordinate = savedCoordinate, !participants.contains(where: { $0.matches(localContext) }) {
            participants.append(Participant(id: TweenIdentity.stableID, name: myName, coordinate: coordinate, needsRide: localNeedsRide))
        }
        // Legacy 2-person projection: only synthesise a peer when the roster
        // carries NO remote participant. The old `$0.name == peerDisplayName`
        // guard broke once F2 sanitised the display name — it compared "Friend"
        // against the raw ""/"You" roster entry, never matched, and double-listed
        // the peer (inflating "N in"). Identity-based, and never a display string
        // as an id.
        if let peerCoordinate, !participants.contains(where: { !isLocalParticipant($0) }) {
            participants.append(Participant(id: "peer", name: peerDisplayName, coordinate: peerCoordinate, needsRide: peerNeedsRide))
        }
        return participants.sorted { lhs, rhs in
            if isLocalParticipant(lhs) { return true }
            if isLocalParticipant(rhs) { return false }
            if lhs.needsRide != rhs.needsRide { return lhs.needsRide && !rhs.needsRide }
            return lhs.name.localizedCaseInsensitiveCompare(rhs.name) == .orderedAscending
        }
    }

    var pendingInvitesForDisplay: [PendingInviteRow] {
        let activeNames = Set(activeParticipantsForDisplay.map { $0.name.lowercased() })
        var rows = friends.compactMap { friend -> PendingInviteRow? in
            guard let sentAt = PingLog.lastPing(for: friend.id),
                  !activeNames.contains(friend.name.lowercased())
            else { return nil }
            return PendingInviteRow(
                id: friend.id.uuidString,
                name: friend.name,
                sentAt: sentAt,
                count: 1,
                isGeneric: false)
        }

        if let genericSentAt = lastGenericInviteAt,
           lastReplyAt.map({ genericSentAt > $0 }) ?? true {
            let pendingCount = PingLog.lastGenericInviteCount
            rows.append(PendingInviteRow(
                id: "generic-\(genericSentAt.timeIntervalSince1970)",
                name: pendingCount == 1 ? "Waiting for someone else" : "Waiting for \(pendingCount) people",
                sentAt: genericSentAt,
                count: pendingCount,
                isGeneric: true))
        }

        return rows.sorted { $0.sentAt > $1.sentAt }
    }

    var pendingInvitePersonCount: Int {
        pendingInvitesForDisplay.reduce(0) { $0 + $1.count }
    }

    var pickupRiders: [Participant] {
        activeParticipantsForDisplay.filter(\.needsRide)
    }

    var rideDrivers: [Participant] {
        activeParticipantsForDisplay.filter { !$0.needsRide }
    }

    func rideSubtitle(for participant: Participant) -> String {
        if participant.needsRide {
            if let driver = nearestDriver(to: participant) {
                let distance = ABDistanceLabel.formatDistance(from: participant.coordinate, to: driver.coordinate)
                return "Closest pickup: \(driver.name), \(distance) away"
            }
            return "Waiting for someone who can drive"
        }
        if pickupRiders.isEmpty {
            return "No pickup requests"
        }
        if let rider = nearestRider(for: participant) {
            let distance = ABDistanceLabel.formatDistance(from: participant.coordinate, to: rider.coordinate)
            return "Nearest pickup: \(rider.name), \(distance) away"
        }
        return "Available for pickup"
    }

    func nearestDriver(to rider: Participant) -> Participant? {
        rideDrivers.min { lhs, rhs in
            distance(from: lhs.coordinate, to: rider.coordinate) < distance(from: rhs.coordinate, to: rider.coordinate)
        }
    }

    func nearestRider(for driver: Participant) -> Participant? {
        pickupRiders.min { lhs, rhs in
            distance(from: lhs.coordinate, to: driver.coordinate) < distance(from: rhs.coordinate, to: driver.coordinate)
        }
    }

    func distance(from a: CLLocationCoordinate2D, to b: CLLocationCoordinate2D) -> CLLocationDistance {
        CLLocation(latitude: a.latitude, longitude: a.longitude)
            .distance(from: CLLocation(latitude: b.latitude, longitude: b.longitude))
    }

    var peerDistanceText: String? {
        guard let savedCoordinate, let peerCoordinate else { return nil }
        let distance = ABDistanceLabel.formatDistance(from: savedCoordinate, to: peerCoordinate)
        return "Distance between you: \(distance)"
    }

}
