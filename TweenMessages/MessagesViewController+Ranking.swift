import UIKit
import SwiftUI
import Messages
import MapKit
import CoreLocation
import os

// Fair-spot ranking (split from MessagesViewController.swift).
extension MessagesViewController {
    // MARK: - Ranking

    /// Searches the centroid region for candidate spots and ranks them by
    /// fairness across every "in" participant. Re-renders the expanded UI
    /// when finished. No-ops while fewer than two participants have shared
    /// their location.
    func kickOffRanking() {
        rankingTask?.cancel()

        let participants = rankingParticipants()
        guard participants.count >= 2 else {
            isRanking = false
            if !rankedSpots.isEmpty {
                rankedSpots = []
            }
            presentUI(for: presentationStyle)
            return
        }

        isRanking = true
        presentUI(for: presentationStyle)

        let center = MapGeometry.centroid(of: participants)
        // Search radius widens as the group spreads out.
        let span = participants.reduce(0.04) { acc, p in
            let dLat = abs(p.latitude - center.latitude)
            let dLon = abs(p.longitude - center.longitude)
            return max(acc, max(dLat, dLon) * 2.0)
        }
        // recommendedCap scales with group size (10 for two people) — inside
        // the extension the ~120 MB ceiling caps candidates at 5 regardless.
        let cap = min(Self.rankCap, FairnessRanker.recommendedCap(for: participants.count))

        rankingTask = Task { @MainActor in
            let region = MKCoordinateRegion(
                center: center,
                span: MKCoordinateSpan(latitudeDelta: span, longitudeDelta: span))
            let pool = await Self.searchCandidates(
                query: Self.defaultQuery,
                region: region,
                minimumCount: Self.searchPoolSize,
                timeoutNanoseconds: Self.searchTimeoutNanoseconds)
            guard !Task.isCancelled else { return }
            // Hard between-people cut BEFORE ranking: the merged pool can be
            // dominated by a commercial corridor off to one side (the request
            // region is only relevance guidance, and the broadened fallback is
            // unconstrained), and the soft centrality penalty can't rescue a
            // pool that's entirely off-axis (device feedback).
            let candidates = SpotVicinity.filter(pool, participants: participants, minimumCount: 3)
            guard !candidates.isEmpty else {
                self.isRanking = false
                self.rankedSpots = []
                self.presentUI(for: self.presentationStyle)
                return
            }

            let ranked = await FairnessRanker.rank(
                candidates: candidates, participants: participants, cap: cap)
            guard !Task.isCancelled else { return }

            self.rankedSpots = ranked
            self.isRanking = false
            self.presentUI(for: self.presentationStyle)
        }
    }

    static func searchCandidates(query: String,
                                         region: MKCoordinateRegion,
                                         minimumCount: Int,
                                         timeoutNanoseconds: UInt64) async -> [MKMapItem] {
        let local = await searchItems(query: query,
                                      region: region,
                                      regionRequired: true,
                                      timeoutNanoseconds: timeoutNanoseconds)
        if #available(iOS 18.0, *), local.count < minimumCount {
            let fallback = await searchItems(query: query,
                                             region: region,
                                             regionRequired: false,
                                             timeoutNanoseconds: timeoutNanoseconds)
            return SearchResultMerger.merge(local: local, fallback: fallback, minimumCount: minimumCount)
        }
        return SearchResultMerger.deduped(local)
    }

    static func searchItems(query: String,
                                    region: MKCoordinateRegion,
                                    regionRequired: Bool,
                                    timeoutNanoseconds: UInt64) async -> [MKMapItem] {
        let request = MKLocalSearch.Request()
        request.naturalLanguageQuery = query
        request.region = region
        if regionRequired, #available(iOS 18.0, *) {
            request.regionPriority = .required
        }

        let response = await withTaskGroup(of: MKLocalSearch.Response?.self) { group in
            group.addTask {
                try? await MKLocalSearch(request: request).start()
            }
            group.addTask {
                try? await Task.sleep(nanoseconds: timeoutNanoseconds)
                return nil
            }

            let response = await group.next() ?? nil
            group.cancelAll()
            return response
        }
        return response?.mapItems ?? []
    }

    func rankingParticipants() -> [Participant] {
        let myName = Self.localParticipantName()
        var source: [Participant]
        if let received, received.participants.count >= 2, currentParticipants.count < 2 {
            source = received.participants
        } else if !currentParticipants.isEmpty {
            source = currentParticipants
        } else if let received, !received.participants.isEmpty {
            source = received.participants
        } else {
            source = activeSnapshotParticipants()
        }

        if currentParticipants.isEmpty, !source.isEmpty {
            currentParticipants = source
            LocationCache.saveParticipantSnapshot(source, localContext: localParticipantContext())
            saveParticipantsForActiveConversation(source)
        }

        let myId = localParticipantID()
        let rosterSelfCoordinate = source.first(where: { $0.matches(id: myId, name: myName) })?.coordinate
        source = source.filter { !$0.matches(id: myId, name: myName) }
        // Rank with the cached fix only while it's FRESH (isActive = opted
        // in + within the 5-min window); otherwise fall back to the roster
        // entry — the coordinate peers already see — instead of skewing
        // fairness with a stale private cache (audit W4).
        let selfCoordinate = (LocationCache.isActive ? LocationCache.loadSelf()?.coordinate : nil)
            ?? rosterSelfCoordinate
        if isLocalUserInCurrentConversation, let mySelf = selfCoordinate {
            let needsRide = currentParticipants.first(where: { $0.matches(id: myId, name: myName) })?.needsRide
                ?? activeSnapshotParticipants().first(where: { $0.matches(id: myId, name: myName) })?.needsRide
                ?? false
            source.append(Participant(id: myId, name: myName, coordinate: mySelf, needsRide: needsRide))
        }
        return source
    }

}
