import Foundation
import XCTest
@testable import PRTracker

@MainActor
final class AppModelTests: XCTestCase {
    private var defaults: UserDefaults!
    private var suiteName: String!

    override func setUp() {
        super.setUp()
        suiteName = "AppModelTests.\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suiteName)
    }

    override func tearDown() {
        defaults.removePersistentDomain(forName: suiteName)
        defaults = nil
        suiteName = nil
        super.tearDown()
    }

    func testRefreshSuccessUpdatesLoadedStateAndPostsNotifications() async {
        let buckets = makeBuckets()
        let pending = StubPendingReviewsService(result: .success(.init(buckets: buckets, rateLimitRemaining: 42)))
        let seen = StubSeenStateStore(
            diff: SeenStateDiff(newlyAwaiting: buckets.needsReview, newlyUpdatedSinceReview: [])
        )
        let notifications = StubNotificationService()

        let model = makeModel(
            pendingReviewsService: pending,
            seenStateStore: seen,
            notificationService: notifications
        )

        let didRefresh = await model.refresh(reason: "test-success")
        XCTAssertTrue(didRefresh)
        XCTAssertEqual(model.buckets.user, "alice")
        XCTAssertEqual(model.rateLimitRemaining, 42)
        XCTAssertNotNil(model.lastRefreshedAt)
        XCTAssertNil(model.lastRefreshErrorMessage)
        XCTAssertEqual(pending.fetchCallCount, 1)
        XCTAssertEqual(seen.applyCount, 1)
        XCTAssertEqual(notifications.postedEnabledValues, [false])

        guard case .loaded = model.loadState else {
            return XCTFail("Expected loaded state")
        }
    }

    func testRefreshAuthErrorSetsUnauthenticatedState() async {
        let pending = StubPendingReviewsService(result: .failure(AuthError.notAuthenticated(host: "github.com")))
        let model = makeModel(pendingReviewsService: pending)

        let didRefresh = await model.refresh(reason: "test-auth-error")
        XCTAssertFalse(didRefresh)

        guard case let .unauthenticated(message) = model.loadState else {
            return XCTFail("Expected unauthenticated state")
        }
        XCTAssertTrue(message.contains("github.com"))
    }

    func testRefreshGenericErrorSetsErrorState() async {
        let pending = StubPendingReviewsService(result: .failure(URLError(.badServerResponse)))
        let model = makeModel(pendingReviewsService: pending)

        let didRefresh = await model.refresh(reason: "test-generic-error")
        XCTAssertFalse(didRefresh)

        guard case .error = model.loadState else {
            return XCTFail("Expected error state")
        }
        XCTAssertNil(model.lastRefreshErrorMessage)
    }

    func testRefreshGenericErrorAfterSuccessfulLoadKeepsLoadedStateAndStoresErrorMessage() async {
        let error = URLError(.networkConnectionLost)
        let pending = SequencedPendingReviewsService(results: [
            .success(.init(buckets: makeBuckets(), rateLimitRemaining: 42)),
            .failure(error)
        ])
        let model = makeModel(pendingReviewsService: pending)

        let initialRefresh = await model.refresh(reason: "test-initial-success")
        XCTAssertTrue(initialRefresh)

        let didRefresh = await model.refresh(reason: "test-cached-error")
        XCTAssertFalse(didRefresh)

        guard case .loaded = model.loadState else {
            return XCTFail("Expected loaded state with cached data")
        }
        XCTAssertEqual(model.buckets.user, "alice")
        XCTAssertEqual(model.rateLimitRemaining, 42)
        XCTAssertEqual(model.lastRefreshErrorMessage, error.localizedDescription)
    }

    func testRefreshSuccessClearsPreviousRefreshErrorMessage() async {
        let error = URLError(.timedOut)
        let pending = SequencedPendingReviewsService(results: [
            .success(.init(buckets: makeBuckets(), rateLimitRemaining: 42)),
            .failure(error),
            .success(.init(buckets: makeBuckets(), rateLimitRemaining: 7))
        ])
        let model = makeModel(pendingReviewsService: pending)

        let firstRefresh = await model.refresh(reason: "test-first-success")
        XCTAssertTrue(firstRefresh)
        let failedRefresh = await model.refresh(reason: "test-failure")
        XCTAssertFalse(failedRefresh)
        XCTAssertEqual(model.lastRefreshErrorMessage, error.localizedDescription)

        let recoveryRefresh = await model.refresh(reason: "test-recovery")
        XCTAssertTrue(recoveryRefresh)
        XCTAssertNil(model.lastRefreshErrorMessage)
        XCTAssertEqual(model.rateLimitRemaining, 7)
    }

    func testRefreshOfflineSkipsFetch() async {
        let pending = StubPendingReviewsService(result: .success(.init(buckets: makeBuckets(), rateLimitRemaining: nil)))
        let model = makeModel(pendingReviewsService: pending)
        model.isOnline = false

        let didRefresh = await model.refresh(reason: "test-offline")
        XCTAssertFalse(didRefresh)
        XCTAssertEqual(pending.fetchCallCount, 0)

        guard case .offline = model.loadState else {
            return XCTFail("Expected offline state")
        }
    }

    func testRefreshSkipsConcurrentInFlightRefresh() async {
        let pending = BlockingPendingReviewsService(result: .init(buckets: makeBuckets(), rateLimitRemaining: nil))
        let model = makeModel(pendingReviewsService: pending)

        let firstTask = Task {
            await model.refresh(reason: "first")
        }

        await pending.waitUntilStarted()
        let secondResult = await model.refresh(reason: "second")
        XCTAssertFalse(secondResult)
        XCTAssertEqual(pending.fetchCallCount, 1)

        pending.unblock()
        let firstResult = await firstTask.value
        XCTAssertTrue(firstResult)
        XCTAssertEqual(pending.fetchCallCount, 1)
    }

    func testVisibleBucketsExcludeDraftsWhenSettingDisabled() async {
        defaults.set(false, forKey: AppSettings.Keys.includeDraftPullRequests)

        let draft = makePullRequest(number: 11, isDraft: true)
        let ready = makePullRequest(number: 12, isDraft: false)
        let buckets = ReviewBuckets(
            user: "alice",
            host: "github.com",
            needsReview: [draft, ready],
            needsReReview: [],
            myOpenWaitingOnReviewers: [],
            myOpenBlockedOnYou: [],
            myOpenEnoughApprovals: [],
            totals: BucketTotals(awaiting: 2, reviewed: 0),
            awaitingTruncated: false,
            reviewedTruncated: false,
            myOpenTruncated: false
        )

        let pending = StubPendingReviewsService(result: .success(.init(buckets: buckets, rateLimitRemaining: nil)))
        let model = makeModel(pendingReviewsService: pending)

        _ = await model.refresh(reason: "draft-filter")

        XCTAssertEqual(model.buckets.needsReview.map(\.number), [11, 12])
        XCTAssertEqual(model.visibleBuckets.needsReview.map(\.number), [12])
        XCTAssertEqual(model.reviewerAttentionCount, 1)
    }

    func testSetIncludeDraftPullRequestsPersistsPreference() {
        let model = makeModel(pendingReviewsService: StubPendingReviewsService(result: .success(.init(buckets: makeBuckets(), rateLimitRemaining: nil))))

        model.setIncludeDraftPullRequests(false)

        XCTAssertEqual(defaults.object(forKey: AppSettings.Keys.includeDraftPullRequests) as? Bool, false)
        XCTAssertFalse(model.settings.includeDraftPullRequests)
    }

    func testRefreshFromStoredSettingsDoesNotStartSchedulerBeforeModelStarts() {
        let pending = StubPendingReviewsService(result: .success(.init(buckets: makeBuckets(), rateLimitRemaining: nil)))
        let model = makeModel(pendingReviewsService: pending)

        model.refreshFromStoredSettings()

        XCTAssertEqual(pending.fetchCallCount, 0)
    }

    func testCanSetReminderRejectsAuthoredAndMyOpenContext() {
        let model = makeModel(
            pendingReviewsService: StubPendingReviewsService(result: .success(.init(buckets: makeBuckets(), rateLimitRemaining: nil)))
        )

        let reviewerPR = makePullRequest(number: 40, isDraft: false, author: "bob")
        let authoredByMe = makePullRequest(number: 41, isDraft: false, author: "alice")
        model.buckets = ReviewBuckets(
            user: "alice",
            host: "github.com",
            needsReview: [reviewerPR, authoredByMe],
            needsReReview: [],
            myOpenWaitingOnReviewers: [authoredByMe],
            myOpenBlockedOnYou: [],
            myOpenEnoughApprovals: [],
            totals: BucketTotals(awaiting: 2, reviewed: 0),
            awaitingTruncated: false,
            reviewedTruncated: false,
            myOpenTruncated: false
        )

        XCTAssertTrue(model.canSetReminder(for: reviewerPR, context: .needsReview))
        XCTAssertFalse(model.canSetReminder(for: authoredByMe, context: .needsReview))
        XCTAssertFalse(model.canSetReminder(for: authoredByMe, context: .myOpenWaitingOnReviewers))
    }

    func testDueReminderPostsNotificationAndClearsReminder() async {
        defaults.set(true, forKey: AppSettings.Keys.notificationsEnabled)
        let buckets = makeBuckets()
        let pending = StubPendingReviewsService(result: .success(.init(buckets: buckets, rateLimitRemaining: nil)))
        let notifications = StubNotificationService()
        let reminderStore = StubReminderStore()
        let reminderScheduler = StubReminderScheduler()
        let model = makeModel(
            pendingReviewsService: pending,
            notificationService: notifications,
            reminderStore: reminderStore,
            reminderScheduler: reminderScheduler
        )
        model.buckets = buckets

        let pullRequest = buckets.needsReview[0]
        model.setReminder(
            for: pullRequest,
            context: .needsReview,
            at: Date().addingTimeInterval(120)
        )
        try? await Task.sleep(nanoseconds: 80_000_000)
        guard let reminder = model.reminder(for: pullRequest) else {
            return XCTFail("Expected reminder to be set")
        }

        await reminderScheduler.triggerDue([reminder])
        try? await Task.sleep(nanoseconds: 80_000_000)

        XCTAssertNil(model.reminder(for: pullRequest))
        XCTAssertEqual(notifications.postedReminderIDs, [[reminder.id]])
        let removedAfterDelivery = await reminderStore.removedKeys
        XCTAssertTrue(removedAfterDelivery.contains(reminder.key))
    }

    func testDueReminderStaysPendingWhenNotificationsDisabled() async {
        defaults.set(false, forKey: AppSettings.Keys.notificationsEnabled)
        let buckets = makeBuckets()
        let pending = StubPendingReviewsService(result: .success(.init(buckets: buckets, rateLimitRemaining: nil)))
        let notifications = StubNotificationService()
        let reminderStore = StubReminderStore()
        let reminderScheduler = StubReminderScheduler()
        let model = makeModel(
            pendingReviewsService: pending,
            notificationService: notifications,
            reminderStore: reminderStore,
            reminderScheduler: reminderScheduler
        )
        model.buckets = buckets

        let pullRequest = buckets.needsReview[0]
        model.setReminder(
            for: pullRequest,
            context: .needsReview,
            at: Date().addingTimeInterval(120)
        )
        try? await Task.sleep(nanoseconds: 80_000_000)
        guard let reminder = model.reminder(for: pullRequest) else {
            return XCTFail("Expected reminder to be set")
        }

        await reminderScheduler.triggerDue([reminder])
        try? await Task.sleep(nanoseconds: 80_000_000)

        XCTAssertNotNil(model.reminder(for: pullRequest))
        XCTAssertTrue(notifications.postedReminderIDs.isEmpty)
        let removedWithNotificationsOff = await reminderStore.removedKeys
        XCTAssertFalse(removedWithNotificationsOff.contains(reminder.key))
    }

    func testRefreshRemovesReminderWhenPRNoLongerEligible() async {
        defaults.set(true, forKey: AppSettings.Keys.notificationsEnabled)
        let initialBuckets = makeBuckets()
        let emptyBuckets = ReviewBuckets(
            user: "alice",
            host: "github.com",
            needsReview: [],
            needsReReview: [],
            myOpenWaitingOnReviewers: [],
            myOpenBlockedOnYou: [],
            myOpenEnoughApprovals: [],
            totals: BucketTotals(awaiting: 0, reviewed: 0),
            awaitingTruncated: false,
            reviewedTruncated: false,
            myOpenTruncated: false
        )
        let pending = SequencedPendingReviewsService(results: [
            .success(.init(buckets: initialBuckets, rateLimitRemaining: nil)),
            .success(.init(buckets: emptyBuckets, rateLimitRemaining: nil))
        ])
        let reminderStore = StubReminderStore()
        let reminderScheduler = StubReminderScheduler()
        let model = makeModel(
            pendingReviewsService: pending,
            reminderStore: reminderStore,
            reminderScheduler: reminderScheduler
        )

        _ = await model.refresh(reason: "initial")
        let pullRequest = initialBuckets.needsReview[0]
        model.setReminder(
            for: pullRequest,
            context: .needsReview,
            at: Date().addingTimeInterval(120)
        )
        try? await Task.sleep(nanoseconds: 80_000_000)
        XCTAssertNotNil(model.reminder(for: pullRequest))

        _ = await model.refresh(reason: "pr-removed")
        XCTAssertNil(model.reminder(for: pullRequest))
        let removedAfterReconcile = await reminderStore.removedKeys
        XCTAssertTrue(removedAfterReconcile.contains(pullRequest.reminderKey(host: "github.com")))
    }

    func testDueReminderDoesNotPostTwiceForRepeatedDueCallbacks() async {
        defaults.set(true, forKey: AppSettings.Keys.notificationsEnabled)
        let buckets = makeBuckets()
        let pending = StubPendingReviewsService(result: .success(.init(buckets: buckets, rateLimitRemaining: nil)))
        let notifications = StubNotificationService()
        let reminderStore = StubReminderStore()
        let reminderScheduler = StubReminderScheduler()
        let model = makeModel(
            pendingReviewsService: pending,
            notificationService: notifications,
            reminderStore: reminderStore,
            reminderScheduler: reminderScheduler
        )
        model.buckets = buckets

        let pullRequest = buckets.needsReview[0]
        model.setReminder(
            for: pullRequest,
            context: .needsReview,
            at: Date().addingTimeInterval(120)
        )
        try? await Task.sleep(nanoseconds: 80_000_000)
        guard let reminder = model.reminder(for: pullRequest) else {
            return XCTFail("Expected reminder to be set")
        }

        await reminderScheduler.triggerDue([reminder])
        await reminderScheduler.triggerDue([reminder])
        try? await Task.sleep(nanoseconds: 80_000_000)

        XCTAssertEqual(notifications.postedReminderIDs.count, 1)
    }

    private func makeModel(
        pendingReviewsService: any PendingReviewsServing,
        seenStateStore: (any SeenStateStoring)? = nil,
        notificationService: (any NotificationServing)? = nil,
        reminderStore: (any ReminderStoring)? = nil,
        reminderScheduler: (any ReminderScheduling)? = nil
    ) -> AppModel {
        AppModel(
            userDefaults: defaults,
            pendingReviewsService: pendingReviewsService,
            refreshScheduler: RefreshScheduler(minimumIntervalSeconds: 0.01, maximumBackoffSeconds: 0.05),
            seenStateStore: seenStateStore ?? StubSeenStateStore(diff: SeenStateDiff(newlyAwaiting: [], newlyUpdatedSinceReview: [])),
            notificationService: notificationService ?? StubNotificationService(),
            reminderStore: reminderStore ?? StubReminderStore(),
            reminderScheduler: reminderScheduler ?? StubReminderScheduler(),
            launchAtLoginService: StubLaunchAtLoginService(),
            reachability: StubReachability(),
            sleepWakeObserver: StubSleepWakeObserver()
        )
    }

    private func makeBuckets() -> ReviewBuckets {
        ReviewBuckets(
            user: "alice",
            host: "github.com",
            needsReview: [makePullRequest(number: 10, isDraft: false)],
            needsReReview: [],
            myOpenWaitingOnReviewers: [],
            myOpenBlockedOnYou: [],
            myOpenEnoughApprovals: [],
            totals: BucketTotals(awaiting: 1, reviewed: 0),
            awaitingTruncated: false,
            reviewedTruncated: false,
            myOpenTruncated: false
        )
    }

    private func makePullRequest(number: Int, isDraft: Bool, author: String = "bob") -> PullRequest {
        PullRequest(
            number: number,
            title: "Add tests",
            url: URL(string: "https://github.com/acme/repo/pull/\(number)"),
            updatedAt: Date(timeIntervalSince1970: 1_000),
            repository: "acme/repo",
            author: author,
            isDraft: isDraft,
            latestReviewState: .awaiting,
            approvals: 1,
            updatedSinceReview: false,
            isReReview: false,
            isInMergeQueue: false,
            checksStatus: nil,
            reviewRequestedAt: Date(timeIntervalSince1970: 900),
            lastCommitDate: Date(timeIntervalSince1970: 950)
        )
    }
}

@MainActor
private final class StubPendingReviewsService: PendingReviewsServing {
    private let result: Result<PendingReviewsServiceResult, Error>
    private(set) var fetchCallCount = 0

    init(result: Result<PendingReviewsServiceResult, Error>) {
        self.result = result
    }

    func fetch(settings: AppSettings) async throws -> PendingReviewsServiceResult {
        fetchCallCount += 1
        return try result.get()
    }
}

@MainActor
private final class SequencedPendingReviewsService: PendingReviewsServing {
    private var results: [Result<PendingReviewsServiceResult, Error>]
    private(set) var fetchCallCount = 0

    init(results: [Result<PendingReviewsServiceResult, Error>]) {
        self.results = results
    }

    func fetch(settings: AppSettings) async throws -> PendingReviewsServiceResult {
        fetchCallCount += 1
        guard results.isEmpty == false else {
            throw URLError(.unknown)
        }
        let result = results.removeFirst()
        return try result.get()
    }
}

@MainActor
private final class BlockingPendingReviewsService: PendingReviewsServing {
    private let result: PendingReviewsServiceResult
    private(set) var fetchCallCount = 0
    private var started = false
    private var startedContinuation: CheckedContinuation<Void, Never>?
    private var unblockContinuation: CheckedContinuation<Void, Never>?

    init(result: PendingReviewsServiceResult) {
        self.result = result
    }

    func fetch(settings: AppSettings) async throws -> PendingReviewsServiceResult {
        fetchCallCount += 1
        started = true
        startedContinuation?.resume()
        startedContinuation = nil

        await withCheckedContinuation { continuation in
            unblockContinuation = continuation
        }
        return result
    }

    func waitUntilStarted() async {
        if started {
            return
        }
        await withCheckedContinuation { continuation in
            startedContinuation = continuation
        }
    }

    func unblock() {
        unblockContinuation?.resume()
        unblockContinuation = nil
    }
}

@MainActor
private final class StubSeenStateStore: SeenStateStoring {
    private let diff: SeenStateDiff
    private(set) var applyCount = 0

    init(diff: SeenStateDiff) {
        self.diff = diff
    }

    func apply(current buckets: ReviewBuckets) async -> SeenStateDiff {
        applyCount += 1
        return diff
    }
}

@MainActor
private final class StubNotificationService: NotificationServing {
    private(set) var requestAuthorizationCount = 0
    private(set) var postedEnabledValues: [Bool] = []
    private(set) var postedReminderEnabledValues: [Bool] = []
    private(set) var postedReminderIDs: [[String]] = []

    func requestAuthorizationIfNeeded() async {
        requestAuthorizationCount += 1
    }

    func postNotifications(from diff: SeenStateDiff, enabled: Bool) async {
        postedEnabledValues.append(enabled)
    }

    func postReminderNotifications(_ reminders: [PullRequestReminder], enabled: Bool) async {
        postedReminderEnabledValues.append(enabled)
        postedReminderIDs.append(reminders.map(\.id))
    }
}

private actor StubReminderStore: ReminderStoring {
    private var remindersByKey: [PullRequestReminderKey: PullRequestReminder]
    private(set) var removedKeys: Set<PullRequestReminderKey> = []

    init(initialReminders: [PullRequestReminder] = []) {
        remindersByKey = Dictionary(uniqueKeysWithValues: initialReminders.map { ($0.key, $0) })
    }

    func loadReminders() -> [PullRequestReminder] {
        Array(remindersByKey.values)
    }

    func upsert(_ reminder: PullRequestReminder) {
        remindersByKey[reminder.key] = reminder
    }

    func removeReminder(for key: PullRequestReminderKey) {
        remindersByKey.removeValue(forKey: key)
        removedKeys.insert(key)
    }

    func removeReminders(for keys: Set<PullRequestReminderKey>) {
        for key in keys {
            remindersByKey.removeValue(forKey: key)
        }
        removedKeys.formUnion(keys)
    }
}

private actor StubReminderScheduler: ReminderScheduling {
    private var onDue: (@Sendable ([PullRequestReminder]) async -> Void)?

    func update(
        reminders: [PullRequestReminder],
        now: Date,
        onDue: @escaping @Sendable ([PullRequestReminder]) async -> Void
    ) {
        _ = reminders
        _ = now
        self.onDue = onDue
    }

    func stop() {
        onDue = nil
    }

    func triggerDue(_ reminders: [PullRequestReminder]) async {
        guard let onDue else { return }
        await onDue(reminders)
    }
}

@MainActor
private final class StubLaunchAtLoginService: LaunchAtLoginServing {
    private(set) var setValues: [Bool] = []

    func setEnabled(_ enabled: Bool) throws {
        setValues.append(enabled)
    }
}

private final class StubReachability: ReachabilityServing {
    private(set) var startCount = 0
    private(set) var stopCount = 0

    func start(onUpdate: @escaping @MainActor (Bool) -> Void) {
        _ = onUpdate
        startCount += 1
    }

    func stop() {
        stopCount += 1
    }
}

private final class StubSleepWakeObserver: SleepWakeObserving {
    private(set) var startCount = 0
    private(set) var stopCount = 0

    func start(onWillSleep: @escaping () -> Void, onDidWake: @escaping () -> Void) {
        _ = onWillSleep
        _ = onDidWake
        startCount += 1
    }

    func stop() {
        stopCount += 1
    }
}
