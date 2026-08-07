import SwiftData
import SwiftUI

@MainActor
struct WorkLogsView: View {
    @Query(sort: \WorkLog.checkInAt, order: .reverse) private var workLogs: [WorkLog]
    @Environment(SyncEngine.self) private var syncEngine

    @State private var checkOutTarget: WorkLog?

    /// The caller's own open ("CHECKED_IN") session across every job — drives the top banner.
    /// Derived from the same `@Query` the list already holds rather than a second query.
    private var openWorkLog: WorkLog? { workLogs.first(where: { $0.status == "CHECKED_IN" }) }

    var body: some View {
        NavigationStack {
            Group {
                if workLogs.isEmpty {
                    EmptyStateView(title: "Nothing here yet", detail: "Pull to refresh after signing in")
                } else {
                    List {
                        if let openWorkLog {
                            Section {
                                HStack {
                                    Text("Checked in since \(openWorkLog.checkInAt.formatted(date: .omitted, time: .shortened))")
                                        .font(DS.Font.body)
                                        .foregroundStyle(DS.Color.textPrimary)
                                    Spacer()
                                    Button("Check Out") { checkOutTarget = openWorkLog }
                                }
                            }
                        }
                        Section {
                            ForEach(workLogs) { log in
                                WorkLogRow(log: log)
                            }
                        }
                    }
                }
            }
            .navigationTitle("Work Logs")
            .refreshable { await syncEngine.syncAll() }
            .sheet(item: $checkOutTarget) { workLog in
                CheckOutSheet(workLog: workLog)
            }
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
