import Foundation
import Observation

@MainActor
enum MenuBarIconState {
    case idle
    case needsReview
    case needsReReview
    case error
}

@MainActor
struct ReminderEditorDraft: Identifiable {
    let pullRequest: PullRequest
    let context: PullRequestListContext
    let minimumDate: Date
    var scheduledAt: Date

    var id: String {
        "\(pullRequest.id)-\(context.id)"
    }
}

@MainActor
@Observable
final class AppModel {
    var buckets: ReviewBuckets = .empty
    var loadState: LoadState = .idle
    var lastRefreshedAt: Date?
    var rateLimitRemaining: Int?
    var isOnline = true
    var lastRefreshErrorMessage: String?
    var searchQuery = ""

    private(set) var settings: AppSettings

    private let userDefaults: UserDefaults
    private let pendingReviewsService: any PendingReviewsServing
    private let refreshScheduler: RefreshScheduler
    private let seenStateStore: any SeenStateStoring
    private let notificationService: any NotificationServing
    private let reminderStore: any ReminderStoring
    private let reminderScheduler: any ReminderScheduling
    private let launchAtLoginService: any LaunchAtLoginServing
    private let reachability: any ReachabilityServing
    private let sleepWakeObserver: any SleepWakeObserving

    private(set) var isRefreshing = false
    private(set) var remindersByKey: [PullRequestReminderKey: PullRequestReminder] = [:]
    private(set) var reminderEditorDraft: ReminderEditorDraft?

    private var didStart = false

    init(
        userDefaults: UserDefaults = .standard,
        pendingReviewsService: (any PendingReviewsServing)? = nil,
        refreshScheduler: RefreshScheduler? = nil,
        seenStateStore: (any SeenStateStoring)? = nil,
        notificationService: (any NotificationServing)? = nil,
        reminderStore: (any ReminderStoring)? = nil,
        reminderScheduler: (any ReminderScheduling)? = nil,
        launchAtLoginService: (any LaunchAtLoginServing)? = nil,
        reachability: (any ReachabilityServing)? = nil,
        sleepWakeObserver: (any SleepWakeObserving)? = nil
    ) {
        self.userDefaults = userDefaults
        self.settings = AppSettings.fromUserDefaults(userDefaults)

        self.pendingReviewsService = pendingReviewsService
            ?? PendingReviewsService(authService: GHAuthService())

        self.refreshScheduler = refreshScheduler ?? RefreshScheduler()
        self.seenStateStore = seenStateStore ?? SeenStateStore(defaults: userDefaults)
        self.notificationService = notificationService ?? NotificationService()
        self.reminderStore = reminderStore ?? ReminderStore(defaults: userDefaults)
        self.reminderScheduler = reminderScheduler ?? ReminderScheduler()
        self.launchAtLoginService = launchAtLoginService ?? LaunchAtLoginService()
        self.reachability = reachability ?? Reachability()
        self.sleepWakeObserver = sleepWakeObserver ?? SleepWakeObserver()
    }

    func startIfNeeded() {
        guard didStart == false else { return }
        didStart = true

        refreshFromStoredSettings(forceApplySystemSettings: true, restartScheduler: false)
        Task { [weak self] in
            guard let self else { return }
            await self.loadRemindersForCurrentHost()
        }

        reachability.start { [weak self] reachable in
            guard let self else { return }
            self.isOnline = reachable
            if reachable {
                if case .offline = self.loadState {
                    self.loadState = .idle
                }
                self.startScheduler()
                Task { [weak self] in
                    guard let self else { return }
                    _ = await self.refresh(reason: "reachability-restored")
                }
            } else {
                self.loadState = .offline
                self.refreshScheduler.stop()
            }
        }

        sleepWakeObserver.start(
            onWillSleep: { [weak self] in
                guard let self else { return }
                Task { @MainActor [weak self] in
                    guard let self else { return }
                    self.refreshScheduler.stop()
                    Task {
                        await self.reminderScheduler.stop()
                    }
                }
            },
            onDidWake: { [weak self] in
                guard let self else { return }
                Task { @MainActor [weak self] in
                    guard let self else { return }
                    await self.scheduleReminderChecks()
                    self.startScheduler()
                    _ = await self.refresh(reason: "did-wake")
                }
            }
        )

        startScheduler()
    }

    func onPopoverOpened() {
        Task { [weak self] in
            guard let self else { return }
            _ = await self.refresh(reason: "popover-open")
        }
    }

    func manualRefresh() {
        Task { [weak self] in
            guard let self else { return }
            _ = await self.refresh(reason: "manual")
        }
    }

    func refreshFromStoredSettings(
        forceApplySystemSettings: Bool = false,
        restartScheduler: Bool = true
    ) {
        let previousSettings = settings
        settings = AppSettings.fromUserDefaults(userDefaults)
        if restartScheduler {
            startScheduler()
        }

        if settings.notificationsEnabled, previousSettings.notificationsEnabled == false {
            Task { [weak self] in
                guard let self else { return }
                await self.notificationService.requestAuthorizationIfNeeded()
            }
        }

        if forceApplySystemSettings || previousSettings.launchAtLoginEnabled != settings.launchAtLoginEnabled {
            applyLaunchAtLoginPreference()
        }

        Task { [weak self] in
            guard let self else { return }
            await self.handleReminderSettingsChange(previousSettings: previousSettings)
        }
    }

    func applyLaunchAtLoginPreference() {
        do {
            try launchAtLoginService.setEnabled(settings.launchAtLoginEnabled)
        } catch {
            AppLog.ui.error("Failed to set launch at login: \(error.localizedDescription)")
        }
    }

    func authLoginCommand(hostOverride: String? = nil) -> String {
        AppSettings.loginCommand(for: hostOverride ?? settings.host)
    }

    var menuBarIconState: MenuBarIconState {
        let buckets = visibleBuckets
        switch loadState {
        case .error, .unauthenticated:
            return .error
        case .loaded, .offline:
            if buckets.needsReReview.isEmpty == false {
                return .needsReReview
            }
            if buckets.needsReview.isEmpty == false {
                return .needsReview
            }
            return .idle
        case .idle, .loading:
            return .idle
        }
    }

    var reviewerAttentionCount: Int {
        visibleBuckets.needsReview.count + visibleBuckets.needsReReview.count
    }

    var visibleBuckets: ReviewBuckets {
        buckets.filtered(includeDrafts: settings.includeDraftPullRequests)
    }

    var displayedBuckets: ReviewBuckets {
        visibleBuckets.filtered(matching: searchQuery)
    }

    var hasActiveSearch: Bool {
        searchQuery.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false
    }

    func setIncludeDraftPullRequests(_ include: Bool) {
        guard settings.includeDraftPullRequests != include else { return }
        userDefaults.set(include, forKey: AppSettings.Keys.includeDraftPullRequests)
        refreshFromStoredSettings()
    }

    func canSetReminder(for pullRequest: PullRequest, context: PullRequestListContext) -> Bool {
        pullRequest.canConfigureReminder(
            context: context,
            viewerLogin: visibleBuckets.user
        )
    }

    func reminder(for pullRequest: PullRequest) -> PullRequestReminder? {
        remindersByKey[pullRequest.reminderKey(host: reminderHost)]
    }

    func setReminder(
        for pullRequest: PullRequest,
        context: PullRequestListContext,
        at scheduledAt: Date
    ) {
        guard canSetReminder(for: pullRequest, context: context) else { return }

        let key = pullRequest.reminderKey(host: reminderHost)
        let reminder = PullRequestReminder(
            key: key,
            title: pullRequest.title,
            url: pullRequest.url,
            author: pullRequest.author,
            scheduledAt: max(scheduledAt, Date().addingTimeInterval(60)),
            createdAt: Date()
        )
        remindersByKey[key] = reminder

        Task { [weak self] in
            guard let self else { return }
            await self.reminderStore.upsert(reminder)
            await self.scheduleReminderChecks()
        }
    }

    func clearReminder(for pullRequest: PullRequest) {
        let key = pullRequest.reminderKey(host: reminderHost)
        guard remindersByKey.removeValue(forKey: key) != nil else { return }

        Task { [weak self] in
            guard let self else { return }
            await self.reminderStore.removeReminder(for: key)
            await self.scheduleReminderChecks()
        }
    }

    func beginCustomReminderEditor(for pullRequest: PullRequest, context: PullRequestListContext) {
        guard canSetReminder(for: pullRequest, context: context) else { return }

        let minimumDate = Date().addingTimeInterval(60)
        let fallbackDate = Date().addingTimeInterval(3_600)
        let selectedDate = max(reminder(for: pullRequest)?.scheduledAt ?? fallbackDate, minimumDate)

        reminderEditorDraft = ReminderEditorDraft(
            pullRequest: pullRequest,
            context: context,
            minimumDate: minimumDate,
            scheduledAt: selectedDate
        )
    }

    func updateReminderEditorDate(_ selectedDate: Date) {
        guard var draft = reminderEditorDraft else { return }
        draft.scheduledAt = max(selectedDate, draft.minimumDate)
        reminderEditorDraft = draft
    }

    func cancelReminderEditor() {
        reminderEditorDraft = nil
    }

    func confirmReminderEditor() {
        guard let draft = reminderEditorDraft else { return }
        setReminder(
            for: draft.pullRequest,
            context: draft.context,
            at: draft.scheduledAt
        )
        reminderEditorDraft = nil
    }

    @discardableResult
    func refresh(reason: String) async -> Bool {
        if isRefreshing {
            return false
        }

        if isOnline == false {
            loadState = .offline
            return false
        }

        let previousLoadState = loadState
        isRefreshing = true
        defer { isRefreshing = false }

        if case .loaded = loadState {
            // Keep loaded state while refreshing in the background.
        } else if case .offline = loadState {
            loadState = .loading
        } else {
            loadState = .loading
        }

        do {
            let result = try await pendingReviewsService.fetch(settings: settings)
            buckets = result.buckets
            rateLimitRemaining = result.rateLimitRemaining
            lastRefreshedAt = Date()
            lastRefreshErrorMessage = nil
            loadState = .loaded

            let diff = await seenStateStore.apply(current: visibleBuckets)
            await notificationService.postNotifications(from: diff, enabled: settings.notificationsEnabled)
            await reconcileRemindersWithCurrentBuckets()
            AppLog.refresh.info("Refresh succeeded for reason: \(reason)")
            return true
        } catch let error as AuthError {
            let message = error.errorDescription ?? "Authentication failed."
            lastRefreshErrorMessage = nil
            loadState = .unauthenticated(message)
            AppLog.auth.error("Authentication failed: \(message)")
            return false
        } catch {
            let message = error.localizedDescription
            if lastRefreshedAt != nil {
                lastRefreshErrorMessage = message
                switch previousLoadState {
                case .offline:
                    loadState = .offline
                default:
                    loadState = .loaded
                }
            } else {
                lastRefreshErrorMessage = nil
                loadState = .error(message)
            }
            AppLog.network.error("Refresh failed: \(message)")
            return false
        }
    }

    private func startScheduler() {
        guard didStart else { return }
        refreshScheduler.start(intervalSeconds: settings.refreshIntervalSeconds) { [weak self] in
            guard let self else { return true }
            return await self.refresh(reason: "timer")
        }
    }

    private var reminderHost: String {
        let host = settings.host.trimmingCharacters(in: .whitespacesAndNewlines)
        return AppSettings.normalizedHost(host)
    }

    private func handleReminderSettingsChange(previousSettings: AppSettings) async {
        if previousSettings.host.caseInsensitiveCompare(settings.host) != .orderedSame {
            await loadRemindersForCurrentHost()
            return
        }

        await scheduleReminderChecks()
    }

    private func loadRemindersForCurrentHost() async {
        let allReminders = await reminderStore.loadReminders()
        let host = reminderHost
        let reminders = allReminders.filter { $0.key.matches(host: host) }
        remindersByKey = Dictionary(uniqueKeysWithValues: reminders.map { ($0.key, $0) })
        await scheduleReminderChecks()
    }

    private func reconcileRemindersWithCurrentBuckets() async {
        let viewer = buckets.user.trimmingCharacters(in: .whitespacesAndNewlines)
        guard viewer.isEmpty == false else {
            await scheduleReminderChecks()
            return
        }

        let host = reminderHost
        let eligibleKeys = Set(
            (buckets.needsReview + buckets.needsReReview)
                .filter { $0.isAuthored(by: viewer) == false }
                .map { $0.reminderKey(host: host) }
        )

        let staleKeys = Set(remindersByKey.keys).subtracting(eligibleKeys)
        if staleKeys.isEmpty {
            await scheduleReminderChecks()
            return
        }

        for key in staleKeys {
            remindersByKey.removeValue(forKey: key)
        }
        await reminderStore.removeReminders(for: staleKeys)
        await scheduleReminderChecks()
    }

    private func scheduleReminderChecks(now: Date = Date()) async {
        let reminders = Array(remindersByKey.values)
        await reminderScheduler.update(reminders: reminders, now: now) { [weak self] dueReminders in
            guard let self else { return }
            await MainActor.run {
                self.handleDueReminders(dueReminders)
            }
        }
    }

    private func handleDueReminders(_ dueReminders: [PullRequestReminder]) {
        guard dueReminders.isEmpty == false else { return }
        guard settings.notificationsEnabled else { return }

        let activeDue = dueReminders.compactMap { remindersByKey[$0.key] }
        guard activeDue.isEmpty == false else { return }

        let dueKeys = Set(activeDue.map(\.key))
        for key in dueKeys {
            remindersByKey.removeValue(forKey: key)
        }

        Task { [weak self] in
            guard let self else { return }
            await self.notificationService.postReminderNotifications(activeDue, enabled: self.settings.notificationsEnabled)
            await self.reminderStore.removeReminders(for: dueKeys)
            await self.scheduleReminderChecks()
        }
    }
}

private extension PullRequestListContext {
    var id: String {
        switch self {
        case .needsReview:
            return "needs-review"
        case .needsReReview:
            return "needs-rereview"
        case .myOpenWaitingOnReviewers:
            return "my-open-waiting"
        case .myOpenBlockedOnYou:
            return "my-open-blocked"
        case .myOpenWaitingToBeMerged:
            return "my-open-waiting-to-merge"
        case .myOpenOnMergeQueue:
            return "my-open-on-merge-queue"
        }
    }
}

