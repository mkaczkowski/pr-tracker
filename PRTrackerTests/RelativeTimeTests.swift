import XCTest
@testable import PRTracker

final class RelativeTimeTests: XCTestCase {
    func testMinuteBucket() {
        let now = Date(timeIntervalSince1970: 10_000)
        let date = Date(timeIntervalSince1970: 9_940)
        XCTAssertEqual(RelativeTime.string(from: date, now: now), "1m")
    }

    func testHourBucket() {
        let now = Date(timeIntervalSince1970: 10_000)
        let date = Date(timeIntervalSince1970: 6_400)
        XCTAssertEqual(RelativeTime.string(from: date, now: now), "1h")
    }

    func testDayBucket() {
        let now = Date(timeIntervalSince1970: 500_000)
        let date = Date(timeIntervalSince1970: 400_000)
        XCTAssertEqual(RelativeTime.string(from: date, now: now), "1d")
    }

    func testMonthBucket() {
        let now = Date(timeIntervalSince1970: 3_000_000)
        let date = Date(timeIntervalSince1970: 100_000)
        XCTAssertEqual(RelativeTime.string(from: date, now: now), "1mo")
    }

    func testNilDate() {
        XCTAssertEqual(RelativeTime.string(from: nil), "-")
    }
}

@MainActor
final class RefreshSchedulerTests: XCTestCase {
    func testSchedulerRunsActionOnInterval() async throws {
        let scheduler = RefreshScheduler(minimumIntervalSeconds: 0.01, maximumBackoffSeconds: 0.05)
        var invocationCount = 0

        scheduler.start(intervalSeconds: 0.01) {
            invocationCount += 1
            return true
        }

        try await Task.sleep(nanoseconds: 45_000_000)
        scheduler.stop()

        XCTAssertGreaterThanOrEqual(invocationCount, 2)
    }

    func testStopPreventsFutureInvocations() async throws {
        let scheduler = RefreshScheduler(minimumIntervalSeconds: 0.01, maximumBackoffSeconds: 0.05)
        var invocationCount = 0

        scheduler.start(intervalSeconds: 0.01) {
            invocationCount += 1
            return true
        }

        try await Task.sleep(nanoseconds: 25_000_000)
        scheduler.stop()
        let countAtStop = invocationCount

        try await Task.sleep(nanoseconds: 40_000_000)
        XCTAssertEqual(invocationCount, countAtStop)
    }
}

