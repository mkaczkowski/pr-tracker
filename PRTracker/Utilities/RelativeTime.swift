import Foundation

enum RelativeTime {
    static func string(from date: Date?, now: Date = Date()) -> String {
        guard let date else { return "-" }
        let seconds = max(0, Int(now.timeIntervalSince(date)))

        if seconds < 3_600 {
            return "\(seconds / 60)m"
        }
        if seconds < 86_400 {
            return "\(seconds / 3_600)h"
        }
        if seconds < 2_592_000 {
            return "\(seconds / 86_400)d"
        }
        return "\(seconds / 2_592_000)mo"
    }
}

