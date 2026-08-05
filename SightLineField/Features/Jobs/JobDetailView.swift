import SwiftData
import SwiftUI

@MainActor
struct JobDetailView: View {
    let job: JobSummary

    @Query private var surfaces: [Surface]
    @Query private var openWorkLogs: [WorkLog]

    @State private var isCheckInPresented = false
    @State private var checkOutTarget: WorkLog?

    init(job: JobSummary) {
        self.job = job
        let jobId = job.id
        _surfaces = Query(filter: #Predicate<Surface> { $0.jobId == jobId }, sort: [SortDescriptor(\.label)])
        // Reactive equivalent of `WorkLogActions.openWorkLog(onJob:technicianId:)` — a `@Query`
        // (not a one-shot fetch) so this view re-renders the moment `checkIn`/`checkOut` upserts
        // a row, per the "@Query store-first" house style. See that method's doc comment for why
        // this can't also filter by technician yet.
        _openWorkLogs = Query(
            filter: #Predicate<WorkLog> { $0.jobId == jobId && $0.status == "CHECKED_IN" },
            sort: [SortDescriptor(\.checkInAt, order: .reverse)]
        )
    }

    /// The caller's own open session on this job, if any — mirrors `WorkLogActions
    /// .openWorkLog(onJob:)`.
    private var openWorkLog: WorkLog? { openWorkLogs.first }

    var body: some View {
        List {
            Section {
                if let openWorkLog {
                    VStack(alignment: .leading, spacing: 8) {
                        Text("Checked in since \(openWorkLog.checkInAt.formatted(date: .omitted, time: .shortened))")
                            .font(DS.Font.caption)
                            .foregroundStyle(DS.Color.textSecondary)
                        Button("Check Out") { checkOutTarget = openWorkLog }
                    }
                } else {
                    Button("Check In") { isCheckInPresented = true }
                }
            }

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
        .sheet(isPresented: $isCheckInPresented) {
            CheckInSheet(jobId: job.id)
        }
        .sheet(item: $checkOutTarget) { workLog in
            CheckOutSheet(workLog: workLog)
        }
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
