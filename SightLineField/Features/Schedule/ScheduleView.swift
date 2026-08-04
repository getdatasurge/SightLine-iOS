import SwiftData
import SwiftUI

struct ScheduleView: View {
    @Query(sort: \Appointment.start) private var appointments: [Appointment]

    var body: some View {
        NavigationStack {
            Group {
                if appointments.isEmpty {
                    EmptyStateView(title: "Nothing here yet", detail: "Awaiting first sync (M2)")
                } else {
                    List(appointments) { appointment in
                        VStack(alignment: .leading, spacing: 4) {
                            Text(appointment.title)
                                .font(DS.Font.body)
                                .foregroundStyle(DS.Color.textPrimary)
                            Text(appointment.start, format: .dateTime.month().day().hour().minute())
                                .font(DS.Font.caption)
                                .foregroundStyle(DS.Color.textSecondary)
                        }
                    }
                }
            }
            .navigationTitle("Schedule")
        }
    }
}
