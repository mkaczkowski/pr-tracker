import Foundation
import XCTest
@testable import PRTracker

final class ReminderStoreTests: XCTestCase {
    private var defaults: UserDefaults!
    private var suiteName: String!

    override func setUp() {
        super.setUp()
        suiteName = "ReminderStoreTests.\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suiteName)
    }

    override func tearDown() {
        defaults.removePersistentDomain(forName: suiteName)
        defaults = nil
        suiteName = nil
        super.tearDown()
    }

    func testUpsertLoadAndRemoveReminder() async {
        let store = ReminderStore(defaults: defaults)
        let first = makeReminder(number: 10)
        let second = makeReminder(number: 11)

        await store.upsert(first)
        await store.upsert(second)

        let loaded = await store.loadReminders()
        XCTAssertEqual(Set(loaded.map(\.id)), Set([first.id, second.id]))

        await store.removeReminder(for: first.key)
        let remaining = await store.loadReminders()
        XCTAssertEqual(remaining.map(\.id), [second.id])
    }

    func testUpsertReplacesExistingReminderForSamePR() async {
        let store = ReminderStore(defaults: defaults)
        let initial = makeReminder(number: 25, title: "Initial")
        let replacement = makeReminder(
            number: 25,
            title: "Replacement",
            scheduledAt: Date().addingTimeInterval(7_200)
        )

        await store.upsert(initial)
        await store.upsert(replacement)

        let loaded = await store.loadReminders()
        XCTAssertEqual(loaded.count, 1)
        XCTAssertEqual(loaded.first?.title, "Replacement")
        guard let savedScheduledAt = loaded.first?.scheduledAt else {
            return XCTFail("Expected stored reminder")
        }
        XCTAssertEqual(
            Int(savedScheduledAt.timeIntervalSince1970),
            Int(replacement.scheduledAt.timeIntervalSince1970)
        )
    }

    private func makeReminder(
        number: Int,
        title: String = "Reminder",
        scheduledAt: Date = Date().addingTimeInterval(3_600)
    ) -> PullRequestReminder {
        PullRequestReminder(
            key: PullRequestReminderKey(
                host: "github.com",
                repository: "acme/repo",
                number: number
            ),
            title: title,
            url: URL(string: "https://github.com/acme/repo/pull/\(number)"),
            author: "bob",
            scheduledAt: scheduledAt,
            createdAt: Date()
        )
    }
}
