import Foundation
import OpenAPIRuntime

// MARK: - DTOs

/// Lean, `Sendable` wire projections of the five M2 sync collections `SyncEngine` pulls into
/// SwiftData. Fields are a subset of what the API actually returns — e.g. `JobDTO` carries no
/// price fields (`/jobs` is price-blind) — trimmed to what the local store persists.
struct JobDTO: Decodable, Equatable, Sendable {
    /// `/jobs`' `customer` is a derived `{id, name}` projection, not a raw column — modeled as
    /// optional here defensively even though a job's `customerId` FK is currently required.
    struct Customer: Decodable, Equatable, Sendable {
        let name: String
    }

    let id: String
    /// `Job.title` is nullable server-side (`string | null`); `number` (always present) is the
    /// display fallback so a titleless job can't fail the whole collection's decode.
    let title: String?
    let number: String
    let status: String
    let customer: Customer?
    let updatedAt: Date
}

/// `jobId`/`technicianId` are optional: an appointment can exist unassigned to either. The API
/// has no top-level `title` — `SyncEngine.syncAppointments` derives the local model's title from
/// `notes`, falling back to the linked job's `number` (via `job`), then a generic label.
struct AppointmentDTO: Decodable, Equatable, Sendable {
    /// Lean nested job projection: only `number` is needed, as a title fallback. `Job.number`
    /// is a required column, so once `job` itself is present its `number` always is too.
    struct JobRef: Decodable, Equatable, Sendable {
        let number: String
    }

    let id: String
    let jobId: String?
    let technicianId: String?
    let startsAt: Date
    let endsAt: Date
    let status: String
    let notes: String?
    let job: JobRef?
    let updatedAt: Date
}

/// `isActive` is optional — the M2 API projection may still omit it; see `SyncEngine
/// .syncWorkTypes` for the fallback behavior when it's missing.
struct WorkTypeDTO: Decodable, Equatable, Sendable {
    let id: String
    let name: String
    let unit: String
    let isActive: Bool?
    let updatedAt: Date
}

/// `technicianId` is optional for the same reason as `AppointmentDTO`'s.
struct WorkLogDTO: Decodable, Equatable, Sendable {
    let id: String
    let jobId: String
    let technicianId: String?
    let workTypeId: String?
    let checkInAt: Date
    let checkOutAt: Date?
    let quantity: Double?
    let notes: String?
    let status: String
    let updatedAt: Date
    /// The work-log's client-minted idempotency key (M3 B1), echoed back on every projection
    /// (list, check-in, check-out) once a row is created via clientUuid-keyed check-in (M4
    /// A-B1); `nil` for a row the office created without one. `var` + a default value, unlike
    /// every other optional field on this DTO (`let`, no default): a `let` with a default is
    /// silently excluded from `Decodable` synthesis (the default always wins, the wire value is
    /// never read), which would make this field permanently `nil`. `var` keeps it genuinely
    /// decodable while still letting call sites that don't know about it (e.g.
    /// `SyncEngineTests.swift`, outside this task's file scope) keep compiling unchanged.
    var clientUuid: String? = nil
}

/// No `jobId` — a `Surface` isn't a direct child of `Job` server-side, so `/jobs/{id}/surfaces`
/// items don't carry one. `LiveSyncBackend.fetchSurfaces` already knows it from the path it just
/// called and attaches it via `SurfaceRecord`.
struct SurfaceDTO: Decodable, Equatable, Sendable {
    let id: String
    let label: String
    let status: String
    let notes: String?
    let updatedAt: Date
}

/// A `SurfaceDTO` paired with the id of the job it was fetched under — see `SurfaceDTO`'s doc
/// comment for why that pairing has to happen out here instead of inside the DTO.
struct SurfaceRecord: Equatable, Sendable {
    let jobId: String
    let surface: SurfaceDTO
}

// MARK: - SyncBackend

/// One fetch per M2 sync collection. Each drives cursor pagination internally to exhaustion —
/// callers get the whole page set for this pass back at once and never see a cursor. `since:
/// nil` means a full fetch; `since: date` means "only rows updated strictly after `date`",
/// mirroring `SyncPlanner.FetchMode`. `LiveSyncBackend` is the real implementation; tests fake
/// this seam instead of standing up the generated `Client`.
protocol SyncBackend: Sendable {
    func fetchJobs(since: Date?) async throws -> [JobDTO]
    func fetchAppointments(since: Date?) async throws -> [AppointmentDTO]
    func fetchWorkTypes(since: Date?) async throws -> [WorkTypeDTO]
    func fetchWorkLogs(since: Date?) async throws -> [WorkLogDTO]
    func fetchSurfaces(since: Date?) async throws -> [SurfaceRecord]
}

// MARK: - LiveSyncBackend

/// Wraps the generated `Client` for the five M2 read collections.
///
/// - `jobs`/`workTypes`/`workLogs` are business-wide: `/jobs` has no `technicianId` filter at
///   all, and `/work-logs`, though it has one, is deliberately left unfiltered — a technician
///   needs to see teammates' check-ins on a shared job, not just their own.
/// - `appointments` passes `technicianId: "me"` — under a device session the API resolves that
///   to the caller's own Technician row, so only this technician's schedule syncs.
/// - `workTypes` has no query parameters at all (no `cursor`, no `updatedAfter`): every fetch is
///   a full fetch of the one page the server returns. `since` is accepted (protocol conformance)
///   and ignored — there's nowhere to send it.
/// - `surfaces` have no top-level list endpoint, only `/jobs/{id}/surfaces`. A job's own
///   `updatedAt` isn't guaranteed to move when one of its surfaces changes, so `fetchSurfaces`
///   first paginates the *full, unfiltered* job list to get every job id, then issues one
///   `updatedAfter`-scoped surfaces call per id. Accepted N+1 for M2 — a batch
///   `GET /surfaces?jobId=...` endpoint would remove it, but doesn't exist yet.
struct LiveSyncBackend: SyncBackend {
    let client: Client

    /// Server max (`/jobs`, `/appointments`, `/work-logs` all document `maximum: 100`);
    /// requesting it explicitly cuts round trips ~5x versus the server's own default of 20.
    private static let pageLimit = 100

    func fetchJobs(since: Date?) async throws -> [JobDTO] {
        try await fetchAllJobs(updatedAfter: since)
    }

    func fetchAppointments(since: Date?) async throws -> [AppointmentDTO] {
        try await paginated { cursor in
            let input = Operations.get_sol_appointments.Input(
                query: .init(limit: Self.pageLimit, cursor: cursor, technicianId: "me", updatedAfter: since)
            )
            let output: Operations.get_sol_appointments.Output
            do {
                output = try await client.get_sol_appointments(input)
            } catch {
                throw ApiError.network(error)
            }
            switch output {
            case .ok(let ok):
                let payload = try ok.body.json
                let items = try payload.data.map { try decode($0.additionalProperties, as: AppointmentDTO.self) }
                return (items, payload.pagination.nextCursor)
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
    }

    /// No query parameters exist on this endpoint (see the type doc) — `since` is unused.
    func fetchWorkTypes(since: Date?) async throws -> [WorkTypeDTO] {
        let output: Operations.get_sol_work_hyphen_types.Output
        do {
            output = try await client.get_sol_work_hyphen_types(.init())
        } catch {
            throw ApiError.network(error)
        }
        switch output {
        case .ok(let ok):
            let payload = try ok.body.json
            // regen-pending: the generated envelope still requires `pagination` (unused here —
            // `/work-types` returns its one page unpaginated). Once the backend response and the
            // generated client both go data-only, this stays exactly `payload.data.map { ... }`.
            return try payload.data.map { try decode($0.additionalProperties, as: WorkTypeDTO.self) }
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

    /// Business-wide on purpose — no `technicianId` filter (see the type doc).
    func fetchWorkLogs(since: Date?) async throws -> [WorkLogDTO] {
        try await paginated { cursor in
            let input = Operations.get_sol_work_hyphen_logs.Input(
                query: .init(limit: Self.pageLimit, cursor: cursor, updatedAfter: since)
            )
            let output: Operations.get_sol_work_hyphen_logs.Output
            do {
                output = try await client.get_sol_work_hyphen_logs(input)
            } catch {
                throw ApiError.network(error)
            }
            switch output {
            case .ok(let ok):
                let payload = try ok.body.json
                let items = try payload.data.map { try decode($0.additionalProperties, as: WorkLogDTO.self) }
                return (items, payload.pagination.nextCursor)
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
    }

    func fetchSurfaces(since: Date?) async throws -> [SurfaceRecord] {
        let jobIds = try await fetchAllJobs(updatedAfter: nil).map(\.id)
        var surfaces: [SurfaceRecord] = []
        for jobId in jobIds {
            let input = Operations.get_sol_jobs_sol__lcub_id_rcub__sol_surfaces.Input(
                path: .init(id: jobId),
                query: .init(updatedAfter: since)
            )
            let output: Operations.get_sol_jobs_sol__lcub_id_rcub__sol_surfaces.Output
            do {
                output = try await client.get_sol_jobs_sol__lcub_id_rcub__sol_surfaces(input)
            } catch {
                throw ApiError.network(error)
            }
            switch output {
            case .ok(let ok):
                let payload = try ok.body.json
                let items = try payload.data.map { try decode($0.additionalProperties, as: SurfaceDTO.self) }
                surfaces += items.map { SurfaceRecord(jobId: jobId, surface: $0) }
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
        return surfaces
    }

    // MARK: - Job enumeration (shared by fetchJobs and fetchSurfaces)

    /// `updatedAfter: nil` from `fetchSurfaces` walks every job regardless of its own
    /// staleness — see the type doc for why.
    private func fetchAllJobs(updatedAfter: Date?) async throws -> [JobDTO] {
        try await paginated { cursor in
            let input = Operations.get_sol_jobs.Input(
                query: .init(limit: Self.pageLimit, cursor: cursor, updatedAfter: updatedAfter)
            )
            let output: Operations.get_sol_jobs.Output
            do {
                output = try await client.get_sol_jobs(input)
            } catch {
                throw ApiError.network(error)
            }
            switch output {
            case .ok(let ok):
                let payload = try ok.body.json
                let items = try payload.data.map { try decode($0.additionalProperties, as: JobDTO.self) }
                return (items, payload.pagination.nextCursor)
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
    }

    // MARK: - Pagination

    /// Drives cursor pagination to exhaustion. `fetchPage` receives the page cursor (`nil` for
    /// the first page) and returns that page's decoded items plus the next cursor (`nil` = last
    /// page). Capped so a backend that never returns a `nil` cursor can't hang sync forever.
    private func paginated<T>(
        _ fetchPage: (_ cursor: String?) async throws -> (items: [T], nextCursor: String?)
    ) async throws -> [T] {
        var all: [T] = []
        var cursor: String?
        var pagesFetched = 0
        repeat {
            let page = try await fetchPage(cursor)
            all.append(contentsOf: page.items)
            cursor = page.nextCursor
            pagesFetched += 1
        } while cursor != nil && pagesFetched < Self.maxPagesPerFetch
        return all
    }

    private static let maxPagesPerFetch = 1000

    // MARK: - Decoding

    /// Every list item arrives as an undocumented (`additionalProperties: true`) JSON object —
    /// the same shape swift-openapi-generator produces for `/device-auth/login`'s `data`
    /// (`AuthGateway.decodeData`). Round-trips through `Data` to reuse `Decodable` synthesis
    /// instead of hand-parsing `OpenAPIObjectContainer`.
    private func decode<T: Decodable>(_ container: OpenAPIObjectContainer, as type: T.Type) throws -> T {
        do {
            let data = try JSONEncoder().encode(container)
            return try Self.dtoDecoder.decode(T.self, from: data)
        } catch {
            throw ApiError.decoding
        }
    }

    /// Cached: a single sync pass decodes up to a page's worth of items per collection, and
    /// constructing an `ISO8601DateFormatter` isn't free. Tries fractional-second timestamps
    /// first (the common case for a `Date.toISOString()`-style backend) and falls back to whole
    /// seconds.
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
