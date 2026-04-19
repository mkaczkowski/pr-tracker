import Foundation
import ServiceManagement

enum LaunchAtLoginError: Error, LocalizedError {
    case unavailable
    case failed(String)

    var errorDescription: String? {
        switch self {
        case .unavailable:
            return "Launch at login is unavailable on this system."
        case let .failed(message):
            return message
        }
    }
}

@MainActor
protocol LaunchAtLoginServing {
    func setEnabled(_ enabled: Bool) throws
}

@MainActor
final class LaunchAtLoginService: LaunchAtLoginServing {
    func setEnabled(_ enabled: Bool) throws {
        if #available(macOS 13.0, *) {
            do {
                if enabled {
                    try SMAppService.mainApp.register()
                } else {
                    try SMAppService.mainApp.unregister()
                }
            } catch {
                throw LaunchAtLoginError.failed(error.localizedDescription)
            }
        } else {
            throw LaunchAtLoginError.unavailable
        }
    }
}

