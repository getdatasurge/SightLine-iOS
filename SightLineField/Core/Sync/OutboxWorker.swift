import Foundation
import Observation
import SwiftData

// MARK: - Outbox payloads

/// Wire body for a queued `POST /work-logs/check-in` replay — mirrors `WorkLogGateway
/// .checkIn`'s parameters exactly (`clientUuid` included, since the live call needs it as an
/// argument, not something it can read back out of anything else) so `OutboxWorker.drain()` can
/// decode one straight out of `SyncOutbox.payload` and call through unchanged.
struct CheckInPayload: Codable, Sendable, Equatable {
    let jobId: String
    let workTypeId: String?
    let notes: String?
    let clientUuid: String
}

/// Wire body for a queued `POST /work-logs/check-out` replay — mirrors `WorkLogGateway
/// .checkOut`'s parameters exactly.
struct CheckOutPayload: Codable, Sendable, Equatable {
    let workLogClientUuid: String
    let quantity: Double?
    let notes: String?
}

/// Wire payload for a queued `POST /uploads` replay (M4b) — the picked image's bytes travel
/// inside the `SyncOutbox` row itself (`Data`'s default `Codable` encoding, base64 on the wire)
/// rather than a file-system reference, so a queued photo survives even if whatever produced
/// `imageData` (e.g. a `PhotosPickerItem`'s transferable load) is long gone by the time
/// `drain()` actually replays it. `filename`/`mimeType` are minted once at enqueue time
/// (`PhotoActions.enqueuePhoto`), not re-derived per attempt, so a retry after a transient
/// failure sends byte-for-byte the same multipart part every time.
struct PhotoUploadPayload: Codable, Sendable, Equatable {
    let entityType: String
    let entityId: String
    let filename: String
    let mimeType: String
    let imageData: Data
}

/// Wire body for a queued `POST /buildings/{id}/elevations` replay (M5a) — mirrors
/// `SurveyWriteGateway.createElevation`'s parameters exactly, `clientUuid` included for the
/// same reason `CheckInPayload`'s doc comment gives: the live call needs it as an argument, not
/// something it can read back out of anything else.
struct ElevationCreatePayload: Codable, Sendable, Equatable {
    let buildingId: String
    let label: String
    let facing: String?
    let clientUuid: String
}

/// Wire body for a queued `POST /surfaces/{id}/assign` replay (M5a) — mirrors
/// `SurveyWriteGateway.assignSurface`'s parameters exactly. No `clientUuid`: the route is
/// naturally idempotent (see that method's doc comment), so there's no idempotency key to
/// thread through a replay.
struct SurfaceAssignPayload: Codable, Sendable, Equatable {
    let surfaceId: String
    let buildingId: String
    let elevationId: String
}

/// The operations a `SyncOutbox` row can target. Raw values are what `WorkLogActions`/
/// `PhotoActions`/`ElevationActions` store verbatim in `SyncOutbox.endpoint`; `OutboxWorker
/// .drain()` dispatches on them to pick both the payload type to decode and where to replay:
/// `WorkLogGateway` for the first two, `OutboxWorker.photoGateway` for the third (M4b),
/// `OutboxWorker.surveyGateway` for the last two (M5a).
enum OutboxEndpoint: String, Sendable {
    case checkIn = "work-logs/check-in"
    case checkOut = "work-logs/check-out"
    /// `POST /uploads` (M4b, append-only photo capture). Unlike check-in/check-out, this route
    /// has no client-supplied idempotency key, so a replay after this device sent the request
    /// but never saw the response could upload the same photo twice server-side — accepted for
    /// M4b (matches the spec's "at-least-once" outbox model; no worse than any other endpoint
    /// replaying after a lost response), flagged here rather than silently assumed exactly-once.
    case photoUpload = "uploads"
    /// `POST /buildings/{id}/elevations` (M5a, field-added elevation). `clientUuid`-keyed —
    /// idempotent on replay, same shape as check-in.
    case elevationCreate = "buildings/elevations"
    /// `POST /surfaces/{id}/assign` (M5a, pane→elevation placement). No idempotency key needed
    /// — see `SurveyWriteGateway.assignSurface`'s doc comment.
    case surfaceAssign = "surfaces/assign"
}

// MARK: - OutboxWorker

/// Drains the offline write queue (M4 A-I2). `WorkLogActions.checkIn`/`checkOut` write the
/// local store optimistically and enqueue a `SyncOutbox` row; this class is the only thing that
/// ever actually calls `WorkLogGateway` for those rows, replaying them oldest-first
/// (`SyncOutbox.createdAt` — its FIFO ordinal) whenever `drain()` runs.
///
/// Per-item outcome, per `docs/superpowers/specs/2026-08-05-m4-offline-outbox.md`:
/// - `2xx` → the row is deleted (M4a-review Minor #4 — nothing ever reads a `.done` row again,
///   so leaving it around just grows the table unbounded) and the local `WorkLog` is reconciled
///   from the server's row (keyed by `clientUuid`, never the server's own row id — see
///   `reconcile`'s doc comment).
/// - `400/403/404/409` ("4xx-conflict") → `.conflict` immediately, not gated by `attempts` — a
///   business rejection that replaying the identical request will never turn into a success.
/// - `network` / `401` / `429` / `5xx` (transient/environmental) → `attempts += 1`, stays
///   `.pending` for a future retry — unless `attempts` has now reached `maxAttempts`, which
///   forces `.conflict` too (bounded retries, surfaced via `conflictCount` for a manual
///   `retry(clientUuid:)`, never silently dropped).
/// - `network`/`401` specifically also **stop the whole pass**: every other queued item would
///   fail the exact same way against a dead connection or an invalidated session, so there's no
///   point burning through each one's `attempts` budget over a single offline blip. A lone
///   `429`/`5xx` on one item doesn't imply the same about the rest, so those don't stop the loop.
///
/// **Dependent ordering within a pass** (m4a-review Important #2): a check-out only ever makes
/// sense once its check-in has actually landed server-side. If an earlier row in this same pass
/// (by construction, always a check-in — nothing else has same-clientUuid dependents) fails —
/// transiently (stays `.pending`/hits `maxAttempts`) or permanently (4xx) — its `clientUuid` is
/// remembered in `runPass`'s `failedWorkLogClientUuidsThisPass`, and every later row targeting
/// that same work-log is *skipped* (left exactly as fetched) rather than attempted: replaying a
/// check-out against a work-log the server never created would 404 → `classify` → a *permanent*
/// `.conflict` the check-in's own later success can never un-stick. A skipped row simply waits
/// for the next `drain()` call.
///
/// **Re-fetch until stable** (m4a-review Minor #5): a row enqueued *during* this call — e.g. a
/// second `WorkLogActions.checkOut` from another view while this pass is mid-`await` — misses
/// the fetch snapshot its own fire-and-forget `Task { drain() }` no-ops against (re-entrancy
/// guard), and would otherwise sit untouched until the next external trigger. `drain()` re-fetches
/// after every pass and loops again *only* while the fetched id set actually changed since the
/// last pass — a row still `.pending` purely because it genuinely failed again (or was deferred
/// per the above) does not get hammered in a tight loop; `Self.maxPassesPerDrain` is a hard,
/// purely-defensive cap on top of that, never expected to bind in practice.
///
/// Re-entrant-safe: `drain()` called while already draining is a no-op, so triggering it from
/// several places at once (foreground, reconnect, every `WorkLogActions` enqueue) never runs two
/// passes over the same rows concurrently. `isHeld` (set externally, e.g. a UI-test launch hook)
/// makes it a no-op too — checked again between internal passes, not just at entry, so flipping
/// it mid-drain stops the *next* pass from starting. Cooperatively cancellable: `Task.isCancelled`
/// is checked between passes and between each item within a pass (not while an item's own
/// request is actually in flight — an already-started request is allowed to finish, only a
/// not-yet-started one is skipped), so a `BackgroundRefresher` expiry stops this promptly instead
/// of running the whole queue to completion regardless (ios-units-review Important).
@MainActor
@Observable
final class OutboxWorker {
    private(set) var isDraining = false

    /// External pause switch — `drain()` (both the initial call and every internal re-fetch
    /// pass) no-ops while this is `true`. Not used by anything in this file; exists for a UI
    /// test to freeze outbox activity so it can assert on a stable "N pending" state without
    /// racing a live drain (set by the composition root from a launch-argument hook).
    var isHeld = false

    /// Rows still waiting on a successful replay — queued or actively being sent. A stored,
    /// `@Observable`-tracked mirror of a `fetchCount` query (ios-units-review Minor: the old
    /// computed-property version read no stored state, so SwiftUI registered no dependency and
    /// `SettingsSheet` never refreshed while open), recomputed by `refreshCounts()` after every
    /// `modelContext.save()` this class makes, plus once more from `WorkLogActions.enqueue`
    /// after *its* save (a new row lands directly on the shared context, not through this
    /// class) — so a technician watching `SettingsSheet` sees this tick the instant a
    /// check-in/check-out/photo is queued or resolved, not just once a drain pass happens to run.
    private(set) var pendingCount = 0

    /// Rows that gave up — a permanent rejection or `maxAttempts` exhausted — and need either a
    /// human to look or a manual `retry(clientUuid:)`. Same stored/reactive shape as
    /// `pendingCount`, same reasoning.
    private(set) var conflictCount = 0

    private let gateway: WorkLogGateway
    private let modelContext: ModelContext
    private let maxAttempts = 6

    /// Hard cap on internal re-fetch passes within one `drain()` call — see the class doc
    /// comment's "Re-fetch until stable" section. Generous on purpose: real usage never stacks
    /// more than a handful of mid-pass enqueues, so this is pure defense-in-depth against a
    /// pathological loop, not a number tuned to any expected workload.
    private static let maxPassesPerDrain = 20

    /// Additive dependency for M4b (photo outbox) — deliberately not an `init` parameter, so
    /// `WorkLogActions`'s existing `OutboxWorker(gateway:modelContext:)` call site (and every
    /// existing test) keeps compiling unchanged. `nil` until the composition root
    /// (`AppDependencies`) sets it post-construction; `attempt()` treats a `.photoUpload` row
    /// with no gateway wired as a transient, non-pass-stopping failure rather than crashing, so
    /// a photo enqueued before wiring happens — or a test/preview `OutboxWorker` that never
    /// wires one at all — just stays queued instead of taking down the whole drain pass (or
    /// blocking unrelated check-in/check-out rows behind it).
    var photoGateway: PhotoUploadGateway?

    /// Additive dependency for M5a (survey writes) — same reasoning as `photoGateway` above:
    /// not an `init` parameter, so `WorkLogActions`'s `OutboxWorker(gateway:modelContext:)` call
    /// site (and every existing test) keeps compiling unchanged. `nil` until the composition
    /// root sets it post-construction; `attempt()` treats an `.elevationCreate`/`.surfaceAssign`
    /// row with no gateway wired as a transient, non-pass-stopping failure rather than crashing.
    var surveyGateway: SurveyWriteGateway?

    init(gateway: WorkLogGateway, modelContext: ModelContext) {
        self.gateway = gateway
        self.modelContext = modelContext
        refreshCounts()
    }

    /// Recomputes `pendingCount`/`conflictCount` from the store. `OutboxWorker` calls this
    /// itself after every save it makes (via `saveAndRefreshCounts()`); `WorkLogActions.enqueue`
    /// calls it directly after its own save, since that row lands on the shared `modelContext`
    /// without going through this class at all.
    func refreshCounts() {
        let pending = OutboxState.pending.rawValue
        let inFlight = OutboxState.inFlight.rawValue
        let conflict = OutboxState.conflict.rawValue
        pendingCount = (try? modelContext.fetchCount(FetchDescriptor<SyncOutbox>(
            predicate: #Predicate<SyncOutbox> { $0.state == pending || $0.state == inFlight }
        ))) ?? 0
        conflictCount = (try? modelContext.fetchCount(FetchDescriptor<SyncOutbox>(
            predicate: #Predicate<SyncOutbox> { $0.state == conflict }
        ))) ?? 0
    }

    /// `modelContext.save()` + `refreshCounts()` in one call — every mutating save this class
    /// makes goes through this rather than a bare `try? modelContext.save()`, so `pendingCount`/
    /// `conflictCount` never drift from what's actually persisted.
    private func saveAndRefreshCounts() {
        try? modelContext.save()
        refreshCounts()
    }

    /// Replays every queued item oldest-first, re-fetching and looping until the queue is
    /// stable: `.pending` rows, plus any `.inFlight` left over from a run that never got to
    /// record an outcome (e.g. the app was killed mid-request) — self-healing, since nothing
    /// else ever revives a stuck `.inFlight` row. See the class doc comment for the full
    /// per-item outcome rules, the dependent-ordering guard, the re-fetch loop, and cancellation.
    func drain() async {
        guard !isDraining, !isHeld else { return }
        isDraining = true
        defer { isDraining = false }

        var previouslyFetchedIDs: Set<PersistentIdentifier>?
        for _ in 0..<Self.maxPassesPerDrain {
            guard !isHeld, !Task.isCancelled else { return }

            guard let items = fetchPendingOrInFlight(), !items.isEmpty else { return }

            let fetchedIDs = Set(items.map(\.persistentModelID))
            if fetchedIDs == previouslyFetchedIDs { return }
            previouslyFetchedIDs = fetchedIDs

            if await runPass(items) { return }
        }
    }

    private func fetchPendingOrInFlight() -> [SyncOutbox]? {
        let pending = OutboxState.pending.rawValue
        let inFlight = OutboxState.inFlight.rawValue
        var descriptor = FetchDescriptor<SyncOutbox>(
            predicate: #Predicate<SyncOutbox> { $0.state == pending || $0.state == inFlight }
        )
        descriptor.sortBy = [SortDescriptor(\.createdAt)]
        return try? modelContext.fetch(descriptor)
    }

    /// One FIFO pass over `items` (a fetch snapshot `drain()` took at the top of a loop
    /// iteration). Returns `true` when `drain()` should stop entirely rather than looping for
    /// another pass — a `network`/`401` transient failure (see the class doc comment) or a
    /// cancellation observed between items — `false` when the pass ran to completion (possibly
    /// with some rows deferred as an unresolved dependent, or left `.pending` for a bounded
    /// retry).
    private func runPass(_ items: [SyncOutbox]) async -> Bool {
        var failedWorkLogClientUuidsThisPass: Set<String> = []

        for item in items {
            if Task.isCancelled { return true }

            if let workLogUuid = workLogClientUuid(for: item), failedWorkLogClientUuidsThisPass.contains(workLogUuid) {
                // This row's dependency (its check-in) didn't reach the server this pass —
                // replaying it now would 404 into a permanent conflict it can never recover
                // from on its own. Leave it exactly as fetched; it retries next pass.
                continue
            }

            item.state = OutboxState.inFlight.rawValue
            saveAndRefreshCounts()

            switch await attempt(item) {
            case .success:
                // Minor #4: nothing ever reads a `.done` row again — delete rather than retain
                // it, so the table doesn't grow unbounded over the app's life.
                modelContext.delete(item)
                saveAndRefreshCounts()
            case .permanentFailure(let message):
                item.state = OutboxState.conflict.rawValue
                item.lastError = message
                saveAndRefreshCounts()
                if let workLogUuid = workLogClientUuid(for: item) {
                    failedWorkLogClientUuidsThisPass.insert(workLogUuid)
                }
            case .transientFailure(let message, let stopsPass):
                item.attempts += 1
                item.lastError = message
                item.state = item.attempts >= maxAttempts ? OutboxState.conflict.rawValue : OutboxState.pending.rawValue
                saveAndRefreshCounts()
                if let workLogUuid = workLogClientUuid(for: item) {
                    failedWorkLogClientUuidsThisPass.insert(workLogUuid)
                }
                if stopsPass { return true }
            }
        }
        return false
    }

    /// Un-sticks a `.conflict` row so the next `drain()` picks it back up. Resets `attempts` to
    /// 0 — a manual retry gets a full fresh budget rather than immediately re-conflicting on the
    /// very next transient failure. Does not drain itself: per the spec, the caller (e.g. a
    /// settings retry button) triggers that separately, so retrying several conflicted rows only
    /// needs one subsequent drain pass rather than one per row. A no-op for an unknown
    /// `clientUuid` or a row that isn't currently `.conflict`.
    func retry(clientUuid: String) {
        let conflict = OutboxState.conflict.rawValue
        guard let item = try? modelContext.fetch(FetchDescriptor<SyncOutbox>(
            predicate: #Predicate<SyncOutbox> { $0.clientUuid == clientUuid }
        )).first, item.state == conflict else { return }
        item.state = OutboxState.pending.rawValue
        item.attempts = 0
        item.lastError = nil
        saveAndRefreshCounts()
    }

    // MARK: - Per-item dispatch

    private enum Outcome {
        case success
        case permanentFailure(String)
        case transientFailure(String, stopsPass: Bool)
    }

    private func attempt(_ item: SyncOutbox) async -> Outcome {
        guard let endpoint = OutboxEndpoint(rawValue: item.endpoint) else {
            return .permanentFailure("unrecognized outbox endpoint '\(item.endpoint)'")
        }
        switch endpoint {
        case .checkIn:
            guard let payload = try? JSONDecoder().decode(CheckInPayload.self, from: item.payload) else {
                return .permanentFailure("undecodable check-in payload")
            }
            do {
                let dto = try await gateway.checkIn(jobId: payload.jobId, workTypeId: payload.workTypeId, notes: payload.notes, clientUuid: payload.clientUuid)
                reconcile(dto, clientUuid: payload.clientUuid, source: .checkIn)
                return .success
            } catch {
                return classify(error)
            }
        case .checkOut:
            guard let payload = try? JSONDecoder().decode(CheckOutPayload.self, from: item.payload) else {
                return .permanentFailure("undecodable check-out payload")
            }
            do {
                let dto = try await gateway.checkOut(workLogClientUuid: payload.workLogClientUuid, quantity: payload.quantity, notes: payload.notes)
                reconcile(dto, clientUuid: payload.workLogClientUuid, source: .checkOut)
                return .success
            } catch {
                return classify(error)
            }
        case .photoUpload:
            guard let payload = try? JSONDecoder().decode(PhotoUploadPayload.self, from: item.payload) else {
                return .permanentFailure("undecodable photo-upload payload")
            }
            guard let photoGateway else {
                return .transientFailure("photo upload gateway not configured", stopsPass: false)
            }
            do {
                try await photoGateway.upload(
                    entityType: payload.entityType, entityId: payload.entityId,
                    imageData: payload.imageData, filename: payload.filename, mimeType: payload.mimeType
                )
                return .success
            } catch {
                return classify(error)
            }
        case .elevationCreate:
            guard let payload = try? JSONDecoder().decode(ElevationCreatePayload.self, from: item.payload) else {
                return .permanentFailure("undecodable elevation-create payload")
            }
            guard let surveyGateway else {
                return .transientFailure("survey gateway not configured", stopsPass: false)
            }
            do {
                let dto = try await surveyGateway.createElevation(
                    buildingId: payload.buildingId, label: payload.label, facing: payload.facing, clientUuid: payload.clientUuid
                )
                reconcileElevation(dto, clientUuid: payload.clientUuid)
                return .success
            } catch {
                return classify(error)
            }
        case .surfaceAssign:
            guard let payload = try? JSONDecoder().decode(SurfaceAssignPayload.self, from: item.payload) else {
                return .permanentFailure("undecodable surface-assign payload")
            }
            guard let surveyGateway else {
                return .transientFailure("survey gateway not configured", stopsPass: false)
            }
            do {
                try await surveyGateway.assignSurface(surfaceId: payload.surfaceId, buildingId: payload.buildingId, elevationId: payload.elevationId)
                return .success
            } catch {
                return classify(error)
            }
        }
    }

    /// The work-log `clientUuid` a check-in/check-out row targets — used only to detect
    /// same-pass dependency ordering (see the class doc comment's "Dependent ordering" section).
    /// `nil` for a photo upload or an unrecognized endpoint, neither of which has a same-pass
    /// dependent to protect.
    private func workLogClientUuid(for item: SyncOutbox) -> String? {
        guard let endpoint = OutboxEndpoint(rawValue: item.endpoint) else { return nil }
        switch endpoint {
        case .checkIn:
            return (try? JSONDecoder().decode(CheckInPayload.self, from: item.payload))?.clientUuid
        case .checkOut:
            return (try? JSONDecoder().decode(CheckOutPayload.self, from: item.payload))?.workLogClientUuid
        case .photoUpload, .elevationCreate, .surfaceAssign:
            return nil
        }
    }

    /// Buckets a thrown `WorkLogGateway` error into a drain outcome. `.unauthorized` (401) is
    /// treated like `.network` — a bad session, not a bad row; retrying the identical request
    /// right away won't help either one, so both stop the pass rather than failing every other
    /// queued item the same way a moment later. `.decoding` (a `2xx` whose body didn't parse) is
    /// permanent: replaying the identical request will decode-fail the identical way, so there's
    /// nothing an `attempts`-gated retry could gain.
    private func classify(_ error: Error) -> Outcome {
        guard let apiError = error as? ApiError else {
            return .transientFailure(String(describing: error), stopsPass: false)
        }
        switch apiError {
        case .network(let underlying):
            return .transientFailure("network: \(underlying)", stopsPass: true)
        case .unauthorized:
            return .transientFailure("unauthorized", stopsPass: true)
        case .decoding:
            return .permanentFailure("response body did not decode")
        case .server(let status):
            if status == 429 || (500...599).contains(status) {
                return .transientFailure("server \(status)", stopsPass: false)
            }
            return .permanentFailure("server \(status)")
        }
    }

    // MARK: - Reconcile

    /// Upserts the server's authoritative row into the local store, keyed by `clientUuid` — the
    /// work-log's durable cross-wire identity (spec's "Keystone" section) — never by `dto.id`.
    /// The common case finds the row `WorkLogActions` already wrote optimistically and updates
    /// it in place with its `id` left untouched (it's pinned to `clientUuid` forever — no
    /// id-remapping once this reconciles it); no local match (e.g. this row was inserted
    /// directly rather than through `WorkLogActions`, or another device's check-in is only now
    /// being seen) falls back to inserting one, still keyed by `clientUuid` rather than the
    /// server's own id, for the same reason.
    ///
    /// `source` guards against m4a-review Minor #3: a check-in replay's response DTO is always
    /// still CHECKED_IN (the server hasn't processed a queued check-out yet, or this call
    /// wouldn't be happening), so applying it unconditionally would clobber an already-optimistic
    /// CHECKED_OUT local row back to CHECKED_IN whenever that check-out hasn't *also* landed in
    /// this same pass (e.g. the connection drops between the two, or the check-out is still
    /// waiting behind other rows). Only the check-in path (`source == .checkIn`) needs this
    /// guard — a check-out's own reconcile is always the authoritative "this really happened"
    /// signal and must apply unconditionally, including when it's reconciling the very row this
    /// guard is protecting.
    private func reconcile(_ dto: WorkLogDTO, clientUuid: String, source: OutboxEndpoint) {
        if let model = try? modelContext.fetch(FetchDescriptor<WorkLog>(
            predicate: #Predicate<WorkLog> { $0.clientUuid == clientUuid }
        )).first {
            if source == .checkIn, model.status == "CHECKED_OUT", hasQueuedCheckOut(forWorkLogClientUuid: clientUuid) {
                return
            }
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
            modelContext.insert(WorkLog(
                id: clientUuid,
                clientUuid: clientUuid,
                jobId: dto.jobId,
                technicianId: dto.technicianId,
                workTypeId: dto.workTypeId,
                status: dto.status,
                checkInAt: dto.checkInAt,
                checkOutAt: dto.checkOutAt,
                quantity: dto.quantity,
                notes: dto.notes,
                updatedAt: dto.updatedAt
            ))
        }
        // Covered by the same `save()` the caller (`runPass`) makes right after this row's own
        // outcome — one write for both, not two.
    }

    /// Whether a not-yet-successfully-synced check-out row targets `workLogClientUuid` — a
    /// presence check, not a state filter, because a *successful* check-out row is deleted
    /// immediately (Minor #4): mere existence in the table already means "hasn't landed yet",
    /// whether it's `.pending`, `.inFlight`, or even `.conflict` (needs a manual retry, but the
    /// local CHECKED_OUT state is still this technician's real intent until it does).
    private func hasQueuedCheckOut(forWorkLogClientUuid workLogClientUuid: String) -> Bool {
        let checkOut = OutboxEndpoint.checkOut.rawValue
        guard let rows = try? modelContext.fetch(FetchDescriptor<SyncOutbox>(
            predicate: #Predicate<SyncOutbox> { $0.endpoint == checkOut }
        )) else { return false }
        return rows.contains { row in
            (try? JSONDecoder().decode(CheckOutPayload.self, from: row.payload))?.workLogClientUuid == workLogClientUuid
        }
    }

    // MARK: - Reconcile (Elevation)

    /// Upserts the server's authoritative elevation row after a successful `.elevationCreate`
    /// replay — mirrors `reconcile(_:clientUuid:source:)`'s WorkLog precedent, but keyed against
    /// `Elevation.id` rather than a `clientUuid` column: `ElevationActions.addElevation`
    /// guarantees `id == clientUuid` for every field-added row from the moment it's minted (see
    /// that method's doc comment), so matching on `id` finds the identical optimistic row a
    /// `clientUuid` match would — without an equality comparison against `Elevation.clientUuid`,
    /// which is `nil` for most rows (`SurveyModels.swift`'s doc comment explains why that column
    /// stays optional). `id` is never reassigned here, in either branch — no remapping to the
    /// server's own `dto.id`, which is echoed back but otherwise unused, exactly like `WorkLog`'s
    /// `reconcile`. A `SyncEngine.syncBuildings` pass that later re-fetches this same elevation
    /// (now with the identical `clientUuid` echoed back on the wire) upserts by that same key
    /// (`dto.clientUuid ?? dto.id`) against the same `id` — see that method's own doc comment —
    /// so a create followed by a sync never produces two local rows for what the server
    /// considers one elevation.
    private func reconcileElevation(_ dto: ElevationDTO, clientUuid: String) {
        if let model = try? modelContext.fetch(FetchDescriptor<Elevation>(
            predicate: #Predicate<Elevation> { $0.id == clientUuid }
        )).first {
            model.buildingId = dto.buildingId
            model.elevationNumber = dto.elevationNumber
            model.numberLabel = dto.numberLabel
            model.label = dto.label
            model.bearing = dto.bearing
            model.facing = dto.facing
            model.fieldAdded = dto.fieldAdded
            model.clientUuid = dto.clientUuid
            model.updatedAt = dto.updatedAt
        } else {
            modelContext.insert(Elevation(
                id: clientUuid,
                buildingId: dto.buildingId,
                elevationNumber: dto.elevationNumber,
                numberLabel: dto.numberLabel,
                label: dto.label,
                bearing: dto.bearing,
                facing: dto.facing,
                fieldAdded: dto.fieldAdded,
                clientUuid: dto.clientUuid,
                updatedAt: dto.updatedAt
            ))
        }
        // Covered by the same `save()` the caller (`runPass`) makes right after this row's own
        // outcome — one write for both, not two.
    }
}
