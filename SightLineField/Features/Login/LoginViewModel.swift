import Foundation
import Observation

/// Pure view-model state for `LoginView`: field values, submit gating on field content, and
/// `ApiError` → user-facing copy. Deliberately holds no `SessionManager` reference as stored
/// state — `submit(session:)` takes one as a parameter — so this type has zero SwiftUI/UIKit
/// dependency and is scratch-package buildable/testable on any platform (see
/// `.superpowers/sdd/task-8-report.md`).
@Observable
final class LoginViewModel {
    var email = ""
    var password = ""

    /// Field-emptiness half of the submit-disabled rule. The other half — "or authenticating"
    /// — reads `session.state` directly in `LoginView`, since that's session state, not field
    /// state, and keeping it out of here is what keeps this type session-free.
    var fieldsFilled: Bool { !email.isEmpty && !password.isEmpty }

    func submit(session: SessionManager) async {
        guard fieldsFilled else { return }
        await session.login(email: email, password: password)
    }

    /// Maps `SessionManager.lastError` to login-screen copy. Only `.unauthorized`/`.network`
    /// are spec'd by the brief; `.server`/`.decoding` still get a generic message rather than
    /// silently swallowing a real failure the user hit.
    static func errorMessage(for error: ApiError?) -> String? {
        guard let error else { return nil }
        switch error {
        case .unauthorized: return "Wrong email or password"
        case .network: return "Can't reach server"
        case .server, .decoding: return "Something went wrong. Please try again."
        }
    }
}
