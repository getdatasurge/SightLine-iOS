import Foundation
import OpenAPIRuntime
#if canImport(UIKit)
import UIKit
#endif

struct AccountContext: Equatable, Codable, Sendable {
    let accountId: String
    let email: String
    let businessId: String
    let sessionId: String
    let technicianId: String?
    let capabilities: [String]
}

/// Result of `GET /technicians/me`: the caller's own technician id (if the account is
/// bound to a technician row) plus their live capability grants.
struct Identity: Equatable, Sendable {
    var technicianId: String?
    var capabilities: [String]
}

struct DeviceInfo: Equatable, Sendable {
    let name: String
    let model: String
    let osVersion: String
    let appVersion: String

    static var current: DeviceInfo {
        let appVersion = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "0.0"
        #if canImport(UIKit)
        let device = UIDevice.current
        return DeviceInfo(name: device.name, model: device.model, osVersion: device.systemVersion, appVersion: appVersion)
        #else
        return DeviceInfo(
            name: ProcessInfo.processInfo.hostName,
            model: "unknown",
            osVersion: ProcessInfo.processInfo.operatingSystemVersionString,
            appVersion: appVersion
        )
        #endif
    }
}

/// The only seam that touches generated auth operations. `LiveAuthGateway` wraps `Client`;
/// `StubAuthGateway` (tests only) fakes it.
protocol AuthGateway: Sendable {
    func login(email: String, password: String, device: DeviceInfo) async throws -> (TokenPair, AccountContext)
    func refresh(refreshToken: String) async throws -> TokenPair
    func logout(sessionId: String) async
    func fetchIdentity() async throws -> Identity
}

/// Wraps the generated `Client` for `/device-auth/*`. There is no `/auth/me`: the account
/// context is built entirely from the login response's `session` object.
///
/// Operation names below (`post_sol_device_hyphen_auth_sol_login` etc.) are
/// `swift-openapi-generator`'s literal output, not a typo: the spec declares no
/// `operationId`s, and `openapi-generator-config.yaml` doesn't opt into `namingStrategy:
/// idiomatic`, so the default `defensive` strategy escapes every `/` and `-` in
/// `<method><path>` into `_sol_`/`_hyphen_` instead of camelCasing it. Verified against a
/// real generator run (`.superpowers/sdd/task-10-report.md`) rather than hand-derived.
struct LiveAuthGateway: AuthGateway {
    let client: Client

    func login(email: String, password: String, device: DeviceInfo) async throws -> (TokenPair, AccountContext) {
        let response: Operations.post_sol_device_hyphen_auth_sol_login.Output
        do {
            response = try await client.post_sol_device_hyphen_auth_sol_login(
                .init(
                    body: .json(
                        .init(
                            email: email,
                            password: password,
                            businessId: nil,
                            device: .init(
                                name: device.name,
                                model: device.model,
                                osVersion: device.osVersion,
                                appVersion: device.appVersion
                            )
                        )
                    )
                )
            )
        } catch {
            throw ApiError.network(error)
        }
        switch response {
        case .created(let created):
            let payload = try created.body.json
            let data = try decodeData(payload.data.additionalProperties, as: DeviceAuthLoginData.self)
            let pair = TokenPair(accessToken: data.accessToken, refreshToken: data.refreshToken)
            let context = AccountContext(
                accountId: data.session.accountId,
                email: email,
                businessId: data.session.businessId,
                sessionId: data.session.id,
                technicianId: nil,
                capabilities: []
            )
            return (pair, context)
        case .unauthorized: throw ApiError.unauthorized
        case .badRequest: throw ApiError.server(status: 400)
        case .forbidden: throw ApiError.server(status: 403)
        case .notFound: throw ApiError.server(status: 404)
        case .conflict: throw ApiError.server(status: 409)
        case .tooManyRequests: throw ApiError.server(status: 429)
        case .internalServerError: throw ApiError.server(status: 500)
        case .undocumented(let statusCode, _): throw ApiError.server(status: statusCode)
        }
    }

    func refresh(refreshToken: String) async throws -> TokenPair {
        let response: Operations.post_sol_device_hyphen_auth_sol_refresh.Output
        do {
            response = try await client.post_sol_device_hyphen_auth_sol_refresh(.init(body: .json(.init(refreshToken: refreshToken))))
        } catch {
            throw ApiError.network(error)
        }
        switch response {
        case .ok(let ok):
            let payload = try ok.body.json
            let data = try decodeData(payload.data.additionalProperties, as: DeviceAuthRefreshData.self)
            return TokenPair(accessToken: data.accessToken, refreshToken: data.refreshToken)
        case .unauthorized: throw ApiError.unauthorized
        case .badRequest: throw ApiError.server(status: 400)
        case .forbidden: throw ApiError.server(status: 403)
        case .notFound: throw ApiError.server(status: 404)
        case .conflict: throw ApiError.server(status: 409)
        case .tooManyRequests: throw ApiError.server(status: 429)
        case .internalServerError: throw ApiError.server(status: 500)
        case .undocumented(let statusCode, _): throw ApiError.server(status: statusCode)
        }
    }

    /// Own-session logout. Best-effort: the seam never throws, matching `AuthGateway.logout`'s
    /// no-throw contract, so `SessionManager.logout()` always clears local state.
    func logout(sessionId: String) async {
        _ = try? await client.delete_sol_device_hyphen_auth_sol_sessions_sol__lcub_id_rcub_(.init(path: .init(id: sessionId)))
    }

    /// `GET /technicians/me` — the caller's own technician row + live capability grants.
    /// Freeform `data` payload (no schema in the spec, just `summary`), same treatment as
    /// login/refresh: round-tripped through `decodeData` into `TechnicianMeData`.
    func fetchIdentity() async throws -> Identity {
        let response: Operations.get_sol_technicians_sol_me.Output
        do {
            response = try await client.get_sol_technicians_sol_me()
        } catch {
            throw ApiError.network(error)
        }
        switch response {
        case .ok(let ok):
            let payload = try ok.body.json
            let data = try decodeData(payload.data.additionalProperties, as: TechnicianMeData.self)
            return Identity(technicianId: data.technician?.id, capabilities: data.capabilities)
        case .unauthorized: throw ApiError.unauthorized
        case .badRequest: throw ApiError.server(status: 400)
        case .forbidden: throw ApiError.server(status: 403)
        case .notFound: throw ApiError.server(status: 404)
        case .conflict: throw ApiError.server(status: 409)
        case .tooManyRequests: throw ApiError.server(status: 429)
        case .internalServerError: throw ApiError.server(status: 500)
        case .undocumented(let statusCode, _): throw ApiError.server(status: statusCode)
        }
    }

    private func decodeData<T: Decodable>(_ container: OpenAPIObjectContainer, as type: T.Type) throws -> T {
        do {
            let data = try JSONEncoder().encode(container)
            return try JSONDecoder().decode(T.self, from: data)
        } catch {
            throw ApiError.decoding
        }
    }
}

/// Mirrors the `data` payload of `POST /device-auth/login`'s 201 response.
private struct DeviceAuthLoginData: Decodable {
    struct Session: Decodable {
        let id: String
        let businessId: String
        let accountId: String
        let deviceName: String
    }
    let session: Session
    let accessToken: String
    let refreshToken: String
}

/// Mirrors the `data` payload of `POST /device-auth/refresh`'s 200 response.
private struct DeviceAuthRefreshData: Decodable {
    let accessToken: String
    let refreshToken: String
}

/// Mirrors the `data` payload of `GET /technicians/me`'s 200 response. Shape inferred from
/// the spec's `summary` ("caller's own Technician row ... plus their live capabilities")
/// since the schema itself is undocumented freeform `additionalProperties: true` — not
/// independently verifiable against a live server response, flagged for confirmation.
private struct TechnicianMeData: Decodable {
    struct Technician: Decodable {
        let id: String
    }
    let technician: Technician?
    let capabilities: [String]
}
