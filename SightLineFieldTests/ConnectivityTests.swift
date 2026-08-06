import XCTest
@testable import SightLineField

/// `NWPathMonitor` has no injectable seam, so these drive `Connectivity.handle(satisfied:)`
/// directly (exposed for exactly this reason — see its doc comment) rather than trying to fake
/// real network state changes. Every test method here is synchronous (no `await`), which matters:
/// `Connectivity.init()` still starts a *real* `NWPathMonitor` in the background, but its
/// `pathUpdateHandler` only ever reaches `handle(satisfied:)` via `Task { @MainActor in ... }` —
/// a job that cannot run until this synchronous, MainActor-isolated test body returns and yields
/// control back to the scheduler. So the manual `handle(satisfied:)` calls below are guaranteed
/// to run and be asserted on before any real monitor callback could ever interleave.
@MainActor
final class ConnectivityTests: XCTestCase {

    // MARK: - handle(satisfied:): the first path report seeds state, never fires onBecameOnline

    /// ios-units-review Minor: the old `init` seeded `isOnline` from `monitor.currentPath` read
    /// synchronously *before* `start()`, which isn't reliably populated — if that pre-read
    /// happened to read `.unsatisfied` while the device was actually online, `start()`'s first
    /// real callback looked like a genuine offline→online edge and fired `onBecameOnline()` on
    /// startup. Now nothing seeds `isOnline` from `currentPath` at all: the very first delivered
    /// update — whichever way it reports — is always treated as the starting state, never a
    /// transition, regardless of what `isOnline` happened to default to.
    func testFirstUpdateWhenSatisfiedSeedsOnlineWithoutFiringOnBecameOnline() {
        let connectivity = Connectivity()
        var becameOnlineCount = 0
        connectivity.onBecameOnline = { becameOnlineCount += 1 }

        connectivity.handle(satisfied: true)

        XCTAssertTrue(connectivity.isOnline)
        XCTAssertEqual(becameOnlineCount, 0, "the very first report is a starting state, never a transition — even when it's already satisfied")
    }

    func testFirstUpdateWhenUnsatisfiedSeedsOfflineWithoutFiring() {
        let connectivity = Connectivity()
        var becameOnlineCount = 0
        connectivity.onBecameOnline = { becameOnlineCount += 1 }

        connectivity.handle(satisfied: false)

        XCTAssertFalse(connectivity.isOnline)
        XCTAssertEqual(becameOnlineCount, 0)
    }

    // MARK: - handle(satisfied:): genuine offline -> online edge after startup

    func testOnBecameOnlineFiresOnGenuineOfflineToOnlineEdgeAfterStartup() {
        let connectivity = Connectivity()
        var becameOnlineCount = 0
        connectivity.onBecameOnline = { becameOnlineCount += 1 }

        connectivity.handle(satisfied: false) // starting state: offline
        connectivity.handle(satisfied: true) // genuine edge

        XCTAssertTrue(connectivity.isOnline)
        XCTAssertEqual(becameOnlineCount, 1)
    }

    func testOnBecameOnlineNeverFiresOnRepeatedStillOnlineUpdates() {
        let connectivity = Connectivity()
        var becameOnlineCount = 0
        connectivity.onBecameOnline = { becameOnlineCount += 1 }

        connectivity.handle(satisfied: true) // starting state: already online
        connectivity.handle(satisfied: true) // still online — not an edge
        connectivity.handle(satisfied: true)

        XCTAssertEqual(becameOnlineCount, 0, "must fire only on the offline->online edge, never on a repeated 'still online' report")
    }

    func testOnBecameOnlineFiresAgainOnASecondEdgeAfterGoingOfflineInBetween() {
        let connectivity = Connectivity()
        var becameOnlineCount = 0
        connectivity.onBecameOnline = { becameOnlineCount += 1 }

        connectivity.handle(satisfied: true) // starting state
        connectivity.handle(satisfied: false) // drop offline
        connectivity.handle(satisfied: true) // edge #2

        XCTAssertEqual(becameOnlineCount, 1)
    }

    // MARK: - isOnline mirrors the latest report

    func testIsOnlineTracksTheLatestReportRegardlessOfEdgeFiring() {
        let connectivity = Connectivity()

        connectivity.handle(satisfied: true)
        XCTAssertTrue(connectivity.isOnline)
        connectivity.handle(satisfied: false)
        XCTAssertFalse(connectivity.isOnline)
    }
}
