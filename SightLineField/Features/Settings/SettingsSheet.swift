import SwiftUI

@MainActor
struct SettingsSheet: View {
    @Environment(SessionManager.self) private var session
    @State private var isLoggingOut = false

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
}
