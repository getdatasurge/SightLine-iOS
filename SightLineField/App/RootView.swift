import SwiftUI

@MainActor
struct RootView: View {
    @Environment(SessionManager.self) private var session
    @Environment(SyncEngine.self) private var syncEngine

    var body: some View {
        switch session.state {
        case .signedOut, .authenticating:
            LoginView()
        case .signedIn:
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
            .task { await syncEngine.syncAll() }
        }
    }
}
