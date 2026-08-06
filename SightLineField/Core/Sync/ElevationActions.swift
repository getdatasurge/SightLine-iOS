import Foundation
import Observation
import SwiftData

/// Field-added elevation creation + pane→elevation assignment (M5a), riding the same offline
/// outbox as `WorkLogActions`/`PhotoActions`. Takes the app's one `OutboxWorker` instance rather
/// than building its own — mirrors `PhotoActions`, not `WorkLogActions` (which owns the only
/// `OutboxWorker` in the app): the composition root wires this with
/// `workLogActions.outboxWorker`, so every actions class drains the identical queue instead of
/// racing separate ones.
///
/// Both writes are optimistic + queued, exactly like `WorkLogActions.checkIn`/`checkOut`: mutate
/// the local store as if the call already succeeded, enqueue the real request, kick off a drain
/// without waiting for it. Neither method throws or is `async` — a technician offline never sees
/// an error.
///
/// **Offline-create identity** mirrors `WorkLogActions.checkIn`'s "Keystone" pattern (see that
/// class's doc comment): `addElevation` mints `clientUuid` and inserts the local `Elevation` row
/// with `id == clientUuid`, pinned forever. `OutboxWorker.reconcileElevation` (a successful
/// `.elevationCreate` replay) and `SyncEngine.syncBuildings` (any later buildings-tree sync —
/// the backend echoes `clientUuid` back on a field-added row) both key off this exact identity,
/// so a create followed by a sync never produces two local rows for what the server considers
/// one elevation.
@MainActor
@Observable
final class ElevationActions {
    private let outboxWorker: OutboxWorker
    private let modelContext: ModelContext

    init(outboxWorker: OutboxWorker, modelContext: ModelContext) {
        self.outboxWorker = outboxWorker
        self.modelContext = modelContext
    }

    /// Adds a face the estimator missed while on-site. Mints `clientUuid` — this elevation's
    /// durable identity from this instant on, doubling as the local row's `id` forever — writes
    /// the row immediately with `fieldAdded: true`, and enqueues the real create call.
    ///
    /// `elevationNumber` is server auto-assigned (max within the building + 1) — this optimistic
    /// row computes the identical formula locally, against whatever elevations already exist for
    /// `buildingId` on this device, as a provisional value `OutboxWorker.reconcileElevation`
    /// overwrites with the server's authoritative number once the create succeeds. Usually
    /// matches exactly (the common single-technician-on-this-building-right-now case); when it
    /// doesn't, the row briefly sorts one place off in `JobElevationsView` until that reconcile
    /// lands — never a correctness issue.
    @discardableResult
    func addElevation(buildingId: String, label: String, facing: String?) -> Elevation {
        let clientUuid = UUID().uuidString
        let now = Date()
        let existingNumbers = (try? modelContext.fetch(FetchDescriptor<Elevation>(
            predicate: #Predicate<Elevation> { $0.buildingId == buildingId }
        )))?.map(\.elevationNumber) ?? []
        let model = Elevation(
            id: clientUuid,
            buildingId: buildingId,
            elevationNumber: (existingNumbers.max() ?? 0) + 1,
            label: label,
            facing: facing,
            fieldAdded: true,
            clientUuid: clientUuid,
            updatedAt: now
        )
        modelContext.insert(model)
        enqueue(.elevationCreate, ElevationCreatePayload(buildingId: buildingId, label: label, facing: facing, clientUuid: clientUuid))
        return model
    }

    /// Places an already-synced pane onto a building/elevation face. Mutates the local `Surface`
    /// row's placement links immediately (found by `surfaceId`) — the wire response carries
    /// nothing to reconcile (see `SurveyWriteGateway.assignSurface`'s doc comment), so this
    /// optimistic write IS the final local state; the outbox replay only needs to not throw. A
    /// missing local `Surface` (e.g. not yet synced down) still enqueues the replay — mirrors
    /// `WorkLogActions.checkOut`'s "enqueue regardless, reconcile later" fallback.
    func assignSurface(surfaceId: String, buildingId: String, elevationId: String) {
        if let surface = try? modelContext.fetch(FetchDescriptor<Surface>(
            predicate: #Predicate<Surface> { $0.id == surfaceId }
        )).first {
            surface.buildingId = buildingId
            surface.elevationId = elevationId
            surface.updatedAt = Date()
        }
        enqueue(.surfaceAssign, SurfaceAssignPayload(surfaceId: surfaceId, buildingId: buildingId, elevationId: elevationId))
    }

    /// Inserts a `SyncOutbox` row for `payload` and saves it in the same `ModelContext.save()`
    /// as whatever optimistic mutation the caller above just made, then kicks off a drain
    /// without waiting for it — same shape as `WorkLogActions.enqueue`/`PhotoActions
    /// .enqueuePhoto`.
    private func enqueue<Payload: Encodable>(_ endpoint: OutboxEndpoint, _ payload: Payload) {
        // Strings/Int/optionals — nothing about encoding either payload type can fail; same
        // reasoning as `WorkLogActions.enqueue`'s identical `try!`.
        let data = try! JSONEncoder().encode(payload)
        modelContext.insert(SyncOutbox(clientUuid: UUID().uuidString, endpoint: endpoint.rawValue, payload: data))
        try? modelContext.save()
        outboxWorker.refreshCounts()
        Task { await outboxWorker.drain() }
    }
}
