import Foundation

/// Splits a PR title into its display text and an optional trailing
/// Jira-style key. Keeps the parser narrow on purpose: only matches
/// a parenthesized `LETTERS-DIGITS` token at the very end of the
/// title so we never strip something that wasn't actually a key.
enum TitleParser {
    struct Parsed: Equatable, Sendable {
        let title: String
        let issueKey: String?
    }

    /// Matches ` (KEY-1234)` at end-of-string, where KEY is 2+ uppercase
    /// letters or digits and 1234 is one or more digits.
    private static let pattern: NSRegularExpression = {
        // swiftlint:disable:next force_try
        try! NSRegularExpression(pattern: #"\s*\(([A-Z][A-Z0-9]+-\d+)\)\s*$"#)
    }()

    static func parse(_ rawTitle: String) -> Parsed {
        let trimmed = rawTitle.trimmingCharacters(in: .whitespacesAndNewlines)
        let range = NSRange(trimmed.startIndex..<trimmed.endIndex, in: trimmed)

        guard let match = pattern.firstMatch(in: trimmed, range: range),
              match.numberOfRanges == 2,
              let keyRange = Range(match.range(at: 1), in: trimmed),
              let fullRange = Range(match.range(at: 0), in: trimmed)
        else {
            return Parsed(title: trimmed, issueKey: nil)
        }

        let key = String(trimmed[keyRange])
        let stripped = trimmed.replacingCharacters(in: fullRange, with: "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let cleaned = stripped.isEmpty ? trimmed : stripped
        return Parsed(title: cleaned, issueKey: key)
    }
}
