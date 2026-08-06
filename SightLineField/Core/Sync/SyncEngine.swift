import Foundation
import Observation
import SwiftData
import os

/// Pulls the six M2/M5a collections into SwiftData: per collection, decide full-vs-delta from
/// its watermark (`SyncPlanner.decide`), fetch, upsert newest-wins (`SyncPlanner.planUpserts`),
/// save, then advance the watermark (`SyncPlanner.advance`) — only on success, so a failed
/// collection is retried from the same point next time.
@Observable
@MainActor
final class SyncEngine {
    private(set) var isSyncing = false
    private(set) var lastSyncedAt: Date?
    private(set) var lastSyncError: String?

    private let backend: SyncBackend
    private let modelContext: ModelContext
    private let watermarks: SyncWatermarks

    /// Sync visibility in Console/log-stream — success/failure per collection is otherwise
    /// invisible (no UI surfaces `lastSyncError` yet).
    private static let log = Logger(subsystem: "com.getdatasurge.sightline.field", category: "sync")

    init(backend: SyncBackend, modelContext: ModelContext, watermarks: SyncWatermarks) {
        self.backend = backend
        self.modelContext = modelContext
        self.watermarks = watermarks
    }

    /// Syncs all six collections in turn. A collection's failure is recorded in
    /// `lastSyncError` (collection name + underlying error) but doesn't stop the rest — a
    /// technician who's, say, rate-limited on work-logs should still get their job list
    /// refreshed. `lastSyncedAt` advances to now if *any* collection completed; `lastSyncError`
    /// reflects only this pass (a clean pass clears a stale error from a previous one).
    /// Re-entrant: a call while a sync is already running is a no-op. Cooperatively cancellable
    /// between collections (ios-units-review Important): `Task.isCancelled` is checked at the
    /// top of every loop iteration, so a `BackgroundRefresher` expiry stops this before starting
    /// the *next* collection rather than always running all six to completion regardless — a
    /// collection already `await`ing mid-fetch when cancellation lands is allowed to finish.
    func syncAll() async {
        guard !isSyncing else { return }
        isSyncing = true
        defer { isSyncing = false }

        var succeededAny = false
        var failureMessage: String?

        for collection in SyncCollection.allCases {
            guard !Task.isCancelled else { break }
            do {
                try await sync(collection)
                succeededAny = true
                Self.log.info("sync ok: \(collection.rawValue, privacy: .public)")
            } catch {
                failureMessage = "\(collection.rawValue): \(error)"
                Self.log.error("sync failed: \(collection.rawValue, privacy: .public) — \(String(describing: error), privacy: .public)")
            }
        }

        lastSyncError = failureMessage
        if succeededAny {
            lastSyncedAt = Date()
        }
    }

    private func sync(_ collection: SyncCollection) async throws {
        switch collection {
        case .jobs: try await syncJobs()
        case .appointments: try await syncAppointments()
        case .workTypes: try await syncWorkTypes()
        case .workLogs: try await syncWorkLogs()
        case .surfaces: try await syncSurfaces()
        case .buildings: try await syncBuildings()
        }
    }

    // MARK: - Per-collection sync

    /// The API has no separate street-address field for a job — `JobSummary.address` (the
    /// model's only free-text secondary line) is repurposed to hold the customer's display name
    /// instead, since that's the closest identifying line `/jobs` actually projects.
    private func syncJobs() async throws {
        let watermark = watermarks.get(.jobs)
        let dtos = try await backend.fetchJobs(since: SyncPlanner.decide(watermark: watermark).since)
        guard !dtos.isEmpty else { return }

        let ids = Set(dtos.map(\.id))
        let existing = try modelContext.fetch(FetchDescriptor<JobSummary>(predicate: #Predicate { ids.contains($0.id) }))
        let existingById = Dictionary(uniqueKeysWithValues: existing.map { ($0.id, $0) })
        // `uniquingKeysWith` mirrors `planUpserts`'s own newest-wins tie-break exactly, so the
        // DTO looked up here always matches the `updatedAt` that decided the plan (a page can
        // legitimately contain the same id twice, e.g. a cursor-page overlap).
        let dtoById = Dictionary(dtos.map { ($0.id, $0) }, uniquingKeysWith: { current, new in current.updatedAt >= new.updatedAt ? current : new })

        let plans = SyncPlanner.planUpserts(
            incoming: dtos.map { SyncRecord(id: $0.id, updatedAt: $0.updatedAt) },
            existingIds: Set(existingById.keys)
        )
        for plan in plans {
            guard let dto = dtoById[plan.record.id] else { continue }
            if let model = existingById[plan.record.id] {
                model.name = dto.title ?? dto.number
                model.address = dto.customer?.name
                model.status = dto.status
                model.updatedAt = dto.updatedAt
            } else {
                modelContext.insert(JobSummary(id: dto.id, name: dto.title ?? dto.number, address: dto.customer?.name, status: dto.status, updatedAt: dto.updatedAt))
            }
        }
        try modelContext.save()

        if let advanced = SyncPlanner.advance(current: watermark, seen: dtos.map(\.updatedAt)) {
            watermarks.set(.jobs, to: advanced)
        }
    }

    /// `AppointmentDTO.technicianId` isn't persisted — `Appointment` has no such column yet;
    /// only the fields the local model already declares are copied over. `title` has no wire
    /// equivalent: `notes` (technician-entered) doubles as the display title, falling back to
    /// the linked job's `number`, then a generic label.
    private func syncAppointments() async throws {
        let watermark = watermarks.get(.appointments)
        let dtos = try await backend.fetchAppointments(since: SyncPlanner.decide(watermark: watermark).since)
        guard !dtos.isEmpty else { return }

        let ids = Set(dtos.map(\.id))
        let existing = try modelContext.fetch(FetchDescriptor<Appointment>(predicate: #Predicate { ids.contains($0.id) }))
        let existingById = Dictionary(uniqueKeysWithValues: existing.map { ($0.id, $0) })
        // See `syncJobs`'s `dtoById` comment: mirrors `planUpserts`'s newest-wins tie-break.
        let dtoById = Dictionary(dtos.map { ($0.id, $0) }, uniquingKeysWith: { current, new in current.updatedAt >= new.updatedAt ? current : new })

        let plans = SyncPlanner.planUpserts(
            incoming: dtos.map { SyncRecord(id: $0.id, updatedAt: $0.updatedAt) },
            existingIds: Set(existingById.keys)
        )
        for plan in plans {
            guard let dto = dtoById[plan.record.id] else { continue }
            let title = dto.notes ?? dto.job?.number ?? "Appointment"
            if let model = existingById[plan.record.id] {
                model.jobId = dto.jobId
                model.title = title
                model.start = dto.startsAt
                model.end = dto.endsAt
                model.status = dto.status
                model.updatedAt = dto.updatedAt
            } else {
                modelContext.insert(
                    Appointment(id: dto.id, jobId: dto.jobId, title: title, start: dto.startsAt, end: dto.endsAt, status: dto.status, updatedAt: dto.updatedAt)
                )
            }
        }
        try modelContext.save()

        if let advanced = SyncPlanner.advance(current: watermark, seen: dtos.map(\.updatedAt)) {
            watermarks.set(.appointments, to: advanced)
        }
    }

    /// `WorkTypeDTO.isActive` is optional — the API may still omit it during the M2 rollout.
    /// When present it's applied; when absent, a freshly discovered work type defaults to
    /// active and an existing one's `isActive` is left untouched rather than stomped.
    private func syncWorkTypes() async throws {
        let watermark = watermarks.get(.workTypes)
        let dtos = try await backend.fetchWorkTypes(since: SyncPlanner.decide(watermark: watermark).since)
        guard !dtos.isEmpty else { return }

        let ids = Set(dtos.map(\.id))
        let existing = try modelContext.fetch(FetchDescriptor<WorkType>(predicate: #Predicate { ids.contains($0.id) }))
        let existingById = Dictionary(uniqueKeysWithValues: existing.map { ($0.id, $0) })
        // See `syncJobs`'s `dtoById` comment: mirrors `planUpserts`'s newest-wins tie-break.
        let dtoById = Dictionary(dtos.map { ($0.id, $0) }, uniquingKeysWith: { current, new in current.updatedAt >= new.updatedAt ? current : new })

        let plans = SyncPlanner.planUpserts(
            incoming: dtos.map { SyncRecord(id: $0.id, updatedAt: $0.updatedAt) },
            existingIds: Set(existingById.keys)
        )
        for plan in plans {
            guard let dto = dtoById[plan.record.id] else { continue }
            if let model = existingById[plan.record.id] {
                model.name = dto.name
                model.unit = dto.unit
                if let isActive = dto.isActive {
                    model.isActive = isActive
                }
                model.updatedAt = dto.updatedAt
            } else {
                modelContext.insert(WorkType(id: dto.id, name: dto.name, unit: dto.unit, isActive: dto.isActive ?? true, updatedAt: dto.updatedAt))
            }
        }
        try modelContext.save()

        if let advanced = SyncPlanner.advance(current: watermark, seen: dtos.map(\.updatedAt)) {
            watermarks.set(.workTypes, to: advanced)
        }
    }

    /// A row born from an offline check-in is keyed locally by `clientUuid` (M4 A-I3: its `id`
    /// was client-minted before the server ever assigned one) and stays that way forever, even
    /// after the outbox reconciles the server's own row — see `OutboxWorker.reconcile`'s doc
    /// comment. A wire row from `/work-logs` carries both: `dto.id` (the server's real primary
    /// key) and `dto.clientUuid` (the same client-minted key, echoed back) when it originated
    /// from a clientUuid-keyed check-in (M4 A-B1); `dto.clientUuid` is `nil` for an office-created
    /// row that never went through that path, which falls back to `dto.id` — the same value this
    /// class's own fallback insert below stores as `clientUuid` for such a row. Matching existing
    /// rows by `dto.clientUuid ?? dto.id` against `WorkLog.clientUuid` (never `WorkLog.id`) finds
    /// the right row either way, instead of missing a clientUuid-keyed one (because `dto.id !=
    /// local.id`) and inserting a duplicate.
    private func syncWorkLogs() async throws {
        let watermark = watermarks.get(.workLogs)
        let dtos = try await backend.fetchWorkLogs(since: SyncPlanner.decide(watermark: watermark).since)
        guard !dtos.isEmpty else { return }

        let keys = Set(dtos.map { $0.clientUuid ?? $0.id })
        let existing = try modelContext.fetch(FetchDescriptor<WorkLog>(predicate: #Predicate { keys.contains($0.clientUuid) }))
        let existingByKey = Dictionary(uniqueKeysWithValues: existing.map { ($0.clientUuid, $0) })
        // See `syncJobs`'s `dtoById` comment: mirrors `planUpserts`'s newest-wins tie-break.
        let dtoByKey = Dictionary(
            dtos.map { ($0.clientUuid ?? $0.id, $0) },
            uniquingKeysWith: { current, new in current.updatedAt >= new.updatedAt ? current : new }
        )

        let plans = SyncPlanner.planUpserts(
            incoming: dtos.map { SyncRecord(id: $0.clientUuid ?? $0.id, updatedAt: $0.updatedAt) },
            existingIds: Set(existingByKey.keys)
        )
        for plan in plans {
            guard let dto = dtoByKey[plan.record.id] else { continue }
            if let model = existingByKey[plan.record.id] {
                // `id`/`clientUuid` are left untouched — see the doc comment above.
                model.jobId = dto.jobId
                model.technicianId = dto.technicianId
                model.workTypeId = dto.workTypeId
                model.status = dto.status
                model.checkInAt = dto.checkInAt
                model.checkOutAt = dto.checkOutAt
                model.quantity = dto.quantity
                model.notes = dto.notes
                model.updatedAt = dto.updatedAt
            } else {
                // `id: dto.clientUuid ?? dto.id` — not `dto.id` — so a row born from a
                // clientUuid-keyed check-in ends up with `id == clientUuid` on *every* device
                // that ever inserts it fresh, not just the one that originated it (which pins
                // this via `WorkLogActions.checkIn`/`OutboxWorker.reconcile`, never via this
                // path). Uniform invariant: `id == clientUuid` whenever `clientUuid` is known,
                // full stop — `dto.id` is never sent back to the server by anything in this
                // app (check-out keys by `clientUuid`, not id), so there's no cost to preferring
                // it, and a path-independent invariant is simpler to reason about than one that
                // depends on which device/route first saw the row.
                modelContext.insert(
                    WorkLog(
                        id: dto.clientUuid ?? dto.id,
                        clientUuid: dto.clientUuid ?? dto.id,
                        jobId: dto.jobId,
                        technicianId: dto.technicianId,
                        workTypeId: dto.workTypeId,
                        status: dto.status,
                        checkInAt: dto.checkInAt,
                        checkOutAt: dto.checkOutAt,
                        quantity: dto.quantity,
                        notes: dto.notes,
                        updatedAt: dto.updatedAt
                    )
                )
            }
        }
        try modelContext.save()

        if let advanced = SyncPlanner.advance(current: watermark, seen: dtos.map(\.updatedAt)) {
            watermarks.set(.workLogs, to: advanced)
        }
    }

    /// `SurfaceDTO.notes` isn't persisted (no such column on `Surface` yet). `SurfaceRecord
    /// .jobId` — injected by `LiveSyncBackend` since the wire item itself carries none — is
    /// what actually links the row to its job locally. Dedup is keyed by `dto.surface.clientUuid
    /// ?? dto.surface.id` matched against `Surface.id` (mirrors `syncWorkLogs`/`syncBuildings`'s
    /// elevation dedup): a device-captured pane's local `id == clientUuid` (pinned by
    /// `SurfaceActions.captureSurface`/`OutboxWorker.reconcileSurface`), so the backend echoing
    /// that same `clientUuid` back (M5b GET-projection widening, already shipped) updates the
    /// optimistic row in place instead of inserting a duplicate.
    private func syncSurfaces() async throws {
        let watermark = watermarks.get(.surfaces)
        let dtos = try await backend.fetchSurfaces(since: SyncPlanner.decide(watermark: watermark).since)
        guard !dtos.isEmpty else { return }

        let keys = Set(dtos.map { $0.surface.clientUuid ?? $0.surface.id })
        let existing = try modelContext.fetch(FetchDescriptor<Surface>(predicate: #Predicate { keys.contains($0.id) }))
        let existingByKey = Dictionary(uniqueKeysWithValues: existing.map { ($0.id, $0) })
        // See `syncJobs`'s `dtoById` comment: mirrors `planUpserts`'s newest-wins tie-break.
        let dtoByKey = Dictionary(
            dtos.map { ($0.surface.clientUuid ?? $0.surface.id, $0) },
            uniquingKeysWith: { current, new in current.surface.updatedAt >= new.surface.updatedAt ? current : new }
        )

        let plans = SyncPlanner.planUpserts(
            incoming: dtos.map { SyncRecord(id: $0.surface.clientUuid ?? $0.surface.id, updatedAt: $0.surface.updatedAt) },
            existingIds: Set(existingByKey.keys)
        )
        for plan in plans {
            guard let dto = dtoByKey[plan.record.id] else { continue }
            if let model = existingByKey[plan.record.id] {
                // `id` left untouched (see the method doc). `serverId` is deliberately NOT set
                // here — this slice populates it only via `reconcileSurface`; a `syncSurfaces`
                // widening to also stamp it is a documented future follow-up (`Surface.serverId`).
                model.jobId = dto.jobId
                model.label = dto.surface.label
                model.status = dto.surface.status
                model.buildingId = dto.surface.buildingId
                model.elevationId = dto.surface.elevationId
                model.roomId = dto.surface.roomId
                model.clientUuid = dto.surface.clientUuid
                model.updatedAt = dto.surface.updatedAt
            } else {
                modelContext.insert(
                    Surface(
                        id: dto.surface.clientUuid ?? dto.surface.id,
                        jobId: dto.jobId,
                        label: dto.surface.label,
                        status: dto.surface.status,
                        buildingId: dto.surface.buildingId,
                        elevationId: dto.surface.elevationId,
                        roomId: dto.surface.roomId,
                        clientUuid: dto.surface.clientUuid,
                        updatedAt: dto.surface.updatedAt
                    )
                )
            }
        }
        try modelContext.save()

        if let advanced = SyncPlanner.advance(current: watermark, seen: dtos.map { $0.surface.updatedAt }) {
            watermarks.set(.surfaces, to: advanced)
        }
    }

    /// Buildings nest under one specific job, so unlike the other five collections this can't
    /// just call one `backend.fetchX(since:)` and be done — `fetchBuildings` takes an explicit
    /// `jobId` (see its protocol doc comment). Job ids come from the local store's own
    /// `JobSummary` rows rather than a second live "list every job" network call: `.jobs`
    /// always runs before `.buildings` in `SyncCollection.allCases`, so by the time this runs,
    /// every job this device knows about is already present locally (from this pass or an
    /// earlier one). Each building's tree arrives with its elevations nested
    /// (`BuildingDTO.elevations`); both are flattened and upserted as two independent
    /// newest-wins passes (mirroring every other `syncX`'s dedup/upsert shape exactly), sharing
    /// one `buildings` watermark advanced from every row — building or elevation — actually
    /// seen this pass.
    private func syncBuildings() async throws {
        let watermark = watermarks.get(.buildings)
        let since = SyncPlanner.decide(watermark: watermark).since

        let jobIds = try modelContext.fetch(FetchDescriptor<JobSummary>()).map(\.id)
        var buildingDTOs: [(jobId: String, building: BuildingDTO)] = []
        for jobId in jobIds {
            let dtos = try await backend.fetchBuildings(jobId: jobId, since: since)
            buildingDTOs += dtos.map { (jobId, $0) }
        }
        guard !buildingDTOs.isEmpty else { return }

        let buildingIds = Set(buildingDTOs.map { $0.building.id })
        let existingBuildings = try modelContext.fetch(FetchDescriptor<Building>(predicate: #Predicate { buildingIds.contains($0.id) }))
        let existingBuildingsById = Dictionary(uniqueKeysWithValues: existingBuildings.map { ($0.id, $0) })
        // See `syncJobs`'s `dtoById` comment: mirrors `planUpserts`'s newest-wins tie-break.
        let buildingByRecordId = Dictionary(
            buildingDTOs.map { ($0.building.id, $0) },
            uniquingKeysWith: { current, new in current.building.updatedAt >= new.building.updatedAt ? current : new }
        )

        let buildingPlans = SyncPlanner.planUpserts(
            incoming: buildingDTOs.map { SyncRecord(id: $0.building.id, updatedAt: $0.building.updatedAt) },
            existingIds: Set(existingBuildingsById.keys)
        )
        for plan in buildingPlans {
            guard let entry = buildingByRecordId[plan.record.id] else { continue }
            let dto = entry.building
            if let model = existingBuildingsById[plan.record.id] {
                model.jobId = entry.jobId
                model.name = dto.name
                model.buildingIndex = dto.buildingIndex
                model.notes = dto.notes
                model.updatedAt = dto.updatedAt
            } else {
                modelContext.insert(
                    Building(id: dto.id, jobId: entry.jobId, name: dto.name, buildingIndex: dto.buildingIndex, notes: dto.notes, updatedAt: dto.updatedAt)
                )
            }
        }

        // M5a write lane: keyed by `dto.clientUuid ?? dto.id` — mirrors `syncWorkLogs`'s dedup
        // exactly (see that method's doc comment). A field-added elevation's local row (minted
        // by `ElevationActions.addElevation`, reconciled by `OutboxWorker.reconcileElevation`)
        // has `id == clientUuid` forever; the backend echoes `clientUuid` back on that same row
        // once it's synced down again (`.superpowers/sdd/m5a-backend-report.md`), so matching
        // existing rows against `Elevation.id` (never inserting/matching by bare `dto.id` when
        // a `clientUuid` is present) finds that identical row instead of duplicating it — the
        // create-then-sync acceptance case this dedup exists for. An estimator-created elevation
        // (`dto.clientUuid == nil`) falls back to `dto.id`, unchanged from before this lane.
        let elevationDTOs = buildingDTOs.flatMap(\.building.elevations)
        let elevationKeys = Set(elevationDTOs.map { $0.clientUuid ?? $0.id })
        let existingElevations = try modelContext.fetch(FetchDescriptor<Elevation>(predicate: #Predicate { elevationKeys.contains($0.id) }))
        let existingElevationsByKey = Dictionary(uniqueKeysWithValues: existingElevations.map { ($0.id, $0) })
        let elevationByKey = Dictionary(
            elevationDTOs.map { ($0.clientUuid ?? $0.id, $0) },
            uniquingKeysWith: { current, new in current.updatedAt >= new.updatedAt ? current : new }
        )

        let elevationPlans = SyncPlanner.planUpserts(
            incoming: elevationDTOs.map { SyncRecord(id: $0.clientUuid ?? $0.id, updatedAt: $0.updatedAt) },
            existingIds: Set(existingElevationsByKey.keys)
        )
        for plan in elevationPlans {
            guard let dto = elevationByKey[plan.record.id] else { continue }
            if let model = existingElevationsByKey[plan.record.id] {
                // `id` is left untouched — see the comment above.
                model.buildingId = dto.buildingId
                model.elevationNumber = dto.elevationNumber
                model.numberLabel = dto.numberLabel
                model.label = dto.label
                model.bearing = dto.bearing
                model.facing = dto.facing
                model.fieldAdded = dto.fieldAdded
                model.clientUuid = dto.clientUuid
                // M5b: every path that learns the server's real elevation id persists it —
                // the source of truth a `.surfaceCapture` dispatch resolves `elevationId`
                // against (`OutboxWorker.resolveServerId`). Uniform for estimator-created
                // (`serverId == id`) and field-added (`serverId != id`) rows alike.
                model.serverId = dto.id
                model.updatedAt = dto.updatedAt
            } else {
                modelContext.insert(
                    Elevation(
                        id: dto.clientUuid ?? dto.id,
                        buildingId: dto.buildingId,
                        elevationNumber: dto.elevationNumber,
                        numberLabel: dto.numberLabel,
                        label: dto.label,
                        bearing: dto.bearing,
                        facing: dto.facing,
                        fieldAdded: dto.fieldAdded,
                        clientUuid: dto.clientUuid,
                        serverId: dto.id,
                        updatedAt: dto.updatedAt
                    )
                )
            }
        }
        try modelContext.save()

        let seenUpdatedAts = buildingDTOs.map(\.building.updatedAt) + elevationDTOs.map(\.updatedAt)
        if let advanced = SyncPlanner.advance(current: watermark, seen: seenUpdatedAts) {
            watermarks.set(.buildings, to: advanced)
        }
    }
}

private extension FetchMode {
    var since: Date? {
        switch self {
        case .full: return nil
        case .delta(let since): return since
        }
    }
}
