import SwiftData
import SwiftUI

@MainActor
struct JobListView: View {
    @Query(sort: \JobSummary.updatedAt, order: .reverse) private var jobs: [JobSummary]

    var body: some View {
        NavigationStack {
            Group {
                if jobs.isEmpty {
                    EmptyStateView(title: "Nothing here yet", detail: "Awaiting first sync (M2)")
                } else {
                    List(jobs) { job in
                        NavigationLink {
                            JobDetailView(job: job)
                        } label: {
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
                        }
                    }
                }
            }
            .navigationTitle("Jobs")
        }
    }
}
