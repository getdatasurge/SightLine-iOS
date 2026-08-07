import SwiftData
import SwiftUI

@MainActor
struct ScheduleView: View {
    @Query(sort: \Appointment.start) private var appointments: [Appointment]
    @Environment(SyncEngine.self) private var syncEngine

    /// Appointments grouped by calendar day, restricted to today and later, sorted
    /// chronologically (today first). Past appointments are dropped rather than shown in a
    /// "history" section — M2 has no such section in the design.
    private var days: [(day: Date, appointments: [Appointment])] {
        let calendar = Calendar.current
        let today = calendar.startOfDay(for: Date())
        let upcoming = appointments.filter { calendar.startOfDay(for: $0.start) >= today }
        let grouped = Dictionary(grouping: upcoming) { calendar.startOfDay(for: $0.start) }
        return grouped.keys.sorted().map { day in
            (day: day, appointments: grouped[day, default: []].sorted { $0.start < $1.start })
        }
    }

    var body: some View {
        NavigationStack {
            Group {
                if days.isEmpty {
                    EmptyStateView(title: "Nothing here yet", detail: "Pull to refresh after signing in")
                } else {
                    List {
                        ForEach(days, id: \.day) { entry in
                            Section(entry.day.formatted(.dateTime.weekday(.wide).month().day())) {
                                ForEach(entry.appointments) { appointment in
                                    NavigationLink {
                                        JobCardView(appointmentId: appointment.id)
                                    } label: {
                                        AppointmentRow(appointment: appointment)
                                    }
                                }
                            }
                        }
                    }
                }
            }
            .navigationTitle("Schedule")
            .refreshable { await syncEngine.syncAll() }
        }
    }
}

private struct AppointmentRow: View {
    let appointment: Appointment

    private var timeRange: String {
        let start = appointment.start.formatted(date: .omitted, time: .shortened)
        let end = appointment.end.formatted(date: .omitted, time: .shortened)
        return "\(start) – \(end)"
    }

    var body: some View {
        HStack(alignment: .firstTextBaseline) {
            VStack(alignment: .leading, spacing: 4) {
                Text(timeRange)
                    .font(DS.Font.caption)
                    .foregroundStyle(DS.Color.textSecondary)
                Text(appointment.title)
                    .font(DS.Font.body)
                    .foregroundStyle(DS.Color.textPrimary)
            }
            Spacer()
            ScheduleStatusChip(status: appointment.status)
        }
    }
}

/// Neutral status capsule for `Appointment.status`. Appointment statuses are their own string
/// vocabulary (e.g. scheduled/confirmed/cancelled) with no dedicated color mapping the way
/// `Surface.status` has via `DS.Color.surfaceStatus` — reusing that function here would risk
/// coincidentally recoloring an appointment status that happens to share a literal with the
/// surface-fabrication pipeline (e.g. "COMPLETED"), so this sticks to neutral `DS` tokens.
/// Internal (not `private`) — `JobCardView` reuses it for the same `Appointment.status` field
/// on its own detail screen.
struct ScheduleStatusChip: View {
    let status: String

    var body: some View {
        Text(status)
            .font(DS.Font.caption)
            .foregroundStyle(DS.Color.textPrimary)
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .background(DS.Color.textSecondary.opacity(0.15), in: Capsule())
    }
}
