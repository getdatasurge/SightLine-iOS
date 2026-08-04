# SightLine Field — M2 iOS Skeleton Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** A buildable SwiftUI iOS app skeleton with working login against the live M1 `/api/v1/auth/*` backend, SwiftData store schema, generated OpenAPI client, shell screens, tests, and CI.

**Architecture:** XcodeGen-defined app (`.xcodeproj` gitignored). Layering: views read only the local SwiftData store; the network layer writes into the store. `SessionManager` owns auth state; a middleware injects bearer tokens and performs one refresh-then-retry. Features import only each other's public surfaces.

**Tech Stack:** Swift 5.10+, SwiftUI, SwiftData, `@Observable`, XcodeGen, swift-openapi-generator (SPM plugin) + swift-openapi-urlsession, XCTest, GitHub Actions (macOS).

## Global Constraints

- Minimum iOS: **17.0**. Bundle id: `com.getdatasurge.sightline.field`. Display name: **SightLine Field**.
- SwiftUI only. No UIKit. No third-party dependencies beyond Apple's swift-openapi packages.
- Keychain accessibility: `kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly`. Tokens NEVER in UserDefaults.
- No hand-written networking outside `Core/ApiClient` transport/middleware seam.
- No fake/sample data in shells — explicit empty states labeled "Awaiting first sync (M2)".
- Views never `await` network calls directly (PP.10 layering).
- Branch: `feat/m2-skeleton`. NEVER push without explicit user go-ahead. Commit per task.
- Build/test command (also CI): `xcodegen generate && xcodebuild -project SightLineField.xcodeproj -scheme SightLineField -destination 'platform=iOS Simulator,name=iPhone 16' build test`.

---

### Task 1: Repo scaffolding — project.yml, gitignore, README, PLAN

**Files:**
- Create: `project.yml`, `.gitignore`, `README.md`, `PLAN.md`
- Create: `SightLineField/App/SightLineFieldApp.swift`, `SightLineField/App/RootView.swift` (placeholder bodies; replaced in Task 8)
- Create: `SightLineField/Resources/Assets.xcassets/Contents.json`

**Interfaces:**
- Produces: app target `SightLineField`, test target `SightLineFieldTests`, SPM deps `swift-openapi-runtime`/`swift-openapi-urlsession` available to all later tasks.

- [ ] **Step 1: Write `project.yml`**

```yaml
name: SightLineField
options:
  bundleIdPrefix: com.getdatasurge.sightline
  deploymentTarget:
    iOS: "17.0"
  createIntermediateGroups: true
packages:
  OpenAPIRuntime:
    url: https://github.com/apple/swift-openapi-runtime
    from: 1.5.0
  OpenAPIURLSession:
    url: https://github.com/apple/swift-openapi-urlsession
    from: 1.0.2
targets:
  SightLineField:
    type: application
    platform: iOS
    sources: [SightLineField]
    dependencies:
      - package: OpenAPIRuntime
        product: OpenAPIRuntime
      - package: OpenAPIURLSession
        product: OpenAPIURLSession
    info:
      path: SightLineField/Info.plist
      properties:
        CFBundleDisplayName: SightLine Field
        UILaunchScreen: {}
        NSAppTransportSecurity:
          NSAllowsLocalNetworking: true
    settings:
      base:
        PRODUCT_BUNDLE_IDENTIFIER: com.getdatasurge.sightline.field
        SWIFT_VERSION: "5.10"
        TARGETED_DEVICE_FAMILY: "1"
  SightLineFieldTests:
    type: bundle.unit-test
    platform: iOS
    sources: [SightLineFieldTests]
    dependencies:
      - target: SightLineField
```

- [ ] **Step 2: Write `.gitignore`**

```
.DS_Store
*.xcodeproj
xcuserdata/
DerivedData/
.build/
```

- [ ] **Step 3: Write placeholder app entry**

`SightLineField/App/SightLineFieldApp.swift`:
```swift
import SwiftUI

@main
struct SightLineFieldApp: App {
    var body: some Scene {
        WindowGroup { RootView() }
    }
}
```

`SightLineField/App/RootView.swift`:
```swift
import SwiftUI

struct RootView: View {
    var body: some View {
        Text("SightLine Field")
    }
}
```

`SightLineField/Resources/Assets.xcassets/Contents.json`:
```json
{ "info": { "author": "xcode", "version": 1 } }
```

- [ ] **Step 4: Write `README.md`** — setup: `brew install xcodegen`, `xcodegen generate`, open project, select iPhone simulator, run; dev pairing note: backend must run the `integration/field-app` branch (M1 auth) — `PORT=3005 npm run dev` in that worktree; Debug base URL defaults to `http://localhost:3005`, override with launch argument `-apiBaseURL <url>`.

- [ ] **Step 5: Write `PLAN.md`** — copy the "Milestone outline" section from `docs/superpowers/specs/2026-08-04-m2-ios-skeleton-design.md` (M2 read-only app, M3 online writes, M4 offline sync, M5 capture port) plus a "Current status: skeleton" header linking the spec.

- [ ] **Step 6: Verify generation + build**

Run: `xcodegen generate && xcodebuild -project SightLineField.xcodeproj -scheme SightLineField -destination 'platform=iOS Simulator,name=iPhone 16' build`
Expected: `BUILD SUCCEEDED` (add one placeholder XCTest file `SightLineFieldTests/PlaceholderTests.swift` with `func testTruth() { XCTAssertTrue(true) }` so the test target compiles).

- [ ] **Step 7: Commit**

```bash
git add -A && git commit -m "chore: XcodeGen project skeleton, app entry, README/PLAN"
```

---

### Task 2: Core/Config — AppEnvironment

**Files:**
- Create: `SightLineField/Core/Config/AppEnvironment.swift`
- Test: `SightLineFieldTests/AppEnvironmentTests.swift`

**Interfaces:**
- Produces: `struct AppEnvironment { let baseURL: URL; static func resolve(processInfo: ProcessInfo) -> AppEnvironment }`.

- [ ] **Step 1: Write failing tests**

```swift
import XCTest
@testable import SightLineField

final class AppEnvironmentTests: XCTestCase {
    func testDefaultDebugBaseURL() {
        let env = AppEnvironment.resolve(arguments: [])
        XCTAssertEqual(env.baseURL.absoluteString, "http://localhost:3005")
    }
    func testLaunchArgumentOverride() {
        let env = AppEnvironment.resolve(arguments: ["-apiBaseURL", "https://staging.example.com"])
        XCTAssertEqual(env.baseURL.absoluteString, "https://staging.example.com")
    }
    func testMalformedOverrideFallsBackToDefault() {
        let env = AppEnvironment.resolve(arguments: ["-apiBaseURL", ""])
        XCTAssertEqual(env.baseURL.absoluteString, "http://localhost:3005")
    }
}
```

- [ ] **Step 2: Run tests, expect FAIL** (`AppEnvironment` undefined).

- [ ] **Step 3: Implement**

```swift
import Foundation

struct AppEnvironment: Sendable {
    let baseURL: URL

    static let `default` = AppEnvironment(baseURL: defaultBaseURL)

    private static var defaultBaseURL: URL {
        #if DEBUG
        URL(string: "http://localhost:3005")!
        #else
        URL(string: "https://staging-placeholder.sightline.invalid")! // TBD host is intentional: Release target unset until staging exists (spec: non-blocking)
        #endif
    }

    static func resolve(arguments: [String] = ProcessInfo.processInfo.arguments) -> AppEnvironment {
        if let i = arguments.firstIndex(of: "-apiBaseURL"),
           arguments.indices.contains(i + 1),
           let url = URL(string: arguments[i + 1]),
           url.scheme != nil {
            return AppEnvironment(baseURL: url)
        }
        return .default
    }
}
```

- [ ] **Step 4: Run tests, expect PASS.**
- [ ] **Step 5: Commit** — `git add -A && git commit -m "feat(config): AppEnvironment with launch-arg override"`

---

### Task 3: Core/Auth — KeychainTokenStore

**Files:**
- Create: `SightLineField/Core/Auth/TokenPair.swift`, `SightLineField/Core/Auth/KeychainTokenStore.swift`
- Test: `SightLineFieldTests/KeychainTokenStoreTests.swift`

**Interfaces:**
- Produces:
  - `struct TokenPair: Codable, Equatable { let accessToken: String; let refreshToken: String }`
  - `protocol TokenStore: Sendable { func load() -> TokenPair?; func save(_ pair: TokenPair) throws; func clear() }`
  - `final class KeychainTokenStore: TokenStore` (service `com.getdatasurge.sightline.field`, account `device-session`, `kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly`).
  - `final class InMemoryTokenStore: TokenStore` (test double, lives in app target so SessionManager tests reuse it).

- [ ] **Step 1: Write failing tests** (run on simulator keychain)

```swift
import XCTest
@testable import SightLineField

final class KeychainTokenStoreTests: XCTestCase {
    let store = KeychainTokenStore(service: "com.getdatasurge.sightline.field.tests")
    override func tearDown() { store.clear() }

    func testRoundTrip() throws {
        let pair = TokenPair(accessToken: "slm_a.1", refreshToken: "slm_r.2")
        try store.save(pair)
        XCTAssertEqual(store.load(), pair)
    }
    func testOverwrite() throws {
        try store.save(TokenPair(accessToken: "a", refreshToken: "b"))
        try store.save(TokenPair(accessToken: "c", refreshToken: "d"))
        XCTAssertEqual(store.load(), TokenPair(accessToken: "c", refreshToken: "d"))
    }
    func testClear() throws {
        try store.save(TokenPair(accessToken: "a", refreshToken: "b"))
        store.clear()
        XCTAssertNil(store.load())
    }
}
```

- [ ] **Step 2: Run tests, expect FAIL.**

- [ ] **Step 3: Implement**

```swift
import Foundation
import Security

struct TokenPair: Codable, Equatable, Sendable {
    let accessToken: String
    let refreshToken: String
}

protocol TokenStore: Sendable {
    func load() -> TokenPair?
    func save(_ pair: TokenPair) throws
    func clear()
}

struct KeychainError: Error { let status: OSStatus }

final class KeychainTokenStore: TokenStore {
    private let service: String
    private let account = "device-session"

    init(service: String = "com.getdatasurge.sightline.field") { self.service = service }

    private var baseQuery: [String: Any] {
        [kSecClass as String: kSecClassGenericPassword,
         kSecAttrService as String: service,
         kSecAttrAccount as String: account]
    }

    func load() -> TokenPair? {
        var query = baseQuery
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var item: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &item) == errSecSuccess,
              let data = item as? Data else { return nil }
        return try? JSONDecoder().decode(TokenPair.self, from: data)
    }

    func save(_ pair: TokenPair) throws {
        let data = try JSONEncoder().encode(pair)
        clear()
        var query = baseQuery
        query[kSecValueData as String] = data
        query[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        let status = SecItemAdd(query as CFDictionary, nil)
        guard status == errSecSuccess else { throw KeychainError(status: status) }
    }

    func clear() { SecItemDelete(baseQuery as CFDictionary) }
}

final class InMemoryTokenStore: TokenStore, @unchecked Sendable {
    private var pair: TokenPair?
    private let lock = NSLock()
    func load() -> TokenPair? { lock.withLock { pair } }
    func save(_ p: TokenPair) throws { lock.withLock { pair = p } }
    func clear() { lock.withLock { pair = nil } }
}
```

- [ ] **Step 4: Run tests, expect PASS.**
- [ ] **Step 5: Commit** — `git commit -am "feat(auth): Keychain token store (AfterFirstUnlockThisDeviceOnly)"`

---

### Task 4: OpenAPI spec snapshot + generated client

**Files:**
- Create: `openapi/openapi.json` (fetched snapshot), `SightLineField/Core/ApiClient/openapi.json` (copy consumed by plugin), `SightLineField/Core/ApiClient/openapi-generator-config.yaml`
- Modify: `project.yml` (add `OpenAPIGenerator` package + plugin to target)

**Interfaces:**
- Produces: generated `Client` type + `Operations`/`Components` namespaces (types mode) for `/api/v1/auth/*` and existing v1 resources; later tasks call `Client(serverURL:transport:middlewares:)`.

- [ ] **Step 1: Fetch the spec from a server running M1.** In the web repo's field-app worktree (`…/SightLine/.worktrees/field-app`, branch `integration/field-app`): start `PORT=3005 npm run dev` as a supervised process (do NOT touch the standing local stack), wait for ready, then:

Run: `curl -sf http://localhost:3005/api/v1/openapi | python3 -m json.tool > openapi/openapi.json && cp openapi/openapi.json SightLineField/Core/ApiClient/openapi.json`
Expected: valid OpenAPI 3.1 JSON containing `"/auth/login"`, `"/auth/refresh"`, `"/auth/logout"`, `"/auth/me"` paths. If auth paths are absent, STOP — wrong branch is serving; fix the server checkout before proceeding. Stop the temporary server afterwards.

- [ ] **Step 2: Write generator config** `SightLineField/Core/ApiClient/openapi-generator-config.yaml`:

```yaml
generate:
  - types
  - client
accessModifier: internal
```

- [ ] **Step 3: Wire the plugin in `project.yml`** — add to `packages:`:

```yaml
  OpenAPIGenerator:
    url: https://github.com/apple/swift-openapi-generator
    from: 1.7.0
```

and under the `SightLineField` target:

```yaml
    buildToolPlugins:
      - plugin: OpenAPIGenerator
        package: OpenAPIGenerator
```

- [ ] **Step 4: Regenerate + build.**

Run: `xcodegen generate && xcodebuild -project SightLineField.xcodeproj -scheme SightLineField -destination 'platform=iOS Simulator,name=iPhone 16' build`
Expected: `BUILD SUCCEEDED`; plugin emits `Client.swift`/`Types.swift` into DerivedData. First run may require `-skipPackagePluginValidation`; if so, add `xcodebuild` flag in README and CI.

- [ ] **Step 5: Commit** — `git add -A && git commit -m "feat(api): committed OpenAPI snapshot + swift-openapi-generator plugin"`

---

### Task 5: Core/ApiClient — transport seam + auth middleware

**Files:**
- Create: `SightLineField/Core/ApiClient/ApiError.swift`, `SightLineField/Core/ApiClient/BearerAuthMiddleware.swift`, `SightLineField/Core/ApiClient/ApiClientFactory.swift`
- Test: `SightLineFieldTests/BearerAuthMiddlewareTests.swift`

**Interfaces:**
- Consumes: `TokenStore` (Task 3), `AppEnvironment` (Task 2), generated `Client` (Task 4).
- Produces:
  - `enum ApiError: Error { case network(Error), unauthorized, server(status: Int), decoding }`
  - `protocol TokenRefresher: Sendable { func refreshTokens() async -> Bool }` (implemented by `SessionManager` in Task 6)
  - `struct BearerAuthMiddleware: ClientMiddleware` — injects `Authorization: Bearer <access>` from `TokenStore`; on 401 response asks `TokenRefresher` to refresh once and replays the request; second 401 propagates.
  - `enum ApiClientFactory { static func make(environment: AppEnvironment, tokenStore: TokenStore, refresher: TokenRefresher) -> Client }` using `URLSessionTransport`, serverURL `environment.baseURL.appending(path: "api/v1")`.

- [ ] **Step 1: Write failing middleware tests** using a stub `next` closure:

```swift
import XCTest
import OpenAPIRuntime
import HTTPTypes
@testable import SightLineField

final class RefresherSpy: TokenRefresher, @unchecked Sendable {
    var result = false
    private(set) var calls = 0
    func refreshTokens() async -> Bool { calls += 1; return result }
}

final class BearerAuthMiddlewareTests: XCTestCase {
    func run(_ mw: BearerAuthMiddleware, statuses: [Int], onRequest: ((HTTPRequest) -> Void)? = nil) async throws -> HTTPResponse {
        var remaining = statuses
        let (req, url) = (HTTPRequest(method: .get, scheme: nil, authority: nil, path: "/jobs"), URL(string: "http://x")!)
        return try await mw.intercept(req, body: nil, baseURL: url, operationID: "listJobs") { request, _, _ in
            onRequest?(request)
            return (HTTPResponse(status: .init(code: remaining.removeFirst())), nil)
        }.0
    }

    func testInjectsBearerHeader() async throws {
        let store = InMemoryTokenStore()
        try store.save(TokenPair(accessToken: "slm_a.1", refreshToken: "r"))
        var seen: String?
        _ = try await run(BearerAuthMiddleware(tokenStore: store, refresher: RefresherSpy()), statuses: [200]) {
            seen = $0.headerFields[.authorization]
        }
        XCTAssertEqual(seen, "Bearer slm_a.1")
    }

    func testRefreshesOnceAndReplaysOn401() async throws {
        let store = InMemoryTokenStore()
        try store.save(TokenPair(accessToken: "old", refreshToken: "r"))
        let spy = RefresherSpy(); spy.result = true
        let resp = try await run(BearerAuthMiddleware(tokenStore: store, refresher: spy), statuses: [401, 200])
        XCTAssertEqual(resp.status.code, 200)
        XCTAssertEqual(spy.calls, 1)
    }

    func testSecond401Propagates() async throws {
        let store = InMemoryTokenStore()
        try store.save(TokenPair(accessToken: "old", refreshToken: "r"))
        let spy = RefresherSpy(); spy.result = true
        let resp = try await run(BearerAuthMiddleware(tokenStore: store, refresher: spy), statuses: [401, 401])
        XCTAssertEqual(resp.status.code, 401)
        XCTAssertEqual(spy.calls, 1)
    }
}
```

- [ ] **Step 2: Run tests, expect FAIL.**

- [ ] **Step 3: Implement**

```swift
import Foundation
import OpenAPIRuntime
import HTTPTypes

enum ApiError: Error {
    case network(Error)
    case unauthorized
    case server(status: Int)
    case decoding
}

protocol TokenRefresher: Sendable {
    func refreshTokens() async -> Bool
}

struct BearerAuthMiddleware: ClientMiddleware {
    let tokenStore: TokenStore
    let refresher: TokenRefresher

    func intercept(
        _ request: HTTPRequest,
        body: HTTPBody?,
        baseURL: URL,
        operationID: String,
        next: (HTTPRequest, HTTPBody?, URL) async throws -> (HTTPResponse, HTTPBody?)
    ) async throws -> (HTTPResponse, HTTPBody?) {
        func authed(_ r: HTTPRequest) -> HTTPRequest {
            var r = r
            if let pair = tokenStore.load() {
                r.headerFields[.authorization] = "Bearer \(pair.accessToken)"
            }
            return r
        }
        let (response, responseBody) = try await next(authed(request), body, baseURL)
        guard response.status.code == 401, await refresher.refreshTokens() else {
            return (response, responseBody)
        }
        return try await next(authed(request), body, baseURL)
    }
}
```

`ApiClientFactory.swift`:
```swift
import Foundation
import OpenAPIRuntime
import OpenAPIURLSession

enum ApiClientFactory {
    static func make(environment: AppEnvironment, tokenStore: TokenStore, refresher: TokenRefresher) -> Client {
        Client(
            serverURL: environment.baseURL.appending(path: "api/v1"),
            transport: URLSessionTransport(),
            middlewares: [BearerAuthMiddleware(tokenStore: tokenStore, refresher: refresher)]
        )
    }
}
```

- [ ] **Step 4: Run tests, expect PASS.**
- [ ] **Step 5: Commit** — `git commit -am "feat(api): bearer middleware with single-refresh replay, client factory"`

---

### Task 6: Core/Auth — SessionManager

**Files:**
- Create: `SightLineField/Core/Auth/SessionManager.swift`, `SightLineField/Core/Auth/AuthGateway.swift`
- Test: `SightLineFieldTests/SessionManagerTests.swift`

**Interfaces:**
- Consumes: `TokenStore`, `TokenPair` (Task 3); generated auth operations (Task 4).
- Produces:
  - `struct AccountContext: Equatable, Sendable { let accountId: String; let email: String; let businessId: String; let businessName: String; let technicianId: String?; let capabilities: [String] }` (field names must match `/auth/me` response in `openapi/openapi.json` — verify at implementation, adjust decoding, not the struct names).
  - `protocol AuthGateway: Sendable { func login(email: String, password: String, device: DeviceInfo) async throws -> (TokenPair, AccountContext); func refresh(refreshToken: String) async throws -> TokenPair; func logout() async; func me() async throws -> AccountContext }` — the ONLY seam that touches generated auth operations; `LiveAuthGateway` wraps `Client`, `StubAuthGateway` lives in tests.
  - `struct DeviceInfo { let name: String; let model: String; let osVersion: String; let appVersion: String; static var current: DeviceInfo }` (from `UIDevice`/`Bundle`).
  - `@Observable @MainActor final class SessionManager: TokenRefresher` with `enum State: Equatable { case signedOut, authenticating, signedIn(AccountContext) }`, `private(set) var state: State`, `func bootstrap() async` (keychain pair present → `me()` → signedIn; failure → refresh once → retry `me()`; failure → clear + signedOut), `func login(email:password:) async`, `func logout() async`, `nonisolated func refreshTokens() async -> Bool` (one-time-use rotation: on refresh failure clears store and flips to signedOut — theft signal).

- [ ] **Step 1: Write failing tests** with `StubAuthGateway` (configurable results, call counts):

```swift
import XCTest
@testable import SightLineField

@MainActor
final class SessionManagerTests: XCTestCase {
    func ctx() -> AccountContext {
        AccountContext(accountId: "a1", email: "t@x.com", businessId: "b1",
                       businessName: "Shop", technicianId: "tech1", capabilities: ["jobs.manage"])
    }

    func testLoginSuccessStoresPairAndSignsIn() async throws {
        let store = InMemoryTokenStore()
        let gw = StubAuthGateway(loginResult: .success((TokenPair(accessToken: "a", refreshToken: "r"), ctx())))
        let sm = SessionManager(gateway: gw, tokenStore: store)
        await sm.login(email: "t@x.com", password: "pw")
        XCTAssertEqual(sm.state, .signedIn(ctx()))
        XCTAssertEqual(store.load(), TokenPair(accessToken: "a", refreshToken: "r"))
    }

    func testLoginFailureStaysSignedOutWithError() async {
        let sm = SessionManager(gateway: StubAuthGateway(loginResult: .failure(ApiError.unauthorized)),
                                tokenStore: InMemoryTokenStore())
        await sm.login(email: "t@x.com", password: "bad")
        XCTAssertEqual(sm.state, .signedOut)
        XCTAssertNotNil(sm.lastError)
    }

    func testRefreshRotationSavesNewPair() async throws {
        let store = InMemoryTokenStore()
        try store.save(TokenPair(accessToken: "old", refreshToken: "r1"))
        let gw = StubAuthGateway(refreshResult: .success(TokenPair(accessToken: "new", refreshToken: "r2")))
        let sm = SessionManager(gateway: gw, tokenStore: store)
        let ok = await sm.refreshTokens()
        XCTAssertTrue(ok)
        XCTAssertEqual(store.load(), TokenPair(accessToken: "new", refreshToken: "r2"))
    }

    func testRefreshFailureClearsAndSignsOut() async throws {
        let store = InMemoryTokenStore()
        try store.save(TokenPair(accessToken: "old", refreshToken: "r1"))
        let sm = SessionManager(gateway: StubAuthGateway(refreshResult: .failure(ApiError.unauthorized)), tokenStore: store)
        let ok = await sm.refreshTokens()
        XCTAssertFalse(ok)
        XCTAssertNil(store.load())
        XCTAssertEqual(sm.state, .signedOut)
    }

    func testLogoutClearsEvenIfNetworkFails() async throws {
        let store = InMemoryTokenStore()
        try store.save(TokenPair(accessToken: "a", refreshToken: "r"))
        let sm = SessionManager(gateway: StubAuthGateway(logoutThrows: true), tokenStore: store)
        await sm.logout()
        XCTAssertNil(store.load())
        XCTAssertEqual(sm.state, .signedOut)
    }

    func testBootstrapWithValidPairSignsIn() async throws {
        let store = InMemoryTokenStore()
        try store.save(TokenPair(accessToken: "a", refreshToken: "r"))
        let sm = SessionManager(gateway: StubAuthGateway(meResult: .success(ctx())), tokenStore: store)
        await sm.bootstrap()
        XCTAssertEqual(sm.state, .signedIn(ctx()))
    }
}
```

- [ ] **Step 2: Run tests, expect FAIL.**
- [ ] **Step 3: Implement `SessionManager` + `StubAuthGateway`** per the Produces block (implementation is direct state-machine code; keep `LiveAuthGateway` in `AuthGateway.swift` mapping generated operation inputs/outputs and translating non-2xx to `ApiError`).
- [ ] **Step 4: Run tests, expect PASS.**
- [ ] **Step 5: Commit** — `git commit -am "feat(auth): SessionManager state machine + AuthGateway seam"`

---

### Task 7: Core/Store + Core/DesignSystem

**Files:**
- Create: `SightLineField/Core/Store/Models.swift`, `SightLineField/Core/Store/StoreContainer.swift`
- Create: `SightLineField/Core/DesignSystem/Tokens.swift`
- Test: `SightLineFieldTests/StoreContainerTests.swift`

**Interfaces:**
- Produces:
  - SwiftData `@Model` classes: `JobSummary(id: String, name: String, address: String?, status: String, updatedAt: Date)`, `Appointment(id: String, jobId: String?, title: String, start: Date, end: Date, status: String, updatedAt: Date)`, `WorkType(id: String, name: String, unit: String, isActive: Bool, updatedAt: Date)`, `WorkLog(id: String, clientUuid: String, jobId: String, workTypeId: String?, status: String, checkInAt: Date, checkOutAt: Date?, quantity: Double?, notes: String?, updatedAt: Date)`, `Surface(id: String, jobId: String, label: String, status: String, updatedAt: Date)`, `SyncOutbox(clientUuid: String, endpoint: String, payload: Data, attempts: Int, lastError: String?, state: String)` with `enum OutboxState: String { case pending, inFlight, conflict, done }`.
  - `enum StoreContainer { static func make(inMemory: Bool = false) throws -> ModelContainer }` registering all six models.
  - `enum DS` namespace: `DS.Color.accent/.background/.textPrimary/.textSecondary`, `DS.Color.surfaceStatus(_ status: String) -> Color` (MEASURED/CUT/FILM_CUT/INSTALLED/COMPLETED/NEEDS_REVIEW/PENDING/UNDER_REVIEW → distinct colors), `DS.Font.title/.body/.caption` — values transcribed from the web repo's `DESIGN.md` token section at implementation time.

- [ ] **Step 1: Write failing test** — `StoreContainerTests`: `make(inMemory: true)` succeeds; insert one of each model, fetch back, count == 1 each.
- [ ] **Step 2: Run, expect FAIL.** 
- [ ] **Step 3: Implement models + container + tokens.**
- [ ] **Step 4: Run tests, expect PASS.**
- [ ] **Step 5: Commit** — `git commit -am "feat(store): SwiftData schema incl. SyncOutbox; design tokens"`

---

### Task 8: Features — Login + shell screens + root routing

**Files:**
- Create: `SightLineField/Features/Login/LoginView.swift`, `LoginViewModel.swift`
- Create: `SightLineField/Features/Schedule/ScheduleView.swift`, `SightLineField/Features/Jobs/JobListView.swift`, `JobDetailView.swift`, `SightLineField/Features/WorkLogs/WorkLogsView.swift`
- Create: `SightLineField/App/AppDependencies.swift`, modify: `SightLineField/App/RootView.swift`, `SightLineFieldApp.swift`
- Create: `SightLineField/Core/DesignSystem/EmptyStateView.swift`

**Interfaces:**
- Consumes: `SessionManager` (Task 6), `StoreContainer`/models (Task 7), `DS` tokens.
- Produces: `AppDependencies` (`@MainActor` composition root building `AppEnvironment` → `KeychainTokenStore` → `SessionManager` → `Client` → `ModelContainer`, injected via SwiftUI environment); `RootView` switches on `session.state`: `signedOut/authenticating → LoginView`, `signedIn → TabView { ScheduleView, JobListView, WorkLogsView }`.

- [ ] **Step 1: Implement.** Rules: `LoginView` = email + secure password fields, submit disabled while empty/authenticating, error text from `session.lastError` (map `ApiError.unauthorized` → "Wrong email or password", network → "Can't reach server"). Shell screens use `@Query` on their model type and render `EmptyStateView(title: "Nothing here yet", detail: "Awaiting first sync (M2)")` when empty — no placeholder rows. `JobDetailView` shows job fields + empty surfaces section. `SightLineFieldApp` calls `await session.bootstrap()` in `.task`.
- [ ] **Step 2: Build + run full test suite** — `BUILD SUCCEEDED`, all tests PASS.
- [ ] **Step 3: Smoke test in simulator against live M1 backend.** Start `PORT=3005 npm run dev` in the field-app worktree (supervised). Run the app; sign in with a seeded technician (from web repo `prisma/seed.ts` — look up the seeded technician email/password there). Expected: login succeeds → tab shell with empty states; kill server → relaunch app → bootstrap fails gracefully to Login with network error (no crash). Stop the temp server.
- [ ] **Step 4: Commit** — `git commit -am "feat(app): login flow, tab shells, auth-gated root"`

---

### Task 9: CI workflow

**Files:**
- Create: `.github/workflows/ci.yml`

- [ ] **Step 1: Write workflow**

```yaml
name: CI
on:
  pull_request:
  push:
    branches: [main]
jobs:
  build-test:
    runs-on: macos-15
    steps:
      - uses: actions/checkout@v4
      - name: Select Xcode
        run: sudo xcode-select -s /Applications/Xcode_16.2.app
      - name: Install XcodeGen
        run: brew install xcodegen
      - name: Generate project
        run: xcodegen generate
      - name: Build and test
        run: |
          xcodebuild -project SightLineField.xcodeproj -scheme SightLineField \
            -destination 'platform=iOS Simulator,name=iPhone 16' \
            -skipPackagePluginValidation build test
```

- [ ] **Step 2: Validate locally** — run the same `xcodebuild` line; expect BUILD + TEST SUCCEEDED. (CI itself verified on first PR; no push in this task.)
- [ ] **Step 3: Commit** — `git commit -am "ci: build + test on macOS runner"`

---

### Task 10: Final verification

- [ ] **Step 1:** Clean build from scratch: `rm -rf SightLineField.xcodeproj DerivedData && xcodegen generate && xcodebuild … build test` → all green.
- [ ] **Step 2:** Repeat the Task 8 smoke test (login live, empty states, offline-graceful bootstrap).
- [ ] **Step 3:** README accuracy pass — follow it verbatim on the checkout; fix drift.
- [ ] **Step 4:** Commit any fixes; report to user; **do not push** without explicit go-ahead.
