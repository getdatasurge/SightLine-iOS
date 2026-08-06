import Foundation
import OpenAPIRuntime

/// The DTO `LiveSurfaceCaptureGateway` decodes the `POST /jobs/{id}/surfaces` response into
/// (M5b) — the price-blind capture projection the backend echoes back on a fresh (`201`) or
/// idempotent-replay (`200`) capture. `id` is the server's real primary key (persisted as
/// `Surface.serverId` by `OutboxWorker.reconcileSurface`, the load-bearing value the photo-per-
/// surface chain resolver depends on). `areaSqFt` is server-computed (eighth-inch-fraction
/// aware) — `nil` only for the quick-sqft branch's inverse, never for a measured capture. Every
/// dimension/`areaSqFt` field is independently optional because the wire body is a union of the
/// measured and quick-sqft shapes; `clientUuid` is optional purely for decode resilience —
/// `reconcileSurface` matches on the payload's own `clientUuid`, never this one.
struct SurfaceCaptureDTO: Decodable, Equatable, Sendable {
    let id: String
    let label: String
    let status: String
    let widthIn: Double?
    let heightIn: Double?
    let widthFraction: String?
    let heightFraction: String?
    let quantity: Int?
    let glassType: String?
    let areaSqFt: Double?
    let buildingId: String?
    let elevationId: String?
    let roomId: String?
    let clientUuid: String?
    let updatedAt: Date
}

/// The seam `OutboxWorker` replays `.surfaceCapture` rows through (M5b). A separate protocol
/// from `SurveyWriteGateway` on purpose: that file's two ops are single-field JSON bodies, while
/// a 15-field capture with its own multi-field response DTO earns its own seam/DTO/file — this
/// codebase's "one seam, one concern" convention (`PhotoUploadGateway` lives apart from
/// `WorkLogGateway` for the same reason). Plain JSON body over the generated `Client`, same
/// shape as `SurveyWriteGateway` (no multipart, unlike `PhotoUploadGateway`).
protocol SurfaceCaptureGateway: Sendable {
    /// `clientUuid` is minted by the caller (`SurfaceActions.captureSurface`), not this seam —
    /// same reasoning as every other clientUuid-keyed gateway op: an outbox replay after a
    /// transient failure reuses the same key instead of minting a new one per attempt.
    /// `elevationId`/`buildingId` are already-resolved SERVER ids by the time this is called —
    /// `OutboxWorker.attempt()` resolves the payload's local ids through `Elevation.serverId`
    /// at dispatch time (the chain resolver), so this seam only ever sees real server ids or
    /// `nil`. Returns the server's authoritative row for `OutboxWorker.reconcileSurface` to
    /// upsert the optimistic local row against (`serverId`, server-computed `areaSqFt`, status).
    func captureSurface(
        jobId: String, label: String, widthIn: Double, heightIn: Double,
        widthFraction: String?, heightFraction: String?, quantity: Int?, glassType: String?,
        buildingId: String?, elevationId: String?, clientUuid: String
    ) async throws -> SurfaceCaptureDTO
}

/// Wraps the generated `Client` for the M5b device-session pane capture.
///
/// **SEAM — not yet compilable as of this commit**: `Operations
/// .post_sol_jobs_sol__lcub_id_rcub__sol_surfaces` doesn't exist in the DerivedData-generated
/// `Client`/`Types` yet. The backend route + its OpenAPI `post` entry are already shipped
/// (`.superpowers/sdd/m5b-backend-report.md`, commits `e74b1d80`/`5e91e1d3`), but the checked-in
/// generated client predates them — regenerated during integration (Main's build). Operation
/// name derived from the exact `swift-openapi-generator` `defensive` naming convention every
/// other operation in this codebase already uses (method + `_sol_`-for-`/`, `_lcub_id_rcub_`-
/// for-`{id}`), verified against the sibling `get_sol_jobs_sol__lcub_id_rcub__sol_surfaces` and
/// `post_sol_buildings_sol__lcub_id_rcub__sol_elevations` — not hand-guessed.
///
/// `POST /jobs/{id}/surfaces` answers `201` on a fresh capture and `200` on an idempotent replay
/// (same `clientUuid` seen before) — both wrap the identical `{data: SurfaceRecord}` shape, so
/// both decode the same way. `isQuickSqft: false` is always sent (this slice is measured W×H
/// capture only, per plan §1/§4); `parent`/`priceOverride`/`photoUrls` are never sent (the route
/// forces `parent` from the job's site and rejects money/photo fields). **409 →
/// `ApiError.server(409)` → `classify` treats it as `.permanentFailure`** (a legacy job with no
/// site attached surfaces as a stuck `.conflict` row — a technician can't fix "office hasn't
/// attached a property" by retrying, so this is correct, not a bug).
struct LiveSurfaceCaptureGateway: SurfaceCaptureGateway {
    let client: Client

    func captureSurface(
        jobId: String, label: String, widthIn: Double, heightIn: Double,
        widthFraction: String?, heightFraction: String?, quantity: Int?, glassType: String?,
        buildingId: String?, elevationId: String?, clientUuid: String
    ) async throws -> SurfaceCaptureDTO {
        let input = Operations.post_sol_jobs_sol__lcub_id_rcub__sol_surfaces.Input(
            path: .init(id: jobId),
            body: .json(.init(
                isQuickSqft: false,
                label: label,
                widthIn: widthIn,
                heightIn: heightIn,
                quantity: quantity,
                widthFraction: widthFraction,
                heightFraction: heightFraction,
                glassType: glassType,
                buildingId: buildingId,
                elevationId: elevationId,
                clientUuid: clientUuid
            ))
        )
        let response: Operations.post_sol_jobs_sol__lcub_id_rcub__sol_surfaces.Output
        do {
            response = try await client.post_sol_jobs_sol__lcub_id_rcub__sol_surfaces(input)
        } catch {
            throw ApiError.network(error)
        }
        switch response {
        case .ok(let ok):
            return try decode(try ok.body.json.data.additionalProperties, as: SurfaceCaptureDTO.self)
        case .created(let created):
            return try decode(try created.body.json.data.additionalProperties, as: SurfaceCaptureDTO.self)
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

    /// Same undocumented-object round trip as `SurveyWriteGateway.decode`/`SyncBackend.decode`.
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
