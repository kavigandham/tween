import SwiftUI
import MapKit
import CoreLocation

// The vote board (split from ExpandedView.swift).
//
// This replaced the Agree / Others / I'm out row. That row made "I want to go
// somewhere else" and "yes, that one" share a single slot, so a disagreement
// overwrote the thing being disagreed with and the next tap agreed to whatever
// happened to be left standing. Here every pick stays on screen with its own
// vote count, which is both the fix and, it turns out, the feature people
// actually wanted: you can SEE that Hassan wants Hey Tea and Belal wants Kung
// Fu Tea.
extension ExpandedView {

    // MARK: Board

    var voteBoard: some View {
        VStack(spacing: Tokens.Spacing.s2) {
            ForEach(board.standings.prefix(Self.maxVisibleOptions), id: \.option.id) { entry in
                optionRow(entry.option, votes: entry.votes)
            }
            if board.options.count > Self.maxVisibleOptions {
                Text("+\(board.options.count - Self.maxVisibleOptions) more picks")
                    .font(Tokens.Typography.caption)
                    .foregroundStyle(Tokens.Palette.textSecondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
    }

    /// Cap on rows so the panel can't outgrow the map it floats over. One
    /// option per person means this only bites in a genuinely big group chat.
    static var maxVisibleOptions: Int { 4 }

    func optionRow(_ option: PollOption, votes: Int) -> some View {
        let isMine = myVote == option.id
        let isLeading = board.leader?.id == option.id
        return Button {
            guard !isMine else { return }
            sendTick += 1
            onVote(option)
        } label: {
            HStack(spacing: Tokens.Spacing.s3) {
                // Vote count as the leading element, the way a poll reads.
                Text("\(votes)")
                    .font(.system(size: 15, weight: .bold, design: .rounded))
                    .foregroundStyle(isLeading ? Tokens.Palette.onBrand : Tokens.Palette.textSecondary)
                    .frame(width: 30, height: 30)
                    .background(isLeading ? AnyShapeStyle(Tokens.Palette.brand)
                                          : AnyShapeStyle(Tokens.Palette.surfaceSecondary),
                                in: Circle())
                    .accessibilityHidden(true)

                VStack(alignment: .leading, spacing: 1) {
                    Text(option.name)
                        .font(Tokens.Typography.subheadline.weight(.semibold))
                        .foregroundStyle(Tokens.Palette.textPrimary)
                        .lineLimit(1)
                    Text(optionSubtitle(option))
                        .font(Tokens.Typography.caption)
                        .foregroundStyle(Tokens.Palette.textSecondary)
                        .lineLimit(1)
                }

                Spacer(minLength: 0)

                if isMine {
                    Label("Your vote", systemImage: "checkmark.circle.fill")
                        .labelStyle(.iconOnly)
                        .font(.system(size: 20, weight: .semibold))
                        .foregroundStyle(Tokens.Palette.success)
                } else {
                    Text("Vote")
                        .font(Tokens.Typography.captionBold)
                        .foregroundStyle(Tokens.Palette.accent)
                        .padding(.horizontal, Tokens.Spacing.s3)
                        .frame(minHeight: 30)
                        .background(Tokens.Palette.accent.opacity(0.14), in: Capsule())
                }
            }
            .padding(.horizontal, Tokens.Spacing.s3)
            .frame(maxWidth: .infinity, minHeight: Tokens.Layout.minTapTarget)
            .background(Tokens.Palette.elevated,
                        in: RoundedRectangle(cornerRadius: Tokens.Radius.group, style: .continuous))
        }
        .buttonStyle(.spotRow)
        .disabled(isSending || isMine)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(option.name), picked by \(proposerName(for: option)), \(votes) \(votes == 1 ? "vote" : "votes")")
        .accessibilityValue(isMine ? "Your vote" : "")
        .accessibilityHint(isMine ? "" : "Votes for \(option.name)")
        .accessibilityAddTraits(isMine ? [.isButton, .isSelected] : .isButton)
    }

    /// "Hassan's pick · 8 min for everyone" — who put it up, and its drive
    /// times when this device happens to have ranked it.
    func optionSubtitle(_ option: PollOption) -> String {
        let who = proposerName(for: option)
        let owner = who == "You" ? "Your pick" : "\(who)'s pick"
        guard let ranked = rankedSpots.first(where: { spot in
            guard let coordinate = spot.item?.placemark.coordinate else { return false }
            return abs(coordinate.latitude - option.latitude) < 1e-4
                && abs(coordinate.longitude - option.longitude) < 1e-4
        }) else { return owner }
        return "\(owner) · \(SpotETADisplay.compactLabel(for: ranked))"
    }

    // MARK: Headline

    /// "2 of 3 voted" / "Tied 1–1" — the one line that says where the vote is.
    var voteStatusLine: String {
        let progress = board.voteProgress(participants: pollParticipants)
        if board.isTie, progress.voted >= progress.total {
            return "It's a tie — someone has to break it"
        }
        if progress.voted >= progress.total, let leader = board.leader {
            return "\(leader.name) is winning — lock it in?"
        }
        let waiting = max(progress.total - progress.voted, 0)
        return waiting == 0
            ? "\(progress.voted) voted"
            : "\(progress.voted) of \(progress.total) voted"
    }

    // MARK: Actions

    /// The board's action row. Exactly one filled button, and it always names
    /// the place it acts on — never a bare "Confirm", which is how you end up
    /// tapping yes to something you weren't looking at.
    @ViewBuilder
    var voteActionRow: some View {
        let leader = board.leader
        let progress = board.voteProgress(participants: pollParticipants)
        // Loud once everyone has had their say (or when there's only one place
        // on the table, where locking in just means "yes, that one"); quiet
        // while the vote is young, so it reads as an escape hatch rather than
        // a prompt to end a vote nobody has joined.
        let settled = progress.voted >= progress.total || board.options.count == 1
        VStack(spacing: Tokens.Spacing.s2) {
            if let leader, !isSending {
                Button {
                    sendTick += 1
                    onLockIn(leader)
                } label: {
                    Label("Lock in \(leader.name)", systemImage: "checkmark.seal.fill")
                        .lineLimit(1)
                        .minimumScaleFactor(0.8)
                }
                .buttonStyle(.tweenPrimary(settled ? .prominent : .subtle))
                .accessibilityHint("Ends the vote and sets \(leader.name) as the meetup spot")
            } else if isSending {
                Button {} label: {
                    HStack(spacing: Tokens.Spacing.s2) {
                        ProgressView()
                        Text(statusMessage ?? "Sending...")
                            .lineLimit(1)
                    }
                }
                .buttonStyle(.tweenPrimary())
                .disabled(true)
            }

            // A spot the host app staged for us. It used to be a fourth button
            // labelled "Send <name> instead" — "instead" was the old model's
            // word for replacing the live proposal. It ADDS now, like every
            // other pick, but the hand-off path itself has to survive: it's
            // how "search properly in the app, then send" reaches the chat.
            if let draft {
                let didSend = recentlySentSpotName == draft.spotName
                Button {
                    guard !didSend else { return }
                    sendTick += 1
                    onSendDraft()
                } label: {
                    Label(didSend ? "Added \(draft.spotName)" : "Add \(draft.spotName)",
                          systemImage: didSend ? "checkmark.circle.fill" : "plus.circle.fill")
                        .lineLimit(1)
                        .minimumScaleFactor(0.8)
                }
                .buttonStyle(.tweenPrimary(.subtle))
                .disabled(isSending || didSend)
                .accessibilityHint("Puts your preloaded spot on the board")
            }

            HStack(spacing: 0) {
                tertiaryAction(title: isPickingAlternative ? "Hide places" : "Add your pick",
                               systemImage: isPickingAlternative ? "chevron.up" : "plus.circle",
                               tint: Tokens.Palette.accent) {
                    withAnimation(reduceMotion ? nil : .snappy(duration: 0.22)) {
                        isPickingAlternative.toggle()
                    }
                }
                .accessibilityHint("Shows fair places you can put on the board")
                Divider().frame(height: 18)
                tertiaryAction(title: "I'm out", systemImage: "location.slash",
                               tint: Tokens.Palette.destructive, action: onImOut)
                    .accessibilityHint("Stops sharing you as active for this meetup")
            }
        }
    }

    // MARK: En route

    /// "Belal · 12 min away" for everyone who has said they're leaving.
    /// Counts down from when they sent it, so a mark from ten minutes ago
    /// doesn't still claim twelve minutes out.
    @ViewBuilder
    var enRouteStrip: some View {
        if !enRouteMarks.isEmpty {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: Tokens.Spacing.s2) {
                    ForEach(enRouteMarks, id: \.participantID) { mark in
                        Label("\(mark.name) · \(mark.summary)", systemImage: "figure.walk.motion")
                            .font(Tokens.Typography.caption2Bold)
                            .foregroundStyle(Tokens.Palette.textPrimary)
                            .lineLimit(1)
                            .padding(.horizontal, Tokens.Spacing.s2)
                            .frame(minHeight: 26)
                            .background(Tokens.Palette.success.opacity(0.16), in: Capsule())
                            .accessibilityLabel("\(mark.name) is on the way, \(mark.summary)")
                    }
                }
                .padding(.horizontal, 1)
            }
        }
    }

    /// Whether the local user has already announced their departure, so the
    /// button can report rather than re-offer.
    var myEnRouteMark: EnRouteLog.Mark? {
        let me = localParticipantID ?? myName
        return enRouteMarks.first { $0.participantID == me }
    }
}
