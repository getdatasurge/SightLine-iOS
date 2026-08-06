import XCTest
import SwiftData
@testable import SightLineField

/// `ElevationActions`' two writes (M5a) — mirrors `WorkLogActionsTests`'/`PhotoActions`'s split:
/// only the synchronous optimistic-write-then-enqueue half is tested here; drain-time gateway
/// behavior (`.elevationCreate`/`.surfaceAssign` actually reaching `SurveyWriteGateway`) belongs
/// to `OutboxWorkerTests`, which drives `OutboxWorker.drain()` directly with no competing
/// fire-and-forget drain to race against.
@MainActor
final class ElevationActionsTests: XCTestCase {
    func makeContext() throws -> ModelContext {
        try StoreContainer.make(inMemory: true).mainContext
    }

    /// `ElevationActions` doesn't own an `OutboxWorker` (mirrors `PhotoActions`, not
    /// `WorkLogActions`) — any `WorkLogGateway` stub works here since nothing in these tests
    /// ever drains; reuses `StubWorkLogGateway` (`WorkLogActionsTests.swift`) rather than
    /// declaring a second do-nothing fake.
    func makeActions(context: ModelContext) -> ElevationActions {
        let worker = OutboxWorker(gateway: StubWorkLogGateway(), modelContext: context)
        return ElevationActions(outboxWorker: worker, modelContext: context)
    }

    // MARK: - addElevation

    func testAddElevationWritesOptimisticFieldAddedRowAndEnqueuesOutboxItem() throws {
        let context = try makeContext()
        let actions = makeActions(context: context)

        let result = actions.addElevation(buildingId: "bldg-1", label: "New Wall", facing: "North")

        let clientUuid = try XCTUnwrap(result.clientUuid)
        XCTAssertNotNil(UUID(uuidString: clientUuid))
        XCTAssertEqual(result.id, clientUuid, "the optimistic row's id is pinned to its own clientUuid")
        XCTAssertEqual(result.buildingId, "bldg-1")
        XCTAssertEqual(result.label, "New Wall")
        XCTAssertEqual(result.facing, "North")
        XCTAssertTrue(result.fieldAdded)
        XCTAssertEqual(result.elevationNumber, 1, "first elevation on this building: provisional number 1")

        let elevations = try context.fetch(FetchDescriptor<Elevation>())
        XCTAssertEqual(elevations.count, 1)
        XCTAssertEqual(elevations.first?.id, clientUuid)

        let outboxItems = try context.fetch(FetchDescriptor<SyncOutbox>())
        XCTAssertEqual(outboxItems.count, 1)
        let item = try XCTUnwrap(outboxItems.first)
        XCTAssertEqual(item.endpoint, OutboxEndpoint.elevationCreate.rawValue)
        XCTAssertEqual(item.state, OutboxState.pending.rawValue)
        XCTAssertEqual(item.attempts, 0)
        let payload = try JSONDecoder().decode(ElevationCreatePayload.self, from: item.payload)
        XCTAssertEqual(payload.buildingId, "bldg-1")
        XCTAssertEqual(payload.label, "New Wall")
        XCTAssertEqual(payload.facing, "North")
        XCTAssertEqual(payload.clientUuid, clientUuid)
    }

    func testAddElevationMintsAFreshUuidPerCallAndIncrementsProvisionalNumber() throws {
        let context = try makeContext()
        let actions = makeActions(context: context)

        let first = actions.addElevation(buildingId: "bldg-1", label: "Wall A", facing: nil)
        let second = actions.addElevation(buildingId: "bldg-1", label: "Wall B", facing: nil)

        XCTAssertNotEqual(first.clientUuid, second.clientUuid)
        XCTAssertEqual(first.elevationNumber, 1)
        XCTAssertEqual(second.elevationNumber, 2, "provisional number accounts for the sibling just added")
        XCTAssertEqual(try context.fetchCount(FetchDescriptor<Elevation>()), 2)
        XCTAssertEqual(try context.fetchCount(FetchDescriptor<SyncOutbox>()), 2)
    }

    func testAddElevationProvisionalNumberIsScopedPerBuilding() throws {
        let context = try makeContext()
        let actions = makeActions(context: context)

        actions.addElevation(buildingId: "bldg-1", label: "Wall A", facing: nil)
        let otherBuilding = actions.addElevation(buildingId: "bldg-2", label: "Wall B", facing: nil)

        XCTAssertEqual(otherBuilding.elevationNumber, 1, "a different building starts its own provisional numbering at 1")
    }

    func testAddElevationDoesNotCallGatewaySynchronously() throws {
        let context = try makeContext()
        let gateway = StubWorkLogGateway()
        let worker = OutboxWorker(gateway: gateway, modelContext: context)
        let actions = ElevationActions(outboxWorker: worker, modelContext: context)

        actions.addElevation(buildingId: "bldg-1", label: "New Wall", facing: nil)

        // Nothing about this call stack touches the network: `addElevation` has no `await`
        // before returning, so the fire-and-forget `Task { drain() }` it kicks off cannot have
        // run any of its body yet — mirrors `WorkLogActionsTests`'s identical assertion.
        XCTAssertTrue(gateway.checkInCalls.isEmpty)
        XCTAssertTrue(gateway.checkOutCalls.isEmpty)
    }

    // MARK: - assignSurface

    func testAssignSurfaceSetsLocalLinksAndEnqueuesOutboxItem() throws {
        let context = try makeContext()
        context.insert(Surface(id: "surf-1", jobId: "job-1", label: "Front door glass", status: "MEASURED", updatedAt: Date(timeIntervalSince1970: 1_000)))
        try context.save()
        let actions = makeActions(context: context)

        actions.assignSurface(surfaceId: "surf-1", buildingId: "bldg-1", elevationId: "elev-1")

        let surface = try XCTUnwrap(try context.fetch(FetchDescriptor<Surface>()).first)
        XCTAssertEqual(surface.buildingId, "bldg-1")
        XCTAssertEqual(surface.elevationId, "elev-1")

        let outboxItems = try context.fetch(FetchDescriptor<SyncOutbox>())
        XCTAssertEqual(outboxItems.count, 1)
        let item = try XCTUnwrap(outboxItems.first)
        XCTAssertEqual(item.endpoint, OutboxEndpoint.surfaceAssign.rawValue)
        let payload = try JSONDecoder().decode(SurfaceAssignPayload.self, from: item.payload)
        XCTAssertEqual(payload.surfaceId, "surf-1")
        XCTAssertEqual(payload.buildingId, "bldg-1")
        XCTAssertEqual(payload.elevationId, "elev-1")
    }

    func testAssignSurfaceStillEnqueuesWhenLocalSurfaceRowMissing() throws {
        let context = try makeContext()
        let actions = makeActions(context: context)

        actions.assignSurface(surfaceId: "does-not-exist", buildingId: "bldg-1", elevationId: "elev-1")

        XCTAssertTrue(try context.fetch(FetchDescriptor<Surface>()).isEmpty)
        XCTAssertEqual(try context.fetchCount(FetchDescriptor<SyncOutbox>()), 1, "enqueue still happens — a later drain reconciles from whatever the server says")
    }
}
