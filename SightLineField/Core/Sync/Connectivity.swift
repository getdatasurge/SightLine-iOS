import Foundation
import Network
import Observation

/// Wraps `NWPathMonitor` behind a main-actor-observable flag. `NWPathMonitor` itself delivers
/// updates on an arbitrary background queue via `pathUpdateHandler`; every observed mutation is
/// hopped onto the main actor here (`Task { @MainActor in … } `) so `OutboxWorker` and any SwiftUI
/// reader never need their own synchronization or actor-hop boilerplate.
@MainActor
@Observable
final class Connectivity {
    private(set) var isOnline = false

    /// Fired exactly on the offline→online edge — not on every "still online" update, and not on
    /// the initial path report even when it happens to already be satisfied (that's a starting
    /// state, not a transition). `OutboxWorker` wires this to kick off a drain the moment
    /// connectivity returns, rather than waiting on the next foreground/check-in to notice.
    var onBecameOnline: (() -> Void)?

    private let monitor = NWPathMonitor()
    private let queue = DispatchQueue(label: "com.getdatasurge.sightline.field.connectivity")

    /// Whether `handle(satisfied:)` has processed at least one real path update from the
    /// monitor yet. `NWPathMonitor.currentPath` isn't reliably populated before `start()`
    /// (ios-units-review Minor) — reading it synchronously in `init` could seed `isOnline`
    /// `false` while the device is actually online, making `start()`'s very first callback look
    /// like a genuine offline→online edge and firing `onBecameOnline()` on startup. `isOnline`
    /// now starts at its plain default instead, and this flag — not a `currentPath` pre-read —
    /// decides whether the first callback is a *starting state* (seed `isOnline`, no fire,
    /// whichever way it comes in) or a genuine *transition* (the normal edge-detection below).
    private var hasReceivedFirstUpdate = false

    init() {
        monitor.pathUpdateHandler = { [weak self] path in
            let satisfied = path.status == .satisfied
            Task { @MainActor [weak self] in
                self?.handle(satisfied: satisfied)
            }
        }
        monitor.start(queue: queue)
    }

    deinit {
        monitor.cancel()
    }

    /// Not `private`: `NWPathMonitor` has no injectable seam (there's nothing to fake to drive
    /// it deterministically in a test), so this is exposed directly for unit-testing the
    /// edge-detection state machine itself, the same way `BackgroundRefresher.performRefresh()`
    /// is exposed because `BGAppRefreshTask` has no public initializer either.
    func handle(satisfied: Bool) {
        guard hasReceivedFirstUpdate else {
            hasReceivedFirstUpdate = true
            isOnline = satisfied
            return
        }
        let wasOnline = isOnline
        isOnline = satisfied
        if satisfied, !wasOnline {
            onBecameOnline?()
        }
    }
}
