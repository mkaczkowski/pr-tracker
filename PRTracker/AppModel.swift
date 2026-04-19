import Foundation
import Observation

@MainActor
enum MenuBarIconState {
    case idle
    case hasAwaiting
    case hasStaleOrUpdated
    case error
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

    private(set) var settings: AppSettings

    private let userDefaults: UserDefaults
    private let pendingReviewsService: any PendingReviewsServing
    private let refreshScheduler: RefreshScheduler
    private let seenStateStore: any SeenStateStoring
    private let notificationService: any NotificationServing
    private let launchAtLoginService: any LaunchAtLoginServing
    private let reachability: any ReachabilityServing
    private let sleepWakeObserver: any SleepWakeObserving

    private(set) var isRefreshing = false

    private var didStart = false

    init(
        userDefaults: UserDefaults = .standard,
        pendingReviewsService: (any PendingReviewsServing)? = nil,
        refreshScheduler: RefreshScheduler? = nil,
        seenStateStore: (any SeenStateStoring)? = nil,
        notificationService: (any NotificationServing)? = nil,
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
        self.launchAtLoginService = launchAtLoginService ?? LaunchAtLoginService()
        self.reachability = reachability ?? Reachability()
        self.sleepWakeObserver = sleepWakeObserver ?? SleepWakeObserver()
    }

    func startIfNeeded() {
        guard didStart == false else { return }
        didStart = true

        refreshFromStoredSettings(forceApplySystemSettings: true, restartScheduler: false)

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
                    self?.refreshScheduler.stop()
                }
            },
            onDidWake: { [weak self] in
                guard let self else { return }
                Task { @MainActor [weak self] in
                    guard let self else { return }
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
            if buckets.hasUpdatedSinceReview {
                return .hasStaleOrUpdated
            }
            if buckets.awaitingReview.isEmpty == false {
                return .hasAwaiting
            }
            return .idle
        case .idle, .loading:
            return .idle
        }
    }

    var awaitingCount: Int {
        visibleBuckets.awaitingReview.count
    }

    var visibleBuckets: ReviewBuckets {
        buckets.filtered(includeDrafts: settings.includeDraftPullRequests)
    }

    func setIncludeDraftPullRequests(_ include: Bool) {
        guard settings.includeDraftPullRequests != include else { return }
        userDefaults.set(include, forKey: AppSettings.Keys.includeDraftPullRequests)
        refreshFromStoredSettings()
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
}

