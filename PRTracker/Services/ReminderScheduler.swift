import Foundation

protocol ReminderScheduling {
    func update(
        reminders: [PullRequestReminder],
        now: Date,
        onDue: @escaping @Sendable ([PullRequestReminder]) async -> Void
    ) async
    func stop() async
}

actor ReminderScheduler: ReminderScheduling {
    private var scheduledTask: Task<Void, Never>?

    deinit {
        scheduledTask?.cancel()
    }

    func update(
        reminders: [PullRequestReminder],
        now: Date = Date(),
        onDue: @escaping @Sendable ([PullRequestReminder]) async -> Void
    ) {
        scheduledTask?.cancel()
        scheduledTask = nil

        let sorted = reminders.sorted { lhs, rhs in
            if lhs.scheduledAt != rhs.scheduledAt {
                return lhs.scheduledAt < rhs.scheduledAt
            }
            return lhs.id < rhs.id
        }

        let dueNow = sorted.filter { $0.scheduledAt <= now }
        if dueNow.isEmpty == false {
            Task {
                await onDue(dueNow)
            }
        }

        guard let nextDueDate = sorted.first(where: { $0.scheduledAt > now })?.scheduledAt else {
            return
        }

        scheduledTask = Task {
            let waitInterval = max(0, nextDueDate.timeIntervalSince(Date()))
            if waitInterval > 0 {
                do {
                    try await Task.sleep(nanoseconds: nanoseconds(from: waitInterval))
                } catch {
                    return
                }
            }

            guard Task.isCancelled == false else { return }

            let due = sorted.filter { $0.scheduledAt <= Date() }
            guard due.isEmpty == false else { return }
            await onDue(due)
        }
    }

    func stop() {
        scheduledTask?.cancel()
        scheduledTask = nil
    }

    private func nanoseconds(from interval: TimeInterval) -> UInt64 {
        let maxSeconds = Double(UInt64.max) / 1_000_000_000
        let bounded = min(max(interval, 0), maxSeconds)
        return UInt64(bounded * 1_000_000_000)
    }
}
