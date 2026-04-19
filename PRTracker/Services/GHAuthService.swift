import Foundation

enum AuthError: Error, Equatable, LocalizedError, Sendable {
    case notInstalled
    case notAuthenticated(host: String)
    case staleCredentials(host: String)
    case failed(message: String)

    var errorDescription: String? {
        switch self {
        case .notInstalled:
            return "GitHub CLI (`gh`) is not installed."
        case let .notAuthenticated(host):
            return "Not authenticated for \(host). Run: \(AppSettings.loginCommand(for: host))"
        case let .staleCredentials(host):
            return "Existing credentials for \(host) are stale or invalid."
        case let .failed(message):
            return message
        }
    }
}

actor GHAuthService {
    private let processSpawner: ProcessSpawning
    private let fileManager: FileManager

    private var cachedGHPath: String?
    private var tokenCache: [String: String] = [:]

    init(
        processSpawner: ProcessSpawning = ProcessSpawner(),
        fileManager: FileManager = .default
    ) {
        self.processSpawner = processSpawner
        self.fileManager = fileManager
    }

    func invalidateCachedToken(for host: String? = nil) {
        if let host {
            tokenCache.removeValue(forKey: host)
        } else {
            tokenCache.removeAll()
        }
    }

    func token(for host: String) async throws -> String {
        if let token = tokenCache[host] {
            return token
        }

        let ghPath = try await discoverGHBinary()
        let result = try await processSpawner.run(
            executable: ghPath,
            arguments: ["auth", "token", "--hostname", host],
            environment: nil
        )

        guard result.exitCode == 0 else {
            let stderr = result.stderr.trimmingCharacters(in: .whitespacesAndNewlines)
            if stderr.localizedCaseInsensitiveContains("not logged in")
                || stderr.localizedCaseInsensitiveContains("not authenticated")
                || stderr.localizedCaseInsensitiveContains("authentication failed")
            {
                throw AuthError.notAuthenticated(host: host)
            }

            if stderr.localizedCaseInsensitiveContains("token is no longer valid")
                || stderr.localizedCaseInsensitiveContains("expired")
            {
                throw AuthError.staleCredentials(host: host)
            }

            throw AuthError.failed(message: stderr.isEmpty ? "Unable to fetch token from gh." : stderr)
        }

        let token = result.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
        guard token.isEmpty == false else {
            throw AuthError.notAuthenticated(host: host)
        }

        tokenCache[host] = token
        return token
    }

    private func discoverGHBinary() async throws -> String {
        if let cachedGHPath {
            return cachedGHPath
        }

        let candidates = [
            "~/.local/bin/gh",
            "/opt/homebrew/bin/gh",
            "/usr/local/bin/gh",
            "/usr/bin/gh"
        ]

        for candidate in candidates {
            let expanded = (candidate as NSString).expandingTildeInPath
            if fileManager.isExecutableFile(atPath: expanded) {
                cachedGHPath = expanded
                return expanded
            }
        }

        let whichResult = try await processSpawner.run(
            executable: "/bin/zsh",
            arguments: ["-lc", "command -v gh"],
            environment: nil
        )

        if whichResult.exitCode == 0 {
            let discovered = whichResult.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
            if discovered.isEmpty == false {
                cachedGHPath = discovered
                return discovered
            }
        }

        throw AuthError.notInstalled
    }
}

