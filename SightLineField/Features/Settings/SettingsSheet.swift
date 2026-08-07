import SwiftData
import SwiftUI
@MainActor
struct SettingsSheet: View {
    @Environment(SessionManager.self) private var session
    @Environment(SyncEngine.self) private var syncEngine
    @Environment(OutboxWorker.self) private var outbox
    @State private var isLoggingOut = false
    /// `.conflict` rows — surfaced by the Retry button below; `retry(clientUuid:)` un-sticks each
    /// one back to `.pending` and the follow-up `drain()` replays it.
    @Query private var conflictedRows: [SyncOutbox]

    init() {
        let conflict = OutboxState.conflict.rawValue
        _conflictedRows = Query(filter: #Predicate<SyncOutbox> { $0.state == conflict })
    }

    var body: some View {
        NavigationStack {
            List {
                Section {
                    switch session.state {
                    case .signedIn(let account):
                        VStack(alignment: .leading, spacing: 4) {
                            Text(account.email)
                                .font(DS.Font.body)
                                .foregroundStyle(DS.Color.textPrimary)
                            Text(account.businessId)
                                .font(DS.Font.caption)
                                .foregroundStyle(DS.Color.textSecondary)
                        }
                    case .signedOut, .authenticating:
                        EmptyView()
                    }
                }

                Section("Sync") {
                    HStack {
                        Text("Last synced")
                            .font(DS.Font.body)
                            .foregroundStyle(DS.Color.textPrimary)
                        Spacer()
                        Text(lastSyncedLabel)
                            .font(DS.Font.caption)
                            .foregroundStyle(DS.Color.textSecondary)
                    }
                    if let error = syncEngine.lastSyncError {
                        Text(error)
                            .font(DS.Font.caption)
                            .foregroundStyle(DS.Color.destructive)
                            .lineLimit(3)
                    }
                    Button {
                        Task { await syncEngine.syncAll() }
                    } label: {
                        HStack {
                            Text("Sync Now")
                                .font(DS.Font.body)
                            if syncEngine.isSyncing {
                                Spacer()
                                ProgressView()
                            }
                        }
                    }
                    .disabled(syncEngine.isSyncing)
                    if outbox.pendingCount > 0 {
                        HStack {
                            Text("Pending uploads")
                                .font(DS.Font.body)
                                .foregroundStyle(DS.Color.textPrimary)
                            Spacer()
                            Text("\(outbox.pendingCount)")
                                .font(DS.Font.caption)
                                .foregroundStyle(DS.Color.textSecondary)
                        }
                        .accessibilityElement(children: .combine)
                        .accessibilityIdentifier("outbox-pending")
                    }
                    if outbox.conflictCount > 0 {
                        HStack {
                            Text("\(outbox.conflictCount) need attention")
                                .font(DS.Font.caption)
                                .foregroundStyle(DS.Color.destructive)
                            Spacer()
                            Button("Retry All") {
                                for row in conflictedRows {
                                    outbox.retry(clientUuid: row.clientUuid)
                                }
                                Task { await outbox.drain() }
                            }
                            .font(DS.Font.caption)
                            .accessibilityIdentifier("outbox-retry-all")
                        }
                    }
                }

                Section {
                    Button(role: .destructive) {
                        isLoggingOut = true
                        Task {
                            await session.logout()
                            isLoggingOut = false
                        }
                    } label: {
                        Text("Log Out")
                            .font(DS.Font.body)
                            .foregroundStyle(DS.Color.destructive)
                    }
                    .disabled(isLoggingOut)
                }
            }
            .navigationTitle("Settings")
        }
    }

    private var lastSyncedLabel: String {
        guard let at = syncEngine.lastSyncedAt else { return "Never" }
        return at.formatted(.relative(presentation: .named))
    }
}
