import Foundation

struct AppSettings: Codable, Hashable, Sendable {
    struct Keys {
        static let host = "settings.host"
        static let org = "settings.org"
        static let requiredApprovals = "settings.requiredApprovals"
        static let refreshIntervalSeconds = "settings.refreshIntervalSeconds"
        static let includeDraftPullRequests = "settings.includeDraftPullRequests"
        static let notificationsEnabled = "settings.notificationsEnabled"
        static let launchAtLoginEnabled = "settings.launchAtLoginEnabled"
    }

    static let defaultHost = "github.com"
    static let defaultRequiredApprovals = 2
    static let defaultRefreshIntervalSeconds: Double = 300
    static let defaultIncludeDraftPullRequests = true
    static let defaultNotificationsEnabled = false
    static let defaultLaunchAtLoginEnabled = false

    var host: String
    var org: String
    var requiredApprovals: Int
    var refreshIntervalSeconds: Double
    var includeDraftPullRequests: Bool
    var notificationsEnabled: Bool
    var launchAtLoginEnabled: Bool

    static var `default`: AppSettings {
        AppSettings(
            host: defaultHost,
            org: "",
            requiredApprovals: defaultRequiredApprovals,
            refreshIntervalSeconds: defaultRefreshIntervalSeconds,
            includeDraftPullRequests: defaultIncludeDraftPullRequests,
            notificationsEnabled: defaultNotificationsEnabled,
            launchAtLoginEnabled: defaultLaunchAtLoginEnabled
        )
    }

    static func normalizedHost(_ host: String) -> String {
        let trimmed = host.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? defaultHost : trimmed
    }

    static func loginCommand(for host: String) -> String {
        let effectiveHost = normalizedHost(host)
        if effectiveHost.caseInsensitiveCompare("github.com") == .orderedSame {
            return "gh auth login"
        }
        return "gh auth login --hostname \(effectiveHost)"
    }

    static func fromUserDefaults(_ defaults: UserDefaults = .standard) -> AppSettings {
        let host = defaults.string(forKey: Keys.host)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? defaultHost
        let org = defaults.string(forKey: Keys.org) ?? ""
        let requiredApprovals = defaults.object(forKey: Keys.requiredApprovals) as? Int ?? defaultRequiredApprovals
        let refreshInterval = defaults.object(forKey: Keys.refreshIntervalSeconds) as? Double ?? defaultRefreshIntervalSeconds
        let includeDraftPullRequests = defaults.object(forKey: Keys.includeDraftPullRequests) as? Bool ?? defaultIncludeDraftPullRequests
        let notificationsEnabled = defaults.object(forKey: Keys.notificationsEnabled) as? Bool ?? defaultNotificationsEnabled
        let launchAtLoginEnabled = defaults.object(forKey: Keys.launchAtLoginEnabled) as? Bool ?? defaultLaunchAtLoginEnabled

        return AppSettings(
            host: normalizedHost(host),
            org: org,
            requiredApprovals: max(1, requiredApprovals),
            refreshIntervalSeconds: max(60, refreshInterval),
            includeDraftPullRequests: includeDraftPullRequests,
            notificationsEnabled: notificationsEnabled,
            launchAtLoginEnabled: launchAtLoginEnabled
        )
    }
}

