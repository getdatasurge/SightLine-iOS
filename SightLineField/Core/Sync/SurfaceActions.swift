import Foundation
import Observation
import SwiftData

/// Field pane capture (M5b), riding the same offline outbox as `WorkLogActions`/`PhotoActions`/
/// `ElevationActions`. Takes the app's one `OutboxWorker` instance rather than building its own
/// — mirrors `PhotoActions`/`ElevationActions`, not `WorkLogActions` (which owns the only
/// `OutboxWorker`): the composition root wires this with the same worker, so every actions class
/// drains the identical queue instead of racing separate ones.
///
/// The write is optimistic + queued, exactly like `ElevationActions.addElevation`: mutate the
/// local store as if the call already succeeded, enqueue the real request, kick off a drain
/// without waiting for it. `captureSurface` neither throws nor is `async` — a technician offline
/// never sees an error.
///
/// **Offline-capture identity** mirrors `ElevationActions`' keystone pattern: `captureSurface`
/// mints `clientUuid` and inserts the local `Surface` row with `id == clientUuid`, pinned
/// forever. `OutboxWorker.reconcileSurface` (a successful `.surfaceCapture` replay) keys off this
/// exact identity, upserting the server's authoritative row in place — including
/// `Surface.serverId`, the value the photo-per-surface chain resolver later resolves against.
@MainActor
@Observable
final class SurfaceActions {
    private let outboxWorker: OutboxWorker
    private let modelContext: ModelContext

    init(outboxWorker: OutboxWorker, modelContext: ModelContext) {
        self.outboxWorker = outboxWorker
        self.modelContext = modelContext
    }

    /// Captures a measured pane onto a building/elevation face the technician is standing at.
    /// Mints `clientUuid` — this pane's durable identity from this instant, doubling as the
    /// local row's `id` forever — writes the row immediately with `status: "MEASURED"` (the
    /// `SurfaceStatus` start state, the only status a client-side capture can legitimately
    /// assert) and `areaSqFt: nil` (server-computed/eighth-inch-fraction aware — left `nil`
    /// until `OutboxWorker.reconcileSurface` fills it in from the POST response, never
    /// duplicated client-side), then enqueues the real capture call.
    ///
    /// `buildingId`/`elevationId` are stored as the LOCAL ids passed in (an `Elevation.id`,
    /// i.e. possibly still a `clientUuid` for a field-added elevation not yet synced). The
    /// payload is never rewritten once queued; `OutboxWorker.attempt()` resolves `elevationId`
    /// to `Elevation.serverId` fresh at dispatch time (the chain resolver, see that method) —
    /// so a pane captured onto an elevation field-added in the same offline session just defers
    /// one drain until the elevation's own `.elevationCreate` lands, self-healing via FIFO.
    @discardableResult
    func captureSurface(
        jobId: String, label: String,
        widthIn: Double, heightIn: Double,
        widthFraction: String?, heightFraction: String?,
        quantity: Int?, glassType: String?,
        buildingId: String?, elevationId: String?
    ) -> Surface {
        let clientUuid = UUID().uuidString
        let model = Surface(
            id: clientUuid,
            jobId: jobId,
            label: label,
            status: "MEASURED",
            buildingId: buildingId,
            elevationId: elevationId,
            widthIn: widthIn,
            heightIn: heightIn,
            widthFraction: widthFraction,
            heightFraction: heightFraction,
            quantity: quantity,
            glassType: glassType,
            areaSqFt: nil,
            clientUuid: clientUuid,
            serverId: nil,
            updatedAt: Date()
        )
        modelContext.insert(model)
        enqueue(.surfaceCapture, SurfaceCapturePayload(
            jobId: jobId, label: label, widthIn: widthIn, heightIn: heightIn,
            widthFraction: widthFraction, heightFraction: heightFraction,
            quantity: quantity, glassType: glassType,
            buildingId: buildingId, elevationId: elevationId, clientUuid: clientUuid
        ))
        return model
    }

    /// Inserts a `SyncOutbox` row for `payload` and saves it in the same `ModelContext.save()`
    /// as the optimistic insert above, then kicks off a drain without waiting for it — same
    /// shape as `ElevationActions.enqueue`/`WorkLogActions.enqueue`.
    private func enqueue<Payload: Encodable>(_ endpoint: OutboxEndpoint, _ payload: Payload) {
        // Strings/Double/Int/optionals — nothing about encoding this payload can fail; same
        // reasoning as `ElevationActions.enqueue`'s identical `try!`.
        let data = try! JSONEncoder().encode(payload)
        modelContext.insert(SyncOutbox(clientUuid: UUID().uuidString, endpoint: endpoint.rawValue, payload: data))
        try? modelContext.save()
        outboxWorker.refreshCounts()
        Task { await outboxWorker.drain() }
    }
}
