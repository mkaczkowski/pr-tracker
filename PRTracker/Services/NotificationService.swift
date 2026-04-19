import Foundation
import UserNotifications

protocol NotificationServing {
    func requestAuthorizationIfNeeded() async
    func postNotifications(from diff: SeenStateDiff, enabled: Bool) async
}

actor NotificationService: NotificationServing {
    private let center: UNUserNotificationCenter

    init(center: UNUserNotificationCenter = .current()) {
        self.center = center
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
                identifier: "awaiting-\(pr.id)-\(pr.lastCommitDate?.timeIntervalSince1970 ?? 0)"
            )
        }

        for pr in diff.newlyUpdatedSinceReview {
            await post(
                title: "PR updated after your review",
                subtitle: "\(pr.repository) #\(pr.number)",
                body: pr.title,
                identifier: "updated-\(pr.id)-\(pr.lastCommitDate?.timeIntervalSince1970 ?? 0)"
            )
        }
    }

    private func post(title: String, subtitle: String, body: String, identifier: String) async {
        let content = UNMutableNotificationContent()
        content.title = title
        content.subtitle = subtitle
        content.body = body
        content.sound = .default

        let request = UNNotificationRequest(identifier: identifier, content: content, trigger: nil)
        do {
            try await center.add(request)
        } catch {
            AppLog.ui.error("Failed to deliver notification: \(error.localizedDescription)")
        }
    }
}

