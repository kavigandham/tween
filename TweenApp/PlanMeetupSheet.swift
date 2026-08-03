import SwiftUI
import CoreLocation

/// Tween Pro's planning surface: pick when you're meeting, say how each person
/// is travelling, then optionally set a leave-by reminder and drop it in the
/// calendar.
///
/// Everything here is LOCAL planning data. The plan seeds ranking and reminders
/// on this device and is never broadcast — a proposal payload is coordinates
/// and a spot name (constraint 2).
struct PlanMeetupSheet: View {
    let spotName: String
    let coordinate: CLLocationCoordinate2D?
    /// Travel time for the local user, used for the leave-by maths. Nil when
    /// ranking hasn't produced one yet.
    let myTravelTime: TimeInterval?
    let participants: [Participant]
    let localParticipantID: String?
    /// Fired after the plan is persisted so the host can re-rank. Without it a
    /// saved plan changed nothing on screen until the next search, and the user
    /// reasonably concluded the feature did nothing (audit 2026-08-02).
    var onSaved: () -> Void = {}

    @Environment(\.dismiss) private var dismiss

    @State private var plan = MeetupPlanStore.current
    @State private var isScheduled = MeetupPlanStore.current.isScheduled
    @State private var arrival = MeetupPlanStore.current.arrivalDate
        ?? Calendar.current.date(byAdding: .hour, value: 2, to: Date()) ?? Date()
    @State private var reminderState: ActionState = .idle
    @State private var calendarState: ActionState = .idle

    private enum ActionState: Equatable {
        case idle
        case working
        case done(String)
        case failed(String)
    }

    var body: some View {
        NavigationStack {
            List {
                Section {
                    Toggle("Meeting at a set time", isOn: $isScheduled)
                    if isScheduled {
                        DatePicker("Arrive by", selection: $arrival,
                                   in: Date()...,
                                   displayedComponents: [.date, .hourAndMinute])
                    }
                } header: {
                    Text("When")
                } footer: {
                    Text(isScheduled
                         ? "Spots are ranked by the travel time predicted for that arrival, not right now."
                         : "Off means \"meeting now\" — spots rank by live travel time.")
                }

                Section {
                    ForEach(travelRoster) { participant in
                        travelModeRow(for: participant)
                    }
                } header: {
                    Text("How everyone travels")
                } footer: {
                    Text(travelRoster.count > 1
                         ? "Fairness compares each person in their own way of travelling, so a bus rider isn't judged against a driver."
                         : "Once friends join, each of them gets their own row here.")
                }

                if isScheduled {
                    Section {
                        reminderButton
                        calendarButton
                    } footer: {
                        Text("The reminder fires \(Int(LeaveByReminder.bufferSeconds / 60)) minutes before you need to leave. Both stay on this device.")
                    }
                }
            }
            .navigationTitle("Plan meetup")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Save") { save(); dismiss() }.fontWeight(.semibold)
                }
            }
        }
        .presentationDetents([.medium, .large])
        .presentationDragIndicator(.visible)
    }

    /// Always includes the local user. Planning a meetup you're going to means
    /// setting YOUR travel mode, and before anyone joins `participants` is
    /// empty — which rendered a section header and footer wrapped around
    /// nothing at all (screenshot verify 2026-08-02).
    private var travelRoster: [Participant] {
        let localID = localParticipantID ?? TweenIdentity.stableID
        if participants.contains(where: { $0.id == localID }) { return participants }
        let me = Participant(
            id: localID,
            name: UserProfile.displayName ?? UserName.fallback,
            coordinate: .init(latitude: 0, longitude: 0))
        return [me] + participants
    }

    private func travelModeRow(for participant: Participant) -> some View {
        let isMe = participant.id == localParticipantID
        return Picker(selection: Binding(
            get: { plan.mode(for: participant.id) },
            set: { plan.setMode($0, for: participant.id) }
        )) {
            ForEach(TravelMode.allCases) { mode in
                Label(mode.title, systemImage: mode.systemImage).tag(mode)
            }
        } label: {
            Text(isMe ? "You" : participant.name)
                .foregroundStyle(Tokens.Palette.textPrimary)
        }
        .pickerStyle(.menu)
    }

    @ViewBuilder
    private var reminderButton: some View {
        Button {
            Task { await scheduleReminder() }
        } label: {
            actionLabel(
                title: "Set leave-by reminder",
                systemImage: "bell.badge.fill",
                state: reminderState)
        }
        .disabled(reminderState == .working || myTravelTime == nil)

        if myTravelTime == nil {
            Text("Available once Tween knows your travel time to \(spotName).")
                .font(Tokens.Typography.caption)
                .foregroundStyle(Tokens.Palette.textSecondary)
        }
    }

    private var calendarButton: some View {
        Button {
            Task { await addToCalendar() }
        } label: {
            actionLabel(
                title: "Add to calendar",
                systemImage: "calendar.badge.plus",
                state: calendarState)
        }
        .disabled(calendarState == .working)
    }

    private func actionLabel(title: String, systemImage: String, state: ActionState) -> some View {
        HStack {
            Label {
                VStack(alignment: .leading, spacing: 2) {
                    Text(title).foregroundStyle(Tokens.Palette.textPrimary)
                    switch state {
                    case .done(let detail):
                        Text(detail)
                            .font(Tokens.Typography.caption)
                            .foregroundStyle(Tokens.Palette.success)
                    case .failed(let detail):
                        Text(detail)
                            .font(Tokens.Typography.caption)
                            .foregroundStyle(Tokens.Palette.destructive)
                    default:
                        EmptyView()
                    }
                }
            } icon: {
                Image(systemName: systemImage).foregroundStyle(Tokens.Palette.brand)
            }
            Spacer()
            if state == .working { ProgressView() }
        }
    }

    // MARK: Actions

    /// @MainActor is explicit, NOT inherited. A plain method on a SwiftUI View
    /// struct is nonisolated (verified with a type-check probe) — so calling
    /// this through the `() -> Void` onSaved closure erased isolation and ran
    /// the re-rank, and these @State writes, off the main thread
    /// (audit 2026-08-02).
    @MainActor
    private func save() {
        let previousArrival = plan.arrivalDate
        let previousSpot = plan.spotName
        let previousModes = plan.modes
        plan.arrivalDate = isScheduled ? arrival : nil
        plan.setSpot(name: isScheduled ? spotName : nil,
                     coordinate: isScheduled ? coordinate : nil)
        MeetupPlanStore.save(plan)

        // Retire the pending notification whenever what it says would now be
        // WRONG: un-scheduled, moved in time, or — the case the first version
        // of this missed — re-planned to a different place.
        //
        // Repro that fix closes: plan spot A for 7pm and arm the reminder; open
        // spot B's card and tap Plan (the sheet inits from the stored plan, so
        // it opens already scheduled for 7pm) and Save. The arrival is
        // unchanged, so an arrival-only guard cancelled nothing — and a live
        // notification kept saying "leave now to reach A", timed off the drive
        // to A, for a plan that now points at B (audit 2026-08-02).
        // Modes matter too: the fire date is arrival − travelTime − buffer, and
        // travelTime is mode-dependent. Arm while driving (15 min), switch to
        // walking (90 min), and an arrival+spot-only guard cancelled nothing —
        // the notification still fired 20 minutes before arrival for a
        // 90-minute walk. Modes are written straight into `plan` by the picker,
        // so they can never show up in the other two diffs.
        let spotChanged = previousSpot != plan.spotName
        let modesChanged = previousModes != plan.modes
        if !isScheduled || previousArrival != plan.arrivalDate || spotChanged || modesChanged {
            LeaveByReminder.cancel()
            // Don't keep claiming a reminder that was just retired.
            if case .done = reminderState { reminderState = .idle }
        }
        onSaved()
    }

    @MainActor
    private func scheduleReminder() async {
        guard let myTravelTime else { return }
        reminderState = .working
        save()
        let fired = await LeaveByReminder.schedule(
            spotName: spotName,
            arrivalDate: arrival,
            travelTime: myTravelTime)
        if let fired {
            reminderState = .done("Reminder set for \(fired.formatted(date: .omitted, time: .shortened))")
        } else {
            // Distinguish the two real failures rather than a generic error —
            // "leave now" in the past is a planning mistake the user can fix by
            // moving the time; a denied permission is a Settings trip.
            let leaveBy = LeaveByReminder.fireDate(arrivalDate: arrival, travelTime: myTravelTime)
            reminderState = .failed(leaveBy <= Date()
                ? "You'd need to leave already — pick a later time."
                : "Turn on notifications for Tween in Settings.")
        }
    }

    @MainActor
    private func addToCalendar() async {
        calendarState = .working
        save()
        let others = participants
            .filter { $0.id != localParticipantID }
            .map(\.name)
        do {
            _ = try await CalendarExport.add(
                spotName: spotName,
                coordinate: coordinate,
                arrivalDate: arrival,
                attendees: others)
            calendarState = .done("Added to your calendar")
        } catch CalendarExport.Failure.accessDenied {
            calendarState = .failed("Allow calendar access for Tween in Settings.")
        } catch {
            calendarState = .failed("Couldn't add the event.")
        }
    }
}
