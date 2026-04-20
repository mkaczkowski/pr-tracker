import Foundation

struct GraphQLErrorResponse: Decodable, Sendable {
    let message: String
}

struct GitHubGraphQLResponse: Decodable, Sendable {
    struct DataRoot: Decodable, Sendable {
        struct Viewer: Decodable, Sendable {
            let login: String
        }

        struct SearchResult: Decodable, Sendable {
            let issueCount: Int
            let nodes: [PullRequestNode]
        }

        let viewer: Viewer
        let awaiting: SearchResult
        let reviewed: SearchResult
        let myOpen: SearchResult
    }

    let data: DataRoot?
    let errors: [GraphQLErrorResponse]?
}

struct PullRequestNode: Decodable, Sendable {
    struct ReviewRequestConnection: Decodable, Sendable {
        struct ReviewRequestNode: Decodable, Sendable {
            struct RequestedReviewer: Decodable, Sendable {
                let login: String?
            }

            let requestedReviewer: RequestedReviewer?
        }

        let nodes: [ReviewRequestNode]

        init(nodes: [ReviewRequestNode]) {
            self.nodes = nodes
        }

        init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            nodes = try container.decodeIfPresent([ReviewRequestNode].self, forKey: .nodes) ?? []
        }

        private enum CodingKeys: String, CodingKey { case nodes }
    }

    struct Author: Decodable, Sendable {
        let login: String?
    }

    struct Repository: Decodable, Sendable {
        let nameWithOwner: String
    }

    struct ReviewConnection: Decodable, Sendable {
        struct ReviewNode: Decodable, Sendable {
            struct ReviewAuthor: Decodable, Sendable {
                let login: String?
            }

            let state: String?
            let submittedAt: String?
            let author: ReviewAuthor?
        }

        let nodes: [ReviewNode]

        init(nodes: [ReviewNode]) {
            self.nodes = nodes
        }

        init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            nodes = try container.decodeIfPresent([ReviewNode].self, forKey: .nodes) ?? []
        }

        private enum CodingKeys: String, CodingKey { case nodes }
    }

    struct CommitConnection: Decodable, Sendable {
        struct CommitNode: Decodable, Sendable {
            struct CommitWrapper: Decodable, Sendable {
                let committedDate: String?
            }

            let commit: CommitWrapper?
        }

        let nodes: [CommitNode]

        init(nodes: [CommitNode]) {
            self.nodes = nodes
        }

        init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            nodes = try container.decodeIfPresent([CommitNode].self, forKey: .nodes) ?? []
        }

        private enum CodingKeys: String, CodingKey { case nodes }
    }

    struct TimelineConnection: Decodable, Sendable {
        struct TimelineNode: Decodable, Sendable {
            struct RequestedReviewer: Decodable, Sendable {
                let login: String?
            }

            let createdAt: String?
            let requestedReviewer: RequestedReviewer?
        }

        let nodes: [TimelineNode]
    }

    struct AssigneeConnection: Decodable, Sendable {
        struct AssigneeNode: Decodable, Sendable {
            let login: String?
            let name: String?
        }

        let nodes: [AssigneeNode]

        init(nodes: [AssigneeNode]) {
            self.nodes = nodes
        }

        init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            nodes = try container.decodeIfPresent([AssigneeNode].self, forKey: .nodes) ?? []
        }

        private enum CodingKeys: String, CodingKey { case nodes }
    }

    let number: Int?
    let title: String?
    let url: String?
    let updatedAt: String?
    let isDraft: Bool
    let reviewDecision: String?
    let author: Author?
    let repository: Repository?
    let reviewRequests: ReviewRequestConnection
    let reviews: ReviewConnection
    let commits: CommitConnection
    let assignees: AssigneeConnection
    /// Optional because the `myOpen` GraphQL search does not fetch this connection
    /// (review-request events are only meaningful for PRs not authored by the viewer).
    let timelineItems: TimelineConnection?

    init(
        number: Int?,
        title: String?,
        url: String?,
        updatedAt: String?,
        isDraft: Bool,
        reviewDecision: String?,
        author: Author?,
        repository: Repository?,
        reviewRequests: ReviewRequestConnection,
        reviews: ReviewConnection,
        commits: CommitConnection,
        assignees: AssigneeConnection,
        timelineItems: TimelineConnection?
    ) {
        self.number = number
        self.title = title
        self.url = url
        self.updatedAt = updatedAt
        self.isDraft = isDraft
        self.reviewDecision = reviewDecision
        self.author = author
        self.repository = repository
        self.reviewRequests = reviewRequests
        self.reviews = reviews
        self.commits = commits
        self.assignees = assignees
        self.timelineItems = timelineItems
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        number = try container.decodeIfPresent(Int.self, forKey: .number)
        title = try container.decodeIfPresent(String.self, forKey: .title)
        url = try container.decodeIfPresent(String.self, forKey: .url)
        updatedAt = try container.decodeIfPresent(String.self, forKey: .updatedAt)
        isDraft = try container.decodeIfPresent(Bool.self, forKey: .isDraft) ?? false
        reviewDecision = try container.decodeIfPresent(String.self, forKey: .reviewDecision)
        author = try container.decodeIfPresent(Author.self, forKey: .author)
        repository = try container.decodeIfPresent(Repository.self, forKey: .repository)
        reviewRequests = try container.decodeIfPresent(ReviewRequestConnection.self, forKey: .reviewRequests)
            ?? ReviewRequestConnection(nodes: [])
        // Treat a missing or null connection as an empty one so a single
        // inaccessible PR in the search results doesn't fail the whole decode.
        reviews = try container.decodeIfPresent(ReviewConnection.self, forKey: .reviews) ?? ReviewConnection(nodes: [])
        commits = try container.decodeIfPresent(CommitConnection.self, forKey: .commits) ?? CommitConnection(nodes: [])
        assignees = try container.decodeIfPresent(AssigneeConnection.self, forKey: .assignees) ?? AssigneeConnection(nodes: [])
        timelineItems = try container.decodeIfPresent(TimelineConnection.self, forKey: .timelineItems)
    }

    private enum CodingKeys: String, CodingKey {
        case number, title, url, updatedAt, isDraft, reviewDecision, author, repository, reviewRequests, reviews, commits, assignees, timelineItems
    }
}

enum PendingReviewsServiceError: Error, LocalizedError, Sendable {
    case missingQueryResource
    case invalidResponse
    case invalidHost(String)
    case httpStatus(Int)
    case graphQLErrors([String])
    case decodeFailed(String)

    var errorDescription: String? {
        switch self {
        case .missingQueryResource:
            return "Unable to load PendingReviews.graphql from app resources."
        case .invalidResponse:
            return "Received an invalid response from GitHub."
        case let .invalidHost(host):
            return "The configured host '\(host)' is invalid."
        case let .httpStatus(code):
            return "GitHub API returned HTTP \(code)."
        case let .graphQLErrors(messages):
            return messages.joined(separator: "\n")
        case let .decodeFailed(message):
            return "Failed to decode GitHub response: \(message)"
        }
    }
}

struct PendingReviewsServiceResult: Sendable {
    let buckets: ReviewBuckets
    let rateLimitRemaining: Int?
}

protocol PendingReviewsServing {
    func fetch(settings: AppSettings) async throws -> PendingReviewsServiceResult
}

actor PendingReviewsService: PendingReviewsServing {
    private let authService: GHAuthService
    private let session: URLSession
    private let decoder: JSONDecoder
    private let builder: ReviewBucketsBuilder
    private let queryLoader: () throws -> String

    init(
        authService: GHAuthService,
        session: URLSession = .shared,
        decoder: JSONDecoder = JSONDecoder(),
        builder: ReviewBucketsBuilder = ReviewBucketsBuilder(),
        queryLoader: @escaping () throws -> String = { try PendingReviewsService.loadGraphQLQuery() }
    ) {
        self.authService = authService
        self.session = session
        self.decoder = decoder
        self.builder = builder
        self.queryLoader = queryLoader
    }

    func fetch(settings: AppSettings) async throws -> PendingReviewsServiceResult {
        let query = try queryLoader()
        return try await executeFetch(settings: settings, query: query, retryOnUnauthorized: true)
    }

    private func executeFetch(
        settings: AppSettings,
        query: String,
        retryOnUnauthorized: Bool
    ) async throws -> PendingReviewsServiceResult {
        let host = settings.host.trimmingCharacters(in: .whitespacesAndNewlines)
        let token = try await authService.token(for: host)
        let endpoint = try Self.endpoint(for: host)

        let common = Self.commonSearchQuery(org: settings.org)
        let requestBody = GraphQLRequestBody(
            query: query,
            variables: .init(
                qAwaiting: "\(common) user-review-requested:@me",
                qReviewed: "\(common) reviewed-by:@me -review-requested:@me -author:@me",
                qMyOpen: "\(common) author:@me",
                n: 100
            )
        )

        var request = URLRequest(url: endpoint)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue("PRTracker/1.0", forHTTPHeaderField: "User-Agent")
        request.httpBody = try JSONEncoder().encode(requestBody)

        let (data, response) = try await session.data(for: request)
        guard let httpResponse = response as? HTTPURLResponse else {
            throw PendingReviewsServiceError.invalidResponse
        }

        if httpResponse.statusCode == 401, retryOnUnauthorized {
            await authService.invalidateCachedToken(for: host)
            return try await executeFetch(settings: settings, query: query, retryOnUnauthorized: false)
        }

        guard (200...299).contains(httpResponse.statusCode) else {
            throw PendingReviewsServiceError.httpStatus(httpResponse.statusCode)
        }

        // GitHub may return a partial response (`data` with some fields nulled +
        // a populated `errors` array) when, for example, a PR in the result set
        // is inaccessible. Surface those error messages before attempting the
        // full decode, which would otherwise fail with an opaque message.
        if let errors = Self.extractGraphQLErrors(from: data, decoder: decoder),
           errors.isEmpty == false {
            throw PendingReviewsServiceError.graphQLErrors(errors)
        }

        let payload: GitHubGraphQLResponse
        do {
            payload = try decoder.decode(GitHubGraphQLResponse.self, from: data)
        } catch let decodingError as DecodingError {
            let message = Self.describe(decodingError, body: data)
            AppLog.network.error("Failed to decode GitHub response: \(message, privacy: .public)")
            throw PendingReviewsServiceError.decodeFailed(message)
        } catch {
            AppLog.network.error("Failed to decode GitHub response: \(error.localizedDescription, privacy: .public)")
            throw PendingReviewsServiceError.decodeFailed(error.localizedDescription)
        }

        guard let graphData = payload.data else {
            throw PendingReviewsServiceError.invalidResponse
        }

        let buckets = builder.build(
            from: graphData,
            host: host,
            requiredApprovals: settings.requiredApprovals
        )
        let remaining = Self.rateLimitRemaining(from: httpResponse)
        return PendingReviewsServiceResult(buckets: buckets, rateLimitRemaining: remaining)
    }

    private static func loadGraphQLQuery() throws -> String {
        guard let url = Bundle.main.url(forResource: "PendingReviews", withExtension: "graphql") else {
            throw PendingReviewsServiceError.missingQueryResource
        }
        return try String(contentsOf: url, encoding: .utf8)
    }

    private static func endpoint(for host: String) throws -> URL {
        guard host.isEmpty == false else {
            throw PendingReviewsServiceError.invalidHost(host)
        }

        if host == "github.com" {
            guard let githubURL = URL(string: "https://api.github.com/graphql") else {
                throw PendingReviewsServiceError.invalidResponse
            }
            return githubURL
        }
        guard let enterpriseURL = URL(string: "https://\(host)/api/graphql") else {
            throw PendingReviewsServiceError.invalidHost(host)
        }
        return enterpriseURL
    }

    private static func commonSearchQuery(org: String) -> String {
        let trimmedOrg = org.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmedOrg.isEmpty {
            return "is:pr is:open archived:false"
        }

        let sanitizedOrg = trimmedOrg.filter { character in
            character.isLetter || character.isNumber || character == "-"
        }

        guard sanitizedOrg.isEmpty == false else {
            return "is:pr is:open archived:false"
        }

        return "is:pr is:open archived:false org:\(sanitizedOrg)"
    }

    private static func rateLimitRemaining(from response: HTTPURLResponse) -> Int? {
        guard let value = response.value(forHTTPHeaderField: "X-RateLimit-Remaining") else {
            return nil
        }
        return Int(value)
    }

    /// Best-effort extraction of GraphQL error messages from a response body.
    /// Returns nil if the body isn't JSON or has no `errors` array, so callers
    /// can fall through to the full payload decode.
    private static func extractGraphQLErrors(from data: Data, decoder: JSONDecoder) -> [String]? {
        struct ErrorsOnly: Decodable {
            let errors: [GraphQLErrorResponse]?
        }
        guard let parsed = try? decoder.decode(ErrorsOnly.self, from: data) else {
            return nil
        }
        return parsed.errors?.map(\.message)
    }

    private static func describe(_ error: DecodingError, body: Data) -> String {
        let detail: String
        switch error {
        case let .keyNotFound(key, context):
            detail = "missing key '\(key.stringValue)' at \(pathDescription(context.codingPath))"
        case let .valueNotFound(_, context):
            detail = "unexpected null at \(pathDescription(context.codingPath))"
        case let .typeMismatch(_, context):
            detail = "type mismatch at \(pathDescription(context.codingPath)): \(context.debugDescription)"
        case let .dataCorrupted(context):
            let location = context.codingPath.isEmpty ? "<root>" : pathDescription(context.codingPath)
            detail = "corrupted data at \(location): \(context.debugDescription)"
        @unknown default:
            detail = error.localizedDescription
        }

        if let snippet = bodySnippet(body) {
            return "\(detail). Response begins: \(snippet)"
        }
        return detail
    }

    private static func pathDescription(_ path: [CodingKey]) -> String {
        guard path.isEmpty == false else { return "<root>" }
        return path.map { key -> String in
            if let index = key.intValue {
                return "[\(index)]"
            }
            return key.stringValue
        }.joined(separator: ".")
    }

    private static func bodySnippet(_ data: Data, limit: Int = 200) -> String? {
        guard data.isEmpty == false else { return nil }
        let prefix = data.prefix(limit)
        guard let text = String(data: prefix, encoding: .utf8) else {
            return nil
        }
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.isEmpty == false else { return nil }
        return data.count > limit ? "\(trimmed)…" : trimmed
    }
}

private struct GraphQLRequestBody: Encodable, Sendable {
    struct Variables: Encodable, Sendable {
        let qAwaiting: String
        let qReviewed: String
        let qMyOpen: String
        let n: Int
    }

    let query: String
    let variables: Variables
}

