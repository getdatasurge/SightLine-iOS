import Foundation

/// The seam `OutboxWorker` replays `.photoUpload` rows through (M4b). Deliberately not built on
/// the generated OpenAPI `Client` like `WorkLogGateway`/`SyncBackend` — `swift-openapi-generator`
/// has no ergonomic way to express a freeform multipart `file` part for this route, so
/// `LivePhotoUploadGateway` wraps `URLSession` directly instead. No return value: unlike
/// check-in/check-out, a photo upload has no local row to reconcile against (append-only capture,
/// see the M4b spec) — a call that doesn't throw is the entire success signal `OutboxWorker` needs.
protocol PhotoUploadGateway: Sendable {
    func upload(entityType: String, entityId: String, imageData: Data, filename: String, mimeType: String) async throws
}

/// Wraps `URLSession` for `POST {AppEnvironment.baseURL}/api/v1/uploads` (M4b) — a device-session
/// route, `multipart/form-data` with `file` (binary + filename + content-type), `entityType`
/// ("surface"/"job"), `entityId`. See `.superpowers/sdd/m4b-backend-report.md` for the shipped
/// wire shape (`{data:{id,url,filename,mimeType,sizeBytes,entityType,entityId}}` on success);
/// nothing in that body is consumed here, so it's discarded rather than decoded.
struct LivePhotoUploadGateway: PhotoUploadGateway {
    let environment: AppEnvironment
    let tokenStore: TokenStore
    let urlSession: URLSession

    init(environment: AppEnvironment, tokenStore: TokenStore, urlSession: URLSession = .shared) {
        self.environment = environment
        self.tokenStore = tokenStore
        self.urlSession = urlSession
    }

    func upload(entityType: String, entityId: String, imageData: Data, filename: String, mimeType: String) async throws {
        let boundary = "Boundary-\(UUID().uuidString)"
        var request = URLRequest(url: environment.baseURL.appending(path: "api/v1/uploads"))
        request.httpMethod = "POST"
        request.setValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")
        if let pair = tokenStore.load() {
            request.setValue("Bearer \(pair.accessToken)", forHTTPHeaderField: "Authorization")
        }
        request.httpBody = Self.multipartBody(
            boundary: boundary, entityType: entityType, entityId: entityId,
            imageData: imageData, filename: filename, mimeType: mimeType
        )

        let response: URLResponse
        do {
            (_, response) = try await urlSession.data(for: request)
        } catch {
            throw ApiError.network(error)
        }
        guard let http = response as? HTTPURLResponse else {
            throw ApiError.network(URLError(.badServerResponse))
        }
        switch http.statusCode {
        case 200...299:
            return
        case 401:
            throw ApiError.unauthorized
        default:
            throw ApiError.server(status: http.statusCode)
        }
    }

    /// Three parts, `file` last (its own convention only — the server reads the whole stream
    /// regardless of field order): `entityType`, `entityId`, then `file` with the binary payload
    /// framed by its own `Content-Disposition`/`Content-Type` sub-headers.
    private static func multipartBody(
        boundary: String, entityType: String, entityId: String, imageData: Data, filename: String, mimeType: String
    ) -> Data {
        var body = Data()
        func appendField(_ name: String, _ value: String) {
            body.append("--\(boundary)\r\n".utf8Data)
            body.append("Content-Disposition: form-data; name=\"\(name)\"\r\n\r\n".utf8Data)
            body.append("\(value)\r\n".utf8Data)
        }
        appendField("entityType", entityType)
        appendField("entityId", entityId)
        body.append("--\(boundary)\r\n".utf8Data)
        body.append("Content-Disposition: form-data; name=\"file\"; filename=\"\(filename)\"\r\n".utf8Data)
        body.append("Content-Type: \(mimeType)\r\n\r\n".utf8Data)
        body.append(imageData)
        body.append("\r\n--\(boundary)--\r\n".utf8Data)
        return body
    }
}

private extension String {
    /// Every string appended into the multipart body here is a literal (boundary markers, field
    /// names/values we constructed) — always representable as UTF-8, so this never actually
    /// traps; named instead of `.data(using: .utf8)!` sprinkled at each call site.
    var utf8Data: Data { Data(self.utf8) }
}
