import XCTest
@testable import SightLineField

final class SyncWatermarksTests: XCTestCase {
    var defaults: UserDefaults!
    var watermarks: SyncWatermarks!

    override func setUp() {
        defaults = UserDefaults(suiteName: "SyncWatermarksTests-\(UUID().uuidString)")
        watermarks = SyncWatermarks(defaults: defaults)
    }

    func testGetIsNilByDefault() {
        XCTAssertNil(watermarks.get(.jobs))
    }

    func testSetThenGetRoundTrips() {
        let date = Date(timeIntervalSince1970: 1000)
        watermarks.set(.jobs, to: date)
        XCTAssertEqual(watermarks.get(.jobs), date)
    }

    func testCollectionsAreIndependent() {
        watermarks.set(.jobs, to: Date(timeIntervalSince1970: 100))
        watermarks.set(.appointments, to: Date(timeIntervalSince1970: 200))
        XCTAssertEqual(watermarks.get(.jobs), Date(timeIntervalSince1970: 100))
        XCTAssertEqual(watermarks.get(.appointments), Date(timeIntervalSince1970: 200))
        XCTAssertNil(watermarks.get(.workTypes))
    }

    func testSetNeverRegresses() {
        watermarks.set(.workLogs, to: Date(timeIntervalSince1970: 500))
        watermarks.set(.workLogs, to: Date(timeIntervalSince1970: 100))
        XCTAssertEqual(watermarks.get(.workLogs), Date(timeIntervalSince1970: 500))
    }

    func testSetWithEqualDateIsNoOp() {
        let date = Date(timeIntervalSince1970: 500)
        watermarks.set(.surfaces, to: date)
        watermarks.set(.surfaces, to: date)
        XCTAssertEqual(watermarks.get(.surfaces), date)
    }

    func testSetAdvancesForward() {
        watermarks.set(.jobs, to: Date(timeIntervalSince1970: 100))
        watermarks.set(.jobs, to: Date(timeIntervalSince1970: 300))
        XCTAssertEqual(watermarks.get(.jobs), Date(timeIntervalSince1970: 300))
    }

    func testClearAllWipesEveryCollection() {
        for collection in SyncCollection.allCases {
            watermarks.set(collection, to: Date())
        }
        watermarks.clearAll()
        for collection in SyncCollection.allCases {
            XCTAssertNil(watermarks.get(collection), "\(collection) should be cleared")
        }
    }
}

final class SyncPlannerTests: XCTestCase {
    // MARK: - decide

    func testDecideWithNoWatermarkIsFull() {
        XCTAssertEqual(SyncPlanner.decide(watermark: nil), .full)
    }

    func testDecideWithWatermarkIsDeltaSinceWatermark() {
        let date = Date(timeIntervalSince1970: 42)
        XCTAssertEqual(SyncPlanner.decide(watermark: date), .delta(since: date))
    }

    // MARK: - advance

    func testAdvanceWithNoCurrentAndNoSeenStaysNil() {
        XCTAssertNil(SyncPlanner.advance(current: nil, seen: []))
    }

    func testAdvanceWithNilCurrentTakesMaxOfSeen() {
        let d1 = Date(timeIntervalSince1970: 10)
        let d2 = Date(timeIntervalSince1970: 30)
        let d3 = Date(timeIntervalSince1970: 20)
        XCTAssertEqual(SyncPlanner.advance(current: nil, seen: [d1, d2, d3]), d2)
    }

    func testAdvanceMovesForwardPastCurrent() {
        let current = Date(timeIntervalSince1970: 100)
        let newer = Date(timeIntervalSince1970: 200)
        XCTAssertEqual(SyncPlanner.advance(current: current, seen: [newer]), newer)
    }

    func testAdvanceNeverRegressesBehindCurrent() {
        let current = Date(timeIntervalSince1970: 500)
        let older = Date(timeIntervalSince1970: 100)
        XCTAssertEqual(SyncPlanner.advance(current: current, seen: [older]), current)
    }

    func testAdvanceHandlesOutOfOrderPages() {
        // A later "page" delivered with older dates first shouldn't regress the running max.
        let current = Date(timeIntervalSince1970: 50)
        let page = [
            Date(timeIntervalSince1970: 40),
            Date(timeIntervalSince1970: 300),
            Date(timeIntervalSince1970: 150),
        ]
        XCTAssertEqual(SyncPlanner.advance(current: current, seen: page), Date(timeIntervalSince1970: 300))
    }

    func testAdvanceWithEmptySeenReturnsCurrentUnchanged() {
        let current = Date(timeIntervalSince1970: 500)
        XCTAssertEqual(SyncPlanner.advance(current: current, seen: []), current)
    }

    // MARK: - planUpserts

    func testPlanUpsertsKeepsNewestPerId() {
        let older = SyncRecord(id: "a", updatedAt: Date(timeIntervalSince1970: 10))
        let newer = SyncRecord(id: "a", updatedAt: Date(timeIntervalSince1970: 20))
        let plans = SyncPlanner.planUpserts(incoming: [older, newer], existingIds: [])
        XCTAssertEqual(plans, [UpsertPlan(record: newer, isNew: true)])
    }

    func testPlanUpsertsKeepsNewestRegardlessOfOrder() {
        let newer = SyncRecord(id: "a", updatedAt: Date(timeIntervalSince1970: 20))
        let older = SyncRecord(id: "a", updatedAt: Date(timeIntervalSince1970: 10))
        let plans = SyncPlanner.planUpserts(incoming: [newer, older], existingIds: [])
        XCTAssertEqual(plans, [UpsertPlan(record: newer, isNew: true)])
    }

    func testPlanUpsertsMarksExistingIdsAsNotNew() {
        let record = SyncRecord(id: "a", updatedAt: Date(timeIntervalSince1970: 10))
        let plans = SyncPlanner.planUpserts(incoming: [record], existingIds: ["a"])
        XCTAssertEqual(plans, [UpsertPlan(record: record, isNew: false)])
    }

    func testPlanUpsertsPreservesFirstAppearanceOrderAcrossDistinctIds() {
        let a = SyncRecord(id: "a", updatedAt: Date(timeIntervalSince1970: 10))
        let b = SyncRecord(id: "b", updatedAt: Date(timeIntervalSince1970: 20))
        let c = SyncRecord(id: "c", updatedAt: Date(timeIntervalSince1970: 30))
        let plans = SyncPlanner.planUpserts(incoming: [b, a, c], existingIds: [])
        XCTAssertEqual(plans.map(\.record.id), ["b", "a", "c"])
    }

    func testPlanUpsertsWithEmptyIncomingIsEmpty() {
        XCTAssertEqual(SyncPlanner.planUpserts(incoming: [], existingIds: ["a"]), [])
    }
}
