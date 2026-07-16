import SwiftUI
import UIKit
import MapKit
import CoreLocation

// Invitation banner + prompt surfaces (split from ExpandedView.swift).
extension ExpandedView {
    // MARK: Invitation

    var statusEyebrow: String {
        guard let received else {
            return isUserIn ? "You're in" : "Tween"
        }
        let isMine = received.isProposer(participantID: localParticipantID, name: myName)
        let name = isMine ? "You" : (received.senderName ?? "Your friend")
        switch received.messageType {
        case .invite: return "Invite"
        case .leave: return "\(name) left"
        case .propose: return isMine ? "You chose" : "\(name) chose"
        case .counter: return isMine ? "You suggested" : "\(name) suggests"
        case .agree where received.isFullyAgreed: return "Meetup set"
        case .agree: return "Agreement"
        }
    }

    var statusTitle: String {
        if let draft, received == nil {
            return "Ready to send \(draft.spotName)"
        }
        guard let received else {
            if isRanking { return "Finding fair spots" }
            if hasEnoughPeopleForSpots { return "Ready to pick a spot" }
            if isWaitingForCoordinates { return "Getting locations" }
            // "You're in" (your status) — the "waiting for someone else"
            // explanation lives once in the empty-state card, not repeated as
            // the headline too (device feedback).
            return isUserIn ? "You're in" : "Find a fair spot"
        }
        if received.kind == .place {
            return received.text
        }
        if let sender = received.senderName, !sender.isEmpty {
            return sender
        }
        return received.text
    }

    func groupProgress(for state: TweenState) -> String? {
        let count = state.participants.count
        switch state.messageType {
        case .invite where count >= 2:
            let notInYet = max(totalSeats - count, 0)
            return notInYet > 0 ? "\(count) ready now · \(notInYet) not in yet" : "\(count) ready"
        case .leave:
            return count > 0 ? "\(count) still ready" : "No one is in"
        case .agree where (!state.agreedNames.isEmpty || !state.agreedIDs.isEmpty) && !state.isFullyAgreed:
            let needed = max(count - 1, 1)
            let agreedCount = state.agreedIDs.isEmpty ? state.agreedNames.count : state.agreedIDs.count
            return "\(agreedCount) of \(needed) agreed"
        default:
            return nil
        }
    }


    func invitePromptView(state: TweenState) -> some View {
        // Map gets its own region above the panel (device feedback: the map
        // read as "cut off" behind the floating panel).
        mapSection
            .safeAreaInset(edge: .bottom, spacing: 0) {
            VStack(spacing: Tokens.Spacing.s4) {
                Capsule()
                    .fill(Tokens.Palette.textTertiary.opacity(0.35))
                    .frame(width: 42, height: 5)
                    .accessibilityHidden(true)

                VStack(spacing: Tokens.Spacing.s2) {
                    Image(systemName: "person.2.fill")
                        .font(Tokens.Typography.title2)
                        .foregroundStyle(Tokens.Palette.brand)
                        .frame(width: 48, height: 48)
                        .background(Tokens.Palette.brandLight, in: Circle())

                    Text("You've been invited")
                        .font(Tokens.Typography.callout)
                        .foregroundStyle(Tokens.Palette.textSecondary)

                    Text(state.senderName ?? "Your friend")
                        .font(Tokens.Typography.title.weight(.bold))
                        .foregroundStyle(Tokens.Palette.textPrimary)
                        .multilineTextAlignment(.center)
                        .lineLimit(2)
                        .minimumScaleFactor(0.78)

                    if let progress = groupProgress(for: state) {
                        Text(progress)
                            .font(Tokens.Typography.captionBold)
                            .foregroundStyle(Tokens.Palette.textSecondary)
                            .padding(.horizontal, Tokens.Spacing.s3)
                            .padding(.vertical, Tokens.Spacing.s1)
                            .background(.thinMaterial, in: Capsule())
                    }
                }

                Button(action: onImIn) {
                    if isSending {
                        HStack(spacing: Tokens.Spacing.s2) {
                            ProgressView()
                            Text(statusMessage ?? "Sharing...")
                        }
                        .frame(maxWidth: .infinity)
                    } else {
                        Label("I'm in", systemImage: "location.fill")
                            .frame(maxWidth: .infinity)
                    }
                }
                .buttonStyle(.tweenPrimary())
                .disabled(isSending)
                .accessibilityHint("Shares where you are for this meetup")

                Button(action: onOpenFullApp) {
                    Label("Browse spots", systemImage: "arrow.up.forward.app")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.tweenPrimary(.subtle))
                .accessibilityHint("Opens the full Tween app to search for places")
            }
            .padding(Tokens.Spacing.s4)
            .background(.regularMaterial, in: UnevenRoundedRectangle(
                topLeadingRadius: Tokens.Radius.sheet,
                bottomLeadingRadius: 0,
                bottomTrailingRadius: 0,
                topTrailingRadius: Tokens.Radius.sheet,
                style: .continuous
            ))
            .tweenElevation(.sheet)
        }
        .background(Color(.systemBackground))
    }

}
