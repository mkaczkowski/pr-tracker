import Foundation

enum ReviewState: String, Codable, CaseIterable, Sendable {
    case awaiting = "AWAITING"
    case pending = "PENDING"
    case commented = "COMMENTED"
    case changesRequested = "CHANGES_REQUESTED"
    case dismissed = "DISMISSED"
    case approved = "APPROVED"
}

enum DisplayState: String, Codable, Sendable {
    case awaiting
    case waiting
    case pending
    case commented
    case changesRequested
    case dismissed
    case approved
    case stale

    init(reviewState: ReviewState, updatedSinceReview: Bool) {
        if reviewState == .dismissed && updatedSinceReview {
            self = .stale
            return
        }

        switch reviewState {
        case .awaiting:
            self = .awaiting
        case .pending:
            self = .pending
        case .commented:
            self = .commented
        case .changesRequested:
            self = .changesRequested
        case .dismissed:
            self = .dismissed
        case .approved:
            self = .approved
        }
    }

    var label: String {
        switch self {
        case .awaiting: return "awaiting"
        case .waiting: return "waiting"
        case .pending: return "in review"
        case .commented: return "commented"
        case .changesRequested: return "changes"
        case .dismissed: return "dismissed"
        case .approved: return "approved"
        case .stale: return "re-review"
        }
    }
}

enum PullRequestListContext: Equatable, Sendable {
    case awaitingReview
    case reviewedNotApproved
    case myOpenNeedingAttention
}

struct PullRequest: Codable, Hashable, Identifiable, Sendable {
    let number: Int
    let title: String
    let url: URL?
    let updatedAt: Date?
    let repository: String
    let author: String
    let isDraft: Bool
    let latestReviewState: ReviewState
    let approvals: Int
    let updatedSinceReview: Bool
    let isReReview: Bool
    let reviewRequestedAt: Date?
    let lastCommitDate: Date?

    var id: String {
        "\(repository)#\(number)"
    }

    func displayState(
        requiredApprovals: Int,
        context: PullRequestListContext
    ) -> DisplayState {
        switch context {
        case .myOpenNeedingAttention:
            return authorDisplayState()
        case .awaitingReview, .reviewedNotApproved:
            return reviewerDisplayState(requiredApprovals: requiredApprovals)
        }
    }

    func approvalBadgeShowsComplete(
        requiredApprovals: Int,
        context: PullRequestListContext
    ) -> Bool {
        approvals >= requiredApprovals && !(context == .myOpenNeedingAttention && updatedSinceReview)
    }

    private func reviewerDisplayState(requiredApprovals: Int) -> DisplayState {
        if latestReviewState == .approved, approvals < requiredApprovals {
            return .awaiting
        }

        return DisplayState(reviewState: latestReviewState, updatedSinceReview: updatedSinceReview)
    }

    private func authorDisplayState() -> DisplayState {
        if updatedSinceReview {
            return .stale
        }
        if latestReviewState == .pending {
            return .pending
        }
        return .waiting
    }
}

struct BucketTotals: Codable, Hashable, Sendable {
    let awaiting: Int
    let reviewed: Int
}

struct ReviewBuckets: Codable, Hashable, Sendable {
    let user: String
    let host: String
    let awaitingReview: [PullRequest]
    let reviewedNotApproved: [PullRequest]
    let myOpenNeedingAttention: [PullRequest]
    let totals: BucketTotals
    let awaitingTruncated: Bool
    let reviewedTruncated: Bool
    let myOpenTruncated: Bool

    static let empty = ReviewBuckets(
        user: "",
        host: "",
        awaitingReview: [],
        reviewedNotApproved: [],
        myOpenNeedingAttention: [],
        totals: BucketTotals(awaiting: 0, reviewed: 0),
        awaitingTruncated: false,
        reviewedTruncated: false,
        myOpenTruncated: false
    )

    var hasUpdatedSinceReview: Bool {
        (awaitingReview + reviewedNotApproved).contains(where: \.updatedSinceReview)
    }

    func filtered(includeDrafts: Bool) -> ReviewBuckets {
        guard includeDrafts == false else {
            return self
        }

        return ReviewBuckets(
            user: user,
            host: host,
            awaitingReview: awaitingReview.filter { $0.isDraft == false },
            reviewedNotApproved: reviewedNotApproved.filter { $0.isDraft == false },
            myOpenNeedingAttention: myOpenNeedingAttention.filter { $0.isDraft == false },
            totals: totals,
            awaitingTruncated: awaitingTruncated,
            reviewedTruncated: reviewedTruncated,
            myOpenTruncated: myOpenTruncated
        )
    }
}

struct PRKey: Codable, Hashable, Sendable {
    let repository: String
    let number: Int
    let lastCommitDate: Date?
    let latestReviewState: ReviewState
}

