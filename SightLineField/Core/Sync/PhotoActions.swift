import Foundation
import Observation
import SwiftData

/// Append-only photo capture (M4b), riding the same offline outbox as `WorkLogActions`'
/// check-in/check-out: `enqueuePhoto` only ever adds a new `SyncOutbox` row targeting
/// `.photoUpload` — nothing here edits or deletes.
///
/// Takes the app's one `OutboxWorker` instance rather than building its own (unlike
/// `WorkLogActions`, which owns the only `OutboxWorker` in the app) — the composition root wires
/// this with `workLogActions.outboxWorker`, so both actions classes drain the identical queue
/// instead of racing two separate ones. `modelContext` is still taken directly: writing the
/// `SyncOutbox` row is this class's own job (`OutboxWorker.modelContext` stays private), exactly
/// like `WorkLogActions.enqueue`.
@MainActor
@Observable
final class PhotoActions {
    private let outboxWorker: OutboxWorker
    private let modelContext: ModelContext

    init(outboxWorker: OutboxWorker, modelContext: ModelContext) {
        self.outboxWorker = outboxWorker
        self.modelContext = modelContext
    }

    /// Queues `imageData` for upload against `entityType`/`entityId` (the backend's polymorphic
    /// association — `entityType` is `"job"` or `"surface"`, `entityId` that row's id) and kicks
    /// off a drain without waiting for it. Offline-first, exactly like `WorkLogActions.checkIn`:
    /// this never throws and never awaits the network, so a technician offline never sees an
    /// error — the photo just syncs whenever the outbox next drains.
    ///
    /// `imageData` is expected to already be JPEG (the caller — e.g. `JobDetailView`'s photo
    /// picker — converts before calling this), so `filename`/`mimeType` are minted here once
    /// rather than taken as parameters; a retry after a transient failure then sends
    /// byte-for-byte the same multipart part every time instead of re-deriving them per attempt.
    ///
    /// No local model write here (unlike `checkIn`'s optimistic `WorkLog` insert) — there's no
    /// local photo store yet to reflect into, so a technician sees the pending upload only via
    /// `outboxWorker.pendingCount`/a `SyncOutbox` query, not a thumbnail.
    func enqueuePhoto(entityType: String, entityId: String, imageData: Data) {
        let clientUuid = UUID().uuidString
        let payload = PhotoUploadPayload(
            entityType: entityType,
            entityId: entityId,
            filename: "\(clientUuid).jpg",
            mimeType: "image/jpeg",
            imageData: imageData
        )
        // Strings + Data — nothing about encoding this can fail; same reasoning as
        // `WorkLogActions.enqueue`'s identical `try!` for its own payload types.
        let data = try! JSONEncoder().encode(payload)
        modelContext.insert(SyncOutbox(clientUuid: clientUuid, endpoint: OutboxEndpoint.photoUpload.rawValue, payload: data))
        try? modelContext.save()
        Task { await outboxWorker.drain() }
    }
}
