import XCTest
@testable import PRTracker

final class TitleParserTests: XCTestCase {
    func testExtractsTrailingKeyInParens() {
        let parsed = TitleParser.parse("feat(customHttp): Custom HTTP config outcome (BWP-23902)")
        XCTAssertEqual(parsed.title, "feat(customHttp): Custom HTTP config outcome")
        XCTAssertEqual(parsed.issueKey, "BWP-23902")
    }

    func testTolerantOfTrailingWhitespace() {
        let parsed = TitleParser.parse("feat: thing (ABC-1)   ")
        XCTAssertEqual(parsed.title, "feat: thing")
        XCTAssertEqual(parsed.issueKey, "ABC-1")
    }

    func testIgnoresMidStringParens() {
        let parsed = TitleParser.parse("feat(triggers): add custom repeat options")
        XCTAssertEqual(parsed.title, "feat(triggers): add custom repeat options")
        XCTAssertNil(parsed.issueKey)
    }

    func testIgnoresLowercaseToken() {
        let parsed = TitleParser.parse("feat: rename (foo-123)")
        XCTAssertEqual(parsed.title, "feat: rename (foo-123)")
        XCTAssertNil(parsed.issueKey)
    }

    func testIgnoresKeyMissingDigits() {
        let parsed = TitleParser.parse("feat: a (BWP-)")
        XCTAssertEqual(parsed.title, "feat: a (BWP-)")
        XCTAssertNil(parsed.issueKey)
    }

    func testReturnsTrimmedTitleWhenNoKey() {
        let parsed = TitleParser.parse("   plain title  ")
        XCTAssertEqual(parsed.title, "plain title")
        XCTAssertNil(parsed.issueKey)
    }

    func testKeepsTitleWhenStrippingWouldEmpty() {
        let parsed = TitleParser.parse("(BWP-1)")
        XCTAssertEqual(parsed.title, "(BWP-1)")
        XCTAssertEqual(parsed.issueKey, "BWP-1")
    }
}
