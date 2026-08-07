import XCTest
import SwiftData
@testable import SightLineField

/// `SurfaceActions.captureSurface` (M5b) — mirrors `ElevationActionsTests`'/`PhotoOutboxTests`'s
/// split: only the synchronous optimistic-write-then-enqueue half is tested here; drain-time
/// gateway behavior (`.surfaceCapture` actually reaching `SurfaceCaptureGateway`, the chain
/// resolver, `reconcileSurface`) belongs to `OutboxWorkerTests`, which drives `OutboxWorker
/// .drain()` directly with no competing fire-and-forget drain to race against.
@MainActor
final class SurfaceActionsTests: XCTestCase {
    func makeContext() throws -> ModelContext {
        try StoreContainer.make(inMemory: true).mainContext
    }

    /// `SurfaceActions` doesn't own an `OutboxWorker` (mirrors `PhotoActions`/`ElevationActions`,
    /// not `WorkLogActions`) — any `WorkLogGateway` fake works since nothing here drains; reuses
    /// `FakeWorkLogGateway` (`OutboxWorkerTests.swift`, same test target) rather than declaring a
    /// second do-nothing fake.
    func makeWorker(context: ModelContext) -> OutboxWorker {
        OutboxWorker(gateway: FakeWorkLogGateway(), modelContext: context)
    }

    func testCaptureSurfaceWritesOptimisticMeasuredRowAndEnqueuesOutboxItem() throws {
        let context = try makeContext()
        let actions = SurfaceActions(outboxWorker: makeWorker(context: context), modelContext: context)

        let result = actions.captureSurface(
            jobId: "job-1", label: "Front Door Glass",
            widthIn: 24, heightIn: 36,
            widthFraction: "1/8", heightFraction: "3/4",
            quantity: 2, glassType: "Tempered",
            buildingId: "bldg-1", elevationId: "elev-local-1"
        )

        let clientUuid = try XCTUnwrap(result.clientUuid)
        XCTAssertNotNil(UUID(uuidString: clientUuid))
        XCTAssertEqual(result.id, clientUuid, "the optimistic row's id is pinned to its own clientUuid")
        XCTAssertEqual(result.status, "MEASURED", "the only status a client-side capture can assert")
        XCTAssertNil(result.areaSqFt, "server-computed — stays nil until reconcileSurface fills it in")
        XCTAssertNil(result.serverId, "no server id known until the .surfaceCapture replay succeeds")
        XCTAssertEqual(result.jobId, "job-1")
        XCTAssertEqual(result.label, "Front Door Glass")
        XCTAssertEqual(result.widthIn, 24)
        XCTAssertEqual(result.heightIn, 36)
        XCTAssertEqual(result.widthFraction, "1/8")
        XCTAssertEqual(result.heightFraction, "3/4")
        XCTAssertEqual(result.quantity, 2)
        XCTAssertEqual(result.glassType, "Tempered")
        XCTAssertEqual(result.buildingId, "bldg-1")
        XCTAssertEqual(result.elevationId, "elev-local-1", "the LOCAL elevation id — resolved to a server id only at dispatch")

        let surfaces = try context.fetch(FetchDescriptor<Surface>())
        XCTAssertEqual(surfaces.count, 1)
        XCTAssertEqual(surfaces.first?.id, clientUuid)

        let outboxItems = try context.fetch(FetchDescriptor<SyncOutbox>())
        XCTAssertEqual(outboxItems.count, 1, "exactly one .surfaceCapture row")
        let item = try XCTUnwrap(outboxItems.first)
        XCTAssertEqual(item.endpoint, OutboxEndpoint.surfaceCapture.rawValue)
        XCTAssertEqual(item.state, OutboxState.pending.rawValue)
        XCTAssertEqual(item.attempts, 0)
        let payload = try JSONDecoder().decode(SurfaceCapturePayload.self, from: item.payload)
        XCTAssertEqual(payload.jobId, "job-1")
        XCTAssertEqual(payload.label, "Front Door Glass")
        XCTAssertEqual(payload.widthIn, 24)
        XCTAssertEqual(payload.heightIn, 36)
        XCTAssertEqual(payload.widthFraction, "1/8")
        XCTAssertEqual(payload.heightFraction, "3/4")
        XCTAssertEqual(payload.quantity, 2)
        XCTAssertEqual(payload.glassType, "Tempered")
        XCTAssertEqual(payload.buildingId, "bldg-1")
        XCTAssertEqual(payload.elevationId, "elev-local-1", "payload stores the LOCAL elevation id verbatim, never rewritten")
        XCTAssertEqual(payload.clientUuid, clientUuid)
    }

    func testCaptureSurfaceMintsAFreshUuidPerCall() throws {
        let context = try makeContext()
        let actions = SurfaceActions(outboxWorker: makeWorker(context: context), modelContext: context)

        let first = actions.captureSurface(
            jobId: "job-1", label: "Pane A", widthIn: 10, heightIn: 10,
            widthFraction: nil, heightFraction: nil, quantity: nil, glassType: nil,
            buildingId: nil, elevationId: nil
        )
        let second = actions.captureSurface(
            jobId: "job-1", label: "Pane B", widthIn: 12, heightIn: 12,
            widthFraction: nil, heightFraction: nil, quantity: nil, glassType: nil,
            buildingId: nil, elevationId: nil
        )

        XCTAssertNotEqual(first.id, second.id, "each capture mints its own clientUuid — never reused")
        XCTAssertNotEqual(first.clientUuid, second.clientUuid)

        let surfaces = try context.fetch(FetchDescriptor<Surface>())
        XCTAssertEqual(surfaces.count, 2)
        let items = try context.fetch(FetchDescriptor<SyncOutbox>())
        XCTAssertEqual(items.count, 2)
        XCTAssertNotEqual(items[0].clientUuid, items[1].clientUuid, "each outbox row has its own fresh key too")
    }

    /// Optional fields left `nil` must round-trip through the payload as `nil`, not defaulted.
    func testCaptureSurfacePreservesNilOptionalsThroughPayload() throws {
        let context = try makeContext()
        let actions = SurfaceActions(outboxWorker: makeWorker(context: context), modelContext: context)

        _ = actions.captureSurface(
            jobId: "job-9", label: "Bare Pane", widthIn: 5, heightIn: 5,
            widthFraction: nil, heightFraction: nil, quantity: nil, glassType: nil,
            buildingId: nil, elevationId: nil
        )

        let item = try XCTUnwrap(try context.fetch(FetchDescriptor<SyncOutbox>()).first)
        let payload = try JSONDecoder().decode(SurfaceCapturePayload.self, from: item.payload)
        XCTAssertNil(payload.widthFraction)
        XCTAssertNil(payload.heightFraction)
        XCTAssertNil(payload.quantity)
        XCTAssertNil(payload.glassType)
        XCTAssertNil(payload.buildingId)
        XCTAssertNil(payload.elevationId)
    }

    /// `captureSurface` is synchronous with no internal `await` — on `@MainActor`'s serial
    /// executor the fire-and-forget `Task { drain() }` cannot have run any of its body by the
    /// time control returns, so the gateway is provably untouched (mirrors
    /// `ElevationActionsTests.testAddElevationDoesNotCallGatewaySynchronously`).
    func testCaptureSurfaceDoesNotCallGatewaySynchronously() throws {
        let context = try makeContext()
        let worker = makeWorker(context: context)
        let surfaceGateway = FakeSurfaceCaptureGateway()
        worker.surfaceCaptureGateway = surfaceGateway
        let actions = SurfaceActions(outboxWorker: worker, modelContext: context)

        _ = actions.captureSurface(
            jobId: "job-1", label: "Pane", widthIn: 10, heightIn: 10,
            widthFraction: nil, heightFraction: nil, quantity: nil, glassType: nil,
            buildingId: nil, elevationId: nil
        )

        XCTAssertTrue(surfaceGateway.captureCalls.isEmpty, "the write is optimistic — the gateway is only ever touched by a later drain")
    }
}
