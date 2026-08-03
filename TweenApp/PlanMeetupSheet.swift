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
                    ForEach(participants) { participant in
                        travelModeRow(for: participant)
                    }
                } header: {
                    Text("How everyone travels")
                } footer: {
                    Text("Fairness compares each person in their own way of travelling, so a bus rider isn't judged against a driver.")
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

    private func save() {
        plan.arrivalDate = isScheduled ? arrival : nil
        MeetupPlanStore.save(plan)
    }

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
