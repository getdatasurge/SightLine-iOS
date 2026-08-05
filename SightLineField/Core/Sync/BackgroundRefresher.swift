import BackgroundTasks
import Foundation
import os

/// M4c: drains the offline outbox and pulls a fresh sync from a `BGAppRefreshTask` wake, per
/// `docs/superpowers/specs/2026-08-05-m4-offline-outbox.md` phase C.
///
/// Deliberately registration-free — the App entry point owns
/// `BGTaskScheduler.shared.register(forTaskWithIdentifier:using:launchHandler:)` (once, at
/// launch) and wires its launch handler to call `handle(_:)` on an instance built from the same
/// `OutboxWorker`/`SyncEngine` the rest of the app uses. This class only builds/submits the next
/// wake request and executes the work once woken.
@MainActor
final class BackgroundRefresher {
    /// Must match the `BGTaskSchedulerPermittedIdentifiers` Info.plist entry and whatever
    /// identifier the App-entry registers with — this is the single source of truth both sides
    /// key off, so it lives here rather than being duplicated as a string literal elsewhere.
    static let taskIdentifier = "com.getdatasurge.sightline.field.refresh"

    /// Wake at least this far out. Background refresh is a *hint* to iOS (actual wake timing is
    /// entirely up to the OS, based on usage patterns and battery), never a guarantee — 15
    /// minutes is a reasonable floor that won't visibly over-poll if iOS does honor it closely.
    private static let minimumInterval: TimeInterval = 15 * 60

    private static let log = Logger(subsystem: "com.getdatasurge.sightline.field", category: "background-refresh")

    private let outboxWorker: OutboxWorker
    private let syncEngine: SyncEngine

    init(outboxWorker: OutboxWorker, syncEngine: SyncEngine) {
        self.outboxWorker = outboxWorker
        self.syncEngine = syncEngine
    }

    /// Submits the next wake request. Scheduling can fail for reasons entirely outside this
    /// app's control — background refresh disabled in Settings, no BGTaskScheduler support in
    /// the current environment (e.g. the simulator without a paired device), the identifier not
    /// yet registered — none of which should ever crash the app, so the throw is logged and
    /// swallowed rather than propagated.
    func scheduleNext() {
        let request = BGAppRefreshTaskRequest(identifier: Self.taskIdentifier)
        request.earliestBeginDate = Date(timeIntervalSinceNow: Self.minimumInterval)
        do {
            try BGTaskScheduler.shared.submit(request)
        } catch {
            Self.log.error("BGTaskScheduler.submit failed: \(String(describing: error), privacy: .public)")
        }
    }

    /// The App-entry launch handler's callback for `taskIdentifier`. Reschedules the next wake
    /// *first* — before doing any work — so a refresh that runs long or gets expired mid-flight
    /// still leaves a future one queued rather than silently going dark. The actual drain+sync
    /// runs on its own `Task` so `task.expirationHandler` (fired by iOS if it reclaims the slot
    /// before the work finishes) can cancel it; `setTaskCompleted(success:)` reports `true` only
    /// if that never happened.
    func handle(_ task: BGAppRefreshTask) async {
        scheduleNext()

        let work = Task {
            await self.performRefresh()
        }
        task.expirationHandler = {
            work.cancel()
        }

        await work.value
        task.setTaskCompleted(success: !work.isCancelled)
    }

    /// The actual drain-then-sync body, factored out of `handle(_:)` so it's directly testable —
    /// `BGAppRefreshTask` has no public initializer, so a unit test can't construct one to drive
    /// `handle(_:)` end-to-end. Oldest-first outbox replay first (so a subsequent sync pull sees
    /// this device's own just-uploaded writes reflected back), then a full collection sync.
    func performRefresh() async {
        await outboxWorker.drain()
        await syncEngine.syncAll()
    }
}
