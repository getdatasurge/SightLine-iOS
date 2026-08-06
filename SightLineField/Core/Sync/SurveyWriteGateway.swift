import Foundation
import OpenAPIRuntime

/// The seam `OutboxWorker` replays `.elevationCreate`/`.surfaceAssign` rows through (M5a). Both
/// device-session survey write routes wrap the generated `Client` directly — unlike
/// `.photoUpload`'s `PhotoUploadGateway` (multipart has no ergonomic generated-client story, see
/// that protocol's doc comment), these two are plain JSON bodies, the same shape as
/// `WorkLogGateway`'s two operations.
protocol SurveyWriteGateway: Sendable {
    /// `clientUuid` is minted by the caller (`ElevationActions.addElevation`), not this seam —
    /// same reasoning as `WorkLogGateway.checkIn`'s doc comment: an outbox replay after a
    /// transient failure reuses the same key instead of minting a new one per attempt. Returns
    /// the server's authoritative row (the auto-assigned `elevationNumber`, echoed `clientUuid`,
    /// etc.) for `OutboxWorker.reconcileElevation` to upsert the optimistic local row against.
    func createElevation(buildingId: String, label: String, facing: String?, clientUuid: String) async throws -> ElevationDTO

    /// No `clientUuid` parameter — `POST /surfaces/{id}/assign` is naturally idempotent (a
    /// replay just re-runs the same update), so there's no idempotency key to thread through.
    /// No return value either: `ElevationActions.assignSurface` already wrote the local
    /// `Surface` links optimistically, so a call that doesn't throw is the entire success signal
    /// `OutboxWorker` needs — nothing in the response to reconcile against (mirrors
    /// `PhotoUploadGateway.upload`'s identical reasoning).
    func assignSurface(surfaceId: String, buildingId: String, elevationId: String) async throws
}

/// Wraps the generated `Client` for the two M5a survey write operations — both device-session
/// only. Operation names (`post_sol_buildings_sol__lcub_id_rcub__sol_elevations`,
/// `post_sol_surfaces_sol__lcub_id_rcub__sol_assign`) are `swift-openapi-generator`'s literal
/// `<method><path>` output under the `defensive` naming strategy — verified directly against the
/// freshly-generated `Types.swift`/`Client.swift` (DerivedData, same session as this slice). See
/// `AuthGateway.swift`'s doc comment for the general naming-strategy explanation.
struct LiveSurveyWriteGateway: SurveyWriteGateway {
    let client: Client

    /// `POST /buildings/{id}/elevations` answers `201` on a real create and `200` on an
    /// idempotent replay (same `clientUuid` seen before) — both wrap the identical
    /// `{data: ElevationRow}` shape, so both cases decode the same way. `buildingId`/
    /// `fieldAdded` are never sent in the body — the route forces both server-side
    /// (`fieldAdded: true` always, `buildingId` from the path) and 400s an attempt to smuggle
    /// either in.
    func createElevation(buildingId: String, label: String, facing: String?, clientUuid: String) async throws -> ElevationDTO {
        let input = Operations.post_sol_buildings_sol__lcub_id_rcub__sol_elevations.Input(
            path: .init(id: buildingId),
            body: .json(.init(label: label, facing: facing, clientUuid: clientUuid))
        )
        let response: Operations.post_sol_buildings_sol__lcub_id_rcub__sol_elevations.Output
        do {
            response = try await client.post_sol_buildings_sol__lcub_id_rcub__sol_elevations(input)
        } catch {
            throw ApiError.network(error)
        }
        switch response {
        case .ok(let ok):
            return try decode(try ok.body.json.data.additionalProperties, as: ElevationDTO.self)
        case .created(let created):
            return try decode(try created.body.json.data.additionalProperties, as: ElevationDTO.self)
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

    /// `POST /surfaces/{id}/assign` is always `200` — the generated `Output` has no `.created`
    /// case at all (nothing is ever newly "created" by an assign, only updated), unlike
    /// `createElevation`'s.
    func assignSurface(surfaceId: String, buildingId: String, elevationId: String) async throws {
        let input = Operations.post_sol_surfaces_sol__lcub_id_rcub__sol_assign.Input(
            path: .init(id: surfaceId),
            body: .json(.init(buildingId: buildingId, elevationId: elevationId))
        )
        let response: Operations.post_sol_surfaces_sol__lcub_id_rcub__sol_assign.Output
        do {
            response = try await client.post_sol_surfaces_sol__lcub_id_rcub__sol_assign(input)
        } catch {
            throw ApiError.network(error)
        }
        switch response {
        case .ok: return
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

    /// Same undocumented-object round trip as `WorkLogGateway.decode`/`SyncBackend.decode`.
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
