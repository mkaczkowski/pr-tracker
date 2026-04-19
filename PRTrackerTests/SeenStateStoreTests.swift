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
        let buckets = makeBuckets(awaiting: [awaiting], reviewed: [reviewed])

        let diff = await store.apply(current: buckets)
        XCTAssertEqual(diff.newlyAwaiting.map(\.number), [10])
        XCTAssertEqual(diff.newlyUpdatedSinceReview.map(\.number), [20])
    }

    func testSecondApplyWithSameDataProducesNoDiff() async {
        let store = SeenStateStore(defaults: defaults)
        let pr = makePullRequest(number: 10, updatedSinceReview: false, state: .awaiting)
        let buckets = makeBuckets(awaiting: [pr], reviewed: [])

        _ = await store.apply(current: buckets)
        let second = await store.apply(current: buckets)

        XCTAssertTrue(second.newlyAwaiting.isEmpty)
        XCTAssertTrue(second.newlyUpdatedSinceReview.isEmpty)
    }

    func testUpdatedSinceReviewFlipTriggersDiff() async {
        let store = SeenStateStore(defaults: defaults)
        let initial = makePullRequest(number: 30, updatedSinceReview: false, state: .commented)
        let updated = makePullRequest(number: 30, updatedSinceReview: true, state: .commented)

        _ = await store.apply(current: makeBuckets(awaiting: [], reviewed: [initial]))
        let diff = await store.apply(current: makeBuckets(awaiting: [], reviewed: [updated]))

        XCTAssertEqual(diff.newlyUpdatedSinceReview.map(\.number), [30])
    }

    func testReappearingPRAfterPruneIsDetectedAgain() async {
        let store = SeenStateStore(defaults: defaults)
        let pr = makePullRequest(number: 40, updatedSinceReview: true, state: .commented)

        _ = await store.apply(current: makeBuckets(awaiting: [], reviewed: [pr]))
        _ = await store.apply(current: makeBuckets(awaiting: [], reviewed: []))
        let diff = await store.apply(current: makeBuckets(awaiting: [], reviewed: [pr]))

        XCTAssertEqual(diff.newlyUpdatedSinceReview.map(\.number), [40])
    }

    private func makeBuckets(awaiting: [PullRequest], reviewed: [PullRequest]) -> ReviewBuckets {
        ReviewBuckets(
            user: "alice",
            host: "github.com",
            awaitingReview: awaiting,
            reviewedNotApproved: reviewed,
            myOpenNeedingAttention: [],
            totals: BucketTotals(awaiting: awaiting.count, reviewed: reviewed.count),
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
            reviewRequestedAt: Date(timeIntervalSince1970: 900),
            lastCommitDate: Date(timeIntervalSince1970: 950)
        )
    }
}
