import Foundation
import SwiftData

@Model
final class JobSummary {
    @Attribute(.unique) var id: String
    var name: String
    var address: String?
    var status: String
    var updatedAt: Date

    init(id: String, name: String, address: String? = nil, status: String, updatedAt: Date) {
        self.id = id
        self.name = name
        self.address = address
        self.status = status
        self.updatedAt = updatedAt
    }
}

@Model
final class Appointment {
    @Attribute(.unique) var id: String
    var jobId: String?
    var title: String
    var start: Date
    var end: Date
    var status: String
    var updatedAt: Date

    init(id: String, jobId: String? = nil, title: String, start: Date, end: Date, status: String, updatedAt: Date) {
        self.id = id
        self.jobId = jobId
        self.title = title
        self.start = start
        self.end = end
        self.status = status
        self.updatedAt = updatedAt
    }
}

@Model
final class WorkType {
    @Attribute(.unique) var id: String
    var name: String
    var unit: String
    var isActive: Bool
    var updatedAt: Date

    init(id: String, name: String, unit: String, isActive: Bool, updatedAt: Date) {
        self.id = id
        self.name = name
        self.unit = unit
        self.isActive = isActive
        self.updatedAt = updatedAt
    }
}

@Model
final class WorkLog {
    @Attribute(.unique) var id: String
    var clientUuid: String
    var jobId: String
    var technicianId: String?
    var workTypeId: String?
    var status: String
    var checkInAt: Date
    var checkOutAt: Date?
    var quantity: Double?
    var notes: String?
    var updatedAt: Date

    init(
        id: String,
        clientUuid: String,
        jobId: String,
        technicianId: String? = nil,
        workTypeId: String? = nil,
        status: String,
        checkInAt: Date,
        checkOutAt: Date? = nil,
        quantity: Double? = nil,
        notes: String? = nil,
        updatedAt: Date
    ) {
        self.id = id
        self.clientUuid = clientUuid
        self.jobId = jobId
        self.technicianId = technicianId
        self.workTypeId = workTypeId
        self.status = status
        self.checkInAt = checkInAt
        self.checkOutAt = checkOutAt
        self.quantity = quantity
        self.notes = notes
        self.updatedAt = updatedAt
    }
}

@Model
final class Surface {
    @Attribute(.unique) var id: String
    var jobId: String
    var label: String
    var status: String
    /// M5a: the building/elevation/room a synced pane has been placed onto, if any — mirrors
    /// the widened `GET /jobs/{id}/surfaces` projection (`SurfaceDTO`). All three are
    /// independently optional: a pane can be unassigned, assigned to a building/elevation only,
    /// grouped into a flat `Room` only, or (in principle) both.
    var buildingId: String?
    var elevationId: String?
    var roomId: String?
    /// M5b device capture (optimistic pane measurement). All `nil` for a pre-M5b synced row;
    /// filled in by `OutboxWorker.reconcileSurface` from the `POST /jobs/{id}/surfaces`
    /// response. `areaSqFt` stays `nil` until then — server-computed and eighth-inch-fraction
    /// aware, deliberately not duplicated client-side (same "derived field stays nil until
    /// reconcile" stance the capture flow documents). `widthFraction`/`heightFraction` are
    /// WinTracker eighth-inch labels ("none"/"1/8"/…).
    var widthIn: Double?
    var heightIn: Double?
    var widthFraction: String?
    var heightFraction: String?
    var quantity: Int?
    var glassType: String?
    var areaSqFt: Double?
    /// The field-captured identity key (M5b), mirroring `Elevation.clientUuid`: minted by
    /// `SurfaceActions.captureSurface` for an offline capture, doubling as this row's own `id`
    /// forever from that instant. `nil` for a pre-existing estimator-synced pane. Optional for
    /// the same lightweight-migration reason `Elevation.clientUuid` is (rows predate the
    /// column).
    var clientUuid: String?
    /// The server's real primary key for this pane (M5b chain resolver) — the wire `entityId` a
    /// `.photoUpload(entityType: "surface")` dispatch resolves to. Populated by
    /// `reconcileSurface` after a `.surfaceCapture` replay succeeds, and (M5c) by `syncSurfaces`
    /// for a pane never captured on this device — both paths converge on `dto.id`, so an
    /// estimator-synced pane's photos resolve too.
    var serverId: String?
    var updatedAt: Date

    init(
        id: String,
        jobId: String,
        label: String,
        status: String,
        buildingId: String? = nil,
        elevationId: String? = nil,
        roomId: String? = nil,
        widthIn: Double? = nil,
        heightIn: Double? = nil,
        widthFraction: String? = nil,
        heightFraction: String? = nil,
        quantity: Int? = nil,
        glassType: String? = nil,
        areaSqFt: Double? = nil,
        clientUuid: String? = nil,
        serverId: String? = nil,
        updatedAt: Date
    ) {
        self.id = id
        self.jobId = jobId
        self.label = label
        self.status = status
        self.buildingId = buildingId
        self.elevationId = elevationId
        self.roomId = roomId
        self.widthIn = widthIn
        self.heightIn = heightIn
        self.widthFraction = widthFraction
        self.heightFraction = heightFraction
        self.quantity = quantity
        self.glassType = glassType
        self.areaSqFt = areaSqFt
        self.clientUuid = clientUuid
        self.serverId = serverId
        self.updatedAt = updatedAt
    }
}

enum OutboxState: String, Codable {
    case pending
    case inFlight
    case conflict
    case done
}

@Model
final class SyncOutbox {
    @Attribute(.unique) var clientUuid: String
    var endpoint: String
    var payload: Data
    var attempts: Int
    var lastError: String?
    var state: String
    var createdAt: Date

    init(clientUuid: String, endpoint: String, payload: Data, attempts: Int = 0, lastError: String? = nil, state: String = OutboxState.pending.rawValue, createdAt: Date = Date()) {
        self.clientUuid = clientUuid
        self.endpoint = endpoint
        self.payload = payload
        self.attempts = attempts
        self.lastError = lastError
        self.state = state
        self.createdAt = createdAt
    }
}
