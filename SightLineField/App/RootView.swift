import SwiftUI

struct RootView: View {
    @Environment(SessionManager.self) private var session

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
            }
            .tint(DS.Color.accent)
        }
    }
}
