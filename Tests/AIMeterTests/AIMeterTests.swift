import XCTest
@testable import AIMeter

final class AIMeterTests: XCTestCase {
    func testFormatTokenCount() {
        XCTAssertEqual(formatTokenCount(0), "0")
        XCTAssertEqual(formatTokenCount(-50), "0")
        XCTAssertEqual(formatTokenCount(999), "999")
        XCTAssertEqual(formatTokenCount(1_500), "1.5K")
        XCTAssertEqual(formatTokenCount(640_000), "640.0K")
        XCTAssertEqual(formatTokenCount(1_250_000), "1.25M")
        XCTAssertEqual(formatTokenCount(10_000_000), "10.00M")
    }

    func testGaugeWarningSymbolAndColorThresholds() {
        XCTAssertNil(gaugeWarningSymbol(for: 0.80))
        XCTAssertNil(gaugeWarningSymbol(for: 0.35))
        XCTAssertEqual(gaugeWarningSymbol(for: 0.34), "exclamationmark.triangle.fill")
        XCTAssertEqual(gaugeWarningSymbol(for: 0.15), "exclamationmark.triangle.fill")
        XCTAssertEqual(gaugeWarningSymbol(for: 0.14), "exclamationmark.octagon.fill")
    }

    func testStartOfMonthUnixTimestampIsUTC() {
        // 2026-10-19T12:00:00Z -> start of month should be 2026-10-01T00:00:00Z (1790812800)
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = TimeZone(secondsFromGMT: 0)!
        let oct1 = cal.date(from: DateComponents(year: 2026, month: 10, day: 1, hour: 0, minute: 0, second: 0))!
        let midMonth = cal.date(from: DateComponents(year: 2026, month: 10, day: 19, hour: 15, minute: 30, second: 0))!
        XCTAssertEqual(UsageParser.startOfMonthUnixTimestamp(for: midMonth), Int(oct1.timeIntervalSince1970))
    }

    func testParseOpenAIUsagePageAndPagination() throws {
        let sampleJSON = """
        {
          "object": "page",
          "data": [
            {
              "results": [
                {"input_tokens": 1200, "output_tokens": 300},
                {"input_tokens": "500", "output_tokens": 250}
              ]
            }
          ],
          "has_more": true,
          "next_page": "page_abc123"
        }
        """.data(using: .utf8)!

        let parsed = try UsageParser.parseOpenAIUsagePage(data: sampleJSON)
        XCTAssertEqual(parsed.tokens, 2250)
        XCTAssertEqual(parsed.nextPage, "page_abc123")
    }

    func testParseOpenAICostsPageSupportsNumericAndStringAmounts() throws {
        let sampleJSON = """
        {
          "object": "page",
          "data": [
            {
              "results": [
                {"amount": {"value": 1.25, "currency": "usd"}},
                {"amount": {"value": "2.75", "currency": "usd"}}
              ]
            }
          ],
          "has_more": false,
          "next_page": "ignored_when_has_more_false"
        }
        """.data(using: .utf8)!

        let parsed = try UsageParser.parseOpenAICostsPage(data: sampleJSON)
        XCTAssertEqual(parsed.costUSD, 4.00, accuracy: 0.0001)
        XCTAssertNil(parsed.nextPage)
    }

    func testParseGeminiMonitoringSeries() throws {
        let sampleJSON = """
        {
          "timeSeries": [
            {
              "points": [
                {"value": {"int64Value": "15000"}},
                {"value": {"int64Value": 5000}}
              ]
            }
          ]
        }
        """.data(using: .utf8)!

        let total = try UsageParser.parseGeminiMonitoringSeries(data: sampleJSON)
        XCTAssertEqual(total, 20000)
    }
}
