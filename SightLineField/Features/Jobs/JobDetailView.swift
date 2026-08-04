import SwiftData
import SwiftUI

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
                    Text(job.status)
                        .font(DS.Font.caption)
                        .foregroundStyle(DS.Color.textPrimary)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 4)
                        .background(DS.Color.surfaceStatus(job.status), in: Capsule())
                }
                LabeledContent("Updated", value: job.updatedAt.formatted(date: .abbreviated, time: .shortened))
            }

            Section("Surfaces") {
                if surfaces.isEmpty {
                    EmptyStateView(title: "Nothing here yet", detail: "Awaiting first sync (M2)")
                        .listRowInsets(EdgeInsets())
                } else {
                    ForEach(surfaces) { surface in
                        Text(surface.label)
                            .font(DS.Font.body)
                            .foregroundStyle(DS.Color.textPrimary)
                    }
                }
            }
        }
        .navigationTitle(job.name)
    }
}
