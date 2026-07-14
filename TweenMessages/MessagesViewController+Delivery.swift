import UIKit
import SwiftUI
import Messages
import MapKit
import CoreLocation
import os

// Bubble delivery + canonical store commits + maps opening (split from
// MessagesViewController.swift).
extension MessagesViewController {

    /// Encodes the state into a bubble, renders its image, and sends/stages it
    /// in the conversation. Staying on the same `MSSession` keeps the thread
    /// collapsed to a single evolving bubble rather than a stack of new ones.
    @discardableResult
    func sendBubbleNow(for state: TweenState) async -> Bool {
        await deliverBubble(for: state)
    }

    @discardableResult
    func deliverBubble(for state: TweenState) async -> Bool {
        guard let conversation = activeConversation else { return false }
        // Key every canonical write below to the conversation this bubble is
        // being sent in, captured NOW — NOT the `conversationKey` ivar, which a
        // mid-send conversation switch (willBecomeActive repoints it) would land
        // this send's roster/revision/tombstones under the wrong chat.
        let deliveryKey = Self.conversationKey(for: conversation)
        // Departure gossip: every outgoing payload carries the tombstones this
        // device holds, so ANY later bubble tap propagates removals — without
        // it, a leave only ever reached whoever tapped the leave bubble itself.
        var outgoing = state
        outgoing.departed = RosterMerge.gossipKeys(
            departed: ConversationMeetupStore.departedParticipants(key: deliveryKey),
            roster: state.participants)
        guard let url = outgoing.encodedURL() else { return false }

        let localName = UserProfile.displayName
        let image = await BubbleImageRenderer.makeImage(
            state: state,
            participants: state.participants,
            localID: localParticipantID(),
            localName: localName)
        guard !Task.isCancelled else { return false }

        let layout = MSMessageTemplateLayout()
        layout.image = image
        BubbleCaption.apply(to: layout, state: state, totalSeats: self.totalConversationParticipants)

        let session = conversation.selectedMessage?.session ?? lastKnownSession ?? MSSession()
        let message = MSMessage(session: session)
        message.url = url
        message.layout = layout

        guard !Task.isCancelled else { return false }
        do {
            var stagedInsert = false
            do {
                try await conversation.send(message)
                logger.debug("Sent outgoing Tween bubble kind=\(state.kind.rawValue, privacy: .public)")
            } catch {
                // Messages gates direct send on a recent user tap + a visible
                // extension (one send per detected interaction, WWDC17 Direct
                // Send API). Our sends run seconds after the tap (location
                // fix, snapshot render), so a rejection here is expected —
                // stage the bubble in the input field instead so delivery
                // never dead-ends. If insert also throws, the outer catch
                // reports the failure as before.
                logger.error("Direct send rejected; staging via insert: \(String(describing: error), privacy: .public)")
                try await conversation.insert(message)
                sendStatusMessage = Self.stagedDeliveryStatus
                stagedInsert = true
            }
            // A staged LEAVE or AGREE hasn't happened yet — the user can
            // still delete the bubble instead of sending it. Defer the
            // revision floor and the canonical snapshot to didStartSending
            // (the marker is the backstop for the extension dying in
            // between — see commitStagedSendIfNeeded) so local state never
            // records a departure or agreement no peer will ever see. Keyed
            // off the conversation parameter, not the ivar, so a nil
            // conversationKey can't silently skip the marker.
            if stagedInsert, state.messageType == .leave || state.messageType == .agree {
                ConversationMeetupStore.setPendingStagedSend(
                    state.messageType, key: deliveryKey)
                return true
            }
            // Any real (non-staged) delivery supersedes a previously staged
            // leave/agree the user abandoned. Without this, an orphaned
            // marker survived e.g. a rejoin at a TIED revision (staging
            // defers the floor bump, so the next mint reuses the number) and
            // a later tap of the old own bubble replayed the stale intent
            // past every guard (audit at b902d4d).
            ConversationMeetupStore.setPendingStagedSend(
                nil, key: deliveryKey)
            // Delivery succeeded — NOW the minted revision becomes the floor
            // for the decode guard (this device's own stale bubbles included).
            if let revision = state.revision {
                ConversationMeetupStore.noteRevision(
                    revision, sender: localParticipantID(), key: deliveryKey)
            }
            recordCanonicalSnapshot(for: state, key: deliveryKey)
            recordPendingInviteIfNeeded(for: state)
            return true
        } catch {
            logger.error("Failed to deliver outgoing Tween bubble: \(String(describing: error), privacy: .public)")
            sendStatusMessage = "Couldn't send the Tween message. Try again."
            return false
        }
    }

    func recordCanonicalSnapshot(for state: TweenState, key conversationKey: String) {
        switch state.messageType {
        case .invite:
            ConversationMeetupStore.saveParticipants(state.participants, key: conversationKey)
        case .propose, .counter:
            ConversationMeetupStore.saveProposed(state, key: conversationKey)
            ConversationMeetupStore.clearDraft(key: conversationKey)
        case .agree:
            if state.isFullyAgreed {
                ConversationMeetupStore.saveAgreed(state, key: conversationKey)
            } else {
                ConversationMeetupStore.saveProposed(state, key: conversationKey)
            }
        case .leave:
            // Keep the remaining roster — the meetup stays live for everyone
            // else, and a later rejoin must broadcast the full group, not
            // [me]. This device renders as "out" via membership + tombstone.
            ConversationMeetupStore.saveParticipants(state.participants, key: conversationKey)
            if state.participants.isEmpty {
                ConversationMeetupStore.clearProposalState(key: conversationKey)
            }
        }
    }

    func recordPendingInviteIfNeeded(for state: TweenState) {
        switch state.messageType {
        case .invite, .propose, .counter:
            let pendingCount = max(totalConversationParticipants - state.participants.count, 0)
            guard pendingCount > 0 else { return }
            PingLog.logGenericInvite(count: pendingCount)
        case .agree, .leave:
            return
        }
    }

    /// Requests a single fix and polls the provider for up to ~5s for a result.
    ///
    /// First run only: while the When-In-Use permission alert is on screen
    /// (authorization still .notDetermined), the 5s budget isn't burning —
    /// wait out the alert (up to ~30s) BEFORE starting the fix window, so the
    /// very first "I'm in" doesn't fail just because the user took a moment
    /// to read the prompt. Already-authorized (or denied) users skip this
    /// instantly and get exactly the original behavior.
    func acquireLocation() async -> CLLocationCoordinate2D? {
        locationProvider.requestOnce()
        var alertTicks = 0
        while locationProvider.authorizationStatus == .notDetermined, alertTicks < 300 {
            if Task.isCancelled { return nil }
            try? await Task.sleep(for: .milliseconds(100))
            alertTicks += 1
        }
        for _ in 0..<50 {
            if Task.isCancelled { return nil }
            switch locationProvider.status {
            case .got(let coordinate):
                return coordinate
            case .denied, .failed:
                return nil
            default:
                try? await Task.sleep(for: .milliseconds(100))
            }
        }
        return nil
    }

    func openFullAppSearch() {
        guard let url = URL(string: "tween://search") else { return }
        extensionContext?.open(url, completionHandler: nil)
    }

    /// The single "Open in Maps" button — resolves the user's preference
    /// (host app Settings → Apple/Google, App Group-shared) at tap time.
    func openInPreferredMaps(for state: TweenState) {
        switch MapsPreference.current {
        case .apple:  openAppleMaps(for: state)
        case .google: openGoogleMaps(for: state)
        }
    }

    func openAppleMaps(for state: TweenState) {
        let item = MKMapItem(placemark: MKPlacemark(coordinate: state.coordinate))
        item.name = state.text
        item.openInMaps(launchOptions: [
            MKLaunchOptionsDirectionsModeKey: MKLaunchOptionsDirectionsModeDriving
        ])
    }

    func openGoogleMaps(for state: TweenState) {
        // iMessage extensions may not open URLs to other apps —
        // extensionContext.open launches the CONTAINING app regardless of the
        // URL (which is why handing it a comgooglemaps:// link opened Tween —
        // device feedback). So open the containing app ON PURPOSE with a
        // handoff deep link; the host decodes it and immediately relaunches
        // into Google Maps (app scheme when installed, web/universal link
        // otherwise). One extra hop, but it always lands in Google Maps.
        guard let handoff = MapLinks.googleMapsHandoffURL(
            name: state.text, coordinate: state.coordinate) else { return }
        extensionContext?.open(handoff) { [weak self] didOpen in
            guard !didOpen else { return }
            DispatchQueue.main.async {
                self?.sendStatusMessage = "Couldn't open Google Maps. Try from the Tween app."
                self?.presentUI(for: self?.presentationStyle ?? .expanded)
            }
        }
    }
}
