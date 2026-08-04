import SwiftUI

struct LoginView: View {
    @Environment(SessionManager.self) private var session
    @State private var viewModel = LoginViewModel()

    private var isAuthenticating: Bool { session.state == .authenticating }
    private var isSubmitDisabled: Bool { !viewModel.fieldsFilled || isAuthenticating }

    var body: some View {
        @Bindable var viewModel = viewModel
        VStack(spacing: 16) {
            Text("SightLine Field")
                .font(DS.Font.title)
                .foregroundStyle(DS.Color.textPrimary)

            VStack(spacing: 12) {
                TextField("Email", text: $viewModel.email)
                    .textContentType(.username)
                    .keyboardType(.emailAddress)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .font(DS.Font.body)
                    .disabled(isAuthenticating)

                SecureField("Password", text: $viewModel.password)
                    .textContentType(.password)
                    .font(DS.Font.body)
                    .disabled(isAuthenticating)
            }
            .textFieldStyle(.roundedBorder)

            if let message = LoginViewModel.errorMessage(for: session.lastError) {
                // DS has no dedicated error/destructive token (task-7 provenance table); system
                // red is the minimal legible choice rather than inventing an unsourced token.
                Text(message)
                    .font(DS.Font.caption)
                    .foregroundStyle(.red)
            }

            Button {
                Task { await viewModel.submit(session: session) }
            } label: {
                if isAuthenticating {
                    ProgressView()
                        .frame(maxWidth: .infinity)
                } else {
                    Text("Log In")
                        .font(DS.Font.body)
                        .frame(maxWidth: .infinity)
                }
            }
            .buttonStyle(.borderedProminent)
            .tint(DS.Color.accent)
            .disabled(isSubmitDisabled)
        }
        .padding()
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(DS.Color.background)
    }
}
