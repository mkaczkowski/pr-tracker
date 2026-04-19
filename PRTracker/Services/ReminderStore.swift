import Foundation

protocol ReminderStoring {
    func loadReminders() async -> [PullRequestReminder]
    func upsert(_ reminder: PullRequestReminder) async
    func removeReminder(for key: PullRequestReminderKey) async
    func removeReminders(for keys: Set<PullRequestReminderKey>) async
}

actor ReminderStore: ReminderStoring {
    private let defaults: UserDefaults
    private let key = "prReminders.v1"

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    func loadReminders() -> [PullRequestReminder] {
        loadPersistedState()
    }

    func upsert(_ reminder: PullRequestReminder) {
        var remindersByKey = Dictionary(
            uniqueKeysWithValues: loadPersistedState().map { ($0.key, $0) }
        )
        remindersByKey[reminder.key] = reminder
        savePersistedState(Array(remindersByKey.values))
    }

    func removeReminder(for key: PullRequestReminderKey) {
        removeReminders(for: [key])
    }

    func removeReminders(for keys: Set<PullRequestReminderKey>) {
        guard keys.isEmpty == false else { return }
        let remaining = loadPersistedState().filter { keys.contains($0.key) == false }
        savePersistedState(remaining)
    }

    private func loadPersistedState() -> [PullRequestReminder] {
        guard let data = defaults.data(forKey: key) else {
            return []
        }

        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        guard let reminders = try? decoder.decode([PullRequestReminder].self, from: data) else {
            return []
        }

        let remindersByKey = Dictionary(uniqueKeysWithValues: reminders.map { ($0.key, $0) })
        return Array(remindersByKey.values)
    }

    private func savePersistedState(_ reminders: [PullRequestReminder]) {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601

        let sorted = reminders.sorted { lhs, rhs in
            if lhs.scheduledAt != rhs.scheduledAt {
                return lhs.scheduledAt < rhs.scheduledAt
            }
            return lhs.id < rhs.id
        }

        guard let data = try? encoder.encode(sorted) else { return }
        defaults.set(data, forKey: key)
    }
}
