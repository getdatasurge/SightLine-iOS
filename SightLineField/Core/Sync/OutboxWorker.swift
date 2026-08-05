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

/// The two operations a `SyncOutbox` row can target. Raw values are what `WorkLogActions`
/// stores verbatim in `SyncOutbox.endpoint`; `OutboxWorker.drain()` dispatches on them to pick
/// both the payload type to decode and the `WorkLogGateway` method to replay.
enum OutboxEndpoint: String, Sendable {
    case checkIn = "work-logs/check-in"
    case checkOut = "work-logs/check-out"
}

// MARK: - OutboxWorker

/// Drains the offline write queue (M4 A-I2). `WorkLogActions.checkIn`/`checkOut` write the
/// local store optimistically and enqueue a `SyncOutbox` row; this class is the only thing that
/// ever actually calls `WorkLogGateway` for those rows, replaying them oldest-first
/// (`SyncOutbox.createdAt` — its FIFO ordinal) whenever `drain()` runs.
///
/// Per-item outcome, per `docs/superpowers/specs/2026-08-05-m4-offline-outbox.md`:
/// - `2xx` → `.done`, and the local `WorkLog` is reconciled from the server's row (keyed by
///   `clientUuid`, never the server's own row id — see `reconcile`'s doc comment).
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
/// Re-entrant-safe: `drain()` called while already draining is a no-op, so triggering it from
/// several places at once (foreground, reconnect, every `WorkLogActions` enqueue) never runs two
/// passes over the same rows concurrently.
@MainActor
@Observable
final class OutboxWorker {
    private(set) var isDraining = false

    private let gateway: WorkLogGateway
    private let modelContext: ModelContext
    private let maxAttempts = 6

    init(gateway: WorkLogGateway, modelContext: ModelContext) {
        self.gateway = gateway
        self.modelContext = modelContext
    }

    /// Rows still waiting on a successful replay — queued or actively being sent.
    var pendingCount: Int {
        let pending = OutboxState.pending.rawValue
        let inFlight = OutboxState.inFlight.rawValue
        return (try? modelContext.fetchCount(FetchDescriptor<SyncOutbox>(
            predicate: #Predicate<SyncOutbox> { $0.state == pending || $0.state == inFlight }
        ))) ?? 0
    }

    /// Rows that gave up — a permanent rejection or `maxAttempts` exhausted — and need either a
    /// human to look or a manual `retry(clientUuid:)`.
    var conflictCount: Int {
        let conflict = OutboxState.conflict.rawValue
        return (try? modelContext.fetchCount(FetchDescriptor<SyncOutbox>(
            predicate: #Predicate<SyncOutbox> { $0.state == conflict }
        ))) ?? 0
    }

    /// Replays every queued item oldest-first: `.pending` rows, plus any `.inFlight` left over
    /// from a run that never got to record an outcome (e.g. the app was killed mid-request) —
    /// self-healing, since nothing else ever revives a stuck `.inFlight` row. See the class doc
    /// comment for the per-item outcome rules.
    func drain() async {
        guard !isDraining else { return }
        isDraining = true
        defer { isDraining = false }

        let pending = OutboxState.pending.rawValue
        let inFlight = OutboxState.inFlight.rawValue
        var descriptor = FetchDescriptor<SyncOutbox>(
            predicate: #Predicate<SyncOutbox> { $0.state == pending || $0.state == inFlight }
        )
        descriptor.sortBy = [SortDescriptor(\.createdAt)]
        guard let items = try? modelContext.fetch(descriptor) else { return }

        for item in items {
            item.state = OutboxState.inFlight.rawValue
            try? modelContext.save()

            switch await attempt(item) {
            case .success:
                item.state = OutboxState.done.rawValue
                item.lastError = nil
                try? modelContext.save()
            case .permanentFailure(let message):
                item.state = OutboxState.conflict.rawValue
                item.lastError = message
                try? modelContext.save()
            case .transientFailure(let message, let stopsPass):
                item.attempts += 1
                item.lastError = message
                item.state = item.attempts >= maxAttempts ? OutboxState.conflict.rawValue : OutboxState.pending.rawValue
                try? modelContext.save()
                if stopsPass { return }
            }
        }
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
        try? modelContext.save()
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
                reconcile(dto, clientUuid: payload.clientUuid)
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
                reconcile(dto, clientUuid: payload.workLogClientUuid)
                return .success
            } catch {
                return classify(error)
            }
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
    private func reconcile(_ dto: WorkLogDTO, clientUuid: String) {
        if let model = try? modelContext.fetch(FetchDescriptor<WorkLog>(
            predicate: #Predicate<WorkLog> { $0.clientUuid == clientUuid }
        )).first {
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
        // Covered by the same `save()` the caller (`drain()`) makes right after recording this
        // item's own `.done` transition — one write for both, not two.
    }
}
