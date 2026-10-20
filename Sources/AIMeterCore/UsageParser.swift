import Foundation

// MARK: - Pure Parsers & Calculations (Testable)
public enum UsageParser {
    public static func startOfMonthUnixTimestamp(for date: Date = Date()) -> Int {
        var utcCalendar = Calendar(identifier: .gregorian)
        utcCalendar.timeZone = TimeZone(secondsFromGMT: 0) ?? .gmt
        let components = utcCalendar.dateComponents([.year, .month], from: date)
        let startOfMonth = utcCalendar.date(from: components) ?? date
        return Int(startOfMonth.timeIntervalSince1970)
    }

    public static func startTimestamp(for period: LimitPeriod, now: Date = Date()) -> Int {
        var utcCalendar = Calendar(identifier: .gregorian)
        utcCalendar.timeZone = TimeZone(secondsFromGMT: 0) ?? .gmt
        switch period {
        case .twoHours:
            return Int(now.addingTimeInterval(-2 * 3600).timeIntervalSince1970)
        case .fiveHours:
            return Int(now.addingTimeInterval(-5 * 3600).timeIntervalSince1970)
        case .daily:
            let startOfDay = utcCalendar.startOfDay(for: now)
            return Int(startOfDay.timeIntervalSince1970)
        case .weekly:
            let sevenDaysAgo = utcCalendar.date(byAdding: .day, value: -6, to: utcCalendar.startOfDay(for: now)) ?? now.addingTimeInterval(-7 * 86400)
            return Int(sevenDaysAgo.timeIntervalSince1970)
        case .monthly:
            return startOfMonthUnixTimestamp(for: now)
        }
    }

    public struct BucketTokenRecord: Equatable {
        public let startTime: Int
        public let endTime: Int
        public let tokens: Int

        public init(startTime: Int, endTime: Int, tokens: Int) {
            self.startTime = startTime
            self.endTime = endTime
            self.tokens = tokens
        }
    }

    public static func parseOpenAIUsagePageWithBuckets(data: Data) throws -> (buckets: [BucketTokenRecord], totalTokens: Int, nextPage: String?) {
        guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw URLError(.cannotParseResponse)
        }
        var totalTokens = 0
        var records: [BucketTokenRecord] = []
        if let buckets = json["data"] as? [[String: Any]] {
            for bucket in buckets {
                let bStart = parseIntValue(bucket["start_time"])
                let bEnd = parseIntValue(bucket["end_time"])
                var bucketTokens = 0
                if let results = bucket["results"] as? [[String: Any]] {
                    for res in results {
                        let input = parseIntValue(res["input_tokens"])
                        let output = parseIntValue(res["output_tokens"])
                        bucketTokens += (input + output)
                    }
                }
                totalTokens += bucketTokens
                records.append(BucketTokenRecord(startTime: bStart, endTime: bEnd, tokens: bucketTokens))
            }
        }
        let hasMore = (json["has_more"] as? Bool) ?? true
        let nextPage = hasMore ? (json["next_page"] as? String) : nil
        return (records, totalTokens, (nextPage?.isEmpty == false) ? nextPage : nil)
    }

    public static func parseOpenAIUsagePage(data: Data) throws -> (tokens: Int, nextPage: String?) {
        let parsed = try parseOpenAIUsagePageWithBuckets(data: data)
        return (parsed.totalTokens, parsed.nextPage)
    }

    public static func parseOpenAICostsPage(data: Data) throws -> (costUSD: Double, nextPage: String?) {
        guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw URLError(.cannotParseResponse)
        }
        var totalCost = 0.0
        if let buckets = json["data"] as? [[String: Any]] {
            for bucket in buckets {
                if let results = bucket["results"] as? [[String: Any]] {
                    for res in results {
                        if let amountObj = res["amount"] as? [String: Any] {
                            totalCost += parseDoubleValue(amountObj["value"])
                        }
                    }
                }
            }
        }
        let hasMore = (json["has_more"] as? Bool) ?? true
        let nextPage = hasMore ? (json["next_page"] as? String) : nil
        return (totalCost, (nextPage?.isEmpty == false) ? nextPage : nil)
    }

    public static func parseGeminiMonitoringSeries(data: Data) throws -> Int {
        guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw URLError(.cannotParseResponse)
        }
        guard let series = json["timeSeries"] as? [[String: Any]] else {
            return 0
        }
        var total = 0
        for item in series {
            if let points = item["points"] as? [[String: Any]] {
                for pt in points {
                    if let valObj = pt["value"] as? [String: Any] {
                        total += parseIntValue(valObj["int64Value"] ?? valObj["doubleValue"])
                    }
                }
            }
        }
        return total
    }

    public static func parseIntValue(_ anyVal: Any?) -> Int {
        if let intVal = anyVal as? Int {
            return intVal
        } else if let numVal = anyVal as? NSNumber {
            return numVal.intValue
        } else if let strVal = anyVal as? String, let parsed = Int(strVal) {
            return parsed
        } else if let strVal = anyVal as? String, let parsedDouble = Double(strVal) {
            return Int(parsedDouble.rounded())
        }
        return 0
    }

    public static func parseDoubleValue(_ anyVal: Any?) -> Double {
        if let dblVal = anyVal as? Double {
            return dblVal
        } else if let intVal = anyVal as? Int {
            return Double(intVal)
        } else if let numVal = anyVal as? NSNumber {
            return numVal.doubleValue
        } else if let strVal = anyVal as? String, let parsed = Double(strVal) {
            return parsed
        }
        return 0.0
    }
}
