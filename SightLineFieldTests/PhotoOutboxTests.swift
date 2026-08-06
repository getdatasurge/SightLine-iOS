import XCTest
import SwiftData
@testable import SightLineField

/// Fakes `PhotoUploadGateway` — mirrors `FakeWorkLogGateway` (`OutboxWorkerTests.swift`, reused
/// directly below for the `WorkLogGateway` half of `OutboxWorker`'s init that these photo-only
/// tests don't otherwise care about; same test target, already `internal`, not re-declared).
final class FakePhotoUploadGateway: PhotoUploadGateway, @unchecked Sendable {
    var uploadResult: Result<Void, Error> = .failure(ApiError.decoding)

    private(set) var uploadCalls: [(entityType: String, entityId: String, imageData: Data, filename: String, mimeType: String)] = []

    func upload(entityType: String, entityId: String, imageData: Data, filename: String, mimeType: String) async throws {
        uploadCalls.append((entityType, entityId, imageData, filename, mimeType))
        try uploadResult.get()
    }
}

@MainActor
final class PhotoOutboxTests: XCTestCase {
    func makeContext() throws -> ModelContext {
        try StoreContainer.make(inMemory: true).mainContext
    }

    @discardableResult
    private func insertPhotoItem(
        context: ModelContext, entityType: String = "job", entityId: String = "job-1",
        filename: String = "photo.jpg", mimeType: String = "image/jpeg", imageData: Data = Data([0xFF, 0xD8, 0xFF]),
        attempts: Int = 0, state: OutboxState = .pending, createdAt: Date
    ) -> SyncOutbox {
        let payload = PhotoUploadPayload(entityType: entityType, entityId: entityId, filename: filename, mimeType: mimeType, imageData: imageData)
        let item = SyncOutbox(
            clientUuid: UUID().uuidString, endpoint: OutboxEndpoint.photoUpload.rawValue,
            payload: try! JSONEncoder().encode(payload), attempts: attempts, state: state.rawValue, createdAt: createdAt
        )
        context.insert(item)
        return item
    }

    /// Polls until `condition()` is true or gives up. `PhotoActions.enqueuePhoto`'s `Task {
    /// await outboxWorker.drain() }` is fire-and-forget (offline-first, mirrors
    /// `WorkLogActions.enqueue` — see that class's doc comment), so there's no handle to await
    /// directly; yielding repeatedly lets the cooperative scheduler actually run it to
    /// completion instead of relying on a fixed, flaky sleep. If `condition` never turns true (a
    /// real regression — e.g. the `Task { ... }` line got deleted), every assertion after this
    /// call still sees the un-driven initial state and fails honestly, rather than the wait
    /// silently making a broken drain look like it ran.
    private func waitUntil(_ condition: () -> Bool) async {
        for _ in 0..<200 where !condition() {
            await Task.yield()
        }
    }

    // MARK: - PhotoActions.enqueuePhoto

    func testEnqueuePhotoWritesOutboxRowAndTriggersDrain() async throws {
        let context = try makeContext()
        let photoGateway = FakePhotoUploadGateway()
        photoGateway.uploadResult = .success(())
        let worker = OutboxWorker(gateway: FakeWorkLogGateway(), modelContext: context)
        worker.photoGateway = photoGateway
        let actions = PhotoActions(outboxWorker: worker, modelContext: context)
        let imageData = Data([0xAA, 0xBB, 0xCC])

        actions.enqueuePhoto(entityType: "job", entityId: "job-42", imageData: imageData)

        let items = try context.fetch(FetchDescriptor<SyncOutbox>())
        XCTAssertEqual(items.count, 1)
        let item = try XCTUnwrap(items.first)
        XCTAssertEqual(item.endpoint, OutboxEndpoint.photoUpload.rawValue)
        let payload = try JSONDecoder().decode(PhotoUploadPayload.self, from: item.payload)
        XCTAssertEqual(payload.entityType, "job")
        XCTAssertEqual(payload.entityId, "job-42")
        XCTAssertEqual(payload.imageData, imageData)
        XCTAssertEqual(payload.mimeType, "image/jpeg")

        await waitUntil { photoGateway.uploadCalls.count == 1 }
        XCTAssertEqual(photoGateway.uploadCalls.count, 1, "enqueuePhoto must trigger its own drain, offline-first, without the caller draining itself")
        XCTAssertTrue(try context.fetch(FetchDescriptor<SyncOutbox>()).isEmpty, "a successfully-synced row is purged (OutboxWorker Minor #4), never left `.done`")
    }

    func testEnqueuePhotoMintsAFreshClientUuidPerCall() throws {
        let context = try makeContext()
        let worker = OutboxWorker(gateway: FakeWorkLogGateway(), modelContext: context)
        let actions = PhotoActions(outboxWorker: worker, modelContext: context)

        actions.enqueuePhoto(entityType: "job", entityId: "job-1", imageData: Data([0x01]))
        actions.enqueuePhoto(entityType: "job", entityId: "job-1", imageData: Data([0x02]))

        let items = try context.fetch(FetchDescriptor<SyncOutbox>())
        XCTAssertEqual(items.count, 2)
        XCTAssertNotEqual(items[0].clientUuid, items[1].clientUuid)
    }

    // MARK: - OutboxWorker.drain(): .photoUpload happy path

    func testDrainWithSuccessStubPurgesRowAndCallsUploadWithDecodedFields() async throws {
        let context = try makeContext()
        let imageData = Data([0x01, 0x02, 0x03])
        insertPhotoItem(
            context: context, entityType: "surface", entityId: "surface-9",
            filename: "abc.jpg", mimeType: "image/jpeg", imageData: imageData,
            createdAt: Date(timeIntervalSince1970: 500)
        )
        try context.save()

        let photoGateway = FakePhotoUploadGateway()
        photoGateway.uploadResult = .success(())
        let worker = OutboxWorker(gateway: FakeWorkLogGateway(), modelContext: context)
        worker.photoGateway = photoGateway

        await worker.drain()

        XCTAssertEqual(photoGateway.uploadCalls.count, 1)
        let call = try XCTUnwrap(photoGateway.uploadCalls.first)
        XCTAssertEqual(call.entityType, "surface")
        XCTAssertEqual(call.entityId, "surface-9")
        XCTAssertEqual(call.filename, "abc.jpg")
        XCTAssertEqual(call.mimeType, "image/jpeg")
        XCTAssertEqual(call.imageData, imageData)

        XCTAssertTrue(try context.fetch(FetchDescriptor<SyncOutbox>()).isEmpty, "a successfully-synced row is purged (OutboxWorker Minor #4), never left `.done`")
    }

    // MARK: - OutboxWorker.drain(): 4xx-conflict is immediate, not gated by attempts

    func testDrainWithClientRejectionStatusesBecomesConflictImmediately() async throws {
        for status in [400, 409] {
            let context = try makeContext()
            let item = insertPhotoItem(context: context, createdAt: Date(timeIntervalSince1970: 500))
            try context.save()

            let photoGateway = FakePhotoUploadGateway()
            photoGateway.uploadResult = .failure(ApiError.server(status: status))
            let worker = OutboxWorker(gateway: FakeWorkLogGateway(), modelContext: context)
            worker.photoGateway = photoGateway

            await worker.drain()

            XCTAssertEqual(item.state, OutboxState.conflict.rawValue, "status \(status) must conflict immediately")
            XCTAssertEqual(item.attempts, 0, "status \(status) must not burn an attempt")
        }
    }

    // MARK: - OutboxWorker.drain(): network stop-on-offline

    func testDrainWithNetworkStubLeavesRowPendingIncrementsAttemptsAndStopsPass() async throws {
        let context = try makeContext()
        let first = insertPhotoItem(context: context, createdAt: Date(timeIntervalSince1970: 100))
        let second = insertPhotoItem(context: context, createdAt: Date(timeIntervalSince1970: 200))
        try context.save()

        struct Offline: Error {}
        let photoGateway = FakePhotoUploadGateway()
        photoGateway.uploadResult = .failure(ApiError.network(Offline()))
        let worker = OutboxWorker(gateway: FakeWorkLogGateway(), modelContext: context)
        worker.photoGateway = photoGateway

        await worker.drain()

        XCTAssertEqual(photoGateway.uploadCalls.count, 1, "must stop after the first network failure, never touch the second row")
        XCTAssertEqual(first.state, OutboxState.pending.rawValue)
        XCTAssertEqual(first.attempts, 1)
        XCTAssertNotNil(first.lastError)
        XCTAssertEqual(second.state, OutboxState.pending.rawValue)
        XCTAssertEqual(second.attempts, 0, "never even attempted")
    }

    // MARK: - OutboxWorker.drain(): nil photoGateway

    func testDrainWithNoPhotoGatewayConfiguredLeavesRowPendingWithoutCrashing() async throws {
        let context = try makeContext()
        let item = insertPhotoItem(context: context, createdAt: Date(timeIntervalSince1970: 500))
        try context.save()

        let worker = OutboxWorker(gateway: FakeWorkLogGateway(), modelContext: context)
        // worker.photoGateway intentionally left nil — simulates a composition root that
        // hasn't wired one yet.

        await worker.drain() // must not crash

        XCTAssertEqual(item.state, OutboxState.pending.rawValue)
        XCTAssertEqual(item.attempts, 1)
        XCTAssertNotNil(item.lastError)
        XCTAssertEqual(worker.pendingCount, 1)
    }

    func testNilPhotoGatewayDoesNotStopLaterRowsFromProcessing() async throws {
        let context = try makeContext()
        insertPhotoItem(context: context, createdAt: Date(timeIntervalSince1970: 100))
        let checkInClientUuid = UUID().uuidString
        let checkInPayload = CheckInPayload(jobId: "job-1", workTypeId: nil, notes: nil, clientUuid: checkInClientUuid)
        let checkInItem = SyncOutbox(
            clientUuid: UUID().uuidString, endpoint: OutboxEndpoint.checkIn.rawValue,
            payload: try! JSONEncoder().encode(checkInPayload), createdAt: Date(timeIntervalSince1970: 200)
        )
        context.insert(checkInItem)
        try context.save()

        let workLogGateway = FakeWorkLogGateway()
        workLogGateway.checkInResult = .success(WorkLogDTO(
            id: "server-1", jobId: "job-1", technicianId: nil, workTypeId: nil,
            checkInAt: Date(timeIntervalSince1970: 1_000), checkOutAt: nil, quantity: nil, notes: nil,
            status: "CHECKED_IN", updatedAt: Date(timeIntervalSince1970: 1_000), clientUuid: checkInClientUuid
        ))
        let worker = OutboxWorker(gateway: workLogGateway, modelContext: context)
        // photoGateway intentionally left nil.

        await worker.drain()

        XCTAssertEqual(workLogGateway.checkInCalls.count, 1, "a nil photoGateway must not stop unrelated rows behind it from processing")
        let checkInEndpoint = OutboxEndpoint.checkIn.rawValue
        let remainingCheckIns = try context.fetch(FetchDescriptor<SyncOutbox>(
            predicate: #Predicate<SyncOutbox> { $0.endpoint == checkInEndpoint }
        ))
        XCTAssertTrue(remainingCheckIns.isEmpty, "the check-in row succeeded and is purged (OutboxWorker Minor #4), never left `.done`")
    }
}
