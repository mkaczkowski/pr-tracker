import Foundation

struct ReviewBucketsBuilder: Sendable {
    private let searchLimit = 100

    private struct AwaitingCandidate {
        let pullRequest: PullRequest
        let prioritizeForReReview: Bool
    }

    private struct ReviewedCandidate {
        let pullRequest: PullRequest
    }

    private struct MyOpenCandidate {
        let pullRequest: PullRequest
        let needsReReview: Bool
    }

    func build(
        from response: GitHubGraphQLResponse.DataRoot,
        host: String,
        requiredApprovals: Int
    ) -> ReviewBuckets {
        let user = response.viewer.login

        let awaiting = response.awaiting.nodes
            .compactMap { node in
                buildAwaitingCandidate(node: node, user: user)
            }
            .sorted(by: compareAwaiting)
            .map(\.pullRequest)

        let reviewed = response.reviewed.nodes
            .compactMap { node in
                buildReviewedCandidate(node: node, user: user)
            }
            .sorted(by: compareReviewed)
            .map(\.pullRequest)

        let myOpen = response.myOpen.nodes
            .compactMap { node in
                buildMyOpenCandidate(node: node, requiredApprovals: requiredApprovals)
            }
            .sorted(by: compareMyOpen)
            .map(\.pullRequest)

        return ReviewBuckets(
            user: user,
            host: host,
            awaitingReview: awaiting,
            reviewedNotApproved: reviewed,
            myOpenNeedingAttention: myOpen,
            totals: BucketTotals(awaiting: response.awaiting.issueCount, reviewed: response.reviewed.issueCount),
            awaitingTruncated: response.awaiting.issueCount > searchLimit,
            reviewedTruncated: response.reviewed.issueCount > searchLimit,
            myOpenTruncated: response.myOpen.issueCount > searchLimit
        )
    }

    private func buildAwaitingCandidate(node: PullRequestNode, user: String) -> AwaitingCandidate? {
        guard
            let number = node.number,
            let title = node.title,
            let repository = node.repository?.nameWithOwner
        else {
            return nil
        }

        let latestMyReview = latestReview(for: user, reviews: node.reviews.nodes)
        let lastCommitDateString = node.commits.nodes.last?.commit?.committedDate
        let lastCommitDate = DateDecoding.parse(lastCommitDateString)
        let reviewRequestedAt = latestReviewRequestDate(for: user, timelineNodes: node.timelineItems?.nodes ?? [])

        let updatedSinceReview: Bool
        if let latestMyReview, let latestReviewDate = DateDecoding.parse(latestMyReview.submittedAt), let lastCommitDate {
            updatedSinceReview = lastCommitDate > latestReviewDate
        } else {
            updatedSinceReview = false
        }

        let pullRequest = PullRequest(
            number: number,
            title: title,
            url: parseURL(node.url),
            updatedAt: DateDecoding.parse(node.updatedAt),
            repository: repository,
            author: node.author?.login ?? "ghost",
            isDraft: node.isDraft,
            latestReviewState: .awaiting,
            approvals: approvalCount(reviews: node.reviews.nodes),
            updatedSinceReview: updatedSinceReview,
            isReReview: latestMyReview != nil,
            reviewRequestedAt: reviewRequestedAt,
            lastCommitDate: lastCommitDate
        )

        return AwaitingCandidate(
            pullRequest: pullRequest,
            prioritizeForReReview: updatedSinceReview || latestMyReview != nil
        )
    }

    private func buildReviewedCandidate(node: PullRequestNode, user: String) -> ReviewedCandidate? {
        guard
            let number = node.number,
            let title = node.title,
            let repository = node.repository?.nameWithOwner
        else {
            return nil
        }

        guard let latestMyReview = latestReview(for: user, reviews: node.reviews.nodes),
              let stateText = latestMyReview.state,
              let latestState = ReviewState(rawValue: stateText),
              latestState != .approved else {
            return nil
        }

        let lastCommitDateString = node.commits.nodes.last?.commit?.committedDate
        let lastCommitDate = DateDecoding.parse(lastCommitDateString)
        let latestReviewDate = DateDecoding.parse(latestMyReview.submittedAt)
        let reviewRequestedAt = latestReviewRequestDate(for: user, timelineNodes: node.timelineItems?.nodes ?? [])

        let updatedSinceReview: Bool
        if let latestReviewDate, let lastCommitDate {
            updatedSinceReview = lastCommitDate > latestReviewDate
        } else {
            updatedSinceReview = false
        }

        let pullRequest = PullRequest(
            number: number,
            title: title,
            url: parseURL(node.url),
            updatedAt: DateDecoding.parse(node.updatedAt),
            repository: repository,
            author: node.author?.login ?? "ghost",
            isDraft: node.isDraft,
            latestReviewState: latestState,
            approvals: approvalCount(reviews: node.reviews.nodes),
            updatedSinceReview: updatedSinceReview,
            isReReview: false,
            reviewRequestedAt: reviewRequestedAt,
            lastCommitDate: lastCommitDate
        )

        return ReviewedCandidate(pullRequest: pullRequest)
    }

    /// Builds a `PullRequest` for the "my open PRs waiting on reviewers" bucket.
    ///
    /// A PR qualifies when the ball is in the reviewers' court — that is:
    ///   * The latest non-author review is *not* `CHANGES_REQUESTED` without a
    ///     follow-up push (those are blocked on the author), AND
    ///   * the PR either still needs more approvals, or new commits have landed
    ///     since the most recent non-author review (so a re-review is owed).
    private func buildMyOpenCandidate(
        node: PullRequestNode,
        requiredApprovals: Int
    ) -> MyOpenCandidate? {
        guard
            let number = node.number,
            let title = node.title,
            let repository = node.repository?.nameWithOwner
        else {
            return nil
        }

        let authorLogin = node.author?.login
        let lastCommitDate = DateDecoding.parse(node.commits.nodes.last?.commit?.committedDate)
        let latestNonAuthorReview = latestReviewExcludingAuthor(
            reviews: node.reviews.nodes,
            author: authorLogin
        )
        let latestNonAuthorDate = DateDecoding.parse(latestNonAuthorReview?.submittedAt)
        let latestNonAuthorState = latestNonAuthorReview?.state.flatMap(ReviewState.init(rawValue:))

        let pushedSinceReview: Bool = {
            guard let reviewDate = latestNonAuthorDate, let commitDate = lastCommitDate else {
                return false
            }
            return commitDate > reviewDate
        }()

        // Changes requested and the author hasn't pushed anything since →
        // the ball is in the author's court, not the reviewers'.
        if latestNonAuthorState == .changesRequested, pushedSinceReview == false {
            return nil
        }

        let approvals = approvalCount(reviews: node.reviews.nodes)
        let needsMoreApprovals = approvals < requiredApprovals
        guard needsMoreApprovals || pushedSinceReview else {
            return nil
        }

        let pullRequest = PullRequest(
            number: number,
            title: title,
            url: parseURL(node.url),
            updatedAt: DateDecoding.parse(node.updatedAt),
            repository: repository,
            author: authorLogin ?? "ghost",
            isDraft: node.isDraft,
            latestReviewState: latestNonAuthorState ?? .awaiting,
            approvals: approvals,
            updatedSinceReview: pushedSinceReview,
            isReReview: false,
            reviewRequestedAt: nil,
            lastCommitDate: lastCommitDate
        )

        return MyOpenCandidate(pullRequest: pullRequest, needsReReview: pushedSinceReview)
    }

    private func approvalCount(reviews: [PullRequestNode.ReviewConnection.ReviewNode]) -> Int {
        var latestByAuthor: [String: PullRequestNode.ReviewConnection.ReviewNode] = [:]

        for review in reviews {
            guard let author = review.author?.login else {
                continue
            }
            let existing = latestByAuthor[author]

            if let existing {
                let existingDate = existing.submittedAt ?? ""
                let candidateDate = review.submittedAt ?? ""
                if candidateDate >= existingDate {
                    latestByAuthor[author] = review
                }
            } else {
                latestByAuthor[author] = review
            }
        }

        return latestByAuthor.values.reduce(0) { partialResult, review in
            partialResult + ((review.state == ReviewState.approved.rawValue) ? 1 : 0)
        }
    }

    private func latestReview(
        for user: String,
        reviews: [PullRequestNode.ReviewConnection.ReviewNode]
    ) -> PullRequestNode.ReviewConnection.ReviewNode? {
        reviews
            .filter { $0.author?.login == user }
            .max(by: { ($0.submittedAt ?? "") < ($1.submittedAt ?? "") })
    }

    private func latestReviewExcludingAuthor(
        reviews: [PullRequestNode.ReviewConnection.ReviewNode],
        author: String?
    ) -> PullRequestNode.ReviewConnection.ReviewNode? {
        reviews
            .filter { review in
                guard let login = review.author?.login else { return false }
                return login != author
            }
            .max(by: { ($0.submittedAt ?? "") < ($1.submittedAt ?? "") })
    }

    private func latestReviewRequestDate(
        for user: String,
        timelineNodes: [PullRequestNode.TimelineConnection.TimelineNode]
    ) -> Date? {
        let latestEvent = timelineNodes
            .filter { $0.requestedReviewer?.login == user }
            .max(by: { ($0.createdAt ?? "") < ($1.createdAt ?? "") })

        return DateDecoding.parse(latestEvent?.createdAt)
    }

    private func parseURL(_ value: String?) -> URL? {
        guard let value else { return nil }
        return URL(string: value)
    }

    private func compareAwaiting(_ lhs: AwaitingCandidate, _ rhs: AwaitingCandidate) -> Bool {
        if lhs.prioritizeForReReview != rhs.prioritizeForReReview {
            return lhs.prioritizeForReReview
        }
        if let decision = preferAscending(lhs.pullRequest.reviewRequestedAt, rhs.pullRequest.reviewRequestedAt) {
            return decision
        }
        if let decision = preferDescending(lhs.pullRequest.lastCommitDate, rhs.pullRequest.lastCommitDate) {
            return decision
        }
        if let decision = preferDescending(lhs.pullRequest.updatedAt, rhs.pullRequest.updatedAt) {
            return decision
        }
        return fallback(lhs.pullRequest, rhs.pullRequest)
    }

    private func compareReviewed(_ lhs: ReviewedCandidate, _ rhs: ReviewedCandidate) -> Bool {
        if lhs.pullRequest.updatedSinceReview != rhs.pullRequest.updatedSinceReview {
            return lhs.pullRequest.updatedSinceReview
        }
        if let decision = preferDescending(lhs.pullRequest.lastCommitDate, rhs.pullRequest.lastCommitDate) {
            return decision
        }
        if let decision = preferAscending(lhs.pullRequest.reviewRequestedAt, rhs.pullRequest.reviewRequestedAt) {
            return decision
        }
        if let decision = preferDescending(lhs.pullRequest.updatedAt, rhs.pullRequest.updatedAt) {
            return decision
        }
        return fallback(lhs.pullRequest, rhs.pullRequest)
    }

    private func compareMyOpen(_ lhs: MyOpenCandidate, _ rhs: MyOpenCandidate) -> Bool {
        if lhs.needsReReview != rhs.needsReReview {
            return lhs.needsReReview
        }
        if let decision = preferAscending(lhs.pullRequest.updatedAt, rhs.pullRequest.updatedAt) {
            return decision
        }
        if lhs.pullRequest.approvals != rhs.pullRequest.approvals {
            return lhs.pullRequest.approvals < rhs.pullRequest.approvals
        }
        if let decision = preferAscending(lhs.pullRequest.lastCommitDate, rhs.pullRequest.lastCommitDate) {
            return decision
        }
        return fallback(lhs.pullRequest, rhs.pullRequest)
    }

    private func preferDescending(_ lhs: Date?, _ rhs: Date?) -> Bool? {
        // A concrete timestamp is more actionable than a missing one, so nil
        // always sorts last regardless of ascending vs descending direction.
        switch (lhs, rhs) {
        case let (left?, right?) where left != right:
            return left > right
        case (.some, .none):
            return true
        case (.none, .some):
            return false
        default:
            return nil
        }
    }

    private func preferAscending(_ lhs: Date?, _ rhs: Date?) -> Bool? {
        // A concrete timestamp is more actionable than a missing one, so nil
        // always sorts last regardless of ascending vs descending direction.
        switch (lhs, rhs) {
        case let (left?, right?) where left != right:
            return left < right
        case (.some, .none):
            return true
        case (.none, .some):
            return false
        default:
            return nil
        }
    }

    private func fallback(_ lhs: PullRequest, _ rhs: PullRequest) -> Bool {
        lhs.number > rhs.number
    }
}

