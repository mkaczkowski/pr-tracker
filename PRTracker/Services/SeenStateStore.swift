import Foundation

struct SeenStateDiff: Sendable {
    let newlyAwaiting: [PullRequest]
    let newlyUpdatedSinceReview: [PullRequest]
}

protocol SeenStateStoring {
    func apply(current buckets: ReviewBuckets) async -> SeenStateDiff
}

actor SeenStateStore: SeenStateStoring {
    private struct PersistedState: Codable, Sendable {
        var awaitingKeys: Set<PRKey>
        var updatedStateByPRID: [String: Bool]
    }

    private let defaults: UserDefaults
    private let key = "seenState.v1"

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    func apply(current buckets: ReviewBuckets) -> SeenStateDiff {
        var persisted = loadPersistedState()

        let currentAwaitingKeys = Set(buckets.awaitingReview.map(Self.makeKey))
        let currentAllPRs = buckets.awaitingReview + buckets.reviewedNotApproved
        let currentByID = Dictionary(uniqueKeysWithValues: currentAllPRs.map { ($0.id, $0) })

        let newAwaiting = buckets.awaitingReview.filter { pullRequest in
            let key = Self.makeKey(from: pullRequest)
            return persisted.awaitingKeys.contains(key) == false
        }

        let newUpdated = currentAllPRs.filter { pullRequest in
            let previous = persisted.updatedStateByPRID[pullRequest.id] ?? false
            return pullRequest.updatedSinceReview && previous == false
        }

        // Keep only state for PRs currently visible in either bucket.
        let activeIDs = Set(currentByID.keys)
        persisted.updatedStateByPRID = persisted.updatedStateByPRID.filter { activeIDs.contains($0.key) }

        for pullRequest in currentAllPRs {
            persisted.updatedStateByPRID[pullRequest.id] = pullRequest.updatedSinceReview
        }

        persisted.awaitingKeys = currentAwaitingKeys
        savePersistedState(persisted)

        return SeenStateDiff(
            newlyAwaiting: newAwaiting,
            newlyUpdatedSinceReview: newUpdated
        )
    }

    private func loadPersistedState() -> PersistedState {
        guard let data = defaults.data(forKey: key) else {
            return PersistedState(awaitingKeys: [], updatedStateByPRID: [:])
        }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return (try? decoder.decode(PersistedState.self, from: data))
            ?? PersistedState(awaitingKeys: [], updatedStateByPRID: [:])
    }

    private func savePersistedState(_ state: PersistedState) {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        if let data = try? encoder.encode(state) {
            defaults.set(data, forKey: key)
        }
    }

    private static func makeKey(from pullRequest: PullRequest) -> PRKey {
        PRKey(
            repository: pullRequest.repository,
            number: pullRequest.number,
            lastCommitDate: pullRequest.lastCommitDate,
            latestReviewState: pullRequest.latestReviewState
        )
    }
}

