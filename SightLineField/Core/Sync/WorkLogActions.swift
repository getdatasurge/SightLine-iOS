import Foundation
import Observation
import OpenAPIRuntime
import SwiftData

/// The only seam that touches the generated `/work-logs/check-in` and `/work-logs/check-out`
/// operations. `LiveWorkLogGateway` wraps `Client`; tests fake this seam instead of standing up
/// the generated client — same split as `AuthGateway`/`LiveAuthGateway`. `OutboxWorker` is the
/// sole caller now (M4 A-I3) — `WorkLogActions` no longer calls this directly, it writes
/// optimistically and enqueues instead; see that class's doc comment.
protocol WorkLogGateway: Sendable {
    /// `clientUuid` is minted by the caller (`WorkLogActions.checkIn`), not this seam — keeping
    /// idempotency-key generation out of the gateway means a retry (an outbox replay after a
    /// transient failure) reuses the same key instead of minting a new one per attempt.
    func checkIn(jobId: String, workTypeId: String?, notes: String?, clientUuid: String) async throws -> WorkLogDTO
    /// Keyed by the work-log's `clientUuid`, not a server id (M4 A-B2) — offline, a check-in has
    /// no server id yet for a check-out to reference. Idempotent server-side: replaying against
    /// an already-CHECKED_OUT log returns that same row instead of 404/409ing.
    func checkOut(workLogClientUuid: String, quantity: Double?, notes: String?) async throws -> WorkLogDTO
}

/// Wraps the generated `Client` for the two M3/M4 write operations. Both endpoints are
/// device-session only; `technicianId` is forced server-side from the session and is never part
/// of either request body (a client-supplied one 400s on check-in — there's no field for it to
/// even occupy here).
///
/// Operation names (`post_sol_work_hyphen_logs_sol_check_hyphen_in` etc.) are
/// `swift-openapi-generator`'s literal `<method><path>` output under the `defensive` naming
/// strategy — verified directly against the freshly-generated `Types.swift`/`Client.swift`
/// (DerivedData, same session as the M4a snapshot regen). See `AuthGateway.swift`'s doc comment
/// for the general naming-strategy explanation.
struct LiveWorkLogGateway: WorkLogGateway {
    let client: Client

    /// `POST /work-logs/check-in` answers `200` on an idempotent replay (same `clientUuid` seen
    /// before) and `201` on a real create — both wrap the identical `{data: WorkLogRow}` shape,
    /// so both cases decode the same way.
    func checkIn(jobId: String, workTypeId: String?, notes: String?, clientUuid: String) async throws -> WorkLogDTO {
        let response: Operations.post_sol_work_hyphen_logs_sol_check_hyphen_in.Output
        do {
            response = try await client.post_sol_work_hyphen_logs_sol_check_hyphen_in(
                .init(body: .json(.init(jobId: jobId, workTypeId: workTypeId, notes: notes, clientUuid: clientUuid)))
            )
        } catch {
            throw ApiError.network(error)
        }
        switch response {
        case .ok(let ok):
            return try decode(try ok.body.json.data.additionalProperties, as: WorkLogDTO.self)
        case .created(let created):
            return try decode(try created.body.json.data.additionalProperties, as: WorkLogDTO.self)
        case .badRequest: throw ApiError.server(status: 400)
        case .unauthorized: throw ApiError.unauthorized
        case .forbidden: throw ApiError.server(status: 403)
        case .notFound: throw ApiError.server(status: 404)
        case .conflict: throw ApiError.server(status: 409)
        case .tooManyRequests: throw ApiError.server(status: 429)
        case .internalServerError: throw ApiError.server(status: 500)
        case .undocumented(let statusCode, _): throw ApiError.server(status: statusCode)
        }
    }

    /// `POST /work-logs/check-out` (M4 A-B2) — replaces the old path-id route outright; body
    /// only, keyed by `workLogClientUuid` rather than a path `{id}`. Always `200`, never `201`:
    /// idempotent replay against an already-CHECKED_OUT log returns that same row rather than a
    /// fresh transition, so there's only ever one success case to decode.
    func checkOut(workLogClientUuid: String, quantity: Double?, notes: String?) async throws -> WorkLogDTO {
        let response: Operations.post_sol_work_hyphen_logs_sol_check_hyphen_out.Output
        do {
            response = try await client.post_sol_work_hyphen_logs_sol_check_hyphen_out(
                .init(body: .json(.init(workLogClientUuid: workLogClientUuid, quantity: quantity, notes: notes)))
            )
        } catch {
            throw ApiError.network(error)
        }
        switch response {
        case .ok(let ok):
            return try decode(try ok.body.json.data.additionalProperties, as: WorkLogDTO.self)
        case .badRequest: throw ApiError.server(status: 400)
        case .unauthorized: throw ApiError.unauthorized
        case .forbidden: throw ApiError.server(status: 403)
        case .notFound: throw ApiError.server(status: 404)
        case .conflict: throw ApiError.server(status: 409)
        case .tooManyRequests: throw ApiError.server(status: 429)
        case .internalServerError: throw ApiError.server(status: 500)
        case .undocumented(let statusCode, _): throw ApiError.server(status: statusCode)
        }
    }

    /// Same undocumented-object round trip as `AuthGateway.decodeData`/`SyncBackend.decode` —
    /// `data` is freeform (`additionalProperties: true`) on both write responses, same as every
    /// other envelope in this API. `WorkLogDTO` (`SyncBackend.swift`) already mirrors the wire
    /// `WorkLogRow` shape used by `GET /work-logs`; check-in/check-out return that identical row,
    /// so reusing the type here avoids a second, parallel decode target.
    private func decode<T: Decodable>(_ container: OpenAPIObjectContainer, as type: T.Type) throws -> T {
        do {
            let data = try JSONEncoder().encode(container)
            return try Self.dtoDecoder.decode(T.self, from: data)
        } catch {
            throw ApiError.decoding
        }
    }

    private static let dtoDecoder: JSONDecoder = {
        let jsonDecoder = JSONDecoder()
        jsonDecoder.dateDecodingStrategy = .custom { decoder in
            let container = try decoder.singleValueContainer()
            let string = try container.decode(String.self)
            if let date = isoWithFractionalSeconds.date(from: string) ?? isoWhole.date(from: string) {
                return date
            }
            throw DecodingError.dataCorruptedError(in: container, debugDescription: "Expected an ISO 8601 date, got \"\(string)\"")
        }
        return jsonDecoder
    }()

    private static let isoWithFractionalSeconds: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter
    }()

    private static let isoWhole = ISO8601DateFormatter()
}

/// Check-in/check-out actions, plus the local "what's my open session?" store query. As of M4
/// (A-I3) both writes are **optimistic + queued**, never a direct network call on this call
/// stack: mint the work-log's `clientUuid`, write the local `WorkLog` row as if the call already
/// succeeded, enqueue the real request onto `outboxWorker`, and kick off a drain without waiting
/// for it. Neither method throws or is `async` any more — there's nothing on this call stack
/// that can fail, so a technician offline never sees an error; the write "succeeds" instantly
/// and syncs whenever the outbox next drains (foreground, reconnect, or a later explicit
/// `outboxWorker.drain()`). See `docs/superpowers/specs/2026-08-05-m4-offline-outbox.md`'s
/// "Keystone" section: `clientUuid` is the work-log's durable identity across the wire, and the
/// local row's `id` stays pinned to it forever — no id-remapping once the outbox reconciles it.
@MainActor
@Observable
final class WorkLogActions {
    private let modelContext: ModelContext

    /// The outbox this instance's writes enqueue into. Exposed (not just an implementation
    /// detail) so the composition root can wire `Connectivity.onBecameOnline`/the settings
    /// sync-status view to the same worker via `appDependencies.workLogActions.outboxWorker`,
    /// without `WorkLogActions` itself needing to proxy `isDraining`/`pendingCount`/
    /// `conflictCount`/`retry(clientUuid:)`.
    let outboxWorker: OutboxWorker

    /// Production entry point — matches `AppDependencies`' composition-root call
    /// (`WorkLogActions(client:modelContext:)`) exactly, building the live gateway internally.
    convenience init(client: Client, modelContext: ModelContext) {
        self.init(gateway: LiveWorkLogGateway(client: client), modelContext: modelContext)
    }

    /// Test/seam entry point — takes the `WorkLogGateway` protocol directly so unit tests can
    /// fake the network without standing up the generated `Client`. Builds its own
    /// `OutboxWorker` from the same `gateway`/`modelContext` rather than taking one as a separate
    /// parameter, so this initializer's shape — and `AppDependencies`' existing call site — never
    /// has to change to add one ("WorkLogActions gains an OutboxWorker dependency", composed
    /// here rather than injected).
    init(gateway: WorkLogGateway, modelContext: ModelContext) {
        self.modelContext = modelContext
        self.outboxWorker = OutboxWorker(gateway: gateway, modelContext: modelContext)
    }

    /// The caller's own open ("CHECKED_IN") work-log session on a job, if any — drives the
    /// Check In ↔ Check Out state split in `JobDetailView`/`WorkLogsView`.
    ///
    /// Scoped to the caller's `technicianId` when known: `WorkLog.technicianId` is persisted by
    /// `SyncEngine.syncWorkLogs`, the outbox's own reconcile step, and — as of the m4a-review
    /// Important #1 fix — `checkIn`'s own optimistic write, so a teammate's open session on a
    /// shared job never flips this caller's UI into "Check Out", and this caller's own
    /// just-created offline session is visible immediately instead of only after the outbox
    /// reconciles. Rows synced before the column existed still carry `nil` and are excluded
    /// from the scoped query — acceptable: they predate the caller's session on that job. With
    /// `technicianId == nil` (account has no Technician row) falls back to job-wide, mirroring
    /// the business-wide sync stance.
    func openWorkLog(onJob jobId: String, technicianId: String?) -> WorkLog? {
        let predicate: Predicate<WorkLog>
        if let technicianId {
            predicate = #Predicate<WorkLog> { $0.jobId == jobId && $0.status == "CHECKED_IN" && $0.technicianId == technicianId }
        } else {
            predicate = #Predicate<WorkLog> { $0.jobId == jobId && $0.status == "CHECKED_IN" }
        }
        var descriptor = FetchDescriptor<WorkLog>(predicate: predicate)
        descriptor.sortBy = [SortDescriptor(\.checkInAt, order: .reverse)]
        return (try? modelContext.fetch(descriptor))?.first
    }

    /// Opens a new session, optimistically. Mints `clientUuid` — the work-log's durable identity
    /// from this instant on, doubling as the local row's `id` forever (reconciled from the
    /// server's response, but never remapped to the server's own row id) — writes the row
    /// already `CHECKED_IN`, and enqueues the real check-in call.
    ///
    /// `technicianId` is the caller's own — never sent to the server itself (the wire body has
    /// no such field; `LiveWorkLogGateway`'s doc comment explains why) — but must land on this
    /// optimistic row anyway: `openWorkLog(onJob:technicianId:)` scopes its query by it, so a
    /// row missing it is invisible to that query until the outbox reconciles the server's
    /// response. Without this (m4a-review Important #1), the Check In → Check Out toggle never
    /// flips offline, and a second tap mints a *second* clientUuid/WorkLog/outbox row — a
    /// duplicate open session server-side once the outbox drains.
    @discardableResult
    func checkIn(jobId: String, workTypeId: String?, notes: String?, technicianId: String?) -> WorkLog {
        let clientUuid = UUID().uuidString
        let now = Date()
        let model = WorkLog(
            id: clientUuid,
            clientUuid: clientUuid,
            jobId: jobId,
            technicianId: technicianId,
            workTypeId: workTypeId,
            status: "CHECKED_IN",
            checkInAt: now,
            notes: notes,
            updatedAt: now
        )
        modelContext.insert(model)
        enqueue(.checkIn, CheckInPayload(jobId: jobId, workTypeId: workTypeId, notes: notes, clientUuid: clientUuid))
        return model
    }

    /// Closes the caller's own open session, optimistically. `workLogClientUuid` is the
    /// work-log's durable identity — from `checkIn`'s return value or a `@Query`-sourced
    /// `WorkLog.clientUuid` — and is also what the check-out wire op keys by (M4 A-B2), so this
    /// never needs a server id. Mutates the local row to `CHECKED_OUT` immediately when it's
    /// found (the normal case: the presenting view already holds this exact row); if it somehow
    /// isn't there yet, the enqueue still happens and a later drain's reconcile step creates it
    /// from whatever the server returns.
    @discardableResult
    func checkOut(workLogClientUuid: String, quantity: Double?, notes: String?) -> WorkLog? {
        let match = try? modelContext.fetch(FetchDescriptor<WorkLog>(
            predicate: #Predicate<WorkLog> { $0.clientUuid == workLogClientUuid }
        )).first
        if let match {
            let now = Date()
            match.status = "CHECKED_OUT"
            match.checkOutAt = now
            match.quantity = quantity
            match.notes = notes
            match.updatedAt = now
        }
        enqueue(.checkOut, CheckOutPayload(workLogClientUuid: workLogClientUuid, quantity: quantity, notes: notes))
        return match
    }

    /// Inserts a `SyncOutbox` row for `payload` and saves it in the same `ModelContext.save()`
    /// as whatever optimistic `WorkLog` mutation `checkIn`/`checkOut` just made above (SwiftData
    /// saves every pending change on the context, not just the object touched last), then kicks
    /// off a drain without waiting for it — the fire-and-forget half of "optimistic + enqueue".
    /// `outboxWorker.refreshCounts()` runs right after the save: this row lands directly on the
    /// shared `modelContext` rather than through `OutboxWorker`, so nothing else would otherwise
    /// tell its `@Observable` `pendingCount` about it before the fire-and-forget drain gets
    /// around to running.
    private func enqueue<Payload: Encodable>(_ endpoint: OutboxEndpoint, _ payload: Payload) {
        // `CheckInPayload`/`CheckOutPayload` are plain strings/doubles/optionals — nothing about
        // encoding them can fail, so this never actually traps.
        let data = try! JSONEncoder().encode(payload)
        modelContext.insert(SyncOutbox(clientUuid: UUID().uuidString, endpoint: endpoint.rawValue, payload: data))
        try? modelContext.save()
        outboxWorker.refreshCounts()
        Task { await outboxWorker.drain() }
    }
}

/// Sheet-facing copy for a thrown error. `.network` gets the spec'd offline message; every other
/// `ApiError` case falls back to a short, honest description rather than a generic "something
/// went wrong" that would hide a real, potentially actionable failure (403 vs. 500 look
/// different to a technician deciding whether to retry). No longer reachable from
/// `WorkLogActions.checkIn`/`checkOut` directly (M4: neither throws), but still what a future
/// conflict-retry UI wants for `SyncOutbox.lastError`-driven messaging.
extension ApiError {
    var userMessage: String {
        switch self {
        case .network: return "You're offline — try again when connected."
        case .unauthorized: return "Your session expired. Please sign in again."
        case .server(let status): return "Server error (\(status)). Please try again."
        case .decoding: return "Something went wrong. Please try again."
        }
    }
}
