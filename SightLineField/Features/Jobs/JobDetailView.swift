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
    @Environment(SessionManager.self) private var session

    @State private var isCheckInPresented = false
    @State private var checkOutTarget: WorkLog?
    @State private var pickerItem: PhotosPickerItem?
    @State private var assignTarget: Surface?
    @State private var isCameraPresented = false
    @State private var pendingCameraEntity: (entityType: String, entityId: String)?

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

    /// The signed-in account's own technician id, if the account is bound to one — threaded
    /// into `CheckInSheet` so the optimistic row it creates carries the same `technicianId`
    /// `WorkLogActions.openWorkLog(onJob:technicianId:)` scopes its query by, per `SettingsSheet`'s
    /// `session.state` pattern.
    private var technicianId: String? {
        if case .signedIn(let account) = session.state {
            return account.technicianId
        }
        return nil
    }

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
                Menu {
                    PhotosPicker(selection: $pickerItem, matching: .images) {
                        Label("Photo Library", systemImage: "photo.on.rectangle")
                    }
                    if UIImagePickerController.isSourceTypeAvailable(.camera) {
                        Button {
                            pendingCameraEntity = (entityType: "job", entityId: job.id)
                            isCameraPresented = true
                        } label: {
                            Label("Take Photo", systemImage: "camera")
                        }
                    }
                } label: {
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
                        SurfaceRow(surface: surface, onAssign: { assignTarget = $0 })
                    }
                }

                NavigationLink {
                    JobElevationsView(jobId: job.id)
                } label: {
                    Text("Elevations")
                        .font(DS.Font.body)
                        .foregroundStyle(DS.Color.textPrimary)
                }
            }
        }
        .navigationTitle(job.name)
        .sheet(isPresented: $isCheckInPresented) {
            CheckInSheet(jobId: job.id, technicianId: technicianId)
        }
        .sheet(item: $checkOutTarget) { workLog in
            CheckOutSheet(workLog: workLog)
        }
        .sheet(item: $assignTarget) { surface in
            AssignSurfaceSheet(jobId: job.id, surface: surface)
        }
        .sheet(isPresented: $isCameraPresented) {
            if let entity = pendingCameraEntity {
                CameraCaptureView { data in
                    photoActions.enqueuePhoto(
                        entityType: entity.entityType, entityId: entity.entityId,
                        imageData: Self.jpegData(from: data)
                    )
                }
            }
        }
        .onChange(of: pickerItem) { _, newItem in
            Task {
                if await Self.loadAndEnqueue(newItem, entityType: "job", entityId: job.id, photoActions: photoActions) {
                    pickerItem = nil
                }
            }
        }
    }

    /// Shared by the job-level "Add Photo" picker above and each `SurfaceRow`'s per-pane
    /// picker below: loads `item`'s raw bytes, converts to JPEG (`jpegData(from:)`), and hands
    /// off to `PhotoActions` — offline-first (mirrors `checkIn`/`checkOut`): no error UI on a
    /// failed load, matching the "never shows an error" contract for this optimistic capture
    /// flow. Returns whether the enqueue happened, so each call site resets its own
    /// `PhotosPickerItem` selection only on success — picking the exact same asset again after
    /// a failed load still needs a distinct value to re-fire `.onChange`.
    fileprivate static func loadAndEnqueue(
        _ item: PhotosPickerItem?,
        entityType: String,
        entityId: String,
        photoActions: PhotoActions
    ) async -> Bool {
        guard let item, let data = try? await item.loadTransferable(type: Data.self) else { return false }
        photoActions.enqueuePhoto(entityType: entityType, entityId: entityId, imageData: jpegData(from: data))
        return true
    }

    /// `PhotosPickerItem.loadTransferable(type: Data.self)` hands back whatever encoding the
    /// original asset used (HEIC on a real device's camera roll) — re-encoded to JPEG here so
    /// `PhotoActions.enqueuePhoto`'s `mimeType: "image/jpeg"` is always accurate. Falls back to
    /// the raw bytes if decoding fails (simulator-synthesized library images, or `UIKit`
    /// unavailable) rather than silently dropping the capture.
    static func jpegData(from data: Data) -> Data {
        #if canImport(UIKit)
        if let image = UIImage(data: data), let jpeg = image.jpegData(compressionQuality: 0.8) {
            return jpeg
        }
        #endif
        return data
    }
}

/// One `Surface` row in `JobDetailView`'s "Surfaces" section (M5c). Combines the read-only
/// label/status line with two per-row actions: "Assign to Elevation" (shown only while
/// unassigned — opens `AssignSurfaceSheet`, which calls `ElevationActions.assignSurface`) and
/// "Add Photo" (always available — `PhotoActions.enqueuePhoto(entityType: "surface", ...)` via
/// the same load-convert-to-JPEG flow the job-level Photos section uses, through
/// `JobDetailView.loadAndEnqueue`). The trailing icon-button convention matches
/// `JobElevationsView.ElevationRow`'s "Capture Pane" action, so both survey screens share one
/// affordance vocabulary.
private struct SurfaceRow: View {
    let surface: Surface
    let onAssign: (Surface) -> Void

    @Environment(PhotoActions.self) private var photoActions
    @State private var pickerItem: PhotosPickerItem?
    @State private var isCameraPresented = false

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .firstTextBaseline) {
                Text(surface.label)
                    .font(DS.Font.body)
                    .foregroundStyle(DS.Color.textPrimary)
                Spacer()
                SurfaceStatusChip(status: surface.status)
            }
            .accessibilityElement(children: .combine)

            HStack {
                if surface.elevationId == nil {
                    Button {
                        onAssign(surface)
                    } label: {
                        Label("Assign to Elevation", systemImage: "building.2")
                            .font(DS.Font.caption)
                    }
                    .buttonStyle(.borderless)
                    .frame(minHeight: DS.Layout.minTouchTarget)
                    .contentShape(Rectangle())
                } else {
                    Label("Assigned", systemImage: "checkmark.circle")
                        .font(DS.Font.caption)
                        .foregroundStyle(DS.Color.textSecondary)
                }

                Spacer(minLength: 8)

                Menu {
                    PhotosPicker(selection: $pickerItem, matching: .images) {
                        Label("Photo Library", systemImage: "photo.on.rectangle")
                    }
                    if UIImagePickerController.isSourceTypeAvailable(.camera) {
                        Button { isCameraPresented = true } label: {
                            Label("Take Photo", systemImage: "camera")
                        }
                    }
                } label: {
                    Label("Add Photo", systemImage: "camera")
                        .labelStyle(.iconOnly)
                        .font(DS.Font.body)
                }
                .frame(minWidth: DS.Layout.minTouchTarget, minHeight: DS.Layout.minTouchTarget)
                .contentShape(Rectangle())
            }
        }
        .padding(.vertical, 4)
        .onChange(of: pickerItem) { _, newItem in
            Task {
                if await JobDetailView.loadAndEnqueue(newItem, entityType: "surface", entityId: surface.id, photoActions: photoActions) {
                    pickerItem = nil
                }
            }
        }
        .sheet(isPresented: $isCameraPresented) {
            CameraCaptureView { data in
                photoActions.enqueuePhoto(
                    entityType: "surface", entityId: surface.id,
                    imageData: JobDetailView.jpegData(from: data)
                )
            }
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

/// Live camera capture (F4 gap: M4b shipped library-picker-only). Both "Add Photo" affordances
/// are now a two-choice menu — library picker plus, on devices with a camera, this sheet; the
/// captured frame rides the exact same offline path (`PhotoActions.enqueuePhoto` through the
/// caller's JPEG conversion). The simulator has no camera, so `isSourceTypeAvailable(.camera)`
/// hides "Take Photo" there and no UITest can exercise it — device-only by nature.
#if canImport(UIKit)
struct CameraCaptureView: UIViewControllerRepresentable {
    let onCapture: (Data) -> Void

    func makeUIViewController(context: Context) -> UIImagePickerController {
        let picker = UIImagePickerController()
        picker.sourceType = .camera
        picker.delegate = context.coordinator
        return picker
    }

    func updateUIViewController(_ uiViewController: UIImagePickerController, context: Context) {}

    func makeCoordinator() -> Coordinator { Coordinator(onCapture: onCapture) }

    @MainActor
    final class Coordinator: NSObject, UIImagePickerControllerDelegate, UINavigationControllerDelegate {
        let onCapture: (Data) -> Void

        init(onCapture: @escaping (Data) -> Void) {
            self.onCapture = onCapture
        }

        func imagePickerController(
            _ picker: UIImagePickerController,
            didFinishPickingMediaWithInfo info: [UIImagePickerController.InfoKey: Any]
        ) {
            defer { picker.dismiss(animated: true) }
            guard let image = info[.originalImage] as? UIImage,
                  let data = image.jpegData(compressionQuality: 0.8) else { return }
            onCapture(data)
        }

        func imagePickerControllerDidCancel(_ picker: UIImagePickerController) {
            picker.dismiss(animated: true)
        }
    }
}
#endif
