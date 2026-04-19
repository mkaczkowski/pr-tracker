import Foundation
import XCTest
@testable import PRTracker

final class GHAuthServiceTests: XCTestCase {
    func testDiscoversGhViaShellAndCachesToken() async throws {
        let spawner = MockProcessSpawner()
        await spawner.enqueue(
            executable: "/bin/zsh",
            arguments: ["-lc", "command -v gh"],
            result: .init(exitCode: 0, stdout: "/opt/homebrew/bin/gh\n", stderr: "")
        )
        await spawner.enqueue(
            executable: "/opt/homebrew/bin/gh",
            arguments: ["auth", "token", "--hostname", "github.com"],
            result: .init(exitCode: 0, stdout: "token-123\n", stderr: "")
        )

        let auth = GHAuthService(
            processSpawner: spawner,
            fileManager: FakeFileManager()
        )

        let token1 = try await auth.token(for: "github.com")
        let token2 = try await auth.token(for: "github.com")

        XCTAssertEqual(token1, "token-123")
        XCTAssertEqual(token2, "token-123")

        let invocationCount = await spawner.invocationCount()
        XCTAssertEqual(invocationCount, 2, "Second token call should use cache and avoid process execution")
    }

    func testReturnsNotAuthenticatedError() async throws {
        let spawner = MockProcessSpawner()
        await spawner.enqueue(
            executable: "/bin/zsh",
            arguments: ["-lc", "command -v gh"],
            result: .init(exitCode: 0, stdout: "/opt/homebrew/bin/gh\n", stderr: "")
        )
        await spawner.enqueue(
            executable: "/opt/homebrew/bin/gh",
            arguments: ["auth", "token", "--hostname", "github.com"],
            result: .init(exitCode: 1, stdout: "", stderr: "not logged in")
        )

        let auth = GHAuthService(
            processSpawner: spawner,
            fileManager: FakeFileManager()
        )

        do {
            _ = try await auth.token(for: "github.com")
            XCTFail("Expected authentication error")
        } catch let error as AuthError {
            XCTAssertEqual(error, .notAuthenticated(host: "github.com"))
        }
    }
}

final class PendingReviewsServiceTests: XCTestCase {
    override func tearDown() {
        MockURLProtocol.requestHandler = nil
        super.tearDown()
    }

    func testUsesGithubEndpointAndSanitizesOrgQuery() async throws {
        let spawner = MockProcessSpawner()
        await enqueueDiscoveryAndTokens(spawner, host: "github.com", tokens: ["token-123"])

        let auth = GHAuthService(
            processSpawner: spawner,
            fileManager: FakeFileManager()
        )
        let session = makeMockSession()
        let service = PendingReviewsService(
            authService: auth,
            session: session,
            queryLoader: { "query TestQuery { viewer { login } }" }
        )

        var capturedRequest: URLRequest?
        MockURLProtocol.requestHandler = { request in
            capturedRequest = request
            return (
                Self.httpResponse(url: request.url!, statusCode: 200),
                Self.successGraphQLPayload()
            )
        }

        let settings = AppSettings(
            host: "github.com",
            org: "acme team!@#",
            requiredApprovals: 2,
            refreshIntervalSeconds: 300,
            includeDraftPullRequests: true,
            notificationsEnabled: false,
            launchAtLoginEnabled: false
        )

        _ = try await service.fetch(settings: settings)

        let request = try XCTUnwrap(capturedRequest)
        XCTAssertEqual(request.url?.absoluteString, "https://api.github.com/graphql")

        let body = try XCTUnwrap(httpBodyData(from: request))
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: body) as? [String: Any])
        let variables = try XCTUnwrap(json["variables"] as? [String: Any])
        let awaitingQuery = try XCTUnwrap(variables["qAwaiting"] as? String)
        let reviewedQuery = try XCTUnwrap(variables["qReviewed"] as? String)
        let myOpenQuery = try XCTUnwrap(variables["qMyOpen"] as? String)

        XCTAssertTrue(awaitingQuery.contains("org:acmeteam"))
        XCTAssertTrue(reviewedQuery.contains("org:acmeteam"))
        XCTAssertTrue(myOpenQuery.contains("author:@me"))
        XCTAssertFalse(myOpenQuery.contains("draft:false"))
        XCTAssertEqual(variables["n"] as? Int, 100)
    }

    func testUsesEnterpriseEndpointForCustomHost() async throws {
        let spawner = MockProcessSpawner()
        await enqueueDiscoveryAndTokens(spawner, host: "git.example.com", tokens: ["token-abc"])

        let auth = GHAuthService(
            processSpawner: spawner,
            fileManager: FakeFileManager()
        )
        let session = makeMockSession()
        let service = PendingReviewsService(
            authService: auth,
            session: session,
            queryLoader: { "query TestQuery { viewer { login } }" }
        )

        var capturedURL: URL?
        MockURLProtocol.requestHandler = { request in
            capturedURL = request.url
            return (
                Self.httpResponse(url: request.url!, statusCode: 200),
                Self.successGraphQLPayload()
            )
        }

        let settings = AppSettings(
            host: "git.example.com",
            org: "",
            requiredApprovals: 2,
            refreshIntervalSeconds: 300,
            includeDraftPullRequests: true,
            notificationsEnabled: false,
            launchAtLoginEnabled: false
        )

        _ = try await service.fetch(settings: settings)
        XCTAssertEqual(capturedURL?.absoluteString, "https://git.example.com/api/graphql")
    }

    func testRetriesOnceOnUnauthorizedAndInvalidatesToken() async throws {
        let spawner = MockProcessSpawner()
        await enqueueDiscoveryAndTokens(spawner, host: "git.example.com", tokens: ["first-token", "second-token"])

        let auth = GHAuthService(
            processSpawner: spawner,
            fileManager: FakeFileManager()
        )
        let session = makeMockSession()
        let service = PendingReviewsService(
            authService: auth,
            session: session,
            queryLoader: { "query TestQuery { viewer { login } }" }
        )

        var requestCount = 0
        MockURLProtocol.requestHandler = { request in
            requestCount += 1
            if requestCount == 1 {
                return (
                    Self.httpResponse(url: request.url!, statusCode: 401),
                    Data("{}".utf8)
                )
            }
            return (
                Self.httpResponse(url: request.url!, statusCode: 200),
                Self.successGraphQLPayload()
            )
        }

        let settings = AppSettings(
            host: "git.example.com",
            org: "",
            requiredApprovals: 2,
            refreshIntervalSeconds: 300,
            includeDraftPullRequests: true,
            notificationsEnabled: false,
            launchAtLoginEnabled: false
        )

        let result = try await service.fetch(settings: settings)
        XCTAssertEqual(result.buckets.user, "alice")
        XCTAssertEqual(requestCount, 2)

        let invocationCount = await spawner.invocationCount()
        XCTAssertEqual(invocationCount, 3, "Expected gh discovery + token fetch + token refresh")
    }

    func testThrowsGraphQLErrorPayload() async throws {
        let spawner = MockProcessSpawner()
        await enqueueDiscoveryAndTokens(spawner, host: "github.com", tokens: ["token-123"])

        let auth = GHAuthService(
            processSpawner: spawner,
            fileManager: FakeFileManager()
        )
        let session = makeMockSession()
        let service = PendingReviewsService(
            authService: auth,
            session: session,
            queryLoader: { "query TestQuery { viewer { login } }" }
        )

        MockURLProtocol.requestHandler = { request in
            let payload = Data(#"{"errors":[{"message":"bad query"}]}"#.utf8)
            return (
                Self.httpResponse(url: request.url!, statusCode: 200),
                payload
            )
        }

        let settings = AppSettings(
            host: "github.com",
            org: "",
            requiredApprovals: 2,
            refreshIntervalSeconds: 300,
            includeDraftPullRequests: true,
            notificationsEnabled: false,
            launchAtLoginEnabled: false
        )

        do {
            _ = try await service.fetch(settings: settings)
            XCTFail("Expected GraphQL error")
        } catch let error as PendingReviewsServiceError {
            guard case let .graphQLErrors(messages) = error else {
                return XCTFail("Unexpected error case: \(error)")
            }
            XCTAssertEqual(messages, ["bad query"])
        }
    }

    func testThrowsInvalidHostForMalformedHost() async throws {
        let spawner = MockProcessSpawner()
        await enqueueDiscoveryAndTokens(spawner, host: "bad host", tokens: ["token-123"])

        let auth = GHAuthService(
            processSpawner: spawner,
            fileManager: FakeFileManager()
        )
        let session = makeMockSession()
        let service = PendingReviewsService(
            authService: auth,
            session: session,
            queryLoader: { "query TestQuery { viewer { login } }" }
        )

        let settings = AppSettings(
            host: "bad host",
            org: "",
            requiredApprovals: 2,
            refreshIntervalSeconds: 300,
            includeDraftPullRequests: true,
            notificationsEnabled: false,
            launchAtLoginEnabled: false
        )

        do {
            _ = try await service.fetch(settings: settings)
            XCTFail("Expected invalid host error")
        } catch let error as PendingReviewsServiceError {
            guard case let .invalidHost(host) = error else {
                return XCTFail("Unexpected error case: \(error)")
            }
            XCTAssertEqual(host, "bad host")
        }
    }

    private func makeMockSession() -> URLSession {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [MockURLProtocol.self]
        return URLSession(configuration: configuration)
    }

    private func enqueueDiscoveryAndTokens(_ spawner: MockProcessSpawner, host: String, tokens: [String]) async {
        await spawner.enqueue(
            executable: "/bin/zsh",
            arguments: ["-lc", "command -v gh"],
            result: .init(exitCode: 0, stdout: "/opt/homebrew/bin/gh\n", stderr: "")
        )

        for token in tokens {
            await spawner.enqueue(
                executable: "/opt/homebrew/bin/gh",
                arguments: ["auth", "token", "--hostname", host],
                result: .init(exitCode: 0, stdout: "\(token)\n", stderr: "")
            )
        }
    }

    private static func successGraphQLPayload() -> Data {
        Data(
            #"""
            {
              "data": {
                "viewer": { "login": "alice" },
                "awaiting": { "issueCount": 0, "nodes": [] },
                "reviewed": { "issueCount": 0, "nodes": [] },
                "myOpen": { "issueCount": 0, "nodes": [] }
              }
            }
            """#.utf8
        )
    }

    private static func httpResponse(url: URL, statusCode: Int) -> HTTPURLResponse {
        HTTPURLResponse(
            url: url,
            statusCode: statusCode,
            httpVersion: nil,
            headerFields: nil
        )!
    }

    private func httpBodyData(from request: URLRequest) -> Data? {
        if let body = request.httpBody {
            return body
        }

        guard let stream = request.httpBodyStream else {
            return nil
        }

        stream.open()
        defer { stream.close() }

        let bufferSize = 1_024
        let buffer = UnsafeMutablePointer<UInt8>.allocate(capacity: bufferSize)
        defer { buffer.deallocate() }

        var data = Data()
        while stream.hasBytesAvailable {
            let readCount = stream.read(buffer, maxLength: bufferSize)
            if readCount > 0 {
                data.append(buffer, count: readCount)
            } else {
                break
            }
        }

        return data.isEmpty ? nil : data
    }
}

private final class FakeFileManager: FileManager, @unchecked Sendable {
    override func isExecutableFile(atPath path: String) -> Bool {
        false
    }
}

private actor MockProcessSpawner: ProcessSpawning {
    private struct Key: Hashable {
        let executable: String
        let arguments: [String]
    }

    private var queue: [Key: [ProcessResult]] = [:]
    private var invocations: [Key] = []

    func enqueue(executable: String, arguments: [String], result: ProcessResult) {
        let key = Key(executable: executable, arguments: arguments)
        var values = queue[key] ?? []
        values.append(result)
        queue[key] = values
    }

    func run(
        executable: String,
        arguments: [String],
        environment: [String: String]?
    ) async throws -> ProcessResult {
        let key = Key(executable: executable, arguments: arguments)
        invocations.append(key)
        guard var values = queue[key], values.isEmpty == false else {
            return ProcessResult(exitCode: 127, stdout: "", stderr: "command not mocked")
        }
        let next = values.removeFirst()
        queue[key] = values
        return next
    }

    func invocationCount() -> Int {
        invocations.count
    }
}

private final class MockURLProtocol: URLProtocol {
    static var requestHandler: ((URLRequest) throws -> (HTTPURLResponse, Data))?

    override class func canInit(with request: URLRequest) -> Bool {
        true
    }

    override class func canonicalRequest(for request: URLRequest) -> URLRequest {
        request
    }

    override func startLoading() {
        guard let handler = Self.requestHandler else {
            fatalError("MockURLProtocol.requestHandler must be set before use")
        }

        do {
            let (response, data) = try handler(request)
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: data)
            client?.urlProtocolDidFinishLoading(self)
        } catch {
            client?.urlProtocol(self, didFailWithError: error)
        }
    }

    override func stopLoading() {}
}


