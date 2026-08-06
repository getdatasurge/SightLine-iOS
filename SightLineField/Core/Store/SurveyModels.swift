import Foundation
import SwiftData

/// Building/Elevation local mirrors (M5a). A job's buildings are almost always estimator-created
/// on the web before a technician arrives (office already ran the walk-mode trace or a manual
/// add) — most rows here still only ever arrive via `SyncEngine.syncBuildings()`. As of the M5a
/// write lane, `Elevation` can ALSO originate on-device: `ElevationActions.addElevation` mints a
/// field-added row directly (`fieldAdded: true`, `clientUuid` pinned to its own `id` forever —
/// see that method's doc comment) and `ElevationActions.assignSurface` places a `Surface` onto
/// one, both replayed through the offline outbox (`OutboxWorker`) exactly like `WorkLog`'s
/// check-in/check-out. `Building` itself is still read-only — nothing in this slice creates one
/// on-device, and assign-pane UI isn't wired into any view yet (`JobElevationsView.swift`'s doc
/// comment) — only the write plumbing landed this pass.

/// A survey building, scoped to one job. Field list per `.superpowers/sdd/m5a-backend-report.md`
/// / `.superpowers/m5-survey-scout.md` §1 — price-blind, no address/footprint/map fields (those
/// exist server-side but aren't part of this slice's local mirror).
@Model
final class Building {
    @Attribute(.unique) var id: String
    var jobId: String
    /// Optional: an estimator may leave a building unnamed (backend sends `name: null`); it's
    /// then identified only by `buildingIndex`.
    var name: String?
    var buildingIndex: Int
    var notes: String?
    var updatedAt: Date

    init(id: String, jobId: String, name: String? = nil, buildingIndex: Int, notes: String? = nil, updatedAt: Date) {
        self.id = id
        self.jobId = jobId
        self.name = name
        self.buildingIndex = buildingIndex
        self.notes = notes
        self.updatedAt = updatedAt
    }

    /// A never-empty label for UI: the estimator's `name`, or `"Building N"` when unnamed.
    var displayName: String { name ?? "Building \(buildingIndex)" }
}

/// One face of a `Building`. `bearing`/`facing` are optional — an elevation can exist before the
/// orientation engine (or a field tech) has set either. `fieldAdded` flags a face an installer
/// discovered on-site rather than one the estimator planned ahead of time.
@Model
final class Elevation {
    @Attribute(.unique) var id: String
    var buildingId: String
    var elevationNumber: Int
    var numberLabel: String?
    /// Optional: an estimator-planned elevation may be unnamed (backend sends `label: null`);
    /// only `elevationNumber`/`numberLabel` identify it then. A field-added row always carries
    /// the technician's entered label.
    var label: String?
    var bearing: Int?
    var facing: String?
    var fieldAdded: Bool
    /// The field-added identity key (M5a), mirroring `WorkLog.clientUuid`'s role: minted by
    /// `ElevationActions.addElevation` for an offline create, doubling as this row's own `id`
    /// forever from that instant on (never remapped once the outbox reconciles the server's
    /// row — see that method's doc comment). `nil` for the common case, an estimator-planned
    /// elevation that never went through a field-add. Kept optional (unlike `WorkLog
    /// .clientUuid`, always non-nil): `Elevation` already had rows on-device before this column
    /// existed (the M5a read-only sync shipped first), so a non-optional column would need a
    /// shared placeholder default applied to every pre-existing row on lightweight migration —
    /// a uniqueness hazard `WorkLog` never risked, since it was born with this column from day
    /// one. Identity/dedup logic (`SyncEngine.syncBuildings`, `OutboxWorker.reconcileElevation`)
    /// therefore always matches on `id`, never this field — see both doc comments.
    var clientUuid: String?
    /// The server's real primary key for this elevation (M5b chain resolver). Populated on
    /// EVERY path that ever learns it — `OutboxWorker.reconcileElevation` after a successful
    /// `.elevationCreate` replay, and `SyncEngine.syncBuildings`'s upsert (both insert and
    /// update branches) — regardless of whether the row also carries a `clientUuid`. For an
    /// estimator-created elevation (`clientUuid == nil`) this is trivially `serverId == id`
    /// (both are `dto.id`); for a field-added one it's `nil` only during the brief window
    /// between `ElevationActions.addElevation` minting the row (`id == clientUuid`, no server
    /// id yet) and that row's own `.elevationCreate` succeeding. The single source of truth for
    /// the wire `elevationId` a `.surfaceCapture` dispatch resolves to — see
    /// `OutboxWorker.resolveServerId`.
    var serverId: String?
    var updatedAt: Date

    init(
        id: String,
        buildingId: String,
        elevationNumber: Int,
        numberLabel: String? = nil,
        label: String? = nil,
        bearing: Int? = nil,
        facing: String? = nil,
        fieldAdded: Bool,
        clientUuid: String? = nil,
        serverId: String? = nil,
        updatedAt: Date
    ) {
        self.id = id
        self.buildingId = buildingId
        self.elevationNumber = elevationNumber
        self.numberLabel = numberLabel
        self.label = label
        self.bearing = bearing
        self.facing = facing
        self.fieldAdded = fieldAdded
        self.clientUuid = clientUuid
        self.serverId = serverId
        self.updatedAt = updatedAt
    }
}
