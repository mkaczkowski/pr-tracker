import Foundation
import XCTest
@testable import PRTracker

final class ReminderSchedulerTests: XCTestCase {
    func testUpdateImmediatelyEmitsOverdueReminders() async {
        let scheduler = ReminderScheduler()
        let overdue = makeReminder(number: 10, scheduledAt: Date().addingTimeInterval(-60))
        let capture = ReminderCapture()

        await scheduler.update(reminders: [overdue], now: Date()) { reminders in
            await capture.append(reminders)
        }

        try? await Task.sleep(nanoseconds: 80_000_000)

        let count = await capture.count
        let firstIDs = await capture.firstIDs
        XCTAssertEqual(count, 1)
        XCTAssertEqual(firstIDs, [overdue.id])
    }

    func testScheduledReminderFiresOnlyOnce() async {
        let scheduler = ReminderScheduler()
        let reminder = makeReminder(number: 20, scheduledAt: Date().addingTimeInterval(0.12))
        let capture = ReminderCapture()

        await scheduler.update(reminders: [reminder], now: Date()) { reminders in
            await capture.append(reminders)
        }

        try? await Task.sleep(nanoseconds: 420_000_000)

        let count = await capture.count
        let firstIDs = await capture.firstIDs
        XCTAssertEqual(count, 1)
        XCTAssertEqual(firstIDs, [reminder.id])
    }

    private func makeReminder(number: Int, scheduledAt: Date) -> PullRequestReminder {
        PullRequestReminder(
            key: PullRequestReminderKey(
                host: "github.com",
                repository: "acme/repo",
                number: number
            ),
            title: "Reminder",
            url: URL(string: "https://github.com/acme/repo/pull/\(number)"),
            author: "bob",
            scheduledAt: scheduledAt,
            createdAt: Date()
        )
    }
}

private actor ReminderCapture {
    private var received: [[PullRequestReminder]] = []

    func append(_ reminders: [PullRequestReminder]) {
        received.append(reminders)
    }

    var count: Int {
        received.count
    }

    var firstIDs: [String] {
        received.first?.map(\.id) ?? []
    }
}
