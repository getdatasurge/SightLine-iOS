import Foundation
import Observation
import SwiftData

/// Pulls the five M2 collections into SwiftData: per collection, decide full-vs-delta from its
/// watermark (`SyncPlanner.decide`), fetch, upsert newest-wins (`SyncPlanner.planUpserts`), save,
/// then advance the watermark (`SyncPlanner.advance`) — only on success, so a failed collection
/// is retried from the same point next time.
@Observable
@MainActor
final class SyncEngine {
    private(set) var isSyncing = false
    private(set) var lastSyncedAt: Date?
    private(set) var lastSyncError: String?

    private let backend: SyncBackend
    private let modelContext: ModelContext
    private let watermarks: SyncWatermarks

    init(backend: SyncBackend, modelContext: ModelContext, watermarks: SyncWatermarks) {
        self.backend = backend
        self.modelContext = modelContext
        self.watermarks = watermarks
    }

    /// Syncs all five collections in turn. A collection's failure is recorded in
    /// `lastSyncError` (collection name + underlying error) but doesn't stop the rest — a
    /// technician who's, say, rate-limited on work-logs should still get their job list
    /// refreshed. `lastSyncedAt` advances to now if *any* collection completed; `lastSyncError`
    /// reflects only this pass (a clean pass clears a stale error from a previous one).
    /// Re-entrant: a call while a sync is already running is a no-op.
    func syncAll() async {
        guard !isSyncing else { return }
        isSyncing = true
        defer { isSyncing = false }

        var succeededAny = false
        var failureMessage: String?

        for collection in SyncCollection.allCases {
            do {
                try await sync(collection)
                succeededAny = true
            } catch {
                failureMessage = "\(collection.rawValue): \(error)"
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
                model.name = dto.title
                model.address = dto.customer?.name
                model.status = dto.status
                model.updatedAt = dto.updatedAt
            } else {
                modelContext.insert(JobSummary(id: dto.id, name: dto.title, address: dto.customer?.name, status: dto.status, updatedAt: dto.updatedAt))
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

    /// `WorkLogDTO.technicianId` isn't persisted (no such column on `WorkLog` yet).
    /// `clientUuid` is the local offline-create idempotency key — a server-sourced log has no
    /// such thing, so it reuses the server `id` (deterministic, always non-empty, and
    /// incidentally distinguishable from a locally-created-then-synced row, whose `clientUuid`
    /// would be a client-generated UUID instead).
    private func syncWorkLogs() async throws {
        let watermark = watermarks.get(.workLogs)
        let dtos = try await backend.fetchWorkLogs(since: SyncPlanner.decide(watermark: watermark).since)
        guard !dtos.isEmpty else { return }

        let ids = Set(dtos.map(\.id))
        let existing = try modelContext.fetch(FetchDescriptor<WorkLog>(predicate: #Predicate { ids.contains($0.id) }))
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
                model.jobId = dto.jobId
                model.workTypeId = dto.workTypeId
                model.status = dto.status
                model.checkInAt = dto.checkInAt
                model.checkOutAt = dto.checkOutAt
                model.quantity = dto.quantity
                model.notes = dto.notes
                model.updatedAt = dto.updatedAt
            } else {
                modelContext.insert(
                    WorkLog(
                        id: dto.id,
                        clientUuid: dto.id,
                        jobId: dto.jobId,
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
    /// what actually links the row to its job locally.
    private func syncSurfaces() async throws {
        let watermark = watermarks.get(.surfaces)
        let dtos = try await backend.fetchSurfaces(since: SyncPlanner.decide(watermark: watermark).since)
        guard !dtos.isEmpty else { return }

        let ids = Set(dtos.map { $0.surface.id })
        let existing = try modelContext.fetch(FetchDescriptor<Surface>(predicate: #Predicate { ids.contains($0.id) }))
        let existingById = Dictionary(uniqueKeysWithValues: existing.map { ($0.id, $0) })
        // See `syncJobs`'s `dtoById` comment: mirrors `planUpserts`'s newest-wins tie-break.
        let dtoById = Dictionary(dtos.map { ($0.surface.id, $0) }, uniquingKeysWith: { current, new in current.surface.updatedAt >= new.surface.updatedAt ? current : new })

        let plans = SyncPlanner.planUpserts(
            incoming: dtos.map { SyncRecord(id: $0.surface.id, updatedAt: $0.surface.updatedAt) },
            existingIds: Set(existingById.keys)
        )
        for plan in plans {
            guard let dto = dtoById[plan.record.id] else { continue }
            if let model = existingById[plan.record.id] {
                model.jobId = dto.jobId
                model.label = dto.surface.label
                model.status = dto.surface.status
                model.updatedAt = dto.surface.updatedAt
            } else {
                modelContext.insert(Surface(id: dto.surface.id, jobId: dto.jobId, label: dto.surface.label, status: dto.surface.status, updatedAt: dto.surface.updatedAt))
            }
        }
        try modelContext.save()

        if let advanced = SyncPlanner.advance(current: watermark, seen: dtos.map { $0.surface.updatedAt }) {
            watermarks.set(.surfaces, to: advanced)
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
