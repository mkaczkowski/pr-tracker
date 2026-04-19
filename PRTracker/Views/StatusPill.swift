import SwiftUI

/// Compact review-state capsule shown at the trailing edge of each PR row.
///
/// The palette keeps "awaiting" distinct from "stale": blue reads like the
/// normal work queue, while amber flags a review that has gone stale and may
/// need a closer look. More urgent states still carry heavier fills than
/// informational ones.
struct StatusPill: View {
    let state: DisplayState
    var body: some View {
        Text(state.label)
            .font(.subheadline.weight(.semibold))
            .padding(.horizontal, 10)
            .padding(.vertical, 4)
            .foregroundStyle(tint)
            .background(tint.opacity(backgroundOpacity))
            .clipShape(Capsule())
            .accessibilityLabel("Status \(state.label)")
    }

    /// Color carries the *meaning* (red = problem, green = good, etc.). The
    /// background opacity carries the *urgency* — see `backgroundOpacity`.
    private var tint: Color {
        switch state {
        case .changesRequested:
            return .red
        case .awaiting, .waiting:
            return .blue
        case .stale:
            return .orange
        case .approved:
            return .green
        case .pending:
            return .indigo
        case .commented, .dismissed:
            return .gray
        }
    }

    /// Heavier fill for states that demand action; lighter fill for
    /// informational states so they don't compete with the actionable ones.
    private var backgroundOpacity: Double {
        switch state {
        case .changesRequested, .stale:
            return 0.18
        case .awaiting, .waiting:
            return 0.14
        case .approved, .commented, .dismissed, .pending:
            return 0.10
        }
    }
}
