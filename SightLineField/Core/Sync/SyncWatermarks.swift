import Foundation

/// A synced collection whose sync progress is tracked independently.
enum SyncCollection: String, CaseIterable {
    case jobs
    case appointments
    case workTypes
    case workLogs
    case surfaces
    case buildings
}

/// Per-collection "last synced through" timestamps, persisted in `UserDefaults`.
///
/// Watermarks never regress: setting an older (or equal) date than what's stored is a no-op.
/// This makes `set` safe to call with out-of-order page results without any external ordering
/// guarantee.
struct SyncWatermarks {
    private let defaults: UserDefaults

    init(defaults: UserDefaults) {
        self.defaults = defaults
    }

    private func key(for collection: SyncCollection) -> String {
        "sync.watermark.\(collection.rawValue)"
    }

    func get(_ collection: SyncCollection) -> Date? {
        defaults.object(forKey: key(for: collection)) as? Date
    }

    /// Advances the watermark for `collection` to `date`, unless the stored value is already
    /// at or past `date` — a watermark never moves backward.
    func set(_ collection: SyncCollection, to date: Date) {
        let storageKey = key(for: collection)
        if let existing = defaults.object(forKey: storageKey) as? Date, existing >= date {
            return
        }
        defaults.set(date, forKey: storageKey)
    }

    func clearAll() {
        for collection in SyncCollection.allCases {
            defaults.removeObject(forKey: key(for: collection))
        }
    }
}
