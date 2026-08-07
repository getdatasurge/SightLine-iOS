import SwiftData
import SwiftUI

@MainActor
struct JobListView: View {
    @Query(sort: \JobSummary.updatedAt, order: .reverse) private var jobs: [JobSummary]
    @Environment(SyncEngine.self) private var syncEngine

    var body: some View {
        NavigationStack {
            Group {
                if jobs.isEmpty {
                    EmptyStateView(title: "Nothing here yet", detail: "Pull to refresh after signing in")
                } else {
                    List(jobs) { job in
                        NavigationLink {
                            JobDetailView(job: job)
                        } label: {
                            HStack(alignment: .firstTextBaseline) {
                                VStack(alignment: .leading, spacing: 4) {
                                    Text(job.name)
                                        .font(DS.Font.body)
                                        .foregroundStyle(DS.Color.textPrimary)
                                    if let address = job.address {
                                        Text(address)
                                            .font(DS.Font.caption)
                                            .foregroundStyle(DS.Color.textSecondary)
                                    }
                                }
                                Spacer()
                                JobStatusChip(status: job.status)
                            }
                        }
                    }
                }
            }
            .navigationTitle("Jobs")
            .refreshable { await syncEngine.syncAll() }
        }
    }
}

/// Neutral status capsule for `JobSummary.status`, shared with `JobDetailView`'s own status
/// field. Job statuses are their own string vocabulary, distinct from `Surface.status` — this
/// intentionally does not reuse `DS.Color.surfaceStatus`, which would coincidentally recolor a
/// job status that happens to share a literal with the surface-fabrication pipeline (e.g.
/// "COMPLETED").
struct JobStatusChip: View {
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
