import AppKit
import SwiftUI

/// Compact trailing approvals column for a PR row.
///
/// The large number is optimized for quick scanning down the right edge of the
/// list, while the smaller denominator still communicates progress toward the
/// required approval threshold.
struct ApprovalBadge: View {
    let approvals: Int
    let requiredApprovals: Int
    let showsComplete: Bool
    var body: some View {
        VStack(alignment: .trailing, spacing: 1) {
            HStack(alignment: .firstTextBaseline, spacing: 3) {
                Text(verbatim: "\(approvals)")
                    .font(.title3.weight(.bold).monospacedDigit())

                if showsComplete {
                    Image(systemName: "checkmark")
                        .imageScale(.small)
                        .font(.caption.weight(.bold))
                }
            }

            Text(verbatim: "of \(requiredApprovals)")
                .font(.caption2.weight(.semibold))
                .monospacedDigit()
        }
        .foregroundStyle(tint)
        .frame(maxHeight: .infinity, alignment: .center)
        .accessibilityLabel(accessibilityLabel)
    }

    private var isStarted: Bool {
        approvals > 0 && !showsComplete
    }

    /// Tracks progress with neutrals until approvals are both sufficient and fresh.
    private var tint: Color {
        if showsComplete { return .green }
        if isStarted { return Color(nsColor: .secondaryLabelColor) }
        return Color(nsColor: .tertiaryLabelColor)
    }

    private var accessibilityLabel: String {
        if showsComplete {
            return "Approvals complete: \(approvals) of \(requiredApprovals)"
        }
        return "Approvals \(approvals) of \(requiredApprovals)"
    }
}
