import AppKit
import SwiftUI

@MainActor
struct MenuBarPopover: View {
    private enum KeyboardFocusArea: Hashable {
        case searchField
        case resultsList
    }

    private struct DisplayedBucketCounts: Equatable {
        let needsReview: Int
        let needsReReview: Int
        let myBlocked: Int
        let myWaiting: Int
        let myWaitingToMerge: Int
        let myOnMergeQueue: Int
    }

    /// AppKit emits the back-tab character for Shift+Tab; SwiftUI does not
    /// expose a built-in `KeyEquivalent` for it, so we construct one here and
    /// reuse it across the matching `.onKeyPress(keys:)` filter and handler.
    private static let backTabKeyEquivalent = KeyEquivalent(Character(Unicode.Scalar(0x19)!))

    @Bindable var model: AppModel
    @Environment(\.openWindow) private var openWindow
    @FocusState private var focusedArea: KeyboardFocusArea?

    @State private var showAwaiting = true
    @State private var showReReview = true
    @State private var showMyBlocked = true
    @State private var showMyWaiting = true
    @State private var showMyWaitingToMerge = false
    @State private var showMyOnMergeQueue = false

    /// Single source of truth for the hover highlight. PR ids are unique
    /// across sections, so one piece of state lights up exactly one row at a
    /// time even though sections render independent Grids.
    @State private var hoveredPRID: String?
    @State private var selectedPRID: String?
    @State private var lastOpenAt: Date = .distantPast

    private var displayedBuckets: ReviewBuckets {
        model.displayedBuckets
    }

    private var unfilteredVisibleBuckets: ReviewBuckets {
        model.visibleBuckets
    }

    private var sectionExpansion: PullRequestKeyboardNavigation.SectionExpansion {
        PullRequestKeyboardNavigation.SectionExpansion(
            showAwaiting: showAwaiting,
            showReReview: showReReview,
            showMyBlocked: showMyBlocked,
            showMyWaiting: showMyWaiting,
            showMyWaitingToMerge: showMyWaitingToMerge,
            showMyOnMergeQueue: showMyOnMergeQueue
        )
    }

    private var visiblePullRequestEntries: [PullRequestKeyboardNavigation.Entry] {
        PullRequestKeyboardNavigation.visibleEntries(
            in: displayedBuckets,
            expansion: sectionExpansion
        )
    }

    private var visiblePullRequestIDs: [String] {
        visiblePullRequestEntries.map(\.id)
    }

    private var selectedPullRequestEntry: PullRequestKeyboardNavigation.Entry? {
        guard let selectedPRID else { return nil }
        return visiblePullRequestEntries.first { $0.id == selectedPRID }
    }

    private var displayedBucketCounts: DisplayedBucketCounts {
        DisplayedBucketCounts(
            needsReview: displayedBuckets.needsReview.count,
            needsReReview: displayedBuckets.needsReReview.count,
            myBlocked: displayedBuckets.myOpenBlockedOnYou.count,
            myWaiting: displayedBuckets.myOpenWaitingOnReviewers.count,
            myWaitingToMerge: displayedBuckets.myOpenWaitingToBeMerged.count,
            myOnMergeQueue: displayedBuckets.myOpenOnMergeQueue.count
        )
    }

    var body: some View {
        interactivePopover
    }

    private var popoverLayout: some View {
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
        .animation(.snappy(duration: 0.22), value: showReReview)
        .animation(.snappy(duration: 0.22), value: showMyBlocked)
        .animation(.snappy(duration: 0.22), value: showMyWaiting)
        .animation(.snappy(duration: 0.22), value: showMyWaitingToMerge)
        .animation(.snappy(duration: 0.22), value: showMyOnMergeQueue)
    }

    private var interactivePopover: some View {
        popoverWithLifecycleObservers
            .onChange(of: visiblePullRequestIDs) { _, _ in
                reconcileSelectionAfterVisibleRowsChanged()
            }
            .onChange(of: focusedArea) { _, newValue in
                guard newValue == .resultsList else { return }
                selectedPRID = PullRequestKeyboardNavigation.reconciledSelectionID(
                    currentID: selectedPRID,
                    entries: visiblePullRequestEntries
                )
            }
    }

    private var popoverWithLifecycleObservers: some View {
        popoverLayout
            .onAppear(perform: handlePopoverAppear)
            .onChange(of: displayedBucketCounts) { oldCounts, newCounts in
                handleDisplayedBucketCountsChange(oldCounts: oldCounts, newCounts: newCounts)
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
                    Text("PR Tracker")
                        .font(.title3.weight(.semibold))
                    Text(headerSubtitle)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            } icon: {
                Image(systemName: "arrow.triangle.pull")
                    .font(.title3)
                    .foregroundStyle(.tint)
            }
            .labelStyle(.titleAndIcon)

            Spacer()

            HStack(spacing: 10) {
                draftVisibilityToggle

                refreshToolbarButton

                toolbarButton(systemName: "gearshape", helpText: "Open Settings") {
                    NSApp.activate(ignoringOtherApps: true)
                    openWindow(id: "settings")
                }
            }
            .padding(.trailing, 8)
        }
        .padding(.bottom, 2)
    }

    private var headerSubtitle: String {
        let user = unfilteredVisibleBuckets.user.isEmpty ? "@" : "@\(unfilteredVisibleBuckets.user)"
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

        if unfilteredVisibleBuckets.awaitingTruncated {
            TruncationBanner(message: "Needs-review results capped at 100. Narrow by org.")
        }
        if unfilteredVisibleBuckets.reviewedTruncated {
            TruncationBanner(message: "Re-review results capped at 100. Narrow by org.")
        }
        if unfilteredVisibleBuckets.myOpenTruncated {
            TruncationBanner(message: "Your open PRs capped at 100. Narrow by org.")
        }
    }

    @ViewBuilder
    private var loadedContent: some View {
        if unfilteredVisibleBuckets.needsReview.isEmpty
            && unfilteredVisibleBuckets.needsReReview.isEmpty
            && unfilteredVisibleBuckets.myOpenBlockedOnYou.isEmpty
            && unfilteredVisibleBuckets.myOpenWaitingOnReviewers.isEmpty
            && unfilteredVisibleBuckets.myOpenWaitingToBeMerged.isEmpty
            && unfilteredVisibleBuckets.myOpenOnMergeQueue.isEmpty {
            EmptyStateView(
                title: "No PR actions pending",
                subtitle: "Everything looks clear right now."
            )
        } else {
            VStack(alignment: .leading, spacing: 10) {
                searchField

                if displayedBuckets.needsReview.isEmpty
                    && displayedBuckets.needsReReview.isEmpty
                    && displayedBuckets.myOpenBlockedOnYou.isEmpty
                    && displayedBuckets.myOpenWaitingOnReviewers.isEmpty
                    && displayedBuckets.myOpenWaitingToBeMerged.isEmpty
                    && displayedBuckets.myOpenOnMergeQueue.isEmpty {
                    EmptyStateView(
                        title: "No matching pull requests",
                        subtitle: "Try a PR number, Jira key, or title keyword."
                    )
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else {
                    ScrollViewReader { scrollProxy in
                        ScrollView {
                            LazyVStack(alignment: .leading, spacing: 14) {
                                bucketSection(
                                    title: "Needs your review",
                                    pullRequests: displayedBuckets.needsReview,
                                    context: .needsReview,
                                    isExpanded: $showAwaiting
                                )

                                bucketSection(
                                    title: "Needs re-review",
                                    pullRequests: displayedBuckets.needsReReview,
                                    context: .needsReReview,
                                    isExpanded: $showReReview
                                )

                                bucketSection(
                                    title: "Your PRs blocked on you",
                                    pullRequests: displayedBuckets.myOpenBlockedOnYou,
                                    context: .myOpenBlockedOnYou,
                                    isExpanded: $showMyBlocked
                                )

                                bucketSection(
                                    title: "Your PRs waiting on reviewers",
                                    pullRequests: displayedBuckets.myOpenWaitingOnReviewers,
                                    context: .myOpenWaitingOnReviewers,
                                    isExpanded: $showMyWaiting
                                )

                                bucketSection(
                                    title: "My PRs waiting to be merged",
                                    pullRequests: displayedBuckets.myOpenWaitingToBeMerged,
                                    context: .myOpenWaitingToBeMerged,
                                    isExpanded: $showMyWaitingToMerge
                                )

                                bucketSection(
                                    title: "My PRs on MergeQ",
                                    pullRequests: displayedBuckets.myOpenOnMergeQueue,
                                    context: .myOpenOnMergeQueue,
                                    isExpanded: $showMyOnMergeQueue
                                )
                            }
                            // AppKit scrollbars overlay SwiftUI content inside the popover,
                            // so keep a small trailing gutter to protect the approvals
                            // column without making the scrollbar feel inset.
                            .padding(.trailing, 8)
                            .animation(.easeInOut(duration: 0.08), value: hoveredPRID)
                        }
                        // `.automatic` (the default) is required so the container
                        // accepts focus for navigation + activation without
                        // depending on the system "Full Keyboard Access"
                        // accessibility setting. `.activate` alone restricts
                        // focus to primary-action triggering only, which is
                        // why arrows/Tab were ignored previously.
                        .focusable()
                        // Per-row accent already shows the selection, so the
                        // outer container focus ring would just be visual
                        // noise around the whole list.
                        .focusEffectDisabled()
                        .focused($focusedArea, equals: .resultsList)
                        .onKeyPress(.upArrow) {
                            handleMoveSelectionKeyPress(direction: .up)
                        }
                        .onKeyPress(.downArrow) {
                            handleMoveSelectionKeyPress(direction: .down)
                        }
                        // macOS converts Shift+Tab into the back-tab character
                        // (U+0019) before SwiftUI's `keys: [.tab]` filter runs,
                        // so we have to register both equivalents to receive
                        // both directions.
                        .onKeyPress(keys: [.tab, Self.backTabKeyEquivalent]) { keyPress in
                            handleResultsListTabKeyPress(keyPress)
                        }
                        .onKeyPress(.return) {
                            handleActivateSelectionKeyPress()
                        }
                        .onKeyPress(.space) {
                            handleActivateSelectionKeyPress()
                        }
                        .onChange(of: selectedPRID) { _, newID in
                            guard let newID else { return }
                            withAnimation(.snappy(duration: 0.14)) {
                                scrollProxy.scrollTo(newID, anchor: .center)
                            }
                        }
                    }
                }
            }
        }
    }

    private var searchField: some View {
        HStack(spacing: 8) {
            Image(systemName: "magnifyingglass")
                .foregroundStyle(.secondary)

            KeyboardAwareSearchField(
                placeholder: "Filter by PR #, Jira, or title",
                text: $model.searchQuery,
                onBeginEditing: {
                    focusedArea = .searchField
                },
                onMoveDown: {
                    moveFocusFromSearchFieldToResults(direction: .down) == .handled
                },
                onMoveUp: {
                    moveFocusFromSearchFieldToResults(direction: .up) == .handled
                },
                onTab: { isShiftPressed in
                    let direction: PullRequestKeyboardNavigation.Direction = isShiftPressed ? .up : .down
                    return moveFocusFromSearchFieldToResults(direction: direction) == .handled
                }
            )

            if model.hasActiveSearch {
                Button {
                    model.searchQuery = ""
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
                .help("Clear filter")
            }
        }
        .font(.subheadline)
        .padding(.horizontal, 10)
        .padding(.vertical, 7)
        .background(Color.secondary.opacity(0.08))
        .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .strokeBorder(Color.primary.opacity(0.05), lineWidth: 1)
        )
        .padding(.trailing, 8)
    }

    @ViewBuilder
    private func bucketSection(
        title: String,
        pullRequests: [PullRequest],
        context: PullRequestListContext,
        isExpanded: Binding<Bool>
    ) -> some View {
        if pullRequests.isEmpty == false {
            VStack(alignment: .leading, spacing: 6) {
                sectionHeaderRow(
                    title: title,
                    count: pullRequests.count,
                    isExpanded: isExpanded
                )

                if isExpanded.wrappedValue {
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
                                reminder: model.reminder(for: pullRequest),
                                canConfigureReminder: model.canSetReminder(for: pullRequest, context: context),
                                onSetReminder: { scheduledAt in
                                    model.setReminder(for: pullRequest, context: context, at: scheduledAt)
                                },
                                onCustomReminderRequested: {
                                    model.beginCustomReminderEditor(for: pullRequest, context: context)
                                    guard model.reminderEditorDraft != nil else { return }
                                    NSApp.activate(ignoringOtherApps: true)
                                    openWindow(id: "reminder-editor")
                                },
                                onClearReminder: {
                                    model.clearReminder(for: pullRequest)
                                },
                                hoveredID: $hoveredPRID,
                                isSelected: selectedPRID == pullRequest.id,
                                onSelect: {
                                    selectPullRequest(id: pullRequest.id)
                                },
                                onOpenPullRequest: openPullRequest,
                                onOpenPullRequestDebounced: openPullRequestDebounced
                            )
                            .id(pullRequest.id)
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

    private func selectPullRequest(id: String) {
        selectedPRID = id
        focusedArea = .resultsList
    }

    private func handlePopoverAppear() {
        model.searchQuery = ""
        syncSectionExpansionForCurrentBuckets()
        // Pre-select the first PR so the list shows a clear visual entry point
        // even while keyboard focus starts in the search field. The search
        // field forwards arrows / Tab / Shift-Tab into the list (see
        // `KeyboardAwareSearchField`), so users can either type to filter or
        // immediately navigate without thinking about focus.
        selectedPRID = PullRequestKeyboardNavigation.reconciledSelectionID(
            currentID: selectedPRID,
            entries: visiblePullRequestEntries
        )
        focusedArea = .searchField
        model.startIfNeeded()
        model.onPopoverOpened()
    }

    private func handleDisplayedBucketCountsChange(
        oldCounts: DisplayedBucketCounts,
        newCounts: DisplayedBucketCounts
    ) {
        updateSectionExpansion(
            isExpanded: &showAwaiting,
            previousCount: oldCounts.needsReview,
            currentCount: newCounts.needsReview
        )
        updateSectionExpansion(
            isExpanded: &showReReview,
            previousCount: oldCounts.needsReReview,
            currentCount: newCounts.needsReReview
        )
        updateSectionExpansion(
            isExpanded: &showMyBlocked,
            previousCount: oldCounts.myBlocked,
            currentCount: newCounts.myBlocked
        )
        updateSectionExpansion(
            isExpanded: &showMyWaiting,
            previousCount: oldCounts.myWaiting,
            currentCount: newCounts.myWaiting
        )
        updateSectionExpansion(
            isExpanded: &showMyWaitingToMerge,
            previousCount: oldCounts.myWaitingToMerge,
            currentCount: newCounts.myWaitingToMerge
        )
        updateSectionExpansion(
            isExpanded: &showMyOnMergeQueue,
            previousCount: oldCounts.myOnMergeQueue,
            currentCount: newCounts.myOnMergeQueue
        )
    }

    private func handleMoveSelectionKeyPress(
        direction: PullRequestKeyboardNavigation.Direction
    ) -> KeyPress.Result {
        guard focusedArea == .resultsList else { return .ignored }
        selectedPRID = PullRequestKeyboardNavigation.nextSelectionID(
            currentID: selectedPRID,
            entries: visiblePullRequestEntries,
            direction: direction
        )
        return .handled
    }

    private func handleActivateSelectionKeyPress() -> KeyPress.Result {
        guard focusedArea == .resultsList else { return .ignored }
        guard let selectedPullRequestEntry else { return .ignored }
        openPullRequestDebounced(selectedPullRequestEntry.pullRequest)
        return .handled
    }

    private func handleResultsListTabKeyPress(_ keyPress: KeyPress) -> KeyPress.Result {
        let isReverseTraversal = keyPress.modifiers.contains(.shift)
            || keyPress.key == Self.backTabKeyEquivalent
        let direction: PullRequestKeyboardNavigation.Direction = isReverseTraversal ? .up : .down
        return handleMoveSelectionKeyPress(direction: direction)
    }

    private func moveFocusFromSearchFieldToResults(
        direction: PullRequestKeyboardNavigation.Direction
    ) -> KeyPress.Result {
        guard visiblePullRequestEntries.isEmpty == false else { return .ignored }
        // The NSTextField inside `KeyboardAwareSearchField` owns first
        // responder via AppKit, but `@FocusState` only manages SwiftUI focus.
        // Resign the AppKit responder explicitly so focus actually leaves the
        // text field when we hand it to the SwiftUI ScrollView below.
        NSApp.keyWindow?.makeFirstResponder(nil)
        focusedArea = .resultsList
        // Reuse the same advance/regress logic as in-list arrow handling so
        // search-to-list transfer is symmetric and never silently overwrites
        // an existing selection (e.g. user reopens popover with PR #5 still
        // selected, presses Up → moves to PR #4 instead of jumping to last).
        selectedPRID = PullRequestKeyboardNavigation.nextSelectionID(
            currentID: selectedPRID,
            entries: visiblePullRequestEntries,
            direction: direction
        )
        return .handled
    }

    private func reconcileSelectionAfterVisibleRowsChanged() {
        selectedPRID = PullRequestKeyboardNavigation.reconciledSelectionID(
            currentID: selectedPRID,
            entries: visiblePullRequestEntries
        )
    }

    private func openPullRequest(_ pullRequest: PullRequest) {
        guard let url = pullRequest.url else { return }
        // Open the URL in the default browser without activating it. This
        // keeps PR Tracker as the key window so the menu-bar popover stays
        // open and keyboard focus remains on the results list — letting the
        // user queue up multiple PRs and switch to the browser on their own
        // schedule (Cmd+Tab). Falls back to the standard activating open if
        // the system can't resolve a default handler URL.
        guard let applicationURL = NSWorkspace.shared.urlForApplication(toOpen: url) else {
            NSWorkspace.shared.open(url)
            return
        }
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.activates = false
        NSWorkspace.shared.open(
            [url],
            withApplicationAt: applicationURL,
            configuration: configuration,
            completionHandler: nil
        )
    }

    private func openPullRequestDebounced(_ pullRequest: PullRequest) {
        let now = Date()
        guard now.timeIntervalSince(lastOpenAt) > 0.35 else { return }
        lastOpenAt = now
        openPullRequest(pullRequest)
    }

    private func syncSectionExpansionForCurrentBuckets() {
        showAwaiting = displayedBuckets.needsReview.isEmpty == false
        showReReview = displayedBuckets.needsReReview.isEmpty == false
        showMyBlocked = displayedBuckets.myOpenBlockedOnYou.isEmpty == false
        showMyWaiting = displayedBuckets.myOpenWaitingOnReviewers.isEmpty == false
        showMyWaitingToMerge = displayedBuckets.myOpenWaitingToBeMerged.isEmpty == false
        showMyOnMergeQueue = displayedBuckets.myOpenOnMergeQueue.isEmpty == false
    }

    private func updateSectionExpansion(
        isExpanded: inout Bool,
        previousCount: Int,
        currentCount: Int
    ) {
        if currentCount == 0 {
            isExpanded = false
        } else if previousCount == 0 {
            isExpanded = true
        }
    }
}

struct PullRequestKeyboardNavigation {
    struct SectionExpansion: Equatable, Sendable {
        let showAwaiting: Bool
        let showReReview: Bool
        let showMyBlocked: Bool
        let showMyWaiting: Bool
        let showMyWaitingToMerge: Bool
        let showMyOnMergeQueue: Bool
    }

    struct Entry: Identifiable, Hashable, Sendable {
        let pullRequest: PullRequest
        let context: PullRequestListContext

        var id: String {
            pullRequest.id
        }
    }

    enum Direction: Sendable {
        case up
        case down
    }

    static func visibleEntries(
        in buckets: ReviewBuckets,
        expansion: SectionExpansion
    ) -> [Entry] {
        var entries: [Entry] = []

        func append(
            _ pullRequests: [PullRequest],
            context: PullRequestListContext,
            isExpanded: Bool
        ) {
            guard isExpanded else { return }
            entries.append(contentsOf: pullRequests.map { Entry(pullRequest: $0, context: context) })
        }

        append(
            buckets.needsReview,
            context: .needsReview,
            isExpanded: expansion.showAwaiting
        )
        append(
            buckets.needsReReview,
            context: .needsReReview,
            isExpanded: expansion.showReReview
        )
        append(
            buckets.myOpenBlockedOnYou,
            context: .myOpenBlockedOnYou,
            isExpanded: expansion.showMyBlocked
        )
        append(
            buckets.myOpenWaitingOnReviewers,
            context: .myOpenWaitingOnReviewers,
            isExpanded: expansion.showMyWaiting
        )
        append(
            buckets.myOpenWaitingToBeMerged,
            context: .myOpenWaitingToBeMerged,
            isExpanded: expansion.showMyWaitingToMerge
        )
        append(
            buckets.myOpenOnMergeQueue,
            context: .myOpenOnMergeQueue,
            isExpanded: expansion.showMyOnMergeQueue
        )

        return entries
    }

    static func reconciledSelectionID(
        currentID: String?,
        entries: [Entry]
    ) -> String? {
        guard entries.isEmpty == false else { return nil }
        if let currentID, entries.contains(where: { $0.id == currentID }) {
            return currentID
        }
        return entries.first?.id
    }

    static func nextSelectionID(
        currentID: String?,
        entries: [Entry],
        direction: Direction
    ) -> String? {
        guard entries.isEmpty == false else { return nil }

        guard let currentID,
              let currentIndex = entries.firstIndex(where: { $0.id == currentID }) else {
            switch direction {
            case .up:
                return entries.last?.id
            case .down:
                return entries.first?.id
            }
        }

        let nextIndex: Int
        switch direction {
        case .up:
            nextIndex = max(currentIndex - 1, 0)
        case .down:
            nextIndex = min(currentIndex + 1, entries.count - 1)
        }
        return entries[nextIndex].id
    }
}

private struct KeyboardAwareSearchField: NSViewRepresentable {
    let placeholder: String
    @Binding var text: String
    let onBeginEditing: () -> Void
    let onMoveDown: () -> Bool
    let onMoveUp: () -> Bool
    let onTab: (_ isShiftPressed: Bool) -> Bool

    func makeCoordinator() -> Coordinator {
        Coordinator(parent: self)
    }

    func makeNSView(context: Context) -> NSTextField {
        let textField = NSTextField(string: text)
        textField.placeholderString = placeholder
        textField.delegate = context.coordinator
        textField.isBordered = false
        textField.isBezeled = false
        textField.drawsBackground = false
        textField.focusRingType = .none
        textField.lineBreakMode = .byTruncatingTail
        return textField
    }

    func updateNSView(_ nsView: NSTextField, context: Context) {
        context.coordinator.parent = self
        nsView.placeholderString = placeholder
        if nsView.stringValue != text {
            nsView.stringValue = text
        }
    }

    final class Coordinator: NSObject, NSTextFieldDelegate {
        var parent: KeyboardAwareSearchField

        init(parent: KeyboardAwareSearchField) {
            self.parent = parent
        }

        func controlTextDidBeginEditing(_ obj: Notification) {
            parent.onBeginEditing()
        }

        func controlTextDidChange(_ obj: Notification) {
            guard let textField = obj.object as? NSTextField else { return }
            if parent.text != textField.stringValue {
                parent.text = textField.stringValue
            }
        }

        func control(
            _ control: NSControl,
            textView: NSTextView,
            doCommandBy commandSelector: Selector
        ) -> Bool {
            switch commandSelector {
            case #selector(NSResponder.moveDown(_:)):
                return parent.onMoveDown()
            case #selector(NSResponder.moveUp(_:)):
                return parent.onMoveUp()
            case #selector(NSResponder.insertTab(_:)):
                return parent.onTab(false)
            case #selector(NSResponder.insertBacktab(_:)):
                return parent.onTab(true)
            default:
                return false
            }
        }
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

