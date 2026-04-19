import AppKit
import SwiftUI

struct MenuBarPopover: View {
    @Bindable var model: AppModel
    @Environment(\.openWindow) private var openWindow

    @State private var showAwaiting = true
    @State private var showReviewed = true
    @State private var showMyOpen = true

    /// Single source of truth for the hover highlight. PR ids are unique
    /// across sections, so one piece of state lights up exactly one row at a
    /// time even though sections render independent Grids.
    @State private var hoveredPRID: String?

    private var visibleBuckets: ReviewBuckets {
        model.visibleBuckets
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            header

            statusBanners

            content
        }
        // Keep the scrollbar visually close to the popover edge while preserving
        // a bit more leading breathing room for the main content.
        .padding(.leading, 12)
        .padding(.trailing, 6)
        .padding(.vertical, 14)
        .frame(width: 540, height: 600)
        .animation(.snappy(duration: 0.22), value: model.loadState)
        .animation(.snappy(duration: 0.22), value: showAwaiting)
        .animation(.snappy(duration: 0.22), value: showReviewed)
        .animation(.snappy(duration: 0.22), value: showMyOpen)
        .onAppear {
            model.startIfNeeded()
            model.onPopoverOpened()
        }
    }

    @ViewBuilder
    private var content: some View {
        switch model.loadState {
        case .idle, .loading:
            LoadingStateView()
        case let .unauthenticated(message):
            AuthStateView(message: message, command: model.authLoginCommand()) {
                model.manualRefresh()
            }
        case let .error(message):
            ErrorStateView(message: message) {
                model.manualRefresh()
            }
        case .offline, .loaded:
            loadedContent
        }
    }

    private var header: some View {
        HStack(alignment: .top, spacing: 10) {
            Label {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Pending reviews")
                        .font(.title3.weight(.semibold))
                    Text(headerSubtitle)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            } icon: {
                Image(systemName: "eye.trianglebadge.exclamationmark")
                    .font(.title3)
                    .foregroundStyle(.tint)
            }
            .labelStyle(.titleAndIcon)

            Spacer()

            draftVisibilityToggle

            refreshToolbarButton

            toolbarButton(systemName: "gearshape", helpText: "Open Settings") {
                NSApp.activate(ignoringOtherApps: true)
                openWindow(id: "settings")
            }
        }
        .padding(.bottom, 2)
    }

    private var headerSubtitle: String {
        let user = visibleBuckets.user.isEmpty ? "@" : "@\(visibleBuckets.user)"
        let refreshed = RelativeTime.string(from: model.lastRefreshedAt)
        return "\(user) on \(model.settings.host) • refreshed \(refreshed)"
    }

    private var draftVisibilityToggle: some View {
        HeaderSwitch(title: "Drafts", isOn: draftVisibilityBinding)
            .frame(height: 28)
        .help(model.settings.includeDraftPullRequests ? "Hide draft pull requests" : "Show draft pull requests")
    }

    private var draftVisibilityBinding: Binding<Bool> {
        Binding(
            get: { model.settings.includeDraftPullRequests },
            set: { model.setIncludeDraftPullRequests($0) }
        )
    }

    private var refreshToolbarButton: some View {
        Button {
            model.manualRefresh()
        } label: {
            ZStack {
                if model.isRefreshing {
                    ProgressView()
                        .controlSize(.small)
                        .scaleEffect(0.7)
                } else {
                    Image(systemName: "arrow.clockwise")
                        .font(.callout.weight(.semibold))
                }
            }
            .frame(width: 28, height: 28)
        }
        .buttonStyle(.plain)
        .background(Circle().fill(Color.secondary.opacity(0.13)))
        .overlay(
            Circle()
                .strokeBorder(Color.primary.opacity(0.05), lineWidth: 1)
        )
        .contentShape(Circle())
        .disabled(model.isRefreshing)
        .help(model.isRefreshing ? "Refreshing…" : "Refresh")
        .animation(.snappy(duration: 0.18), value: model.isRefreshing)
    }

    @ViewBuilder
    private var statusBanners: some View {
        if model.isOnline == false {
            TruncationBanner(message: "Offline: showing last known data.")
        }
        if let message = model.lastRefreshErrorMessage {
            TruncationBanner(message: "Last refresh failed: \(message)")
        }

        if visibleBuckets.awaitingTruncated {
            TruncationBanner(message: "Awaiting results capped at 100. Narrow by org.")
        }
        if visibleBuckets.reviewedTruncated {
            TruncationBanner(message: "Reviewed results capped at 100. Narrow by org.")
        }
        if visibleBuckets.myOpenTruncated {
            TruncationBanner(message: "Your open PRs capped at 100. Narrow by org.")
        }
    }

    @ViewBuilder
    private var loadedContent: some View {
        if visibleBuckets.awaitingReview.isEmpty
            && visibleBuckets.reviewedNotApproved.isEmpty
            && visibleBuckets.myOpenNeedingAttention.isEmpty {
            EmptyStateView(
                title: "No pending reviews",
                subtitle: "Everything looks clear right now."
            )
        } else {
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 14) {
                    bucketSection(
                        title: "My PRs waiting on reviewers",
                        pullRequests: visibleBuckets.myOpenNeedingAttention,
                        context: .myOpenNeedingAttention,
                        isExpanded: $showMyOpen
                    )

                    bucketSection(
                        title: "Awaiting your review",
                        pullRequests: visibleBuckets.awaitingReview,
                        context: .awaitingReview,
                        isExpanded: $showAwaiting
                    )

                    bucketSection(
                        title: "Reviewed, not currently approved",
                        pullRequests: visibleBuckets.reviewedNotApproved,
                        context: .reviewedNotApproved,
                        isExpanded: $showReviewed
                    )
                }
                // AppKit scrollbars overlay SwiftUI content inside the popover,
                // so keep a small trailing gutter to protect the approvals
                // column without making the scrollbar feel inset.
                .padding(.trailing, 8)
                .animation(.easeInOut(duration: 0.08), value: hoveredPRID)
            }
        }
    }

    private func bucketSection(
        title: String,
        pullRequests: [PullRequest],
        context: PullRequestListContext,
        isExpanded: Binding<Bool>
    ) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            sectionHeaderRow(
                title: title,
                count: pullRequests.count,
                isExpanded: isExpanded
            )

            if isExpanded.wrappedValue {
                if pullRequests.isEmpty {
                    Text("None")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .padding(.leading, 16)
                        .padding(.vertical, 6)
                } else {
                    VStack(alignment: .leading, spacing: 0) {
                        ForEach(Array(pullRequests.enumerated()), id: \.element.id) { index, pullRequest in
                            if index > 0 {
                                Divider()
                                    .padding(.vertical, 5)
                                    .padding(.leading, 16)
                            }

                            PullRequestRow(
                                pullRequest: pullRequest,
                                requiredApprovals: model.settings.requiredApprovals,
                                context: context,
                                hoveredID: $hoveredPRID
                            )
                        }
                    }
                }
            }
        }
    }

    private func sectionHeaderRow(
        title: String,
        count: Int,
        isExpanded: Binding<Bool>
    ) -> some View {
        Button {
            isExpanded.wrappedValue.toggle()
        } label: {
            HStack(spacing: 8) {
                Image(systemName: isExpanded.wrappedValue ? "chevron.down" : "chevron.right")
                    .font(.caption.weight(.bold))
                    .foregroundStyle(.secondary)
                    .frame(width: 10, alignment: .center)
                Text(title)
                    .font(.headline)
                Spacer()
                sectionCountBadge(count)
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 6)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Color.secondary.opacity(0.07))
            .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .strokeBorder(Color.primary.opacity(0.04), lineWidth: 1)
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    /// Compact monospaced count badge. Monospaced digits + a fixed minWidth
    /// keep the badge stable as PR counts change so the section header never
    /// jitters between refreshes.
    private func sectionCountBadge(_ count: Int) -> some View {
        Text(verbatim: "\(count)")
            .font(.caption2.weight(.semibold).monospacedDigit())
            .foregroundStyle(.secondary)
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .frame(minWidth: 22)
            .background(Color.secondary.opacity(0.14))
            .clipShape(Capsule())
    }

    private func toolbarButton(systemName: String, helpText: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: systemName)
                .font(.callout.weight(.semibold))
                .frame(width: 28, height: 28)
        }
        .buttonStyle(.plain)
        .background(Circle().fill(Color.secondary.opacity(0.13)))
        .overlay(
            Circle()
                .strokeBorder(Color.primary.opacity(0.05), lineWidth: 1)
        )
        .contentShape(Circle())
        .help(helpText)
    }
}

private struct HeaderSwitch: View {
    let title: String
    @Binding var isOn: Bool

    var body: some View {
        Toggle(title, isOn: $isOn)
            .toggleStyle(.switch)
            .controlSize(.small)
            .font(.caption)
            .foregroundStyle(.secondary)
    }
}

