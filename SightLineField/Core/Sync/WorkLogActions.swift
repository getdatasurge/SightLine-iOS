import Foundation
import Observation
import OpenAPIRuntime
import SwiftData

/// The only seam that touches the generated `/work-logs/check-in` and `/work-logs/{id}/check-out`
/// operations. `LiveWorkLogGateway` wraps `Client`; tests fake this seam instead of standing up
/// the generated client — same split as `AuthGateway`/`LiveAuthGateway`.
protocol WorkLogGateway: Sendable {
    /// `clientUuid` is minted by the caller (`WorkLogActions.checkIn`), not this seam — keeping
    /// idempotency-key generation out of the gateway means a retry (e.g. after a transient
    /// network error) reuses the same key instead of minting a new one per attempt.
    func checkIn(jobId: String, workTypeId: String?, notes: String?, clientUuid: String) async throws -> WorkLogDTO
    func checkOut(workLogId: String, quantity: Double?, notes: String?) async throws -> WorkLogDTO
}

/// Wraps the generated `Client` for the two M3 write operations. Both endpoints are
/// device-session only; `technicianId` is forced server-side from the session and is never part
/// of either request body (a client-supplied one 400s on check-in — there's no field for it to
/// even occupy here).
///
/// Operation names (`post_sol_work_hyphen_logs_sol_check_hyphen_in` etc.) are
/// `swift-openapi-generator`'s literal `<method><path>` output under the `defensive` naming
/// strategy — verified directly against the freshly-generated `Types.swift`/`Client.swift`
/// (DerivedData, same session as the M3 snapshot commit), not hand-derived. See
/// `AuthGateway.swift`'s doc comment for the general naming-strategy explanation.
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

    func checkOut(workLogId: String, quantity: Double?, notes: String?) async throws -> WorkLogDTO {
        let response: Operations.post_sol_work_hyphen_logs_sol__lcub_id_rcub__sol_check_hyphen_out.Output
        do {
            response = try await client.post_sol_work_hyphen_logs_sol__lcub_id_rcub__sol_check_hyphen_out(
                .init(path: .init(id: workLogId), body: .json(.init(quantity: quantity, notes: notes)))
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

/// Check-in/check-out actions over the generated client, plus the local "what's my open
/// session?" store query. `checkIn`/`checkOut` upsert the server's returned row into SwiftData
/// (mirroring `SyncEngine.syncWorkLogs`'s insert-or-mutate-then-save shape) so every `@Query`
/// bound to `WorkLog` across the app — `JobDetailView`'s action area, `WorkLogsView`'s banner and
/// list — reflects the write immediately, with no separate re-sync required.
///
/// Online-only for M3 (per the spec's non-goals): a network failure surfaces as `ApiError
/// .network` and is not queued for retry. Offline writes/outbox land in M4.
@MainActor
@Observable
final class WorkLogActions {
    private let gateway: WorkLogGateway
    private let modelContext: ModelContext

    /// Production entry point — matches `AppDependencies`' composition-root call
    /// (`WorkLogActions(client:modelContext:)`) exactly, building the live gateway internally.
    convenience init(client: Client, modelContext: ModelContext) {
        self.init(gateway: LiveWorkLogGateway(client: client), modelContext: modelContext)
    }

    /// Test/seam entry point — takes the `WorkLogGateway` protocol directly so unit tests can
    /// fake the network without standing up the generated `Client`.
    init(gateway: WorkLogGateway, modelContext: ModelContext) {
        self.gateway = gateway
        self.modelContext = modelContext
    }

    /// The caller's own open ("CHECKED_IN") work-log session on a job, if any — drives the
    /// Check In ↔ Check Out state split in `JobDetailView`/`WorkLogsView`.
    ///
    /// `technicianId` is part of the signature per the fixed cross-task contract, but the local
    /// `WorkLog` model (`Models.swift`, out of this task's file scope) has no persisted
    /// `technicianId` column — every upserted/synced row is stored without one, deliberately:
    /// `SyncEngine.syncWorkLogs`'s doc comment notes work-log sync is business-wide so a
    /// technician can see a teammate's open session on a shared job, not just their own. Until
    /// the store gains that column, this filters by `jobId` + `status == "CHECKED_IN"` only and
    /// returns the most-recently-opened match if more than one technician happens to be checked
    /// into the same job — a real possibility business-wide, but outside M3's
    /// single-active-technician-per-job scope. Flagged to the task owner; not silently pretended
    /// away.
    func openWorkLog(onJob jobId: String, technicianId: String?) -> WorkLog? {
        var descriptor = FetchDescriptor<WorkLog>(
            predicate: #Predicate<WorkLog> { $0.jobId == jobId && $0.status == "CHECKED_IN" }
        )
        descriptor.sortBy = [SortDescriptor(\.checkInAt, order: .reverse)]
        return (try? modelContext.fetch(descriptor))?.first
    }

    /// Opens a new session. Mints its own `clientUuid` (the server-side idempotency key, B1) so
    /// a retry after a transient failure — the caller re-invoking `checkIn` with the *same*
    /// in-flight state — never double-creates; a genuinely new tap starts a fresh key.
    @discardableResult
    func checkIn(jobId: String, workTypeId: String?, notes: String?) async throws -> WorkLog {
        let clientUuid = UUID().uuidString
        let dto = try await gateway.checkIn(jobId: jobId, workTypeId: workTypeId, notes: notes, clientUuid: clientUuid)
        return try upsert(dto, newRowClientUuid: clientUuid)
    }

    /// Closes the caller's own open session. `workLogId` identifies which row — no local lookup
    /// needed since the presenting view already holds the specific `WorkLog` (from its own
    /// `@Query` or `openWorkLog(onJob:)`) before offering the Check Out sheet.
    @discardableResult
    func checkOut(workLogId: String, quantity: Double?, notes: String?) async throws -> WorkLog {
        let dto = try await gateway.checkOut(workLogId: workLogId, quantity: quantity, notes: notes)
        // No client-minted key on the check-out path — the row being closed already exists
        // locally (from its own check-in or from sync), so the insert branch below is a rare
        // fallback (e.g. this device never synced the row); `dto.id` mirrors `SyncEngine
        // .syncWorkLogs`'s own fallback for a server-sourced row with no local idempotency key.
        return try upsert(dto, newRowClientUuid: dto.id)
    }

    /// Insert-or-mutate + save, mirroring `SyncEngine.syncWorkLogs`'s per-row upsert exactly
    /// (same fields copied, same shape) — the one difference is `clientUuid` on a fresh insert:
    /// sync has no wire `clientUuid` and falls back to the server `id`, but a row born from
    /// `checkIn` here already has the real, locally-minted key worth preserving.
    private func upsert(_ dto: WorkLogDTO, newRowClientUuid: String) throws -> WorkLog {
        let id = dto.id
        let existing = try modelContext.fetch(FetchDescriptor<WorkLog>(predicate: #Predicate<WorkLog> { $0.id == id })).first
        if let model = existing {
            model.jobId = dto.jobId
            model.workTypeId = dto.workTypeId
            model.status = dto.status
            model.checkInAt = dto.checkInAt
            model.checkOutAt = dto.checkOutAt
            model.quantity = dto.quantity
            model.notes = dto.notes
            model.updatedAt = dto.updatedAt
            try modelContext.save()
            return model
        }
        let model = WorkLog(
            id: dto.id,
            clientUuid: newRowClientUuid,
            jobId: dto.jobId,
            workTypeId: dto.workTypeId,
            status: dto.status,
            checkInAt: dto.checkInAt,
            checkOutAt: dto.checkOutAt,
            quantity: dto.quantity,
            notes: dto.notes,
            updatedAt: dto.updatedAt
        )
        modelContext.insert(model)
        try modelContext.save()
        return model
    }
}

/// Sheet-facing copy for a thrown error. `.network` gets the spec'd offline message; every other
/// `ApiError` case falls back to a short, honest description rather than a generic "something
/// went wrong" that would hide a real, potentially actionable failure (403 vs. 500 look
/// different to a technician deciding whether to retry).
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
