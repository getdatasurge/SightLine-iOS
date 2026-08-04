import SwiftUI

/// Shared empty-state placeholder. Every `@Query`-backed shell screen (Schedule, Jobs,
/// WorkLogs, and `JobDetailView`'s surfaces section) renders this instead of fake rows when
/// its SwiftData query comes back empty — there is no M2 sync yet, so an empty query is the
/// expected, honest state rather than something to hide or fill in with placeholder data.
struct EmptyStateView: View {
    let title: String
    let detail: String

    var body: some View {
        VStack(spacing: 8) {
            Text(title)
                .font(DS.Font.title)
                .foregroundStyle(DS.Color.textPrimary)
            Text(detail)
                .font(DS.Font.body)
                .foregroundStyle(DS.Color.textSecondary)
                .multilineTextAlignment(.center)
        }
        .padding()
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(DS.Color.background)
    }
}
