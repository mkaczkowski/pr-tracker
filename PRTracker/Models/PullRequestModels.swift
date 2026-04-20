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
    case needsReview
    case needsReReview
    case myOpenWaitingOnReviewers
    case myOpenBlockedOnYou
    case myOpenEnoughApprovals
}

enum ChecksStatus: String, Codable, Hashable, Sendable {
    case passing
    case pending
    case failing
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
    let isInMergeQueue: Bool
    let checksStatus: ChecksStatus?
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
        case .needsReview:
            return reviewerNeedsReviewDisplayState()
        case .needsReReview:
            return .stale
        case .myOpenWaitingOnReviewers:
            return authorWaitingDisplayState()
        case .myOpenBlockedOnYou:
            return .changesRequested
        case .myOpenEnoughApprovals:
            return .approved
        }
    }

    func approvalBadgeShowsComplete(
        requiredApprovals: Int,
        context: PullRequestListContext
    ) -> Bool {
        guard approvals >= requiredApprovals else { return false }

        switch context {
        case .needsReview, .needsReReview:
            return true
        case .myOpenWaitingOnReviewers, .myOpenBlockedOnYou:
            return false
        case .myOpenEnoughApprovals:
            return true
        }
    }

    private func reviewerNeedsReviewDisplayState() -> DisplayState {
        isReReview ? .stale : .awaiting
    }

    private func authorWaitingDisplayState() -> DisplayState {
        if updatedSinceReview {
            return .stale
        }
        if latestReviewState == .pending {
            return .pending
        }
        return .waiting
    }

    func isAuthored(by viewerLogin: String) -> Bool {
        let normalizedViewer = viewerLogin.trimmingCharacters(in: .whitespacesAndNewlines)
        guard normalizedViewer.isEmpty == false else { return false }
        return author.caseInsensitiveCompare(normalizedViewer) == .orderedSame
    }

    func canConfigureReminder(context: PullRequestListContext, viewerLogin: String) -> Bool {
        let normalizedViewer = viewerLogin.trimmingCharacters(in: .whitespacesAndNewlines)
        guard normalizedViewer.isEmpty == false else { return false }
        guard context.isReviewerContext else { return false }
        return isAuthored(by: normalizedViewer) == false
    }

    func reminderKey(host: String) -> PullRequestReminderKey {
        PullRequestReminderKey(
            host: AppSettings.normalizedHost(host),
            repository: repository,
            number: number
        )
    }
}

struct BucketTotals: Codable, Hashable, Sendable {
    let awaiting: Int
    let reviewed: Int
}

struct ReviewBuckets: Codable, Hashable, Sendable {
    let user: String
    let host: String
    let needsReview: [PullRequest]
    let needsReReview: [PullRequest]
    let myOpenWaitingOnReviewers: [PullRequest]
    let myOpenBlockedOnYou: [PullRequest]
    let myOpenEnoughApprovals: [PullRequest]
    let totals: BucketTotals
    let awaitingTruncated: Bool
    let reviewedTruncated: Bool
    let myOpenTruncated: Bool

    static let empty = ReviewBuckets(
        user: "",
        host: "",
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

    func filtered(includeDrafts: Bool) -> ReviewBuckets {
        guard includeDrafts == false else {
            return self
        }

        return ReviewBuckets(
            user: user,
            host: host,
            needsReview: needsReview.filter { $0.isDraft == false },
            needsReReview: needsReReview.filter { $0.isDraft == false },
            myOpenWaitingOnReviewers: myOpenWaitingOnReviewers.filter { $0.isDraft == false },
            myOpenBlockedOnYou: myOpenBlockedOnYou.filter { $0.isDraft == false },
            myOpenEnoughApprovals: myOpenEnoughApprovals.filter { $0.isDraft == false },
            totals: totals,
            awaitingTruncated: awaitingTruncated,
            reviewedTruncated: reviewedTruncated,
            myOpenTruncated: myOpenTruncated
        )
    }
}

private extension PullRequestListContext {
    var isReviewerContext: Bool {
        switch self {
        case .needsReview, .needsReReview:
            return true
        case .myOpenWaitingOnReviewers, .myOpenBlockedOnYou, .myOpenEnoughApprovals:
            return false
        }
    }
}

struct PRKey: Codable, Hashable, Sendable {
    let repository: String
    let number: Int
    let lastCommitDate: Date?
    let latestReviewState: ReviewState
}

struct PullRequestReminderKey: Codable, Hashable, Sendable {
    let host: String
    let repository: String
    let number: Int

    var id: String {
        "\(host)#\(repository)#\(number)"
    }

    func matches(host: String) -> Bool {
        self.host.caseInsensitiveCompare(AppSettings.normalizedHost(host)) == .orderedSame
    }
}

struct PullRequestReminder: Codable, Hashable, Identifiable, Sendable {
    let key: PullRequestReminderKey
    let title: String
    let url: URL?
    let author: String
    let scheduledAt: Date
    let createdAt: Date

    var id: String {
        key.id
    }

    var repository: String {
        key.repository
    }

    var number: Int {
        key.number
    }
}

