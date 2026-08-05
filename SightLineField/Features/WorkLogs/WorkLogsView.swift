import SwiftData
import SwiftUI

@MainActor
struct WorkLogsView: View {
    @Query(sort: \WorkLog.checkInAt, order: .reverse) private var workLogs: [WorkLog]
    @Environment(SyncEngine.self) private var syncEngine

    var body: some View {
        NavigationStack {
            Group {
                if workLogs.isEmpty {
                    EmptyStateView(title: "Nothing here yet", detail: "Pull to refresh after signing in")
                } else {
                    List(workLogs) { log in
                        WorkLogRow(log: log)
                    }
                }
            }
            .navigationTitle("Work Logs")
            .refreshable { await syncEngine.syncAll() }
        }
    }
}

private struct WorkLogRow: View {
    let log: WorkLog

    /// `workTypeId / status` when a work type is known, else just `status` — `WorkLog` only
    /// stores the work type's id (no joined `WorkType.name` lookup here), so this is the most
    /// honest label available from the store alone.
    private var headline: String {
        guard let workTypeId = log.workTypeId else { return log.status }
        return "\(workTypeId) / \(log.status)"
    }

    private var timeRange: String {
        let start = log.checkInAt.formatted(date: .abbreviated, time: .shortened)
        guard let checkOutAt = log.checkOutAt else { return "\(start) – in progress" }
        let end = checkOutAt.formatted(date: .abbreviated, time: .shortened)
        return "\(start) – \(end)"
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(headline)
                .font(DS.Font.body)
                .foregroundStyle(DS.Color.textPrimary)
            Text(timeRange)
                .font(DS.Font.caption)
                .foregroundStyle(DS.Color.textSecondary)
            if let quantity = log.quantity {
                Text("Qty: \(quantity.formatted())")
                    .font(DS.Font.caption)
                    .foregroundStyle(DS.Color.textSecondary)
            }
        }
    }
}
