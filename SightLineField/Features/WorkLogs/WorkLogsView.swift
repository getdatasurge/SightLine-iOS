import SwiftData
import SwiftUI

@MainActor
struct WorkLogsView: View {
    @Query(sort: \WorkLog.checkInAt, order: .reverse) private var workLogs: [WorkLog]

    var body: some View {
        NavigationStack {
            Group {
                if workLogs.isEmpty {
                    EmptyStateView(title: "Nothing here yet", detail: "Awaiting first sync (M2)")
                } else {
                    List(workLogs) { log in
                        VStack(alignment: .leading, spacing: 4) {
                            Text(log.status)
                                .font(DS.Font.body)
                                .foregroundStyle(DS.Color.textPrimary)
                            Text(log.checkInAt, format: .dateTime.month().day().hour().minute())
                                .font(DS.Font.caption)
                                .foregroundStyle(DS.Color.textSecondary)
                        }
                    }
                }
            }
            .navigationTitle("Work Logs")
        }
    }
}
