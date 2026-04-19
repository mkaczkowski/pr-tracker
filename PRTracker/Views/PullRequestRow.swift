import AppKit
import SwiftUI

/// A single PR row with a dedicated trailing approvals column. Hover state is
/// owned by the parent (`MenuBarPopover`) so one binding can light up both
/// text rows of a PR at the same time.
///
/// Column layout:
///   1. PR content (title row + metadata row)
///   2. approvals column
struct PullRequestRow: View {
    private enum TimeChipKind: Hashable {
        case reviewRequested
        case lastPush
    }

    let pullRequest: PullRequest
    let requiredApprovals: Int
    let context: PullRequestListContext
    @Binding var hoveredID: String?
    @State private var lastOpenAt: Date = .distantPast
    @State private var hoveredTimeChip: TimeChipKind?
    private let numberColumnWidth: CGFloat = 44
    private let approvalsColumnWidth: CGFloat = 42

    private var isHovering: Bool { hoveredID == pullRequest.id }
    private var isClickable: Bool { pullRequest.url != nil }

    private var parsed: TitleParser.Parsed { TitleParser.parse(pullRequest.title) }

    var body: some View {
        HStack(alignment: .top, spacing: 0) {
            VStack(alignment: .leading, spacing: 0) {
                titleRow
                metaRow
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            ApprovalBadge(
                approvals: pullRequest.approvals,
                requiredApprovals: requiredApprovals,
                showsComplete: pullRequest.approvalBadgeShowsComplete(
                    requiredApprovals: requiredApprovals,
                    context: context
                )
            )
            .frame(width: approvalsColumnWidth, alignment: .trailing)
            .padding(.leading, 4)
            .padding(.trailing, 6)
        }
        .modifier(RowChrome(
            isHovering: isHovering,
            isClickable: isClickable,
            onHoverChanged: updateHoverState,
            openPullRequest: openPullRequestDebounced,
            copyURL: copyURL,
            copyCheckoutCommand: copyCheckoutCommand
        ))
        .textSelection(.disabled)
    }

    // MARK: - Title row

    @ViewBuilder
    private var titleRow: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            numberText
                .frame(width: numberColumnWidth, alignment: .trailing)

            titleAndIcons

            Spacer(minLength: 8)

            HStack(alignment: .firstTextBaseline, spacing: 8) {
                StatusPill(
                    state: pullRequest.displayState(
                        requiredApprovals: requiredApprovals,
                        context: context
                    )
                )
            }
        }
        .padding(.top, 4)
        .padding(.bottom, 4)
    }

    /// Title text with optional inline markers placed at its trailing side.
    private var titleAndIcons: some View {
        HStack(alignment: .firstTextBaseline, spacing: 5) {
            if pullRequest.isDraft {
                draftBadge
                    .layoutPriority(1)
            }

            titleLink
                .layoutPriority(0)

            if pullRequest.isReReview {
                Image(systemName: "arrow.triangle.2.circlepath")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .help("Re-review requested")
                    .accessibilityLabel("Re-review requested")
                    .layoutPriority(1)
            }

            Spacer(minLength: 0)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var draftBadge: some View {
        Text("Draft")
            .font(.system(size: 10, weight: .semibold))
            .foregroundStyle(.secondary)
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(Color.secondary.opacity(0.14))
            .clipShape(Capsule())
            .help("Draft pull request")
            .accessibilityLabel("Draft pull request")
    }

    @ViewBuilder
    private var titleLink: some View {
        // Single-line + tail truncation keeps row heights uniform; the full
        // title is still discoverable via the tooltip and accessibility label.
        Text(verbatim: parsed.title)
            .font(.subheadline)
            .foregroundStyle(.primary)
            .lineLimit(1)
            .truncationMode(.tail)
            .help(parsed.title)
    }

    // MARK: - Meta row

    @ViewBuilder
    private var metaRow: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Color.clear
                .frame(width: numberColumnWidth, height: 0)

            metaIdentityCluster

            Spacer(minLength: 8)

            timeChipsCluster
        }
        .padding(.top, 1)
        .padding(.bottom, 4)
    }

    private var metaIdentityCluster: some View {
        HStack(spacing: 6) {
            repositoryView

            Text(verbatim: "·")
                .foregroundStyle(.tertiary)

            authorChip
                .layoutPriority(1)
        }
        .font(.caption)
        .foregroundStyle(.secondary)
        .lineLimit(1)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    /// Splits `org/repo` so the org reads as quiet metadata and the repo —
    /// the part that actually distinguishes one row from another in a queue
    /// dominated by a single org — gets the visual weight.
    @ViewBuilder
    private var repositoryView: some View {
        let parts = pullRequest.repository.split(separator: "/", maxSplits: 1)
        if parts.count == 2 {
            HStack(spacing: 0) {
                Text(verbatim: "\(parts[0])/")
                    .foregroundStyle(.tertiary)
                Text(verbatim: String(parts[1]))
                    .foregroundStyle(.primary.opacity(0.7))
            }
            .lineLimit(1)
            .truncationMode(.tail)
            .help(pullRequest.repository)
        } else {
            Text(verbatim: pullRequest.repository)
                .foregroundStyle(.primary.opacity(0.7))
                .lineLimit(1)
                .truncationMode(.tail)
                .help(pullRequest.repository)
        }
    }

    private var authorChip: some View {
        Text(verbatim: "@\(pullRequest.author)")
    }

    private var timeChipsCluster: some View {
        HStack(spacing: 8) {
            if let reviewRequestedAt = pullRequest.reviewRequestedAt,
               let waited = relativeTime(reviewRequestedAt) {
                timeChip(
                    kind: .reviewRequested,
                    systemImage: "clock",
                    value: waited,
                    tooltip: absoluteTimeTooltip(
                        label: "Review requested",
                        date: reviewRequestedAt
                    )
                )
            }

            if let lastCommitDate = pullRequest.lastCommitDate,
               let pushed = relativeTime(lastCommitDate) {
                timeChip(
                    kind: .lastPush,
                    systemImage: "arrow.up.circle",
                    value: pushed,
                    tooltip: absoluteTimeTooltip(
                        label: "Last push",
                        date: lastCommitDate
                    )
                )
            }
        }
    }

    private func timeChip(
        kind: TimeChipKind,
        systemImage: String,
        value: String,
        tooltip: String
    ) -> some View {
        HStack(spacing: 3) {
            Image(systemName: systemImage)
                .imageScale(.small)
            Text(verbatim: value)
                .monospacedDigit()
        }
        .padding(.horizontal, 3)
        .padding(.vertical, 2)
        .contentShape(Rectangle())
        .overlay(alignment: .top) {
            if hoveredTimeChip == kind {
                HoverTooltip(text: tooltip)
                    .offset(y: -30)
                    .zIndex(1)
            }
        }
        .onHover { hovering in
            if hovering {
                hoveredTimeChip = kind
            } else if hoveredTimeChip == kind {
                hoveredTimeChip = nil
            }
        }
        .accessibilityLabel(tooltip)
    }

    /// Returns nil when the date is missing so the caller can omit the field
    /// entirely instead of rendering a placeholder hyphen next to an icon.
    private func relativeTime(_ date: Date?) -> String? {
        guard date != nil else { return nil }
        return RelativeTime.string(from: date)
    }

    private func absoluteTimeTooltip(label: String, date: Date) -> String {
        "\(label): \(Self.timestampFormatter.string(from: date))"
    }

    private static let timestampFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateStyle = .medium
        formatter.timeStyle = .short
        formatter.doesRelativeDateFormatting = true
        return formatter
    }()

    // MARK: - Layout

    private var numberText: some View {
        Text(verbatim: "#\(pullRequest.number)")
            .font(.caption.monospacedDigit())
            .foregroundStyle(.tertiary.opacity(0.7))
    }

    // MARK: - Actions

    private func openPullRequest() {
        guard let url = pullRequest.url else { return }
        NSWorkspace.shared.open(url)
    }

    private func openPullRequestDebounced() {
        let now = Date()
        guard now.timeIntervalSince(lastOpenAt) > 0.35 else { return }
        lastOpenAt = now
        openPullRequest()
    }

    private func copyURL() {
        guard let url = pullRequest.url else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(url.absoluteString, forType: .string)
    }

    private func copyCheckoutCommand() {
        let command = "gh pr checkout \(pullRequest.number) --repo \(pullRequest.repository)"
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(command, forType: .string)
    }

    private func updateHoverState(_ hovering: Bool) {
        if hovering {
            hoveredID = pullRequest.id
        } else if hoveredID == pullRequest.id {
            hoveredID = nil
        }
    }
}

private struct HoverTooltip: View {
    let text: String

    var body: some View {
        Text(verbatim: text)
            .font(.caption)
            .foregroundStyle(.primary)
            .padding(.horizontal, 8)
            .padding(.vertical, 5)
            .background(
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .fill(Color(nsColor: .windowBackgroundColor))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .strokeBorder(Color.secondary.opacity(0.25), lineWidth: 0.5)
            )
            .shadow(color: .black.opacity(0.15), radius: 4, y: 1)
            .fixedSize()
            .allowsHitTesting(false)
    }
}

private struct RowChrome: ViewModifier {
    let isHovering: Bool
    let isClickable: Bool
    let onHoverChanged: (Bool) -> Void
    let openPullRequest: () -> Void
    let copyURL: () -> Void
    let copyCheckoutCommand: () -> Void

    func body(content: Content) -> some View {
        content
            .background(isHovering ? Color.primary.opacity(0.05) : Color.clear)
            .contentShape(Rectangle())
            .onHover(perform: onHoverChanged)
            .onTapGesture {
                guard isClickable else { return }
                openPullRequest()
            }
            .contextMenu {
                Button("Open Pull Request", action: openPullRequest)
                Button("Copy URL", action: copyURL)
                Button("Copy gh pr checkout command", action: copyCheckoutCommand)
            }
            .modifier(PointingHandCursor(isEnabled: isClickable))
    }
}

private struct PointingHandCursor: ViewModifier {
    let isEnabled: Bool
    @State private var isHovering = false

    func body(content: Content) -> some View {
        content.onHover { hovering in
            guard hovering != isHovering else { return }
            isHovering = hovering

            guard isEnabled else { return }

            if hovering {
                NSCursor.pointingHand.push()
            } else {
                NSCursor.pop()
            }
        }
    }
}
