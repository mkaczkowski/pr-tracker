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

    private enum MyOpenBucket: Sendable {
        case waitingOnReviewers
        case blockedOnYou
        case waitingToBeMerged
        case onMergeQueue
    }

    private struct MyOpenCandidate {
        let pullRequest: PullRequest
        let bucket: MyOpenBucket
        let needsReReview: Bool
    }

    func build(
        from response: GitHubGraphQLResponse.DataRoot,
        host: String,
        requiredApprovals: Int
    ) -> ReviewBuckets {
        let user = response.viewer.login

        let needsReview = response.awaiting.nodes
            .compactMap { node in
                buildAwaitingCandidate(node: node, user: user)
            }
            .sorted(by: compareAwaiting)
            .map(\.pullRequest)

        let needsReReview = response.reviewed.nodes
            .compactMap { node in
                buildReviewedCandidate(node: node, user: user)
            }
            .sorted(by: compareReviewed)
            .map(\.pullRequest)

        let myOpenCandidates = response.myOpen.nodes
            .compactMap { node in
                buildMyOpenCandidate(node: node, requiredApprovals: requiredApprovals)
            }
        let myOpenWaitingOnReviewers = myOpenCandidates
            .filter { $0.bucket == .waitingOnReviewers }
            .sorted(by: compareMyOpenWaitingOnReviewers)
            .map(\.pullRequest)
        let myOpenBlockedOnYou = myOpenCandidates
            .filter { $0.bucket == .blockedOnYou }
            .sorted(by: compareMyOpenBlockedOnYou)
            .map(\.pullRequest)
        let myOpenWaitingToBeMerged = myOpenCandidates
            .filter { $0.bucket == .waitingToBeMerged }
            .sorted(by: compareMyOpenEnoughApprovals)
            .map(\.pullRequest)
        let myOpenOnMergeQueue = myOpenCandidates
            .filter { $0.bucket == .onMergeQueue }
            .sorted(by: compareMyOpenEnoughApprovals)
            .map(\.pullRequest)

        return ReviewBuckets(
            user: user,
            host: host,
            needsReview: needsReview,
            needsReReview: needsReReview,
            myOpenWaitingOnReviewers: myOpenWaitingOnReviewers,
            myOpenBlockedOnYou: myOpenBlockedOnYou,
            myOpenWaitingToBeMerged: myOpenWaitingToBeMerged,
            myOpenOnMergeQueue: myOpenOnMergeQueue,
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
        let isInMergeQueue = hasMergeQAssignee(node: node)
        let checksStatus = buildChecksStatus(node: node)

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
            isInMergeQueue: isInMergeQueue,
            checksStatus: checksStatus,
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

        let author = node.author?.login ?? "ghost"
        guard author.caseInsensitiveCompare(user) != .orderedSame else {
            return nil
        }

        guard let latestMyReview = latestReview(for: user, reviews: node.reviews.nodes),
              let stateText = latestMyReview.state,
              let latestState = ReviewState(rawValue: stateText) else {
            return nil
        }

        let lastCommitDateString = node.commits.nodes.last?.commit?.committedDate
        let lastCommitDate = DateDecoding.parse(lastCommitDateString)
        let latestReviewDate = DateDecoding.parse(latestMyReview.submittedAt)
        let reviewRequestedAt = latestReviewRequestDate(for: user, timelineNodes: node.timelineItems?.nodes ?? [])
        let isInMergeQueue = hasMergeQAssignee(node: node)
        let checksStatus = buildChecksStatus(node: node)

        let updatedSinceReview: Bool
        if let latestReviewDate, let lastCommitDate {
            updatedSinceReview = lastCommitDate > latestReviewDate
        } else {
            updatedSinceReview = false
        }

        guard updatedSinceReview, latestState != .dismissed else {
            return nil
        }

        guard shouldSurfaceForReReview(
            latestState: latestState,
            user: user,
            node: node
        ) else {
            return nil
        }

        let pullRequest = PullRequest(
            number: number,
            title: title,
            url: parseURL(node.url),
            updatedAt: DateDecoding.parse(node.updatedAt),
            repository: repository,
            author: author,
            isDraft: node.isDraft,
            latestReviewState: latestState,
            approvals: approvalCount(reviews: node.reviews.nodes),
            updatedSinceReview: updatedSinceReview,
            isReReview: true,
            isInMergeQueue: isInMergeQueue,
            checksStatus: checksStatus,
            reviewRequestedAt: reviewRequestedAt,
            lastCommitDate: lastCommitDate
        )

        return ReviewedCandidate(pullRequest: pullRequest)
    }

    /// Builds a `PullRequest` for one of the authored-PR action buckets.
    ///
    /// The author-facing buckets answer three questions:
    ///   * Is the PR blocked on the author to address requested changes?
    ///   * Is it still waiting on reviewers to look or re-look?
    ///   * Has it already collected enough approvals?
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
        let isInMergeQueue = hasMergeQAssignee(node: node)
        let checksStatus = buildChecksStatus(node: node)
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

        let approvals = approvalCount(reviews: node.reviews.nodes)
        let needsMoreApprovals = approvals < requiredApprovals
        let isReadyForMerge = approvals >= requiredApprovals
            && pushedSinceReview == false
            && latestNonAuthorState != .pending

        let bucket: MyOpenBucket
        if isInMergeQueue && approvals >= requiredApprovals {
            bucket = .onMergeQueue
        } else if latestNonAuthorState == .changesRequested, pushedSinceReview == false {
            bucket = .blockedOnYou
        } else if isReadyForMerge {
            bucket = isInMergeQueue ? .onMergeQueue : .waitingToBeMerged
        } else if needsMoreApprovals || pushedSinceReview || latestNonAuthorState == .pending || latestNonAuthorReview == nil {
            bucket = .waitingOnReviewers
        } else {
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
            isInMergeQueue: isInMergeQueue,
            checksStatus: checksStatus,
            reviewRequestedAt: nil,
            lastCommitDate: lastCommitDate
        )

        return MyOpenCandidate(
            pullRequest: pullRequest,
            bucket: bucket,
            needsReReview: pushedSinceReview
        )
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

    private func shouldSurfaceForReReview(
        latestState: ReviewState,
        user: String,
        node: PullRequestNode
    ) -> Bool {
        // If the viewer's latest submitted review is an approval, treat the PR
        // as no longer awaiting reviewer action from them.
        if latestState == .approved {
            return false
        }

        if hasOutstandingReviewRequests(forSomeoneOtherThan: user, node: node) {
            return false
        }

        // When someone else's changes request is currently blocking the PR,
        // a stale approval from the viewer is usually informational, not
        // actionable for the viewer.
        if latestState == .approved, node.reviewDecision == ReviewState.changesRequested.rawValue {
            return false
        }

        return true
    }

    private func hasOutstandingReviewRequests(
        forSomeoneOtherThan user: String,
        node: PullRequestNode
    ) -> Bool {
        node.reviewRequests.nodes.contains { reviewRequest in
            guard let login = reviewRequest.requestedReviewer?.login else {
                return false
            }
            return login.caseInsensitiveCompare(user) != .orderedSame
        }
    }

    private func hasMergeQAssignee(node: PullRequestNode) -> Bool {
        node.assignees.nodes.contains { assignee in
            let login = assignee.login?
                .trimmingCharacters(in: .whitespacesAndNewlines)
                .lowercased()
            let name = assignee.name?
                .trimmingCharacters(in: .whitespacesAndNewlines)
                .lowercased()

            if login == "mergeq" || login == "mergeq[bot]" {
                return true
            }

            guard let name else { return false }
            return name == "mergeq - mergeq bot"
                || name == "mergeq bot"
                || name.contains("mergeq")
        }
    }

    private func buildChecksStatus(node: PullRequestNode) -> ChecksStatus? {
        checksStatus(from: node.commits.nodes.last?.commit?.statusCheckRollup?.state)
    }

    private func checksStatus(from rawState: String?) -> ChecksStatus? {
        guard let rawState else { return nil }

        switch rawState {
        case "SUCCESS":
            return .passing
        case "ERROR", "FAILURE", "STARTUP_FAILURE", "TIMED_OUT", "ACTION_REQUIRED", "CANCELLED":
            return .failing
        case "EXPECTED", "PENDING", "IN_PROGRESS", "QUEUED", "REQUESTED", "WAITING", "STALE", "NEUTRAL", "SKIPPED":
            return .pending
        default:
            return nil
        }
    }

    private func parseURL(_ value: String?) -> URL? {
        guard let value else { return nil }
        return URL(string: value)
    }

    private func compareAwaiting(_ lhs: AwaitingCandidate, _ rhs: AwaitingCandidate) -> Bool {
        if lhs.prioritizeForReReview != rhs.prioritizeForReReview {
            return lhs.prioritizeForReReview
        }
        if let decision = preferDescending(lhs.pullRequest.reviewRequestedAt, rhs.pullRequest.reviewRequestedAt) {
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
        if let decision = preferDescending(lhs.pullRequest.lastCommitDate, rhs.pullRequest.lastCommitDate) {
            return decision
        }
        if let decision = preferDescending(lhs.pullRequest.reviewRequestedAt, rhs.pullRequest.reviewRequestedAt) {
            return decision
        }
        if let decision = preferDescending(lhs.pullRequest.updatedAt, rhs.pullRequest.updatedAt) {
            return decision
        }
        return fallback(lhs.pullRequest, rhs.pullRequest)
    }

    private func compareMyOpenWaitingOnReviewers(_ lhs: MyOpenCandidate, _ rhs: MyOpenCandidate) -> Bool {
        if lhs.needsReReview != rhs.needsReReview {
            return lhs.needsReReview
        }
        if let decision = preferDescending(lhs.pullRequest.updatedAt, rhs.pullRequest.updatedAt) {
            return decision
        }
        if lhs.pullRequest.approvals != rhs.pullRequest.approvals {
            return lhs.pullRequest.approvals < rhs.pullRequest.approvals
        }
        if let decision = preferDescending(lhs.pullRequest.lastCommitDate, rhs.pullRequest.lastCommitDate) {
            return decision
        }
        return fallback(lhs.pullRequest, rhs.pullRequest)
    }

    private func compareMyOpenBlockedOnYou(_ lhs: MyOpenCandidate, _ rhs: MyOpenCandidate) -> Bool {
        if let decision = preferDescending(lhs.pullRequest.updatedAt, rhs.pullRequest.updatedAt) {
            return decision
        }
        if let decision = preferDescending(lhs.pullRequest.lastCommitDate, rhs.pullRequest.lastCommitDate) {
            return decision
        }
        return fallback(lhs.pullRequest, rhs.pullRequest)
    }

    private func compareMyOpenEnoughApprovals(_ lhs: MyOpenCandidate, _ rhs: MyOpenCandidate) -> Bool {
        if let decision = preferDescending(lhs.pullRequest.updatedAt, rhs.pullRequest.updatedAt) {
            return decision
        }
        if lhs.pullRequest.approvals != rhs.pullRequest.approvals {
            return lhs.pullRequest.approvals > rhs.pullRequest.approvals
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

