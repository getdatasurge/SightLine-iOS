import XCTest
import SwiftData
@testable import SightLineField

final class StoreContainerTests: XCTestCase {
    @MainActor
    func testInMemoryContainerRoundTripsAllModels() throws {
        let container = try StoreContainer.make(inMemory: true)
        let context = container.mainContext
        let now = Date()

        context.insert(JobSummary(id: "job-1", name: "Acme HQ", address: "1 Main St", status: "OPEN", updatedAt: now))
        context.insert(Appointment(id: "appt-1", jobId: "job-1", title: "Site visit", start: now, end: now.addingTimeInterval(3600), status: "SCHEDULED", updatedAt: now))
        context.insert(WorkType(id: "wt-1", name: "Tint install", unit: "sqft", isActive: true, updatedAt: now))
        context.insert(WorkLog(id: "wl-1", clientUuid: "uuid-1", jobId: "job-1", workTypeId: "wt-1", status: "IN_PROGRESS", checkInAt: now, checkOutAt: nil, quantity: 12.5, notes: "notes", updatedAt: now))
        context.insert(Surface(id: "surf-1", jobId: "job-1", label: "Front door glass", status: "MEASURED", updatedAt: now))
        context.insert(SyncOutbox(clientUuid: "uuid-1", endpoint: "/work-logs", payload: Data("{}".utf8), attempts: 0, lastError: nil, state: OutboxState.pending.rawValue))

        try context.save()

        XCTAssertEqual(try context.fetchCount(FetchDescriptor<JobSummary>()), 1)
        XCTAssertEqual(try context.fetchCount(FetchDescriptor<Appointment>()), 1)
        XCTAssertEqual(try context.fetchCount(FetchDescriptor<WorkType>()), 1)
        XCTAssertEqual(try context.fetchCount(FetchDescriptor<WorkLog>()), 1)
        XCTAssertEqual(try context.fetchCount(FetchDescriptor<Surface>()), 1)
        XCTAssertEqual(try context.fetchCount(FetchDescriptor<SyncOutbox>()), 1)
    }
}
