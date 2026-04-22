import XCTest
@testable import PRTracker

final class ReviewBucketsBuilderTests: XCTestCase {
    func testBuilderMatchesFixtureSemantics() throws {
        let graphFixtureURL = fixtureURL(named: "graphql-response")
        let data = try Data(contentsOf: graphFixtureURL)
        let response = try JSONDecoder().decode(GitHubGraphQLResponse.self, from: data)
        let graphData = try XCTUnwrap(response.data)

        let builder = ReviewBucketsBuilder()
        let buckets = builder.build(
            from: graphData,
            host: "github.com",
            requiredApprovals: 2
        )

        XCTAssertEqual(buckets.user, "alice")
        XCTAssertEqual(buckets.host, "github.com")
        XCTAssertEqual(buckets.needsReview.count, 1)
        XCTAssertEqual(buckets.needsReReview.count, 1)
        XCTAssertEqual(buckets.totals.awaiting, 1)
        XCTAssertEqual(buckets.totals.reviewed, 1)

        let awaiting = try XCTUnwrap(buckets.needsReview.first)
        XCTAssertEqual(awaiting.number, 101)
        XCTAssertEqual(awaiting.latestReviewState, .awaiting)
        XCTAssertEqual(awaiting.approvals, 1)
        XCTAssertTrue(awaiting.updatedSinceReview)
        XCTAssertTrue(awaiting.isReReview)

        let reviewed = try XCTUnwrap(buckets.needsReReview.first)
        XCTAssertEqual(reviewed.number, 55)
        XCTAssertEqual(reviewed.latestReviewState, .commented)
        XCTAssertTrue(reviewed.updatedSinceReview)
        XCTAssertTrue(reviewed.isReReview)

        XCTAssertEqual(buckets.myOpenWaitingOnReviewers.map(\.number), [201, 200])
        XCTAssertEqual(buckets.myOpenBlockedOnYou.map(\.number), [202])
        XCTAssertEqual(buckets.myOpenWaitingToBeMerged.map(\.number), [])
        XCTAssertEqual(buckets.myOpenOnMergeQueue.map(\.number), [203])
        XCTAssertFalse(buckets.myOpenTruncated)

        let reReview = try XCTUnwrap(buckets.myOpenWaitingOnReviewers.first)
        XCTAssertEqual(reReview.latestReviewState, .commented)
        XCTAssertEqual(reReview.approvals, 0)
        XCTAssertTrue(reReview.updatedSinceReview)
        XCTAssertEqual(reReview.checksStatus, .pending)
        XCTAssertNil(reReview.reviewRequestedAt)

        let firstReview = try XCTUnwrap(buckets.myOpenWaitingOnReviewers.last)
        XCTAssertEqual(firstReview.latestReviewState, .awaiting)
        XCTAssertEqual(firstReview.checksStatus, .pending)

        let blocked = try XCTUnwrap(buckets.myOpenBlockedOnYou.first)
        XCTAssertEqual(blocked.latestReviewState, .changesRequested)
        XCTAssertEqual(blocked.checksStatus, .failing)

        let ready = try XCTUnwrap(buckets.myOpenOnMergeQueue.first)
        XCTAssertEqual(ready.approvals, 2)
        XCTAssertTrue(ready.isInMergeQueue)
        XCTAssertEqual(ready.checksStatus, .passing)

        let expectedData = try Data(contentsOf: fixtureURL(named: "pending-reviews"))
        let expected = try JSONDecoder().decode(PendingReviewsFixture.self, from: expectedData)
        XCTAssertEqual(expected.user, buckets.user)
        XCTAssertEqual(expected.host, buckets.host)
        XCTAssertEqual(expected.needsReview.first?.number, awaiting.number)
        XCTAssertEqual(expected.needsReReview.first?.number, reviewed.number)
        XCTAssertEqual(expected.myOpenWaitingOnReviewers.map(\.number), [201, 200])
        XCTAssertEqual(expected.myOpenBlockedOnYou.map(\.number), [202])
        XCTAssertEqual(expected.myOpenWaitingToBeMerged.map(\.number), [])
        XCTAssertEqual(expected.myOpenOnMergeQueue.map(\.number), [203])
    }

    func testTruncationFlagWhenIssueCountExceedsSearchLimit() {
        let dataRoot = GitHubGraphQLResponse.DataRoot(
            viewer: .init(login: "alice"),
            awaiting: .init(issueCount: 101, nodes: []),
            reviewed: .init(issueCount: 150, nodes: []),
            myOpen: .init(issueCount: 200, nodes: [])
        )

        let buckets = ReviewBucketsBuilder().build(
            from: dataRoot,
            host: "github.com",
            requiredApprovals: 2
        )

        XCTAssertTrue(buckets.awaitingTruncated)
        XCTAssertTrue(buckets.reviewedTruncated)
        XCTAssertTrue(buckets.myOpenTruncated)
    }

    func testTruncationFlagFalseAtExactSearchLimit() {
        let dataRoot = GitHubGraphQLResponse.DataRoot(
            viewer: .init(login: "alice"),
            awaiting: .init(issueCount: 100, nodes: []),
            reviewed: .init(issueCount: 100, nodes: []),
            myOpen: .init(issueCount: 100, nodes: [])
        )

        let buckets = ReviewBucketsBuilder().build(
            from: dataRoot,
            host: "github.com",
            requiredApprovals: 2
        )

        XCTAssertFalse(buckets.awaitingTruncated)
        XCTAssertFalse(buckets.reviewedTruncated)
        XCTAssertFalse(buckets.myOpenTruncated)
    }

    func testReReviewBucketExcludesLatestApprovedReviewWhenPRChanged() throws {
        let response = try decodeResponse(
            #"""
            {
              "data": {
                "viewer": { "login": "alice" },
                "awaiting": { "issueCount": 0, "nodes": [] },
                "reviewed": {
                  "issueCount": 1,
                  "nodes": [
                    {
                      "number": 12,
                      "title": "Some PR",
                      "url": "https://github.com/acme/repo/pull/12",
                      "updatedAt": "2026-04-19T11:00:00Z",
                      "author": { "login": "bob" },
                      "repository": { "nameWithOwner": "acme/repo" },
                      "reviews": {
                        "nodes": [
                          { "state": "COMMENTED", "submittedAt": "2026-04-19T09:00:00Z", "author": { "login": "alice" } },
                          { "state": "APPROVED", "submittedAt": "2026-04-19T10:00:00Z", "author": { "login": "alice" } }
                        ]
                      },
                      "commits": { "nodes": [ { "commit": { "committedDate": "2026-04-19T10:30:00Z" } } ] },
                      "timelineItems": { "nodes": [] }
                    }
                  ]
                },
                "myOpen": { "issueCount": 0, "nodes": [] }
              }
            }
            """#
        )

        let graphData = try XCTUnwrap(response.data)
        let buckets = ReviewBucketsBuilder().build(from: graphData, host: "github.com", requiredApprovals: 2)
        XCTAssertTrue(buckets.needsReReview.isEmpty)
    }

    func testReReviewBucketExcludesStaleApprovalWhenOtherReviewersAreRequested() throws {
        let response = try decodeResponse(
            #"""
            {
              "data": {
                "viewer": { "login": "alice" },
                "awaiting": { "issueCount": 0, "nodes": [] },
                "reviewed": {
                  "issueCount": 1,
                  "nodes": [
                    {
                      "number": 73,
                      "title": "Exclude drafts",
                      "url": "https://github.com/acme/repo/pull/73",
                      "updatedAt": "2026-04-19T11:00:00Z",
                      "author": { "login": "bob" },
                      "repository": { "nameWithOwner": "acme/repo" },
                      "reviewDecision": "CHANGES_REQUESTED",
                      "reviewRequests": {
                        "nodes": [
                          { "requestedReviewer": { "login": "carol" } },
                          { "requestedReviewer": { "login": "dave" } }
                        ]
                      },
                      "reviews": {
                        "nodes": [
                          { "state": "APPROVED", "submittedAt": "2026-04-19T08:00:00Z", "author": { "login": "alice" } },
                          { "state": "CHANGES_REQUESTED", "submittedAt": "2026-04-19T09:00:00Z", "author": { "login": "erin" } }
                        ]
                      },
                      "commits": { "nodes": [ { "commit": { "committedDate": "2026-04-19T10:00:00Z" } } ] },
                      "timelineItems": { "nodes": [] }
                    }
                  ]
                },
                "myOpen": { "issueCount": 0, "nodes": [] }
              }
            }
            """#
        )

        let graphData = try XCTUnwrap(response.data)
        let buckets = ReviewBucketsBuilder().build(from: graphData, host: "github.com", requiredApprovals: 2)
        XCTAssertTrue(buckets.needsReReview.isEmpty)
    }

    func testMergeQAssigneeMarksPullRequestAsInMergeQueue() throws {
        let response = try decodeResponse(
            #"""
            {
              "data": {
                "viewer": { "login": "alice" },
                "awaiting": { "issueCount": 0, "nodes": [] },
                "reviewed": { "issueCount": 0, "nodes": [] },
                "myOpen": {
                  "issueCount": 1,
                  "nodes": [
                    {
                      "number": 88,
                      "title": "Queued for merge",
                      "url": "https://github.com/acme/repo/pull/88",
                      "updatedAt": "2026-04-19T11:00:00Z",
                      "isDraft": false,
                      "author": { "login": "alice" },
                      "repository": { "nameWithOwner": "acme/repo" },
                      "assignees": {
                        "nodes": [
                          { "login": "mergeq", "name": "MergeQ - MergeQ Bot" }
                        ]
                      },
                      "reviewRequests": { "nodes": [] },
                      "reviews": {
                        "nodes": [
                          { "state": "APPROVED", "submittedAt": "2026-04-19T09:00:00Z", "author": { "login": "bob" } }
                        ]
                      },
                      "commits": { "nodes": [ { "commit": { "committedDate": "2026-04-19T08:00:00Z" } } ] }
                    }
                  ]
                }
              }
            }
            """#
        )

        let graphData = try XCTUnwrap(response.data)
        let buckets = ReviewBucketsBuilder().build(from: graphData, host: "github.com", requiredApprovals: 1)
        let queued = try XCTUnwrap(buckets.myOpenOnMergeQueue.first)
        XCTAssertTrue(queued.isInMergeQueue)
    }

    func testMergeQAssigneeWithEnoughApprovalsStaysOnMergeQueueAfterFollowUpPush() throws {
        let response = try decodeResponse(
            #"""
            {
              "data": {
                "viewer": { "login": "alice" },
                "awaiting": { "issueCount": 0, "nodes": [] },
                "reviewed": { "issueCount": 0, "nodes": [] },
                "myOpen": {
                  "issueCount": 1,
                  "nodes": [
                    {
                      "number": 89,
                      "title": "Queued with follow-up commit",
                      "url": "https://github.com/acme/repo/pull/89",
                      "updatedAt": "2026-04-20T12:00:00Z",
                      "isDraft": false,
                      "author": { "login": "alice" },
                      "repository": { "nameWithOwner": "acme/repo" },
                      "assignees": {
                        "nodes": [
                          { "login": "MergeQ", "name": "MergeQ Bot" }
                        ]
                      },
                      "reviewRequests": { "nodes": [] },
                      "reviews": {
                        "nodes": [
                          { "state": "APPROVED", "submittedAt": "2026-04-20T09:00:00Z", "author": { "login": "bob" } },
                          { "state": "APPROVED", "submittedAt": "2026-04-20T09:15:00Z", "author": { "login": "carol" } }
                        ]
                      },
                      "commits": { "nodes": [ { "commit": { "committedDate": "2026-04-20T10:00:00Z" } } ] }
                    }
                  ]
                }
              }
            }
            """#
        )

        let graphData = try XCTUnwrap(response.data)
        let buckets = ReviewBucketsBuilder().build(from: graphData, host: "github.com", requiredApprovals: 2)
        XCTAssertTrue(buckets.myOpenWaitingOnReviewers.isEmpty)
        XCTAssertEqual(buckets.myOpenOnMergeQueue.map(\.number), [89])
    }

    func testBuildsChecksStatusFromLatestCommitRollup() throws {
        let response = try decodeResponse(
            #"""
            {
              "data": {
                "viewer": { "login": "alice" },
                "awaiting": {
                  "issueCount": 3,
                  "nodes": [
                    {
                      "number": 501,
                      "title": "Checks green",
                      "url": "https://github.com/acme/repo/pull/501",
                      "updatedAt": "2026-04-19T11:00:00Z",
                      "isDraft": false,
                      "author": { "login": "bob" },
                      "repository": { "nameWithOwner": "acme/repo" },
                      "assignees": { "nodes": [] },
                      "reviewRequests": { "nodes": [] },
                      "reviews": { "nodes": [] },
                      "commits": {
                        "nodes": [
                          { "commit": { "committedDate": "2026-04-19T10:00:00Z", "statusCheckRollup": { "state": "SUCCESS" } } }
                        ]
                      },
                      "timelineItems": { "nodes": [] }
                    },
                    {
                      "number": 502,
                      "title": "Checks pending",
                      "url": "https://github.com/acme/repo/pull/502",
                      "updatedAt": "2026-04-19T10:00:00Z",
                      "isDraft": false,
                      "author": { "login": "carol" },
                      "repository": { "nameWithOwner": "acme/repo" },
                      "assignees": { "nodes": [] },
                      "reviewRequests": { "nodes": [] },
                      "reviews": { "nodes": [] },
                      "commits": {
                        "nodes": [
                          { "commit": { "committedDate": "2026-04-19T09:00:00Z", "statusCheckRollup": { "state": "PENDING" } } }
                        ]
                      },
                      "timelineItems": { "nodes": [] }
                    },
                    {
                      "number": 503,
                      "title": "Checks failing",
                      "url": "https://github.com/acme/repo/pull/503",
                      "updatedAt": "2026-04-19T09:00:00Z",
                      "isDraft": false,
                      "author": { "login": "dave" },
                      "repository": { "nameWithOwner": "acme/repo" },
                      "assignees": { "nodes": [] },
                      "reviewRequests": { "nodes": [] },
                      "reviews": { "nodes": [] },
                      "commits": {
                        "nodes": [
                          { "commit": { "committedDate": "2026-04-19T08:00:00Z", "statusCheckRollup": { "state": "FAILURE" } } }
                        ]
                      },
                      "timelineItems": { "nodes": [] }
                    }
                  ]
                },
                "reviewed": { "issueCount": 0, "nodes": [] },
                "myOpen": { "issueCount": 0, "nodes": [] }
              }
            }
            """#
        )

        let graphData = try XCTUnwrap(response.data)
        let buckets = ReviewBucketsBuilder().build(from: graphData, host: "github.com", requiredApprovals: 2)
        let statuses = Dictionary(uniqueKeysWithValues: buckets.needsReview.map { ($0.number, $0.checksStatus) })
        XCTAssertEqual(statuses[501], .passing)
        XCTAssertEqual(statuses[502], .pending)
        XCTAssertEqual(statuses[503], .failing)
    }

    func testApprovalCountUsesLatestReviewPerAuthor() throws {
        let response = try decodeResponse(
            #"""
            {
              "data": {
                "viewer": { "login": "alice" },
                "awaiting": {
                  "issueCount": 1,
                  "nodes": [
                    {
                      "number": 44,
                      "title": "Awaiting PR",
                      "url": "https://github.com/acme/repo/pull/44",
                      "updatedAt": "2026-04-19T11:00:00Z",
                      "author": { "login": "eve" },
                      "repository": { "nameWithOwner": "acme/repo" },
                      "reviews": {
                        "nodes": [
                          { "state": "APPROVED", "submittedAt": "2026-04-19T08:00:00Z", "author": { "login": "carol" } },
                          { "state": "CHANGES_REQUESTED", "submittedAt": "2026-04-19T09:00:00Z", "author": { "login": "carol" } }
                        ]
                      },
                      "commits": { "nodes": [ { "commit": { "committedDate": "2026-04-19T10:00:00Z" } } ] },
                      "timelineItems": { "nodes": [] }
                    }
                  ]
                },
                "reviewed": { "issueCount": 0, "nodes": [] },
                "myOpen": { "issueCount": 0, "nodes": [] }
              }
            }
            """#
        )

        let graphData = try XCTUnwrap(response.data)
        let buckets = ReviewBucketsBuilder().build(from: graphData, host: "github.com", requiredApprovals: 2)
        let awaiting = try XCTUnwrap(buckets.needsReview.first)
        XCTAssertEqual(awaiting.approvals, 0)
    }

    func testAwaitingSortPrioritizesReReviewThenNewestRequest() throws {
        let response = try decodeResponse(
            #"""
            {
              "data": {
                "viewer": { "login": "alice" },
                "awaiting": {
                  "issueCount": 3,
                  "nodes": [
                    {
                      "number": 10,
                      "title": "Fresh first review",
                      "url": "https://github.com/acme/repo/pull/10",
                      "updatedAt": "2026-04-19T12:00:00Z",
                      "author": { "login": "bob" },
                      "repository": { "nameWithOwner": "acme/repo" },
                      "reviews": { "nodes": [] },
                      "commits": { "nodes": [ { "commit": { "committedDate": "2026-04-19T11:00:00Z" } } ] },
                      "timelineItems": { "nodes": [ { "createdAt": "2026-04-19T10:00:00Z", "requestedReviewer": { "login": "alice" } } ] }
                    },
                    {
                      "number": 11,
                      "title": "Re-review after new push",
                      "url": "https://github.com/acme/repo/pull/11",
                      "updatedAt": "2026-04-19T11:30:00Z",
                      "author": { "login": "carol" },
                      "repository": { "nameWithOwner": "acme/repo" },
                      "reviews": { "nodes": [ { "state": "COMMENTED", "submittedAt": "2026-04-19T09:00:00Z", "author": { "login": "alice" } } ] },
                      "commits": { "nodes": [ { "commit": { "committedDate": "2026-04-19T11:15:00Z" } } ] },
                      "timelineItems": { "nodes": [ { "createdAt": "2026-04-19T10:30:00Z", "requestedReviewer": { "login": "alice" } } ] }
                    },
                    {
                      "number": 12,
                      "title": "Oldest untouched request",
                      "url": "https://github.com/acme/repo/pull/12",
                      "updatedAt": "2026-04-19T09:30:00Z",
                      "author": { "login": "dave" },
                      "repository": { "nameWithOwner": "acme/repo" },
                      "reviews": { "nodes": [] },
                      "commits": { "nodes": [ { "commit": { "committedDate": "2026-04-19T09:00:00Z" } } ] },
                      "timelineItems": { "nodes": [ { "createdAt": "2026-04-19T08:00:00Z", "requestedReviewer": { "login": "alice" } } ] }
                    }
                  ]
                },
                "reviewed": { "issueCount": 0, "nodes": [] },
                "myOpen": { "issueCount": 0, "nodes": [] }
              }
            }
            """#
        )

        let graphData = try XCTUnwrap(response.data)
        let buckets = ReviewBucketsBuilder().build(from: graphData, host: "github.com", requiredApprovals: 2)
        XCTAssertEqual(buckets.needsReview.map(\.number), [11, 10, 12])
    }

    func testReReviewSortExcludesNonUpdatedAndPrioritizesNewestPush() throws {
        let response = try decodeResponse(
            #"""
            {
              "data": {
                "viewer": { "login": "alice" },
                "awaiting": { "issueCount": 0, "nodes": [] },
                "reviewed": {
                  "issueCount": 3,
                  "nodes": [
                    {
                      "number": 20,
                      "title": "Commented, no new push",
                      "url": "https://github.com/acme/repo/pull/20",
                      "updatedAt": "2026-04-19T12:00:00Z",
                      "author": { "login": "bob" },
                      "repository": { "nameWithOwner": "acme/repo" },
                      "reviews": { "nodes": [ { "state": "COMMENTED", "submittedAt": "2026-04-19T08:00:00Z", "author": { "login": "alice" } } ] },
                      "commits": { "nodes": [ { "commit": { "committedDate": "2026-04-19T07:00:00Z" } } ] },
                      "timelineItems": { "nodes": [ { "createdAt": "2026-04-19T07:30:00Z", "requestedReviewer": { "login": "alice" } } ] }
                    },
                    {
                      "number": 21,
                      "title": "Updated since review",
                      "url": "https://github.com/acme/repo/pull/21",
                      "updatedAt": "2026-04-19T10:30:00Z",
                      "author": { "login": "carol" },
                      "repository": { "nameWithOwner": "acme/repo" },
                      "reviews": { "nodes": [ { "state": "COMMENTED", "submittedAt": "2026-04-19T08:30:00Z", "author": { "login": "alice" } } ] },
                      "commits": { "nodes": [ { "commit": { "committedDate": "2026-04-19T09:00:00Z" } } ] },
                      "timelineItems": { "nodes": [ { "createdAt": "2026-04-19T08:15:00Z", "requestedReviewer": { "login": "alice" } } ] }
                    },
                    {
                      "number": 22,
                      "title": "Most recent push after review",
                      "url": "https://github.com/acme/repo/pull/22",
                      "updatedAt": "2026-04-19T10:00:00Z",
                      "author": { "login": "dave" },
                      "repository": { "nameWithOwner": "acme/repo" },
                      "reviews": { "nodes": [ { "state": "CHANGES_REQUESTED", "submittedAt": "2026-04-19T08:00:00Z", "author": { "login": "alice" } } ] },
                      "commits": { "nodes": [ { "commit": { "committedDate": "2026-04-19T09:30:00Z" } } ] },
                      "timelineItems": { "nodes": [ { "createdAt": "2026-04-19T07:45:00Z", "requestedReviewer": { "login": "alice" } } ] }
                    }
                  ]
                },
                "myOpen": { "issueCount": 0, "nodes": [] }
              }
            }
            """#
        )

        let graphData = try XCTUnwrap(response.data)
        let buckets = ReviewBucketsBuilder().build(from: graphData, host: "github.com", requiredApprovals: 2)
        XCTAssertEqual(buckets.needsReReview.map(\.number), [22, 21])
        XCTAssertFalse(buckets.needsReReview.contains(where: { $0.number == 20 }))
    }

    func testMyOpenSortPrioritizesReReviewThenNewestWaitingThenApprovals() throws {
        let response = try decodeResponse(
            #"""
            {
              "data": {
                "viewer": { "login": "alice" },
                "awaiting": { "issueCount": 0, "nodes": [] },
                "reviewed": { "issueCount": 0, "nodes": [] },
                "myOpen": {
                  "issueCount": 4,
                  "nodes": [
                    {
                      "number": 30,
                      "title": "Fresh first review",
                      "url": "https://github.com/acme/repo/pull/30",
                      "updatedAt": "2026-04-19T10:00:00Z",
                      "author": { "login": "alice" },
                      "repository": { "nameWithOwner": "acme/repo" },
                      "reviews": { "nodes": [] },
                      "commits": { "nodes": [ { "commit": { "committedDate": "2026-04-19T10:00:00Z" } } ] }
                    },
                    {
                      "number": 31,
                      "title": "Needs re-review after push",
                      "url": "https://github.com/acme/repo/pull/31",
                      "updatedAt": "2026-04-19T09:00:00Z",
                      "author": { "login": "alice" },
                      "repository": { "nameWithOwner": "acme/repo" },
                      "reviews": { "nodes": [ { "state": "COMMENTED", "submittedAt": "2026-04-19T06:00:00Z", "author": { "login": "bob" } } ] },
                      "commits": { "nodes": [ { "commit": { "committedDate": "2026-04-19T08:30:00Z" } } ] }
                    },
                    {
                      "number": 32,
                      "title": "Older partial approval",
                      "url": "https://github.com/acme/repo/pull/32",
                      "updatedAt": "2026-04-19T07:00:00Z",
                      "author": { "login": "alice" },
                      "repository": { "nameWithOwner": "acme/repo" },
                      "reviews": { "nodes": [ { "state": "APPROVED", "submittedAt": "2026-04-19T06:30:00Z", "author": { "login": "bob" } } ] },
                      "commits": { "nodes": [ { "commit": { "committedDate": "2026-04-19T06:00:00Z" } } ] }
                    },
                    {
                      "number": 33,
                      "title": "Older commented review",
                      "url": "https://github.com/acme/repo/pull/33",
                      "updatedAt": "2026-04-19T07:00:00Z",
                      "author": { "login": "alice" },
                      "repository": { "nameWithOwner": "acme/repo" },
                      "reviews": { "nodes": [ { "state": "COMMENTED", "submittedAt": "2026-04-19T06:45:00Z", "author": { "login": "carol" } } ] },
                      "commits": { "nodes": [ { "commit": { "committedDate": "2026-04-19T06:00:00Z" } } ] }
                    }
                  ]
                }
              }
            }
            """#
        )

        let graphData = try XCTUnwrap(response.data)
        let buckets = ReviewBucketsBuilder().build(from: graphData, host: "github.com", requiredApprovals: 2)
        XCTAssertEqual(buckets.myOpenWaitingOnReviewers.map(\.number), [31, 30, 33, 32])
    }

    func testMyOpenIncludesChangesRequestedAfterFollowUpPush() throws {
        let response = try decodeResponse(
            #"""
            {
              "data": {
                "viewer": { "login": "alice" },
                "awaiting": { "issueCount": 0, "nodes": [] },
                "reviewed": { "issueCount": 0, "nodes": [] },
                "myOpen": {
                  "issueCount": 1,
                  "nodes": [
                    {
                      "number": 300,
                      "title": "Address review feedback",
                      "url": "https://github.com/acme/repo/pull/300",
                      "updatedAt": "2026-04-19T11:00:00Z",
                      "author": { "login": "alice" },
                      "repository": { "nameWithOwner": "acme/repo" },
                      "reviews": {
                        "nodes": [
                          { "state": "CHANGES_REQUESTED", "submittedAt": "2026-04-19T08:00:00Z", "author": { "login": "bob" } }
                        ]
                      },
                      "commits": { "nodes": [ { "commit": { "committedDate": "2026-04-19T10:00:00Z" } } ] }
                    }
                  ]
                }
              }
            }
            """#
        )

        let graphData = try XCTUnwrap(response.data)
        let buckets = ReviewBucketsBuilder().build(from: graphData, host: "github.com", requiredApprovals: 2)
        XCTAssertEqual(buckets.myOpenWaitingOnReviewers.map(\.number), [300])
        let pr = try XCTUnwrap(buckets.myOpenWaitingOnReviewers.first)
        XCTAssertEqual(
            pr.displayState(requiredApprovals: 2, context: .myOpenWaitingOnReviewers),
            .stale
        )
    }

    func testMyOpenIncludesPartialApprovalEvenWithoutNewPush() throws {
        let response = try decodeResponse(
            #"""
            {
              "data": {
                "viewer": { "login": "alice" },
                "awaiting": { "issueCount": 0, "nodes": [] },
                "reviewed": { "issueCount": 0, "nodes": [] },
                "myOpen": {
                  "issueCount": 1,
                  "nodes": [
                    {
                      "number": 301,
                      "title": "One approval, need two",
                      "url": "https://github.com/acme/repo/pull/301",
                      "updatedAt": "2026-04-19T11:00:00Z",
                      "author": { "login": "alice" },
                      "repository": { "nameWithOwner": "acme/repo" },
                      "reviews": {
                        "nodes": [
                          { "state": "APPROVED", "submittedAt": "2026-04-19T10:00:00Z", "author": { "login": "bob" } }
                        ]
                      },
                      "commits": { "nodes": [ { "commit": { "committedDate": "2026-04-19T09:00:00Z" } } ] }
                    }
                  ]
                }
              }
            }
            """#
        )

        let graphData = try XCTUnwrap(response.data)
        let buckets = ReviewBucketsBuilder().build(from: graphData, host: "github.com", requiredApprovals: 2)
        let pr = try XCTUnwrap(buckets.myOpenWaitingOnReviewers.first)
        XCTAssertEqual(pr.number, 301)
        XCTAssertEqual(pr.approvals, 1)
        XCTAssertEqual(pr.latestReviewState, .approved)
        XCTAssertEqual(
            pr.displayState(requiredApprovals: 2, context: .myOpenWaitingOnReviewers),
            .waiting
        )
        XCTAssertFalse(
            pr.approvalBadgeShowsComplete(
                requiredApprovals: 2,
                context: .myOpenWaitingOnReviewers
            )
        )
    }

    func testMyOpenFreshReviewNeededSuppressesGreenApprovalBadge() throws {
        let response = try decodeResponse(
            #"""
            {
              "data": {
                "viewer": { "login": "alice" },
                "awaiting": { "issueCount": 0, "nodes": [] },
                "reviewed": { "issueCount": 0, "nodes": [] },
                "myOpen": {
                  "issueCount": 1,
                  "nodes": [
                    {
                      "number": 302,
                      "title": "Approved before latest push",
                      "url": "https://github.com/acme/repo/pull/302",
                      "updatedAt": "2026-04-19T11:00:00Z",
                      "author": { "login": "alice" },
                      "repository": { "nameWithOwner": "acme/repo" },
                      "reviews": {
                        "nodes": [
                          { "state": "APPROVED", "submittedAt": "2026-04-19T09:00:00Z", "author": { "login": "bob" } }
                        ]
                      },
                      "commits": { "nodes": [ { "commit": { "committedDate": "2026-04-19T10:00:00Z" } } ] }
                    }
                  ]
                }
              }
            }
            """#
        )

        let graphData = try XCTUnwrap(response.data)
        let buckets = ReviewBucketsBuilder().build(from: graphData, host: "github.com", requiredApprovals: 1)
        let pr = try XCTUnwrap(buckets.myOpenWaitingOnReviewers.first)
        XCTAssertEqual(
            pr.displayState(requiredApprovals: 1, context: .myOpenWaitingOnReviewers),
            .stale
        )
        XCTAssertFalse(
            pr.approvalBadgeShowsComplete(
                requiredApprovals: 1,
                context: .myOpenWaitingOnReviewers
            )
        )
    }

    func testMyOpenPendingReviewShowsInReviewStatus() throws {
        let response = try decodeResponse(
            #"""
            {
              "data": {
                "viewer": { "login": "alice" },
                "awaiting": { "issueCount": 0, "nodes": [] },
                "reviewed": { "issueCount": 0, "nodes": [] },
                "myOpen": {
                  "issueCount": 1,
                  "nodes": [
                    {
                      "number": 303,
                      "title": "Reviewer started but not submitted",
                      "url": "https://github.com/acme/repo/pull/303",
                      "updatedAt": "2026-04-19T11:00:00Z",
                      "author": { "login": "alice" },
                      "repository": { "nameWithOwner": "acme/repo" },
                      "reviews": {
                        "nodes": [
                          { "state": "PENDING", "submittedAt": "2026-04-19T10:00:00Z", "author": { "login": "bob" } }
                        ]
                      },
                      "commits": { "nodes": [ { "commit": { "committedDate": "2026-04-19T09:00:00Z" } } ] }
                    }
                  ]
                }
              }
            }
            """#
        )

        let graphData = try XCTUnwrap(response.data)
        let buckets = ReviewBucketsBuilder().build(from: graphData, host: "github.com", requiredApprovals: 2)
        let pr = try XCTUnwrap(buckets.myOpenWaitingOnReviewers.first)
        XCTAssertEqual(
            pr.displayState(requiredApprovals: 2, context: .myOpenWaitingOnReviewers),
            .pending
        )
    }

    func testBlockedAndEnoughApprovalBucketsSortAndDisplayState() throws {
        let response = try decodeResponse(
            #"""
            {
              "data": {
                "viewer": { "login": "alice" },
                "awaiting": { "issueCount": 0, "nodes": [] },
                "reviewed": { "issueCount": 0, "nodes": [] },
                "myOpen": {
                  "issueCount": 4,
                  "nodes": [
                    {
                      "number": 401,
                      "title": "Older blocked PR",
                      "url": "https://github.com/acme/repo/pull/401",
                      "updatedAt": "2026-04-19T08:00:00Z",
                      "author": { "login": "alice" },
                      "repository": { "nameWithOwner": "acme/repo" },
                      "reviews": { "nodes": [ { "state": "CHANGES_REQUESTED", "submittedAt": "2026-04-19T07:00:00Z", "author": { "login": "bob" } } ] },
                      "commits": { "nodes": [ { "commit": { "committedDate": "2026-04-19T06:00:00Z" } } ] }
                    },
                    {
                      "number": 402,
                      "title": "Newer blocked PR",
                      "url": "https://github.com/acme/repo/pull/402",
                      "updatedAt": "2026-04-19T09:00:00Z",
                      "author": { "login": "alice" },
                      "repository": { "nameWithOwner": "acme/repo" },
                      "reviews": { "nodes": [ { "state": "CHANGES_REQUESTED", "submittedAt": "2026-04-19T08:30:00Z", "author": { "login": "carol" } } ] },
                      "commits": { "nodes": [ { "commit": { "committedDate": "2026-04-19T08:00:00Z" } } ] }
                    },
                    {
                      "number": 403,
                      "title": "Most recent ready PR",
                      "url": "https://github.com/acme/repo/pull/403",
                      "updatedAt": "2026-04-19T11:00:00Z",
                      "author": { "login": "alice" },
                      "repository": { "nameWithOwner": "acme/repo" },
                      "reviews": {
                        "nodes": [
                          { "state": "APPROVED", "submittedAt": "2026-04-19T09:00:00Z", "author": { "login": "bob" } },
                          { "state": "APPROVED", "submittedAt": "2026-04-19T09:15:00Z", "author": { "login": "carol" } }
                        ]
                      },
                      "commits": { "nodes": [ { "commit": { "committedDate": "2026-04-19T08:00:00Z" } } ] }
                    },
                    {
                      "number": 404,
                      "title": "Older ready PR",
                      "url": "https://github.com/acme/repo/pull/404",
                      "updatedAt": "2026-04-19T10:00:00Z",
                      "author": { "login": "alice" },
                      "repository": { "nameWithOwner": "acme/repo" },
                      "reviews": {
                        "nodes": [
                          { "state": "APPROVED", "submittedAt": "2026-04-19T08:00:00Z", "author": { "login": "dave" } },
                          { "state": "APPROVED", "submittedAt": "2026-04-19T08:15:00Z", "author": { "login": "erin" } }
                        ]
                      },
                      "commits": { "nodes": [ { "commit": { "committedDate": "2026-04-19T07:00:00Z" } } ] }
                    }
                  ]
                }
              }
            }
            """#
        )

        let graphData = try XCTUnwrap(response.data)
        let buckets = ReviewBucketsBuilder().build(from: graphData, host: "github.com", requiredApprovals: 2)

        XCTAssertEqual(buckets.myOpenBlockedOnYou.map(\.number), [402, 401])
        XCTAssertEqual(buckets.myOpenWaitingToBeMerged.map(\.number), [403, 404])
        XCTAssertTrue(buckets.myOpenOnMergeQueue.isEmpty)

        let blocked = try XCTUnwrap(buckets.myOpenBlockedOnYou.first)
        XCTAssertEqual(
            blocked.displayState(requiredApprovals: 2, context: .myOpenBlockedOnYou),
            .changesRequested
        )
        XCTAssertFalse(
            blocked.approvalBadgeShowsComplete(
                requiredApprovals: 2,
                context: .myOpenBlockedOnYou
            )
        )

        let ready = try XCTUnwrap(buckets.myOpenWaitingToBeMerged.first)
        XCTAssertEqual(
            ready.displayState(requiredApprovals: 2, context: .myOpenWaitingToBeMerged),
            .approved
        )
        XCTAssertTrue(
            ready.approvalBadgeShowsComplete(
                requiredApprovals: 2,
                context: .myOpenWaitingToBeMerged
            )
        )
    }

    func testNeedsReReviewContextAlwaysShowsReReviewState() throws {
        let response = try decodeResponse(
            #"""
            {
              "data": {
                "viewer": { "login": "alice" },
                "awaiting": { "issueCount": 0, "nodes": [] },
                "reviewed": {
                  "issueCount": 1,
                  "nodes": [
                    {
                      "number": 405,
                      "title": "Changes requested then changed",
                      "url": "https://github.com/acme/repo/pull/405",
                      "updatedAt": "2026-04-19T11:00:00Z",
                      "author": { "login": "bob" },
                      "repository": { "nameWithOwner": "acme/repo" },
                      "reviews": { "nodes": [ { "state": "CHANGES_REQUESTED", "submittedAt": "2026-04-19T08:00:00Z", "author": { "login": "alice" } } ] },
                      "commits": { "nodes": [ { "commit": { "committedDate": "2026-04-19T10:00:00Z" } } ] },
                      "timelineItems": { "nodes": [] }
                    }
                  ]
                },
                "myOpen": { "issueCount": 0, "nodes": [] }
              }
            }
            """#
        )

        let graphData = try XCTUnwrap(response.data)
        let buckets = ReviewBucketsBuilder().build(from: graphData, host: "github.com", requiredApprovals: 2)
        let pr = try XCTUnwrap(buckets.needsReReview.first)
        XCTAssertEqual(
            pr.displayState(requiredApprovals: 2, context: .needsReReview),
            .stale
        )
    }

    func testAuthorFallsBackToGhostWhenMissing() throws {
        let response = try decodeResponse(
            #"""
            {
              "data": {
                "viewer": { "login": "alice" },
                "awaiting": {
                  "issueCount": 1,
                  "nodes": [
                    {
                      "number": 99,
                      "title": "Ghost author",
                      "url": "https://github.com/acme/repo/pull/99",
                      "updatedAt": "2026-04-19T11:00:00Z",
                      "author": { "login": null },
                      "repository": { "nameWithOwner": "acme/repo" },
                      "reviews": { "nodes": [] },
                      "commits": { "nodes": [] },
                      "timelineItems": { "nodes": [] }
                    }
                  ]
                },
                "reviewed": { "issueCount": 0, "nodes": [] },
                "myOpen": { "issueCount": 0, "nodes": [] }
              }
            }
            """#
        )

        let graphData = try XCTUnwrap(response.data)
        let buckets = ReviewBucketsBuilder().build(from: graphData, host: "github.com", requiredApprovals: 2)
        let awaiting = try XCTUnwrap(buckets.needsReview.first)
        XCTAssertEqual(awaiting.author, "ghost")
    }

    func testBuilderPreservesDraftFlag() throws {
        let response = try decodeResponse(
            #"""
            {
              "data": {
                "viewer": { "login": "alice" },
                "awaiting": {
                  "issueCount": 1,
                  "nodes": [
                    {
                      "number": 110,
                      "title": "Draft feature",
                      "url": "https://github.com/acme/repo/pull/110",
                      "updatedAt": "2026-04-19T11:00:00Z",
                      "isDraft": true,
                      "author": { "login": "bob" },
                      "repository": { "nameWithOwner": "acme/repo" },
                      "reviews": { "nodes": [] },
                      "commits": { "nodes": [] },
                      "timelineItems": { "nodes": [] }
                    }
                  ]
                },
                "reviewed": { "issueCount": 0, "nodes": [] },
                "myOpen": { "issueCount": 0, "nodes": [] }
              }
            }
            """#
        )

        let graphData = try XCTUnwrap(response.data)
        let buckets = ReviewBucketsBuilder().build(from: graphData, host: "github.com", requiredApprovals: 2)
        XCTAssertEqual(buckets.needsReview.first?.isDraft, true)
        XCTAssertTrue(buckets.filtered(includeDrafts: false).needsReview.isEmpty)
    }

    func testDecodesNodeWithMissingReviewsAndCommitsConnections() throws {
        // GitHub can return PR nodes whose `reviews` / `commits` connections
        // are absent (or null) when a result in the search isn't fully
        // accessible. The decoder should treat these as empty rather than
        // failing with an opaque "data couldn't be read" error.
        let response = try decodeResponse(
            #"""
            {
              "data": {
                "viewer": { "login": "alice" },
                "awaiting": {
                  "issueCount": 1,
                  "nodes": [
                    {
                      "number": 77,
                      "title": "Inaccessible PR",
                      "url": "https://github.com/acme/repo/pull/77",
                      "updatedAt": "2026-04-19T11:00:00Z",
                      "author": { "login": "bob" },
                      "repository": { "nameWithOwner": "acme/repo" },
                      "reviews": null,
                      "commits": null
                    }
                  ]
                },
                "reviewed": { "issueCount": 0, "nodes": [] },
                "myOpen": { "issueCount": 0, "nodes": [] }
              }
            }
            """#
        )

        let graphData = try XCTUnwrap(response.data)
        let buckets = ReviewBucketsBuilder().build(from: graphData, host: "github.com", requiredApprovals: 2)
        let awaiting = try XCTUnwrap(buckets.needsReview.first)
        XCTAssertEqual(awaiting.number, 77)
        XCTAssertEqual(awaiting.approvals, 0)
        XCTAssertFalse(awaiting.updatedSinceReview)
    }

    func testDecodesNodeWithEmptyReviewsAndCommitsObjects() throws {
        // Same scenario as above but with the connections present as empty
        // objects (the older shape we used to require `nodes` for).
        let response = try decodeResponse(
            #"""
            {
              "data": {
                "viewer": { "login": "alice" },
                "awaiting": {
                  "issueCount": 1,
                  "nodes": [
                    {
                      "number": 78,
                      "title": "Empty connections",
                      "url": "https://github.com/acme/repo/pull/78",
                      "updatedAt": "2026-04-19T11:00:00Z",
                      "author": { "login": "bob" },
                      "repository": { "nameWithOwner": "acme/repo" },
                      "reviews": {},
                      "commits": {}
                    }
                  ]
                },
                "reviewed": { "issueCount": 0, "nodes": [] },
                "myOpen": { "issueCount": 0, "nodes": [] }
              }
            }
            """#
        )

        let graphData = try XCTUnwrap(response.data)
        let buckets = ReviewBucketsBuilder().build(from: graphData, host: "github.com", requiredApprovals: 2)
        XCTAssertEqual(buckets.needsReview.map(\.number), [78])
    }

    private func fixtureURL(named name: String) -> URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .appendingPathComponent("Fixtures")
            .appendingPathComponent("\(name).json")
    }

    private func decodeResponse(_ json: String) throws -> GitHubGraphQLResponse {
        let data = Data(json.utf8)
        return try JSONDecoder().decode(GitHubGraphQLResponse.self, from: data)
    }
}

private struct PendingReviewsFixture: Decodable {
    struct PullRequestFixture: Decodable {
        let number: Int
    }

    let user: String
    let host: String
    let needsReview: [PullRequestFixture]
    let needsReReview: [PullRequestFixture]
    let myOpenWaitingOnReviewers: [PullRequestFixture]
    let myOpenBlockedOnYou: [PullRequestFixture]
    let myOpenWaitingToBeMerged: [PullRequestFixture]
    let myOpenOnMergeQueue: [PullRequestFixture]

    enum CodingKeys: String, CodingKey {
        case user
        case host
        case needsReview = "needs_review"
        case needsReReview = "needs_rereview"
        case myOpenWaitingOnReviewers = "my_open_waiting_on_reviewers"
        case myOpenBlockedOnYou = "my_open_blocked_on_you"
        case myOpenWaitingToBeMerged = "my_open_waiting_to_be_merged"
        case myOpenOnMergeQueue = "my_open_on_merge_queue"
    }
}

