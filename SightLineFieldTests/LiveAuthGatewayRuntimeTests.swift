// Exercises LiveAuthGateway's actual runtime encode/decode path against the real generated
// Client, using a stub ClientTransport instead of a live server. Proves the operation-name fix
// and the `payload.data.additionalProperties` shape fix (see task-10-report.md) aren't just
// compile-clean but decode a realistic response body correctly. Compiles only where the
// swift-openapi-generator plugin has produced `Generated/Client.swift` — i.e. in the Xcode
// test target (CI), not standalone `swiftc -parse`.
import XCTest
import HTTPTypes
import OpenAPIRuntime
@testable import SightLineField

private struct StubTransport: ClientTransport {
    let statusCode: Int
    let jsonBody: String
    private(set) var capturedRequest: HTTPRequest?

    func send(_ request: HTTPRequest, body: HTTPBody?, baseURL: URL, operationID: String) async throws -> (HTTPResponse, HTTPBody?) {
        let response = HTTPResponse(status: .init(code: statusCode))
        let data = Data(jsonBody.utf8)
        return (response, HTTPBody(data))
    }
}

final class LiveAuthGatewayRuntimeTests: XCTestCase {
    func makeClient(statusCode: Int, jsonBody: String) -> Client {
        Client(serverURL: URL(string: "http://example.invalid")!, transport: StubTransport(statusCode: statusCode, jsonBody: jsonBody))
    }

    func testLoginDecodesRealisticResponseBody() async throws {
        let json = """
        {"data":{"session":{"id":"sess_1","businessId":"biz_1","accountId":"acct_1","deviceName":"iPhone"},"accessToken":"acc_tok","refreshToken":"ref_tok"}}
        """
        let gateway = LiveAuthGateway(client: makeClient(statusCode: 201, jsonBody: json))
        let (pair, context) = try await gateway.login(email: "t@x.com", password: "pw", device: .current)
        XCTAssertEqual(pair, TokenPair(accessToken: "acc_tok", refreshToken: "ref_tok"))
        XCTAssertEqual(context.accountId, "acct_1")
        XCTAssertEqual(context.businessId, "biz_1")
        XCTAssertEqual(context.sessionId, "sess_1")
        XCTAssertEqual(context.email, "t@x.com")
    }

    func testLoginMapsUnauthorizedStatus() async throws {
        let errorJson = """
        {"error":{"code":"unauthorized","message":"bad credentials"}}
        """
        let gateway = LiveAuthGateway(client: makeClient(statusCode: 401, jsonBody: errorJson))
        do {
            _ = try await gateway.login(email: "t@x.com", password: "bad", device: .current)
            XCTFail("expected ApiError.unauthorized")
        } catch ApiError.unauthorized {
            // expected
        }
    }

    func testRefreshDecodesRealisticResponseBody() async throws {
        let json = """
        {"data":{"accessToken":"new_acc","refreshToken":"new_ref"}}
        """
        let gateway = LiveAuthGateway(client: makeClient(statusCode: 200, jsonBody: json))
        let pair = try await gateway.refresh(refreshToken: "old_ref")
        XCTAssertEqual(pair, TokenPair(accessToken: "new_acc", refreshToken: "new_ref"))
    }

    func testLogoutNeverThrowsOnServerError() async {
        let errorJson = """
        {"error":{"code":"internal_error","message":"boom"}}
        """
        let gateway = LiveAuthGateway(client: makeClient(statusCode: 500, jsonBody: errorJson))
        await gateway.logout(sessionId: "s1") // no-throw contract: must simply return
    }
}
