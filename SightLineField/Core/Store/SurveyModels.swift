import Foundation
import SwiftData

/// Building/Elevation read-only local mirrors (M5a). A job's buildings are almost always
/// estimator-created on the web before a technician arrives (office already ran the walk-mode
/// trace or a manual add) — this slice only syncs that hierarchy down for on-device viewing, via
/// `SyncEngine.syncBuildings()`. No `clientUuid`/on-device creation yet: field-added elevations
/// and pane placement are a later M5 write lane (`.superpowers/m5-survey-scout.md` §5, M5a scope
/// note) — every row here originates server-side and is only ever upserted, never written back.

/// A survey building, scoped to one job. Field list per `.superpowers/sdd/m5a-backend-report.md`
/// / `.superpowers/m5-survey-scout.md` §1 — price-blind, no address/footprint/map fields (those
/// exist server-side but aren't part of this slice's local mirror).
@Model
final class Building {
    @Attribute(.unique) var id: String
    var jobId: String
    var name: String
    var buildingIndex: Int
    var notes: String?
    var updatedAt: Date

    init(id: String, jobId: String, name: String, buildingIndex: Int, notes: String? = nil, updatedAt: Date) {
        self.id = id
        self.jobId = jobId
        self.name = name
        self.buildingIndex = buildingIndex
        self.notes = notes
        self.updatedAt = updatedAt
    }
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
    var label: String
    var bearing: Int?
    var facing: String?
    var fieldAdded: Bool
    var updatedAt: Date

    init(
        id: String,
        buildingId: String,
        elevationNumber: Int,
        numberLabel: String? = nil,
        label: String,
        bearing: Int? = nil,
        facing: String? = nil,
        fieldAdded: Bool,
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
        self.updatedAt = updatedAt
    }
}
