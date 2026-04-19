import AppKit
import Foundation
import UserNotifications

protocol NotificationServing {
    func requestAuthorizationIfNeeded() async
    func postNotifications(from diff: SeenStateDiff, enabled: Bool) async
    func postReminderNotifications(_ reminders: [PullRequestReminder], enabled: Bool) async
}

actor NotificationService: NotificationServing {
    private static let pullRequestURLKey = "pullRequestURL"
    private let center: UNUserNotificationCenter
    private let tapDelegate = NotificationTapDelegate()

    init(center: UNUserNotificationCenter = .current()) {
        self.center = center
        center.delegate = tapDelegate
    }

    func requestAuthorizationIfNeeded() async {
        do {
            _ = try await center.requestAuthorization(options: [.alert, .sound, .badge])
        } catch {
            AppLog.ui.error("Failed to request notifications: \(error.localizedDescription)")
        }
    }

    func postNotifications(
        from diff: SeenStateDiff,
        enabled: Bool
    ) async {
        guard enabled else { return }

        for pr in diff.newlyAwaiting {
            await post(
                title: "New PR awaiting your review",
                subtitle: "\(pr.repository) #\(pr.number)",
                body: pr.title,
                identifier: "awaiting-\(pr.id)-\(pr.lastCommitDate?.timeIntervalSince1970 ?? 0)",
                pullRequestURL: pr.url
            )
        }

        for pr in diff.newlyUpdatedSinceReview {
            await post(
                title: "PR updated after your review",
                subtitle: "\(pr.repository) #\(pr.number)",
                body: pr.title,
                identifier: "updated-\(pr.id)-\(pr.lastCommitDate?.timeIntervalSince1970 ?? 0)",
                pullRequestURL: pr.url
            )
        }
    }

    func postReminderNotifications(_ reminders: [PullRequestReminder], enabled: Bool) async {
        guard enabled else { return }

        for reminder in reminders {
            await post(
                title: "PR reminder",
                subtitle: "\(reminder.repository) #\(reminder.number)",
                body: reminder.title,
                identifier: "reminder-\(reminder.id)-\(reminder.scheduledAt.timeIntervalSince1970)",
                pullRequestURL: reminder.url
            )
        }
    }

    private func post(
        title: String,
        subtitle: String,
        body: String,
        identifier: String,
        pullRequestURL: URL?
    ) async {
        let content = UNMutableNotificationContent()
        content.title = title
        content.subtitle = subtitle
        content.body = body
        content.sound = .default
        if let pullRequestURL {
            content.userInfo[Self.pullRequestURLKey] = pullRequestURL.absoluteString
        }

        let request = UNNotificationRequest(identifier: identifier, content: content, trigger: nil)
        do {
            try await center.add(request)
        } catch {
            AppLog.ui.error("Failed to deliver notification: \(error.localizedDescription)")
        }
    }
}

private final class NotificationTapDelegate: NSObject, UNUserNotificationCenterDelegate {
    func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        didReceive response: UNNotificationResponse
    ) async {
        guard
            let rawURL = response.notification.request.content.userInfo["pullRequestURL"] as? String,
            let url = URL(string: rawURL)
        else {
            return
        }

        await MainActor.run {
            NSWorkspace.shared.open(url)
        }
    }
}

