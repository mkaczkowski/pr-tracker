import OSLog

enum AppLog {
    static let auth = Logger(subsystem: "PRTracker", category: "auth")
    static let network = Logger(subsystem: "PRTracker", category: "network")
    static let refresh = Logger(subsystem: "PRTracker", category: "refresh")
    static let ui = Logger(subsystem: "PRTracker", category: "ui")
}

