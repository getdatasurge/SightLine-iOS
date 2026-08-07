import SwiftUI

@MainActor
struct RootView: View {
    @Environment(SessionManager.self) private var session
    @Environment(SyncEngine.self) private var syncEngine
    @Environment(BiometricGate.self) private var biometric

    var body: some View {
        switch session.state {
        case .signedOut, .authenticating:
            LoginView()
        case .signedIn:
            content
                .task { await syncEngine.syncAll() }
                .task { await biometric.requireUnlock() }
        }
    }

    @ViewBuilder
    private var content: some View {
        if biometric.isUnlocked {
            TabView {
                ScheduleView()
                    .tabItem { Label("Schedule", systemImage: "calendar") }
                JobListView()
                    .tabItem { Label("Jobs", systemImage: "list.bullet") }
                WorkLogsView()
                    .tabItem { Label("Work Logs", systemImage: "clock") }
                SettingsSheet()
                    .tabItem { Label("Settings", systemImage: "gearshape") }
            }
            .tint(DS.Color.accent)
        } else {
            VStack(spacing: 16) {
                Text("SightLine Field")
                    .font(DS.Font.title)
                    .foregroundStyle(DS.Color.textPrimary)
                Button {
                    Task { await biometric.requireUnlock() }
                } label: {
                    Text("Unlock")
                        .font(DS.Font.body)
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .tint(DS.Color.accent)
            }
            .padding()
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(DS.Color.background)
        }
    }
}
