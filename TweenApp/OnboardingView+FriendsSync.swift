import SwiftUI
import MapKit
import CoreLocation
import MessageUI
import Messages
import UIKit
import Combine
import os

// Friend roster sync helpers (split from OnboardingView.swift — structure plan R2).
extension OnboardingView {
    // MARK: - Friends

    /// Pings a friend with a Tween-styled "I'm in" iMessage bubble pre-filled
    /// in the composer (not a plain text). On iMessage the recipient sees the
    /// full rich bubble — same UX as if it had been composed from inside the
    /// Messages extension. SMS-only handles still see `Self.inviteText` as a
    /// plain-text fallback.
    ///
    /// Falls back to plain text if (a) we have no fresh self coord to put in
    /// the bubble, (b) MSMessage rendering fails, or (c) the device can't send
    /// text at all (no SIM / no iMessage).
    /// Inviting a friend is a first-compose path, so gate on a name too (audit
    /// F2 step 1) — the same one-time prompt `imIn`/`sendToChat` use — before we
    /// put the user on anyone's roster.
    func pingFriend(_ friend: TweenFriend) {
        ensureNamed { self.performPing(friend) }
    }

    func performPing(_ friend: TweenFriend) {
        pingTick += 1

        guard let handle = friend.handle, MFMessageComposeViewController.canSendText() else {
            UIPasteboard.general.string = Self.inviteText
            let reason = friend.handle == nil ? "No phone number" : "Messages unavailable"
            showToast("\(reason) - invite copied for \(friend.name)")
            return
        }

        // No FRESH self coord → fall back to the plain-text invite (audit W4:
        // a stale coordinate must not ride into the bubble). The invite still
        // works; your location shares once you're both in. Matches this
        // method's doc contract — "no fresh self coord → plain text".
        guard let myCoord = freshSelfCoordinateForSend else {
            activeSheet = .message(PendingMessage(
                recipients: [handle],
                body: Self.inviteText,
                onSent: {
                    PingLog.logPing(for: friend.id)
                    pingTick += 1
                    showToast("\(friend.name) is pending")
                }))
            return
        }

        let myName = UserProfile.displayName ?? UserName.fallback
        // The last host send path without a revision (audit W9) — without it
        // this bubble decodes under legacy trust-the-tap semantics forever.
        let revision = nextOutgoingRevisionForActiveConversation()
        let state = TweenState(
            text: "I'm in",
            latitude: myCoord.latitude,
            longitude: myCoord.longitude,
            senderName: UserProfile.displayName,
            senderID: TweenIdentity.stableID,
            kind: .participant,
            messageType: .invite,
            participants: [Participant(id: TweenIdentity.stableID, name: myName, coordinate: myCoord, needsRide: localNeedsRide)],
            revision: revision
        )

        // Render the bubble image off the main actor (it's an MKMapSnapshotter
        // round-trip — usually under a second, but we don't want to block).
        // Once ready, build the MSMessage on the main actor and present.
        Task { @MainActor in
            guard let message = await composeTweenMessage(for: state, totalSeats: 2) else { return }
            activeSheet = .message(PendingMessage(
                recipients: [handle],
                body: Self.inviteText,
                message: message,
                onSent: {
                    noteOutgoingRevision(revision)
                    PingLog.logPing(for: friend.id)
                    pingTick += 1
                    showToast("\(friend.name) is pending")
                }))
        }
    }

    func deleteFriend(_ friend: TweenFriend) {
        FriendRoster.delete(id: friend.id)
        friends = FriendRoster.load()
    }

    func startRename(_ friend: TweenFriend) {
        renameText = friend.name
        editorMode = .rename(friend)
    }

    func commitRename() {
        guard case let .rename(friend) = editorMode else { return }
        let trimmed = renameText.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmed.isEmpty {
            FriendRoster.rename(id: friend.id, to: trimmed)
            friends = FriendRoster.load()
        }
        editorMode = nil
    }

    /// Bridges optional `editorMode` to the boolean an `alert` needs.
    var renameBinding: Binding<Bool> {
        Binding(get: { editorMode != nil },
                set: { if !$0 { editorMode = nil } })
    }

    func showToast(_ message: String) {
        withAnimation(Tokens.Motion.snappy) { toast = message }
        Task { @MainActor in
            try? await Task.sleep(for: .seconds(2))
            withAnimation(Tokens.Motion.snappy) { toast = nil }
        }
    }

}
