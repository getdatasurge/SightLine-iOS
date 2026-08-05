import PhotosUI
import SwiftData
import SwiftUI
#if canImport(UIKit)
import UIKit
#endif

@MainActor
struct JobDetailView: View {
    let job: JobSummary

    @Query private var surfaces: [Surface]
    @Query private var openWorkLogs: [WorkLog]
    /// Backing count for the "N pending" caption under Add Photo — every `.photoUpload` row not
    /// yet `.done`, app-wide (not scoped to this job: `SyncOutbox.payload` is an opaque encoded
    /// blob, not queryable by `entityId` through a SwiftData `#Predicate`). Same "@Query
    /// store-first" reasoning as `openWorkLogs` below: reactive, so a completed upload's row
    /// flipping to `.done` updates this without any manual refresh.
    @Query private var pendingPhotoUploads: [SyncOutbox]

    @Environment(PhotoActions.self) private var photoActions

    @State private var isCheckInPresented = false
    @State private var checkOutTarget: WorkLog?
    @State private var pickerItem: PhotosPickerItem?

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
        let photoEndpoint = OutboxEndpoint.photoUpload.rawValue
        let pendingState = OutboxState.pending.rawValue
        let inFlightState = OutboxState.inFlight.rawValue
        _pendingPhotoUploads = Query(filter: #Predicate<SyncOutbox> {
            $0.endpoint == photoEndpoint && ($0.state == pendingState || $0.state == inFlightState)
        })
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

            Section("Photos") {
                PhotosPicker(selection: $pickerItem, matching: .images) {
                    Text("Add Photo")
                }
                if !pendingPhotoUploads.isEmpty {
                    Text("\(pendingPhotoUploads.count) photo\(pendingPhotoUploads.count == 1 ? "" : "s") pending upload")
                        .font(DS.Font.caption)
                        .foregroundStyle(DS.Color.textSecondary)
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
        .onChange(of: pickerItem) { _, newItem in
            loadAndEnqueue(newItem)
        }
    }

    /// Loads the picked item's raw bytes, converts to JPEG, and hands off to `PhotoActions` —
    /// offline-first (mirrors `checkIn`/`checkOut`): no error UI on a failed load, matching the
    /// "never shows an error" contract for this optimistic capture flow. Resets `pickerItem` to
    /// `nil` afterward so picking the exact same asset again still fires `.onChange`.
    private func loadAndEnqueue(_ item: PhotosPickerItem?) {
        guard let item else { return }
        Task {
            guard let data = try? await item.loadTransferable(type: Data.self) else { return }
            photoActions.enqueuePhoto(entityType: "job", entityId: job.id, imageData: Self.jpegData(from: data))
            pickerItem = nil
        }
    }

    /// `PhotosPickerItem.loadTransferable(type: Data.self)` hands back whatever encoding the
    /// original asset used (HEIC on a real device's camera roll) — re-encoded to JPEG here so
    /// `PhotoActions.enqueuePhoto`'s `mimeType: "image/jpeg"` is always accurate. Falls back to
    /// the raw bytes if decoding fails (simulator-synthesized library images, or `UIKit`
    /// unavailable) rather than silently dropping the capture.
    private static func jpegData(from data: Data) -> Data {
        #if canImport(UIKit)
        if let image = UIImage(data: data), let jpeg = image.jpegData(compressionQuality: 0.8) {
            return jpeg
        }
        #endif
        return data
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
