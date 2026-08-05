import SwiftData
import SwiftUI

@MainActor
struct JobDetailView: View {
    let job: JobSummary

    @Query private var surfaces: [Surface]

    init(job: JobSummary) {
        self.job = job
        let jobId = job.id
        _surfaces = Query(filter: #Predicate<Surface> { $0.jobId == jobId }, sort: [SortDescriptor(\.label)])
    }

    var body: some View {
        List {
            Section("Job") {
                LabeledContent("Name", value: job.name)
                if let address = job.address {
                    LabeledContent("Address", value: address)
                }
                LabeledContent("Status") {
                    JobStatusChip(status: job.status)
                }
            }

            // No price line: none of the synced store models carry money fields yet (see
            // report) — this section renders only what `JobSummary`/`Surface` actually hold.
            Section("Surfaces") {
                if surfaces.isEmpty {
                    EmptyStateView(title: "Nothing here yet", detail: "Pull to refresh after signing in")
                        .listRowInsets(EdgeInsets())
                } else {
                    ForEach(surfaces) { surface in
                        HStack {
                            Text(surface.label)
                                .font(DS.Font.body)
                                .foregroundStyle(DS.Color.textPrimary)
                            Spacer()
                            SurfaceStatusChip(status: surface.status)
                        }
                    }
                }
            }
        }
        .navigationTitle(job.name)
    }
}

/// `Surface.status` chip, colored per the surface-fabrication pipeline via
/// `DS.Color.surfaceStatus` — unlike `JobStatusChip`, which is intentionally neutral.
private struct SurfaceStatusChip: View {
    let status: String

    var body: some View {
        Text(status)
            .font(DS.Font.caption)
            .foregroundStyle(DS.Color.textPrimary)
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .background(DS.Color.surfaceStatus(status), in: Capsule())
    }
}
