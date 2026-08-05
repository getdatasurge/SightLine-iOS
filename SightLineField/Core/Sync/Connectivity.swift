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
    private(set) var isOnline: Bool

    /// Fired exactly on the offline→online edge — not on every "still online" update, and not on
    /// the initial path report even when it happens to already be satisfied (that's a starting
    /// state, not a transition). `OutboxWorker` wires this to kick off a drain the moment
    /// connectivity returns, rather than waiting on the next foreground/check-in to notice.
    var onBecameOnline: (() -> Void)?

    private let monitor = NWPathMonitor()
    private let queue = DispatchQueue(label: "com.getdatasurge.sightline.field.connectivity")

    init() {
        // `currentPath` reflects the monitor's best-known state synchronously, so `isOnline`
        // starts accurate immediately rather than defaulting optimistically/pessimistically and
        // waiting for the first background callback to correct it.
        isOnline = monitor.currentPath.status == .satisfied

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

    private func handle(satisfied: Bool) {
        let wasOnline = isOnline
        isOnline = satisfied
        if satisfied, !wasOnline {
            onBecameOnline?()
        }
    }
}
