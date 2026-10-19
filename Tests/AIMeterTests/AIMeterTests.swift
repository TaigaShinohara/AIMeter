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

    func testStartOfMonthAndPeriodTimestampsAreUTC() {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = TimeZone(secondsFromGMT: 0)!
        let oct1 = cal.date(from: DateComponents(year: 2026, month: 10, day: 1, hour: 0, minute: 0, second: 0))!
        let oct19Start = cal.date(from: DateComponents(year: 2026, month: 10, day: 19, hour: 0, minute: 0, second: 0))!
        let midMonth = cal.date(from: DateComponents(year: 2026, month: 10, day: 19, hour: 15, minute: 30, second: 0))!

        XCTAssertEqual(UsageParser.startTimestamp(for: .monthly, now: midMonth), Int(oct1.timeIntervalSince1970))
        XCTAssertEqual(UsageParser.startTimestamp(for: .daily, now: midMonth), Int(oct19Start.timeIntervalSince1970))
        XCTAssertEqual(UsageParser.startTimestamp(for: .fiveHours, now: midMonth), Int(midMonth.timeIntervalSince1970) - 5 * 3600)
    }

    func testPeriodUsageMetricCalculationAndServerRateLimitSync() {
        let localMetric = PeriodUsageMetric(period: .fiveHours, usedTokens: 42_000, limitTokens: 150_000)
        XCTAssertEqual(localMetric.remainingTokens, 108_000)
        XCTAssertEqual(localMetric.remainingPercent, 72)

        // Server rate limit sync (e.g. 56% used -> 44% remaining)
        let syncedMetric = PeriodUsageMetric(
            period: .weekly,
            usedTokens: 160_000_000,
            limitTokens: 200_000_000,
            serverUsedPercent: 56.0,
            resetTimestamp: 1792888154
        )
        XCTAssertEqual(syncedMetric.remainingPercent, 44)
        XCTAssertEqual(syncedMetric.effectiveLimitTokens, 285_714_286)
    }

    func testDecodeMultiPeriodLocalUsageJSON() throws {
        let json = """
        {
          "openaiUsedTokens": 170218895,
          "openaiCostUSD": 460.66,
          "openaiUsedByPeriod": {
            "5h": 21556465,
            "1d": 40036059,
            "7d": 160952376,
            "30d": 170218895
          },
          "openaiServerUsedPercentByPeriod": {
            "7d": 56.0
          },
          "openaiResetAtByPeriod": {
            "7d": 1792888154
          },
          "openaiPlanType": "prolite",
          "geminiUsedTokens": 2296092,
          "geminiCostUSD": 4.95,
          "geminiUsedByPeriod": {
            "5h": 535813,
            "1d": 535813,
            "7d": 535813,
            "30d": 2296092
          }
        }
        """.data(using: .utf8)!

        let decoded = try JSONDecoder().decode(LocalUsageData.self, from: json)
        XCTAssertEqual(decoded.openaiUsedByPeriod?.fiveHours, 21556465)
        XCTAssertEqual(decoded.openaiServerUsedPercentByPeriod?.weekly, 56.0)
        XCTAssertEqual(decoded.openaiResetAtByPeriod?.weekly, 1792888154)
        XCTAssertEqual(decoded.openaiPlanType, "prolite")
    }

    func testParseOpenAIUsagePageAndPagination() throws {
        let sampleJSON = """
        {
          "object": "page",
          "data": [
            {
              "start_time": 1790812800,
              "end_time": 1790899200,
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

        let parsed = try UsageParser.parseOpenAIUsagePageWithBuckets(data: sampleJSON)
        XCTAssertEqual(parsed.totalTokens, 2250)
        XCTAssertEqual(parsed.buckets.count, 1)
        XCTAssertEqual(parsed.buckets.first?.tokens, 2250)
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
