import XCTest
import SwiftData
@testable import SightLineField

/// `BGAppRefreshTask` has no public initializer, so `handle(_:)` itself can't be driven directly
/// from a unit test — these tests exercise `performRefresh()` (the drain-then-sync body
/// `handle(_:)` wraps with task lifecycle) instead, plus `scheduleNext()`'s must-never-throw
/// contract. Reuses `FakeWorkLogGateway` (`OutboxWorkerTests.swift`) and `StubSyncBackend`
/// (`SyncEngineTests.swift`) — same test target, already internal, not re-declared.
@MainActor
final class BackgroundRefresherTests: XCTestCase {
    func freshDefaults() -> UserDefaults {
        UserDefaults(suiteName: "BackgroundRefresherTests.\(UUID().uuidString)")!
    }

    func makeContext() throws -> ModelContext {
        try StoreContainer.make(inMemory: true).mainContext
    }

    private func checkInDTO(id: String, clientUuid: String?) -> WorkLogDTO {
        WorkLogDTO(
            id: id, jobId: "job-1", technicianId: "tech-1", workTypeId: "wt-1",
            checkInAt: Date(timeIntervalSince1970: 1_000), checkOutAt: nil, quantity: nil, notes: "started",
            status: "CHECKED_IN", updatedAt: Date(timeIntervalSince1970: 2_000), clientUuid: clientUuid
        )
    }

    // MARK: - performRefresh(): happy path

    /// Seeds one pending outbox item + its optimistic local `WorkLog` row, then asserts
    /// `performRefresh()` both drains the queue to empty (proving it calls through to
    /// `outboxWorker.drain()`, not just `syncEngine.syncAll()`) and records a sync pass
    /// (proving the reverse) — without throwing. A stub-only implementation that skipped either
    /// call would leave `pendingCount` at 1 or `lastSyncedAt` at `nil`.
    func testPerformRefreshDrainsOutboxAndSyncsWithoutThrowing() async throws {
        let context = try makeContext()
        let workLogClientUuid = UUID().uuidString
        context.insert(WorkLog(
            id: workLogClientUuid, clientUuid: workLogClientUuid, jobId: "job-1", workTypeId: "wt-1",
            status: "CHECKED_IN", checkInAt: Date(timeIntervalSince1970: 1_000), updatedAt: Date(timeIntervalSince1970: 1_000)
        ))
        let payload = CheckInPayload(jobId: "job-1", workTypeId: "wt-1", notes: "started", clientUuid: workLogClientUuid)
        context.insert(SyncOutbox(
            clientUuid: UUID().uuidString, endpoint: OutboxEndpoint.checkIn.rawValue,
            payload: try! JSONEncoder().encode(payload), attempts: 0, state: OutboxState.pending.rawValue,
            createdAt: Date(timeIntervalSince1970: 500)
        ))
        try context.save()

        let gateway = FakeWorkLogGateway()
        gateway.checkInResult = .success(checkInDTO(id: "server-1", clientUuid: workLogClientUuid))
        let outboxWorker = OutboxWorker(gateway: gateway, modelContext: context)
        let syncEngine = SyncEngine(backend: StubSyncBackend(), modelContext: context, watermarks: SyncWatermarks(defaults: freshDefaults()))

        XCTAssertEqual(outboxWorker.pendingCount, 1, "sanity: the seeded item is pending before the refresh runs")

        let refresher = BackgroundRefresher(outboxWorker: outboxWorker, syncEngine: syncEngine)
        await refresher.performRefresh()

        XCTAssertEqual(outboxWorker.pendingCount, 0, "performRefresh must drain the outbox")
        XCTAssertEqual(outboxWorker.conflictCount, 0)
        XCTAssertNotNil(syncEngine.lastSyncedAt, "performRefresh must also run a sync pass, not just drain")
        XCTAssertEqual(gateway.checkInCalls.count, 1)
    }

    /// A queue item the gateway rejects (permanent 4xx-conflict) must not stall
    /// `performRefresh()` — it still finishes and still runs the sync half.
    func testPerformRefreshCompletesEvenWhenAnOutboxItemConflicts() async throws {
        let context = try makeContext()
        let workLogClientUuid = UUID().uuidString
        context.insert(WorkLog(
            id: workLogClientUuid, clientUuid: workLogClientUuid, jobId: "job-1", workTypeId: "wt-1",
            status: "CHECKED_IN", checkInAt: Date(timeIntervalSince1970: 1_000), updatedAt: Date(timeIntervalSince1970: 1_000)
        ))
        let payload = CheckInPayload(jobId: "job-1", workTypeId: "wt-1", notes: nil, clientUuid: workLogClientUuid)
        context.insert(SyncOutbox(
            clientUuid: UUID().uuidString, endpoint: OutboxEndpoint.checkIn.rawValue,
            payload: try! JSONEncoder().encode(payload), attempts: 0, state: OutboxState.pending.rawValue,
            createdAt: Date(timeIntervalSince1970: 500)
        ))
        try context.save()

        let gateway = FakeWorkLogGateway()
        gateway.checkInResult = .failure(ApiError.server(status: 409))
        let outboxWorker = OutboxWorker(gateway: gateway, modelContext: context)
        let syncEngine = SyncEngine(backend: StubSyncBackend(), modelContext: context, watermarks: SyncWatermarks(defaults: freshDefaults()))

        let refresher = BackgroundRefresher(outboxWorker: outboxWorker, syncEngine: syncEngine)
        await refresher.performRefresh()

        XCTAssertEqual(outboxWorker.pendingCount, 0)
        XCTAssertEqual(outboxWorker.conflictCount, 1, "a permanent rejection surfaces as a conflict, not silently dropped")
        XCTAssertNotNil(syncEngine.lastSyncedAt, "the sync half must still run after an outbox conflict")
    }

    // MARK: - scheduleNext(): must never throw

    /// `BGTaskScheduler.submit` throws in this test environment (the identifier was never
    /// registered via `BGTaskScheduler.shared.register`, which only the App entry does) — this
    /// asserts `scheduleNext()` swallows that rather than propagating or crashing the test.
    func testScheduleNextNeverThrows() throws {
        let outboxWorker = OutboxWorker(gateway: FakeWorkLogGateway(), modelContext: try makeContext())
        let syncEngine = SyncEngine(
            backend: StubSyncBackend(), modelContext: try makeContext(), watermarks: SyncWatermarks(defaults: freshDefaults())
        )
        let refresher = BackgroundRefresher(outboxWorker: outboxWorker, syncEngine: syncEngine)

        refresher.scheduleNext()
    }

    // MARK: - taskIdentifier

    func testTaskIdentifierMatchesTheRegisteredBundleIdentifier() {
        XCTAssertEqual(BackgroundRefresher.taskIdentifier, "com.getdatasurge.sightline.field.refresh")
    }
}
