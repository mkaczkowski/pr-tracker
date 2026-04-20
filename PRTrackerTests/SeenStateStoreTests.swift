import Foundation
import XCTest
@testable import PRTracker

final class SeenStateStoreTests: XCTestCase {
    private var defaults: UserDefaults!
    private var suiteName: String!

    override func setUp() {
        super.setUp()
        suiteName = "SeenStateStoreTests.\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suiteName)
    }

    override func tearDown() {
        defaults.removePersistentDomain(forName: suiteName)
        defaults = nil
        suiteName = nil
        super.tearDown()
    }

    func testFirstApplyDetectsNewAwaitingAndUpdatedSinceReview() async {
        let store = SeenStateStore(defaults: defaults)

        let awaiting = makePullRequest(number: 10, updatedSinceReview: false, state: .awaiting)
        let reviewed = makePullRequest(number: 20, updatedSinceReview: true, state: .commented)
        let buckets = makeBuckets(needsReview: [awaiting], needsReReview: [reviewed])

        let diff = await store.apply(current: buckets)
        XCTAssertEqual(diff.newlyAwaiting.map(\.number), [10])
        XCTAssertEqual(diff.newlyUpdatedSinceReview.map(\.number), [20])
    }

    func testSecondApplyWithSameDataProducesNoDiff() async {
        let store = SeenStateStore(defaults: defaults)
        let pr = makePullRequest(number: 10, updatedSinceReview: false, state: .awaiting)
        let buckets = makeBuckets(needsReview: [pr], needsReReview: [])

        _ = await store.apply(current: buckets)
        let second = await store.apply(current: buckets)

        XCTAssertTrue(second.newlyAwaiting.isEmpty)
        XCTAssertTrue(second.newlyUpdatedSinceReview.isEmpty)
    }

    func testUpdatedSinceReviewFlipTriggersDiff() async {
        let store = SeenStateStore(defaults: defaults)
        let initial = makePullRequest(number: 30, updatedSinceReview: false, state: .commented)
        let updated = makePullRequest(number: 30, updatedSinceReview: true, state: .commented)

        _ = await store.apply(current: makeBuckets(needsReview: [], needsReReview: [initial]))
        let diff = await store.apply(current: makeBuckets(needsReview: [], needsReReview: [updated]))

        XCTAssertEqual(diff.newlyUpdatedSinceReview.map(\.number), [30])
    }

    func testReappearingPRAfterPruneIsDetectedAgain() async {
        let store = SeenStateStore(defaults: defaults)
        let pr = makePullRequest(number: 40, updatedSinceReview: true, state: .commented)

        _ = await store.apply(current: makeBuckets(needsReview: [], needsReReview: [pr]))
        _ = await store.apply(current: makeBuckets(needsReview: [], needsReReview: []))
        let diff = await store.apply(current: makeBuckets(needsReview: [], needsReReview: [pr]))

        XCTAssertEqual(diff.newlyUpdatedSinceReview.map(\.number), [40])
    }

    private func makeBuckets(needsReview: [PullRequest], needsReReview: [PullRequest]) -> ReviewBuckets {
        ReviewBuckets(
            user: "alice",
            host: "github.com",
            needsReview: needsReview,
            needsReReview: needsReReview,
            myOpenWaitingOnReviewers: [],
            myOpenBlockedOnYou: [],
            myOpenEnoughApprovals: [],
            totals: BucketTotals(awaiting: needsReview.count, reviewed: needsReReview.count),
            awaitingTruncated: false,
            reviewedTruncated: false,
            myOpenTruncated: false
        )
    }

    private func makePullRequest(number: Int, updatedSinceReview: Bool, state: ReviewState) -> PullRequest {
        PullRequest(
            number: number,
            title: "PR \(number)",
            url: URL(string: "https://github.com/acme/repo/pull/\(number)"),
            updatedAt: Date(timeIntervalSince1970: 1_000),
            repository: "acme/repo",
            author: "dev",
            isDraft: false,
            latestReviewState: state,
            approvals: 0,
            updatedSinceReview: updatedSinceReview,
            isReReview: false,
            isInMergeQueue: false,
            reviewRequestedAt: Date(timeIntervalSince1970: 900),
            lastCommitDate: Date(timeIntervalSince1970: 950)
        )
    }
}
