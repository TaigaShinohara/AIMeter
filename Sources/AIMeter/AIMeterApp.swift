import SwiftUI
import AppKit
import Foundation
import Security

// MARK: - Limit Period Type
enum LimitPeriod: String, CaseIterable, Codable, Identifiable {
    case twoHours = "2h"
    case fiveHours = "5h"
    case daily = "1d"
    case weekly = "7d"
    case monthly = "30d"

    var id: String { rawValue }

    var label: String {
        switch self {
        case .twoHours: return "2時間"
        case .fiveHours: return "5時間"
        case .daily: return "1日"
        case .weekly: return "週次"
        case .monthly: return "月次"
        }
    }

    var shortLabel: String {
        switch self {
        case .twoHours: return "2h"
        case .fiveHours: return "5h"
        case .daily: return "1d"
        case .weekly: return "1w"
        case .monthly: return "1m"
        }
    }
}

// MARK: - Per-Period Usage & Limit Snapshot
struct PeriodUsageMetric: Equatable, Identifiable {
    let period: LimitPeriod
    var usedTokens: Int
    var limitTokens: Int
    var serverUsedPercent: Double? = nil
    var resetTimestamp: Int? = nil

    var id: String { period.rawValue }

    var effectiveLimitTokens: Int {
        if let pct = serverUsedPercent, pct > 0.5, usedTokens > 0 {
            return max(usedTokens, Int((Double(usedTokens) / (pct / 100.0)).rounded()))
        }
        return limitTokens
    }

    var remainingTokens: Int {
        if let pct = serverUsedPercent {
            let ratio = min(1.0, max(0.0, (100.0 - pct) / 100.0))
            if usedTokens > 0, pct > 0.5 {
                return max(0, effectiveLimitTokens - usedTokens)
            }
            return max(0, Int((Double(limitTokens) * ratio).rounded()))
        }
        return max(0, effectiveLimitTokens - usedTokens)
    }

    var remainingRatio: Double {
        if let pct = serverUsedPercent {
            return min(1.0, max(0.0, (100.0 - pct) / 100.0))
        }
        guard effectiveLimitTokens > 0 else { return 0 }
        return min(1.0, max(0.0, Double(remainingTokens) / Double(effectiveLimitTokens)))
    }

    var remainingPercent: Int {
        Int((remainingRatio * 100).rounded())
    }
}

// MARK: - Custom Subscription / Provider Configuration
struct CustomSubscriptionConfig: Codable, Identifiable, Equatable {
    var id: String
    var name: String
    var shortName: String
    var iconName: String
    var isEnabled: Bool
    var showInMenuBar: Bool
    var enabledPeriodRawValues: [String]

    var limit2h: Int = 500_000
    var limit5h: Int
    var limitDaily: Int
    var limitWeekly: Int
    var limitMonthly: Int

    var manualUsed2h: Int = 0
    var manualUsed5h: Int
    var manualUsedDaily: Int
    var manualUsedWeekly: Int
    var manualUsedMonthly: Int

    var usedCostUSD: Double
    var budgetUSD: Double
    var statusNote: String

    enum CodingKeys: String, CodingKey {
        case id, name, shortName, iconName, isEnabled, showInMenuBar, enabledPeriodRawValues
        case limit2h, limit5h, limitDaily, limitWeekly, limitMonthly
        case manualUsed2h, manualUsed5h, manualUsedDaily, manualUsedWeekly, manualUsedMonthly
        case usedCostUSD, budgetUSD, statusNote
    }

    init(
        id: String,
        name: String,
        shortName: String,
        iconName: String,
        isEnabled: Bool,
        showInMenuBar: Bool,
        enabledPeriodRawValues: [String],
        limit2h: Int = 500_000,
        limit5h: Int,
        limitDaily: Int,
        limitWeekly: Int,
        limitMonthly: Int,
        manualUsed2h: Int = 0,
        manualUsed5h: Int,
        manualUsedDaily: Int,
        manualUsedWeekly: Int,
        manualUsedMonthly: Int,
        usedCostUSD: Double,
        budgetUSD: Double,
        statusNote: String
    ) {
        self.id = id
        self.name = name
        self.shortName = shortName
        self.iconName = iconName
        self.isEnabled = isEnabled
        self.showInMenuBar = showInMenuBar
        self.enabledPeriodRawValues = enabledPeriodRawValues
        self.limit2h = limit2h
        self.limit5h = limit5h
        self.limitDaily = limitDaily
        self.limitWeekly = limitWeekly
        self.limitMonthly = limitMonthly
        self.manualUsed2h = manualUsed2h
        self.manualUsed5h = manualUsed5h
        self.manualUsedDaily = manualUsedDaily
        self.manualUsedWeekly = manualUsedWeekly
        self.manualUsedMonthly = manualUsedMonthly
        self.usedCostUSD = usedCostUSD
        self.budgetUSD = budgetUSD
        self.statusNote = statusNote
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(String.self, forKey: .id)
        name = try c.decode(String.self, forKey: .name)
        shortName = try c.decode(String.self, forKey: .shortName)
        iconName = try c.decodeIfPresent(String.self, forKey: .iconName) ?? "cpu.fill"
        isEnabled = try c.decodeIfPresent(Bool.self, forKey: .isEnabled) ?? true
        showInMenuBar = try c.decodeIfPresent(Bool.self, forKey: .showInMenuBar) ?? false
        enabledPeriodRawValues = try c.decodeIfPresent([String].self, forKey: .enabledPeriodRawValues) ?? ["30d"]
        limit5h = try c.decodeIfPresent(Int.self, forKey: .limit5h) ?? 500_000
        limit2h = try c.decodeIfPresent(Int.self, forKey: .limit2h) ?? max(1, limit5h / 2)
        limitDaily = try c.decodeIfPresent(Int.self, forKey: .limitDaily) ?? 2_000_000
        limitWeekly = try c.decodeIfPresent(Int.self, forKey: .limitWeekly) ?? 10_000_000
        limitMonthly = try c.decodeIfPresent(Int.self, forKey: .limitMonthly) ?? 30_000_000
        manualUsed2h = try c.decodeIfPresent(Int.self, forKey: .manualUsed2h) ?? 0
        manualUsed5h = try c.decodeIfPresent(Int.self, forKey: .manualUsed5h) ?? 0
        manualUsedDaily = try c.decodeIfPresent(Int.self, forKey: .manualUsedDaily) ?? 0
        manualUsedWeekly = try c.decodeIfPresent(Int.self, forKey: .manualUsedWeekly) ?? 0
        manualUsedMonthly = try c.decodeIfPresent(Int.self, forKey: .manualUsedMonthly) ?? 0
        usedCostUSD = try c.decodeIfPresent(Double.self, forKey: .usedCostUSD) ?? 0.0
        budgetUSD = try c.decodeIfPresent(Double.self, forKey: .budgetUSD) ?? 20.0
        statusNote = try c.decodeIfPresent(String.self, forKey: .statusNote) ?? ""
    }

    func isPeriodEnabled(_ period: LimitPeriod) -> Bool {
        enabledPeriodRawValues.contains(period.rawValue)
    }

    mutating func setPeriod(_ period: LimitPeriod, enabled: Bool) {
        if enabled {
            if !enabledPeriodRawValues.contains(period.rawValue) {
                enabledPeriodRawValues.append(period.rawValue)
            }
        } else if enabledPeriodRawValues.count > 1 {
            enabledPeriodRawValues.removeAll { $0 == period.rawValue }
        }
    }

    mutating func sanitize() {
        if name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { name = "Custom AI" }
        if shortName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { shortName = "AI" }
        if enabledPeriodRawValues.isEmpty { enabledPeriodRawValues = [LimitPeriod.monthly.rawValue] }
        if limit2h < 1 { limit2h = 1 }
        if limit5h < 1 { limit5h = 1 }
        if limitDaily < 1 { limitDaily = 1 }
        if limitWeekly < 1 { limitWeekly = 1 }
        if limitMonthly < 1 { limitMonthly = 1 }
        if manualUsed2h < 0 { manualUsed2h = 0 }
        if manualUsed5h < 0 { manualUsed5h = 0 }
        if manualUsedDaily < 0 { manualUsedDaily = 0 }
        if manualUsedWeekly < 0 { manualUsedWeekly = 0 }
        if manualUsedMonthly < 0 { manualUsedMonthly = 0 }
        if usedCostUSD < 0 { usedCostUSD = 0 }
        if budgetUSD < 0 { budgetUSD = 0 }
    }

    // 1. xAI Grok / GrokBot (2h burst + 1d cooldown + 7d compute pool)
    static func grokbotPreset() -> CustomSubscriptionConfig {
        CustomSubscriptionConfig(
            id: "grokbot",
            name: "Grok / GrokBot",
            shortName: "Grok",
            iconName: "sparkles",
            isEnabled: true,
            showInMenuBar: true,
            enabledPeriodRawValues: ["2h", "1d", "7d"],
            limit2h: 200_000,
            limit5h: 500_000,
            limitDaily: 1_500_000,
            limitWeekly: 10_000_000,
            limitMonthly: 40_000_000,
            manualUsed2h: 0,
            manualUsed5h: 0,
            manualUsedDaily: 0,
            manualUsedWeekly: 0,
            manualUsedMonthly: 0,
            usedCostUSD: 30.0,
            budgetUSD: 30.0,
            statusNote: "SuperGrok / Bot"
        )
    }

    // 2. Anthropic Claude (5h rolling window + 7d weekly ceiling)
    static func claudePreset() -> CustomSubscriptionConfig {
        CustomSubscriptionConfig(
            id: "claude",
            name: "Anthropic Claude",
            shortName: "Cld",
            iconName: "brain.head.profile",
            isEnabled: true,
            showInMenuBar: true,
            enabledPeriodRawValues: ["5h", "7d"],
            limit2h: 600_000,
            limit5h: 1_500_000,
            limitDaily: 4_000_000,
            limitWeekly: 15_000_000,
            limitMonthly: 45_000_000,
            manualUsed2h: 0,
            manualUsed5h: 0,
            manualUsedDaily: 0,
            manualUsedWeekly: 0,
            manualUsedMonthly: 0,
            usedCostUSD: 20.0,
            budgetUSD: 20.0,
            statusNote: "Pro / Max"
        )
    }

    // 3. Cursor (Daily burst + Monthly credit/token pool)
    static func cursorPreset() -> CustomSubscriptionConfig {
        CustomSubscriptionConfig(
            id: "cursor",
            name: "Cursor",
            shortName: "Cur",
            iconName: "terminal.fill",
            isEnabled: true,
            showInMenuBar: false,
            enabledPeriodRawValues: ["1d", "30d"],
            limit2h: 25,
            limit5h: 50,
            limitDaily: 50,
            limitWeekly: 200,
            limitMonthly: 500,
            manualUsed2h: 0,
            manualUsed5h: 0,
            manualUsedDaily: 0,
            manualUsedWeekly: 0,
            manualUsedMonthly: 0,
            usedCostUSD: 20.0,
            budgetUSD: 20.0,
            statusNote: "Pro / Ultra"
        )
    }

    // 4. Windsurf (Daily + Weekly rolling + Monthly flow pool)
    static func windsurfPreset() -> CustomSubscriptionConfig {
        CustomSubscriptionConfig(
            id: "windsurf",
            name: "Windsurf",
            shortName: "Wind",
            iconName: "wind",
            isEnabled: true,
            showInMenuBar: false,
            enabledPeriodRawValues: ["1d", "7d", "30d"],
            limit2h: 1_500,
            limit5h: 3_000,
            limitDaily: 5_000,
            limitWeekly: 20_000,
            limitMonthly: 50_000,
            manualUsed2h: 0,
            manualUsed5h: 0,
            manualUsedDaily: 0,
            manualUsedWeekly: 0,
            manualUsedMonthly: 0,
            usedCostUSD: 20.0,
            budgetUSD: 20.0,
            statusNote: "Pro"
        )
    }

    // 5. GitHub Copilot (Monthly 300-1500 Premium Requests / AI Credits)
    static func copilotPreset() -> CustomSubscriptionConfig {
        CustomSubscriptionConfig(
            id: "copilot",
            name: "GitHub Copilot",
            shortName: "Cop",
            iconName: "chevron.left.forwardslash.chevron.right",
            isEnabled: true,
            showInMenuBar: false,
            enabledPeriodRawValues: ["30d"],
            limit2h: 30,
            limit5h: 50,
            limitDaily: 100,
            limitWeekly: 150,
            limitMonthly: 300,
            manualUsed2h: 0,
            manualUsed5h: 0,
            manualUsedDaily: 0,
            manualUsedWeekly: 0,
            manualUsedMonthly: 0,
            usedCostUSD: 10.0,
            budgetUSD: 10.0,
            statusNote: "Premium Reqs"
        )
    }

    // 6. Devin (Daily + Weekly + Monthly ACU / usage limits)
    static func devinPreset() -> CustomSubscriptionConfig {
        CustomSubscriptionConfig(
            id: "devin",
            name: "Devin",
            shortName: "Dev",
            iconName: "cpu",
            isEnabled: true,
            showInMenuBar: false,
            enabledPeriodRawValues: ["1d", "7d", "30d"],
            limit2h: 5,
            limit5h: 10,
            limitDaily: 20,
            limitWeekly: 60,
            limitMonthly: 200,
            manualUsed2h: 0,
            manualUsed5h: 0,
            manualUsedDaily: 0,
            manualUsedWeekly: 0,
            manualUsedMonthly: 0,
            usedCostUSD: 20.0,
            budgetUSD: 20.0,
            statusNote: "ACU Pool"
        )
    }

    // 7. Perplexity Pro (Daily 300+ Pro searches + Monthly pool)
    static func perplexityPreset() -> CustomSubscriptionConfig {
        CustomSubscriptionConfig(
            id: "perplexity",
            name: "Perplexity Pro",
            shortName: "Pplx",
            iconName: "globe",
            isEnabled: true,
            showInMenuBar: false,
            enabledPeriodRawValues: ["1d", "30d"],
            limit2h: 60,
            limit5h: 150,
            limitDaily: 300,
            limitWeekly: 1_500,
            limitMonthly: 6_000,
            manualUsed2h: 0,
            manualUsed5h: 0,
            manualUsedDaily: 0,
            manualUsedWeekly: 0,
            manualUsedMonthly: 0,
            usedCostUSD: 20.0,
            budgetUSD: 20.0,
            statusNote: "Pro Search"
        )
    }

    // 8. DeepSeek (1d + 30d API token pool)
    static func deepseekPreset() -> CustomSubscriptionConfig {
        CustomSubscriptionConfig(
            id: "deepseek",
            name: "DeepSeek",
            shortName: "DS",
            iconName: "wave.3.right",
            isEnabled: true,
            showInMenuBar: false,
            enabledPeriodRawValues: ["1d", "30d"],
            limit2h: 1_000_000,
            limit5h: 2_500_000,
            limitDaily: 10_000_000,
            limitWeekly: 50_000_000,
            limitMonthly: 150_000_000,
            manualUsed2h: 0,
            manualUsed5h: 0,
            manualUsedDaily: 0,
            manualUsedWeekly: 0,
            manualUsedMonthly: 0,
            usedCostUSD: 10.0,
            budgetUSD: 20.0,
            statusNote: "V3 / R1 API"
        )
    }

    // 9. Poe (Daily / Monthly Compute Points: 1M points/mo)
    static func poePreset() -> CustomSubscriptionConfig {
        CustomSubscriptionConfig(
            id: "poe",
            name: "Poe",
            shortName: "Poe",
            iconName: "bubble.left.and.bubble.right",
            isEnabled: true,
            showInMenuBar: false,
            enabledPeriodRawValues: ["1d", "30d"],
            limit2h: 20_000,
            limit5h: 50_000,
            limitDaily: 100_000,
            limitWeekly: 300_000,
            limitMonthly: 1_000_000,
            manualUsed2h: 0,
            manualUsed5h: 0,
            manualUsedDaily: 0,
            manualUsedWeekly: 0,
            manualUsedMonthly: 0,
            usedCostUSD: 20.0,
            budgetUSD: 20.0,
            statusNote: "Compute Pts"
        )
    }

    // 10. Trae (Monthly Fast Queue)
    static func traePreset() -> CustomSubscriptionConfig {
        CustomSubscriptionConfig(
            id: "trae",
            name: "Trae AI",
            shortName: "Trae",
            iconName: "bolt.horizontal",
            isEnabled: true,
            showInMenuBar: false,
            enabledPeriodRawValues: ["30d"],
            limit2h: 30,
            limit5h: 60,
            limitDaily: 100,
            limitWeekly: 250,
            limitMonthly: 600,
            manualUsed2h: 0,
            manualUsed5h: 0,
            manualUsedDaily: 0,
            manualUsedWeekly: 0,
            manualUsedMonthly: 0,
            usedCostUSD: 10.0,
            budgetUSD: 10.0,
            statusNote: "Fast Queue"
        )
    }

    static func preset(forId id: String) -> CustomSubscriptionConfig? {
        switch id {
        case "grokbot": return .grokbotPreset()
        case "claude": return .claudePreset()
        case "cursor": return .cursorPreset()
        case "windsurf": return .windsurfPreset()
        case "copilot": return .copilotPreset()
        case "devin": return .devinPreset()
        case "perplexity": return .perplexityPreset()
        case "deepseek": return .deepseekPreset()
        case "poe": return .poePreset()
        case "trae": return .traePreset()
        default: return nil
        }
    }

    static func blankCustom() -> CustomSubscriptionConfig {
        let shortId = String(UUID().uuidString.prefix(6)).lowercased()
        return CustomSubscriptionConfig(
            id: "custom_\(shortId)",
            name: "新規サービス",
            shortName: "Sub",
            iconName: "cpu.fill",
            isEnabled: true,
            showInMenuBar: false,
            enabledPeriodRawValues: ["5h", "1d", "7d", "30d"],
            limit2h: 200_000,
            limit5h: 500_000,
            limitDaily: 2_000_000,
            limitWeekly: 10_000_000,
            limitMonthly: 30_000_000,
            manualUsed2h: 0,
            manualUsed5h: 0,
            manualUsedDaily: 0,
            manualUsedWeekly: 0,
            manualUsedMonthly: 0,
            usedCostUSD: 20.0,
            budgetUSD: 20.0,
            statusNote: ""
        )
    }
}

// MARK: - Local JSON Model
struct ProviderPeriodUsageJSON: Codable, Equatable {
    var twoHours: Int?
    var fiveHours: Int?
    var daily: Int?
    var weekly: Int?
    var monthly: Int?

    enum CodingKeys: String, CodingKey {
        case twoHours = "2h"
        case fiveHours = "5h"
        case daily = "1d"
        case weekly = "7d"
        case monthly = "30d"
    }
}

struct ProviderPeriodPercentJSON: Codable, Equatable {
    var twoHours: Double?
    var fiveHours: Double?
    var daily: Double?
    var weekly: Double?
    var monthly: Double?

    enum CodingKeys: String, CodingKey {
        case twoHours = "2h"
        case fiveHours = "5h"
        case daily = "1d"
        case weekly = "7d"
        case monthly = "30d"
    }
}

struct CustomProviderUsageJSON: Codable, Equatable {
    var usedByPeriod: ProviderPeriodUsageJSON?
    var serverUsedPercentByPeriod: ProviderPeriodPercentJSON?
    var resetAtByPeriod: ProviderPeriodUsageJSON?
    var costUSD: Double?
    var status: String?
}

struct LocalUsageData: Codable, Equatable {
    var openaiUsedTokens: Int?
    var openaiCostUSD: Double?
    var geminiUsedTokens: Int?
    var geminiCostUSD: Double?

    var openaiUsedByPeriod: ProviderPeriodUsageJSON?
    var geminiUsedByPeriod: ProviderPeriodUsageJSON?

    var openaiServerUsedPercentByPeriod: ProviderPeriodPercentJSON?
    var openaiResetAtByPeriod: ProviderPeriodUsageJSON?
    var openaiPlanType: String?
    var openaiCreditBalance: Double?

    var providers: [String: CustomProviderUsageJSON]?
    var detectedProviders: [String]?
    var source: String?
    var updatedAt: String?
}

// MARK: - Keychain Helper
enum KeychainHelper {
    static let service = "com.local.AIMeter"

    static func save(key: String, value: String) {
        guard let data = value.data(using: .utf8) else { return }
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: key
        ]
        SecItemDelete(query as CFDictionary)
        guard !value.isEmpty else { return }

        var addQuery = query
        addQuery[kSecValueData as String] = data
        addQuery[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlock
        SecItemAdd(addQuery as CFDictionary, nil)
    }

    static func load(key: String) -> String? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: key,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne
        ]
        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        guard status == errSecSuccess, let data = item as? Data else {
            return nil
        }
        return String(data: data, encoding: .utf8)
    }
}

// MARK: - Pure Parsers & Calculations (Testable)
enum UsageParser {
    static func startOfMonthUnixTimestamp(for date: Date = Date()) -> Int {
        var utcCalendar = Calendar(identifier: .gregorian)
        utcCalendar.timeZone = TimeZone(secondsFromGMT: 0) ?? .gmt
        let components = utcCalendar.dateComponents([.year, .month], from: date)
        let startOfMonth = utcCalendar.date(from: components) ?? date
        return Int(startOfMonth.timeIntervalSince1970)
    }

    static func startTimestamp(for period: LimitPeriod, now: Date = Date()) -> Int {
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

    struct BucketTokenRecord: Equatable {
        let startTime: Int
        let endTime: Int
        let tokens: Int
    }

    static func parseOpenAIUsagePageWithBuckets(data: Data) throws -> (buckets: [BucketTokenRecord], totalTokens: Int, nextPage: String?) {
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

    static func parseOpenAIUsagePage(data: Data) throws -> (tokens: Int, nextPage: String?) {
        let parsed = try parseOpenAIUsagePageWithBuckets(data: data)
        return (parsed.totalTokens, parsed.nextPage)
    }

    static func parseOpenAICostsPage(data: Data) throws -> (costUSD: Double, nextPage: String?) {
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

    static func parseGeminiMonitoringSeries(data: Data) throws -> Int {
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

    static func parseIntValue(_ anyVal: Any?) -> Int {
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

    static func parseDoubleValue(_ anyVal: Any?) -> Double {
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

// MARK: - Usage Monitor
@MainActor
final class UsageMonitor: ObservableObject {
    @AppStorage("didCalibrateRealLimitsV1") var didCalibrateRealLimitsV1: Bool = false
    @AppStorage("didAutoSeedLocalProvidersV2") var didAutoSeedLocalProvidersV2: Bool = false
    @AppStorage("hasCompletedSetupWizard") var hasCompletedSetupWizard: Bool = false
    @AppStorage("customProviderPathsJSON") var customProviderPathsJSON: String = "{}"
    @AppStorage("openaiAdminKey") var legacyOpenaiAdminKey: String = ""
    @Published var openaiAdminKey: String = "" {
        didSet {
            KeychainHelper.save(key: "openaiAdminKey", value: openaiAdminKey)
        }
    }

    var customProviderPaths: [String: String] {
        get {
            guard let data = customProviderPathsJSON.data(using: .utf8),
                  let dict = try? JSONDecoder().decode([String: String].self, from: data) else {
                return [:]
            }
            return dict
        }
        set {
            if let data = try? JSONEncoder().encode(newValue),
               let str = String(data: data, encoding: .utf8) {
                customProviderPathsJSON = str
            }
        }
    }

    func setCustomPath(for providerId: String, path: String) {
        var current = customProviderPaths
        let trimmed = path.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty {
            current.removeValue(forKey: providerId)
        } else {
            current[providerId] = trimmed
        }
        customProviderPaths = current
    }

    // Built-in Provider Visibility & Period Toggles
    @AppStorage("showOpenAISection") var showOpenAISection: Bool = true
    @AppStorage("showGeminiSection") var showGeminiSection: Bool = true
    @AppStorage("openaiEnabledPeriodsCSV") var openaiEnabledPeriodsCSV: String = "5h,7d,30d"
    @AppStorage("geminiEnabledPeriodsCSV") var geminiEnabledPeriodsCSV: String = "5h,1d,7d,30d"

    // OpenAI Token Limits per Period
    @AppStorage("openaiTokenLimit2h") var openaiTokenLimit2h: Int = 20_000_000
    @AppStorage("openaiTokenLimit5h") var openaiTokenLimit5h: Int = 40_000_000
    @AppStorage("openaiTokenLimitDaily") var openaiTokenLimitDaily: Int = 80_000_000
    @AppStorage("openaiTokenLimitWeekly") var openaiTokenLimitWeekly: Int = 290_000_000
    @AppStorage("openaiTokenLimit") var openaiTokenLimit: Int = 800_000_000
    @AppStorage("openaiBudgetUSD") var openaiBudgetUSD: Double = 600.0

    // Gemini Token Limits per Period
    @AppStorage("gcpProjectId") var gcpProjectId: String = ""
    @AppStorage("geminiTokenLimit2h") var geminiTokenLimit2h: Int = 750_000
    @AppStorage("geminiTokenLimit5h") var geminiTokenLimit5h: Int = 1_500_000
    @AppStorage("geminiTokenLimitDaily") var geminiTokenLimitDaily: Int = 4_000_000
    @AppStorage("geminiTokenLimitWeekly") var geminiTokenLimitWeekly: Int = 15_000_000
    @AppStorage("geminiTokenLimit") var geminiTokenLimit: Int = 40_000_000
    @AppStorage("geminiBudgetUSD") var geminiBudgetUSD: Double = 20.0

    // Custom Subscriptions JSON persistence
    @AppStorage("customSubscriptionsJSON") var customSubscriptionsJSON: String = "[]"
    @Published var customSubscriptions: [CustomSubscriptionConfig] = [] {
        didSet {
            saveCustomSubscriptions()
        }
    }
    @Published var customProviderLiveUsage: [String: CustomProviderUsageJSON] = [:]
    @Published var detectedProviderIds: [String] = []

    // MenuBar Display Period Mode ("min" = bottleneck or LimitPeriod.rawValue)
    @AppStorage("menuBarPeriodMode") var menuBarPeriodMode: String = "min"

    // OpenAI Used Tokens per Period
    @Published var openaiUsed2h: Int = 0
    @Published var openaiUsed5h: Int = 0
    @Published var openaiUsedDaily: Int = 0
    @Published var openaiUsedWeekly: Int = 0
    @Published var openaiUsedTokens: Int = 0
    @Published var openaiServerPct: ProviderPeriodPercentJSON? = nil
    @Published var openaiResetAt: ProviderPeriodUsageJSON? = nil
    @Published var openaiCostUSD: Double = 0.0
    @Published var openaiStatus: String = "実ログ"

    // Gemini Used Tokens per Period
    @Published var geminiUsed2h: Int = 0
    @Published var geminiUsed5h: Int = 0
    @Published var geminiUsedDaily: Int = 0
    @Published var geminiUsedWeekly: Int = 0
    @Published var geminiUsedTokens: Int = 0
    @Published var geminiCostUSD: Double = 0.0
    @Published var geminiStatus: String = "実ログ"

    @Published var lastUpdated: Date = Date()
    @Published var isRefreshing: Bool = false

    private var timer: Timer?
    private var wakeObserver: NSObjectProtocol?
    private let urlSession: URLSession
    private var isLoadingSubscriptions: Bool = false

    init() {
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 15.0
        config.timeoutIntervalForResource = 30.0
        self.urlSession = URLSession(configuration: config)

        if let savedKey = KeychainHelper.load(key: "openaiAdminKey"), !savedKey.isEmpty {
            self.openaiAdminKey = savedKey
            if !legacyOpenaiAdminKey.isEmpty {
                legacyOpenaiAdminKey = ""
            }
        } else if !legacyOpenaiAdminKey.isEmpty {
            let migrated = legacyOpenaiAdminKey
            self.openaiAdminKey = migrated
            KeychainHelper.save(key: "openaiAdminKey", value: migrated)
            legacyOpenaiAdminKey = ""
        }

        if !didCalibrateRealLimitsV1 {
            if openaiTokenLimit == 5_000_000 { openaiTokenLimit = 800_000_000 }
            if openaiTokenLimitWeekly == 2_000_000 { openaiTokenLimitWeekly = 290_000_000 }
            if openaiTokenLimitDaily == 500_000 { openaiTokenLimitDaily = 80_000_000 }
            if openaiTokenLimit5h == 150_000 { openaiTokenLimit5h = 40_000_000 }
            if openaiBudgetUSD == 20.0 { openaiBudgetUSD = 600.0 }

            if geminiTokenLimit == 10_000_000 { geminiTokenLimit = 40_000_000 }
            if geminiTokenLimitWeekly == 4_000_000 { geminiTokenLimitWeekly = 15_000_000 }
            if geminiTokenLimitDaily == 1_000_000 { geminiTokenLimitDaily = 4_000_000 }
            if geminiTokenLimit5h == 300_000 { geminiTokenLimit5h = 1_500_000 }
            menuBarPeriodMode = "min"
            didCalibrateRealLimitsV1 = true
        }

        loadCustomSubscriptions()
        sanitizeSettings()

        Task {
            await refresh()
        }

        let scheduledTimer = Timer.scheduledTimer(withTimeInterval: 60.0, repeats: true) { [weak self] _ in
            guard let self else { return }
            Task { @MainActor in
                await self.refresh()
            }
        }
        scheduledTimer.tolerance = 6.0
        self.timer = scheduledTimer

        self.wakeObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didWakeNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            guard let self else { return }
            Task { @MainActor in
                await self.refresh()
            }
        }
    }

    private func loadCustomSubscriptions() {
        isLoadingSubscriptions = true
        defer { isLoadingSubscriptions = false }
        guard let data = customSubscriptionsJSON.data(using: .utf8),
              let decoded = try? JSONDecoder().decode([CustomSubscriptionConfig].self, from: data) else {
            customSubscriptions = []
            return
        }
        customSubscriptions = decoded
    }

    private func saveCustomSubscriptions() {
        guard !isLoadingSubscriptions else { return }
        if let data = try? JSONEncoder().encode(customSubscriptions),
           let str = String(data: data, encoding: .utf8) {
            customSubscriptionsJSON = str
        }
    }

    func addSubscription(_ preset: CustomSubscriptionConfig) {
        var newSub = preset
        if customSubscriptions.contains(where: { $0.id == newSub.id }) {
            let suffix = String(UUID().uuidString.prefix(4)).lowercased()
            newSub.id = "\(newSub.id)_\(suffix)"
        }
        newSub.sanitize()
        customSubscriptions.append(newSub)
    }

    func autoAddDetectedSubscriptions() {
        let candidateIds = detectedProviderIds.isEmpty
            ? ["grokbot", "claude", "windsurf", "copilot", "cursor"]
            : detectedProviderIds
        for pid in candidateIds where pid != "trae" {
            if !customSubscriptions.contains(where: { $0.id == pid || $0.id.hasPrefix("\(pid)_") }),
               let preset = CustomSubscriptionConfig.preset(forId: pid) {
                var newSub = preset
                newSub.sanitize()
                customSubscriptions.append(newSub)
            }
        }
    }

    func removeSubscription(id: String) {
        customSubscriptions.removeAll { $0.id == id }
    }

    func isBuiltInPeriodEnabled(csv: String, period: LimitPeriod) -> Bool {
        let parts = csv.split(separator: ",").map(String.init)
        return parts.contains(period.rawValue)
    }

    func setBuiltInPeriod(isOpenAI: Bool, period: LimitPeriod, enabled: Bool) {
        let currentCSV = isOpenAI ? openaiEnabledPeriodsCSV : geminiEnabledPeriodsCSV
        var parts = currentCSV.split(separator: ",").map(String.init)
        if enabled {
            if !parts.contains(period.rawValue) {
                parts.append(period.rawValue)
            }
        } else if parts.count > 1 {
            parts.removeAll { $0 == period.rawValue }
        }
        let ordered = LimitPeriod.allCases.map(\.rawValue).filter { parts.contains($0) }.joined(separator: ",")
        if isOpenAI {
            openaiEnabledPeriodsCSV = ordered.isEmpty ? "30d" : ordered
        } else {
            geminiEnabledPeriodsCSV = ordered.isEmpty ? "30d" : ordered
        }
    }

    func sanitizeSettings() {
        if openaiTokenLimit2h < 1 { openaiTokenLimit2h = 1 }
        if openaiTokenLimit5h < 1 { openaiTokenLimit5h = 1 }
        if openaiTokenLimitDaily < 1 { openaiTokenLimitDaily = 1 }
        if openaiTokenLimitWeekly < 1 { openaiTokenLimitWeekly = 1 }
        if openaiTokenLimit < 1 { openaiTokenLimit = 1 }
        if openaiBudgetUSD < 0 { openaiBudgetUSD = 0 }

        if geminiTokenLimit2h < 1 { geminiTokenLimit2h = 1 }
        if geminiTokenLimit5h < 1 { geminiTokenLimit5h = 1 }
        if geminiTokenLimitDaily < 1 { geminiTokenLimitDaily = 1 }
        if geminiTokenLimitWeekly < 1 { geminiTokenLimitWeekly = 1 }
        if geminiTokenLimit < 1 { geminiTokenLimit = 1 }
        if geminiBudgetUSD < 0 { geminiBudgetUSD = 0 }

        for idx in customSubscriptions.indices {
            customSubscriptions[idx].sanitize()
        }
    }

    var openaiMetrics: [PeriodUsageMetric] {
        let all = [
            PeriodUsageMetric(
                period: .twoHours,
                usedTokens: openaiUsed2h,
                limitTokens: openaiTokenLimit2h,
                serverUsedPercent: openaiServerPct?.twoHours,
                resetTimestamp: openaiResetAt?.twoHours
            ),
            PeriodUsageMetric(
                period: .fiveHours,
                usedTokens: openaiUsed5h,
                limitTokens: openaiTokenLimit5h,
                serverUsedPercent: openaiServerPct?.fiveHours,
                resetTimestamp: openaiResetAt?.fiveHours
            ),
            PeriodUsageMetric(
                period: .daily,
                usedTokens: openaiUsedDaily,
                limitTokens: openaiTokenLimitDaily,
                serverUsedPercent: openaiServerPct?.daily,
                resetTimestamp: openaiResetAt?.daily
            ),
            PeriodUsageMetric(
                period: .weekly,
                usedTokens: openaiUsedWeekly,
                limitTokens: openaiTokenLimitWeekly,
                serverUsedPercent: openaiServerPct?.weekly,
                resetTimestamp: openaiResetAt?.weekly
            ),
            PeriodUsageMetric(
                period: .monthly,
                usedTokens: openaiUsedTokens,
                limitTokens: openaiTokenLimit,
                serverUsedPercent: openaiServerPct?.monthly,
                resetTimestamp: openaiResetAt?.monthly
            )
        ]
        let filtered = all.filter { isBuiltInPeriodEnabled(csv: openaiEnabledPeriodsCSV, period: $0.period) }
        return filtered.isEmpty ? all : filtered
    }

    var geminiMetrics: [PeriodUsageMetric] {
        let all = [
            PeriodUsageMetric(period: .twoHours, usedTokens: geminiUsed2h, limitTokens: geminiTokenLimit2h),
            PeriodUsageMetric(period: .fiveHours, usedTokens: geminiUsed5h, limitTokens: geminiTokenLimit5h),
            PeriodUsageMetric(period: .daily, usedTokens: geminiUsedDaily, limitTokens: geminiTokenLimitDaily),
            PeriodUsageMetric(period: .weekly, usedTokens: geminiUsedWeekly, limitTokens: geminiTokenLimitWeekly),
            PeriodUsageMetric(period: .monthly, usedTokens: geminiUsedTokens, limitTokens: geminiTokenLimit)
        ]
        let filtered = all.filter { isBuiltInPeriodEnabled(csv: geminiEnabledPeriodsCSV, period: $0.period) }
        return filtered.isEmpty ? all : filtered
    }

    func metrics(for sub: CustomSubscriptionConfig) -> [PeriodUsageMetric] {
        let baseKey = sub.id.split(separator: "_").first.map(String.init) ?? sub.id
        let live = customProviderLiveUsage[sub.id] ?? customProviderLiveUsage[baseKey]
        let u2h = live?.usedByPeriod?.twoHours ?? sub.manualUsed2h
        let u5h = live?.usedByPeriod?.fiveHours ?? sub.manualUsed5h
        let u1d = live?.usedByPeriod?.daily ?? sub.manualUsedDaily
        let u7d = live?.usedByPeriod?.weekly ?? sub.manualUsedWeekly
        let u30d = live?.usedByPeriod?.monthly ?? sub.manualUsedMonthly

        let all = [
            PeriodUsageMetric(
                period: .twoHours,
                usedTokens: max(sub.manualUsed2h, u2h),
                limitTokens: sub.limit2h,
                serverUsedPercent: live?.serverUsedPercentByPeriod?.twoHours,
                resetTimestamp: live?.resetAtByPeriod?.twoHours
            ),
            PeriodUsageMetric(
                period: .fiveHours,
                usedTokens: max(sub.manualUsed5h, u5h),
                limitTokens: sub.limit5h,
                serverUsedPercent: live?.serverUsedPercentByPeriod?.fiveHours,
                resetTimestamp: live?.resetAtByPeriod?.fiveHours
            ),
            PeriodUsageMetric(
                period: .daily,
                usedTokens: max(sub.manualUsedDaily, u1d),
                limitTokens: sub.limitDaily,
                serverUsedPercent: live?.serverUsedPercentByPeriod?.daily,
                resetTimestamp: live?.resetAtByPeriod?.daily
            ),
            PeriodUsageMetric(
                period: .weekly,
                usedTokens: max(sub.manualUsedWeekly, u7d),
                limitTokens: sub.limitWeekly,
                serverUsedPercent: live?.serverUsedPercentByPeriod?.weekly,
                resetTimestamp: live?.resetAtByPeriod?.weekly
            ),
            PeriodUsageMetric(
                period: .monthly,
                usedTokens: max(sub.manualUsedMonthly, u30d),
                limitTokens: sub.limitMonthly,
                serverUsedPercent: live?.serverUsedPercentByPeriod?.monthly,
                resetTimestamp: live?.resetAtByPeriod?.monthly
            )
        ]
        let filtered = all.filter { sub.isPeriodEnabled($0.period) }
        return filtered.isEmpty ? [all.last!] : filtered
    }

    func effectiveCostUSD(for sub: CustomSubscriptionConfig) -> Double {
        let baseKey = sub.id.split(separator: "_").first.map(String.init) ?? sub.id
        let live = customProviderLiveUsage[sub.id] ?? customProviderLiveUsage[baseKey]
        if let liveCost = live?.costUSD, liveCost > 0 {
            return max(sub.usedCostUSD, liveCost)
        }
        return sub.usedCostUSD
    }

    var totalCostUSD: Double {
        var sum = 0.0
        if showOpenAISection { sum += openaiCostUSD }
        if showGeminiSection { sum += geminiCostUSD }
        for sub in customSubscriptions where sub.isEnabled {
            sum += effectiveCostUSD(for: sub)
        }
        return sum
    }

    func activeRatio(for metrics: [PeriodUsageMetric]) -> Double {
        if menuBarPeriodMode == "min" {
            return metrics.map(\.remainingRatio).min() ?? 0.0
        }
        if let period = LimitPeriod(rawValue: menuBarPeriodMode),
           let matched = metrics.first(where: { $0.period == period }) {
            return matched.remainingRatio
        }
        return metrics.map(\.remainingRatio).min() ?? (metrics.last?.remainingRatio ?? 0.0)
    }

    var menuBarTitle: String {
        var segments: [String] = []
        if showOpenAISection {
            let gptPct = Int((activeRatio(for: openaiMetrics) * 100).rounded())
            segments.append("GPT:\(gptPct)%")
        }
        if showGeminiSection {
            let gemPct = Int((activeRatio(for: geminiMetrics) * 100).rounded())
            segments.append("Gem:\(gemPct)%")
        }
        for sub in customSubscriptions where sub.isEnabled && sub.showInMenuBar {
            let pct = Int((activeRatio(for: metrics(for: sub)) * 100).rounded())
            segments.append("\(sub.shortName):\(pct)%")
        }
        if segments.isEmpty {
            return "AIMeter"
        }
        return segments.joined(separator: " ")
    }

    func refresh() async {
        guard !isRefreshing else { return }
        isRefreshing = true
        sanitizeSettings()
        defer {
            lastUpdated = Date()
            isRefreshing = false
        }

        await runLocalCollectorScript()

        let localData = loadLocalJSON()
        if let localData {
            let monthlyOpenAI = max(0, localData.openaiUsedByPeriod?.monthly ?? localData.openaiUsedTokens ?? 0)
            openaiUsedTokens = monthlyOpenAI
            openaiUsedWeekly = max(0, localData.openaiUsedByPeriod?.weekly ?? min(monthlyOpenAI, Int(Double(monthlyOpenAI) * 0.45)))
            openaiUsedDaily = max(0, localData.openaiUsedByPeriod?.daily ?? min(openaiUsedWeekly, Int(Double(monthlyOpenAI) * 0.12)))
            openaiUsed5h = max(0, localData.openaiUsedByPeriod?.fiveHours ?? min(openaiUsedDaily, Int(Double(monthlyOpenAI) * 0.05)))
            openaiUsed2h = max(0, localData.openaiUsedByPeriod?.twoHours ?? min(openaiUsed5h, Int(Double(monthlyOpenAI) * 0.02)))
            openaiServerPct = localData.openaiServerUsedPercentByPeriod
            openaiResetAt = localData.openaiResetAtByPeriod
            openaiCostUSD = max(0.0, localData.openaiCostUSD ?? 0.0)

            let monthlyGemini = max(0, localData.geminiUsedByPeriod?.monthly ?? localData.geminiUsedTokens ?? 0)
            geminiUsedTokens = monthlyGemini
            geminiUsedWeekly = max(0, localData.geminiUsedByPeriod?.weekly ?? min(monthlyGemini, Int(Double(monthlyGemini) * 0.40)))
            geminiUsedDaily = max(0, localData.geminiUsedByPeriod?.daily ?? min(geminiUsedWeekly, Int(Double(monthlyGemini) * 0.10)))
            geminiUsed5h = max(0, localData.geminiUsedByPeriod?.fiveHours ?? min(geminiUsedDaily, Int(Double(monthlyGemini) * 0.04)))
            geminiUsed2h = max(0, localData.geminiUsedByPeriod?.twoHours ?? min(geminiUsed5h, Int(Double(monthlyGemini) * 0.02)))
            geminiCostUSD = max(0.0, localData.geminiCostUSD ?? 0.0)

            customProviderLiveUsage = localData.providers ?? [:]
            detectedProviderIds = localData.detectedProviders ?? []

            // Automatically seed and clean up detected local accounts on first V2 run
            if !didAutoSeedLocalProvidersV2 {
                // Remove accidental duplicate suffixed entries if base entry exists
                var seenBaseIds = Set<String>()
                var cleaned: [CustomSubscriptionConfig] = []
                for var item in customSubscriptions {
                    let base = item.id.split(separator: "_").first.map(String.init) ?? item.id
                    if seenBaseIds.contains(base) {
                        continue
                    }
                    seenBaseIds.insert(base)
                    item.id = base
                    // Clear legacy sample manual values on copilot/cursor so real local logs are shown
                    if base == "copilot" && item.manualUsedMonthly == 80 {
                        item.manualUsedDaily = 0
                        item.manualUsedWeekly = 0
                        item.manualUsedMonthly = 0
                    }
                    cleaned.append(item)
                }
                customSubscriptions = cleaned
                autoAddDetectedSubscriptions()
                didAutoSeedLocalProvidersV2 = true
            }

            if let plan = localData.openaiPlanType, !plan.isEmpty {
                openaiStatus = plan
            } else {
                openaiStatus = "実ログ"
            }
            geminiStatus = "実ログ"
        } else {
            openaiUsed2h = 0
            openaiUsed5h = 0
            openaiUsedDaily = 0
            openaiUsedWeekly = 0
            openaiUsedTokens = 0
            openaiServerPct = nil
            openaiResetAt = nil
            openaiCostUSD = 0.0

            geminiUsed2h = 0
            geminiUsed5h = 0
            geminiUsedDaily = 0
            geminiUsedWeekly = 0
            geminiUsedTokens = 0
            geminiCostUSD = 0.0
            customProviderLiveUsage = [:]

            openaiStatus = "未取得"
            geminiStatus = "未取得"
        }

        let trimmedOpenAIKey = openaiAdminKey.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmedOpenAIKey.isEmpty {
            await fetchOpenAIUsage(apiKey: trimmedOpenAIKey)
        }

        let trimmedProjectId = gcpProjectId.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmedProjectId.isEmpty {
            await fetchGeminiUsage(projectId: trimmedProjectId)
        }
    }

    private func runLocalCollectorScript() async {
        // Collect natively in Swift with zero external Python dependency
        await LocalUsageCollector.collectAndSave(customPaths: customProviderPaths)
    }

    func loadLocalJSON(from customURL: URL? = nil) -> LocalUsageData? {
        let url = customURL ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".ai_meter_usage.json")
        guard let data = try? Data(contentsOf: url) else { return nil }
        return try? JSONDecoder().decode(LocalUsageData.self, from: data)
    }

    private func fetchOpenAIUsage(apiKey: String) async {
        let now = Date()
        let monthStart = UsageParser.startTimestamp(for: .monthly, now: now)
        let weekStart = UsageParser.startTimestamp(for: .weekly, now: now)
        let dayStart = UsageParser.startTimestamp(for: .daily, now: now)
        let fiveHoursStart = UsageParser.startTimestamp(for: .fiveHours, now: now)
        let twoHoursStart = UsageParser.startTimestamp(for: .twoHours, now: now)

        let queryStart = min(monthStart, weekStart)

        do {
            let dailyBuckets = try await fetchPaginatedOpenAIBuckets(
                apiKey: apiKey,
                startTime: queryStart,
                bucketWidth: "1d",
                limit: 31
            )

            var monthTotal = 0
            var weekTotal = 0
            var dayTotal = 0
            for b in dailyBuckets {
                if b.startTime >= monthStart { monthTotal += b.tokens }
                if b.startTime >= weekStart { weekTotal += b.tokens }
                if b.startTime >= dayStart { dayTotal += b.tokens }
            }
            self.openaiUsedTokens = monthTotal
            self.openaiUsedWeekly = weekTotal
            self.openaiUsedDaily = dayTotal

            if let hourlyBuckets = try? await fetchPaginatedOpenAIBuckets(
                apiKey: apiKey,
                startTime: fiveHoursStart,
                bucketWidth: "1h",
                limit: 6
            ) {
                self.openaiUsed5h = hourlyBuckets.reduce(0) { $0 + $1.tokens }
                self.openaiUsed2h = hourlyBuckets.filter { $0.startTime >= twoHoursStart }.reduce(0) { $0 + $1.tokens }
            }

            if let totalCost = try? await fetchPaginatedOpenAICosts(apiKey: apiKey, startTime: monthStart) {
                self.openaiCostUSD = totalCost
            }
            openaiStatus = "API"
        } catch {
            // Keep local log status
        }
    }

    private func fetchPaginatedOpenAIBuckets(
        apiKey: String,
        startTime: Int,
        bucketWidth: String,
        limit: Int
    ) async throws -> [UsageParser.BucketTokenRecord] {
        var allBuckets: [UsageParser.BucketTokenRecord] = []
        var nextPage: String? = nil
        var pageCount = 0

        repeat {
            pageCount += 1
            var components = URLComponents(string: "https://api.openai.com/v1/organization/usage/completions")
            var queryItems = [
                URLQueryItem(name: "start_time", value: "\(startTime)"),
                URLQueryItem(name: "bucket_width", value: bucketWidth),
                URLQueryItem(name: "limit", value: "\(limit)")
            ]
            if let page = nextPage {
                queryItems.append(URLQueryItem(name: "page", value: page))
            }
            components?.queryItems = queryItems
            guard let url = components?.url else { throw URLError(.badURL) }

            var req = URLRequest(url: url)
            req.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")

            let (data, resp) = try await urlSession.data(for: req)
            guard let httpResp = resp as? HTTPURLResponse, (200...299).contains(httpResp.statusCode) else {
                throw URLError(.badServerResponse)
            }

            let parsed = try UsageParser.parseOpenAIUsagePageWithBuckets(data: data)
            allBuckets.append(contentsOf: parsed.buckets)
            nextPage = parsed.nextPage
        } while nextPage != nil && pageCount < 10

        return allBuckets
    }

    private func fetchPaginatedOpenAICosts(apiKey: String, startTime: Int) async throws -> Double {
        var totalCost = 0.0
        var nextPage: String? = nil
        var pageCount = 0

        repeat {
            pageCount += 1
            var components = URLComponents(string: "https://api.openai.com/v1/organization/costs")
            var queryItems = [
                URLQueryItem(name: "start_time", value: "\(startTime)"),
                URLQueryItem(name: "bucket_width", value: "1d"),
                URLQueryItem(name: "limit", value: "31")
            ]
            if let page = nextPage {
                queryItems.append(URLQueryItem(name: "page", value: page))
            }
            components?.queryItems = queryItems
            guard let url = components?.url else { throw URLError(.badURL) }

            var req = URLRequest(url: url)
            req.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")

            let (data, resp) = try await urlSession.data(for: req)
            guard let httpResp = resp as? HTTPURLResponse, (200...299).contains(httpResp.statusCode) else {
                throw URLError(.badServerResponse)
            }

            let parsed = try UsageParser.parseOpenAICostsPage(data: data)
            totalCost += parsed.costUSD
            nextPage = parsed.nextPage
        } while nextPage != nil && pageCount < 10

        return totalCost
    }

    private func fetchGeminiUsage(projectId: String) async {
        guard let token = await fetchGcloudAccessToken() else {
            return
        }

        let now = Date()
        let isoFormatter = ISO8601DateFormatter()
        let endStr = isoFormatter.string(from: now)
        let monthStartStr = isoFormatter.string(from: Date(timeIntervalSince1970: TimeInterval(UsageParser.startTimestamp(for: .monthly, now: now))))

        let tokenFilter = #"metric.type="aiplatform.googleapis.com/publisher/online_serving/token_count""#
        let requestCountFilter = #"metric.type="serviceruntime.googleapis.com/api/request_count" AND (resource.labels.service="generativelanguage.googleapis.com" OR resource.labels.service="aiplatform.googleapis.com")"#

        do {
            if let monthTokens = try? await queryCloudMonitoring(
                projectId: projectId,
                token: token,
                filter: tokenFilter,
                startStr: monthStartStr,
                endStr: endStr
            ), monthTokens > 0 {
                self.geminiUsedTokens = monthTokens

                let weekStartStr = isoFormatter.string(from: Date(timeIntervalSince1970: TimeInterval(UsageParser.startTimestamp(for: .weekly, now: now))))
                let dayStartStr = isoFormatter.string(from: Date(timeIntervalSince1970: TimeInterval(UsageParser.startTimestamp(for: .daily, now: now))))
                let fiveHStartStr = isoFormatter.string(from: Date(timeIntervalSince1970: TimeInterval(UsageParser.startTimestamp(for: .fiveHours, now: now))))
                let twoHStartStr = isoFormatter.string(from: Date(timeIntervalSince1970: TimeInterval(UsageParser.startTimestamp(for: .twoHours, now: now))))

                if let w = try? await queryCloudMonitoring(projectId: projectId, token: token, filter: tokenFilter, startStr: weekStartStr, endStr: endStr) {
                    self.geminiUsedWeekly = w
                }
                if let d = try? await queryCloudMonitoring(projectId: projectId, token: token, filter: tokenFilter, startStr: dayStartStr, endStr: endStr) {
                    self.geminiUsedDaily = d
                }
                if let h = try? await queryCloudMonitoring(projectId: projectId, token: token, filter: tokenFilter, startStr: fiveHStartStr, endStr: endStr) {
                    self.geminiUsed5h = h
                }
                if let h2 = try? await queryCloudMonitoring(projectId: projectId, token: token, filter: tokenFilter, startStr: twoHStartStr, endStr: endStr) {
                    self.geminiUsed2h = h2
                }

                geminiStatus = "GCP"
                return
            }

            let reqCount = try await queryCloudMonitoring(
                projectId: projectId,
                token: token,
                filter: requestCountFilter,
                startStr: monthStartStr,
                endStr: endStr
            )
            if reqCount > 0 {
                geminiStatus = "GCP (\(reqCount) reqs)"
            }
        } catch {
            // Keep local log status
        }
    }

    private func queryCloudMonitoring(
        projectId: String,
        token: String,
        filter: String,
        startStr: String,
        endStr: String
    ) async throws -> Int {
        guard var components = URLComponents(string: "https://monitoring.googleapis.com/v3/projects/\(projectId)/timeSeries") else {
            throw URLError(.badURL)
        }
        components.queryItems = [
            URLQueryItem(name: "filter", value: filter),
            URLQueryItem(name: "interval.startTime", value: startStr),
            URLQueryItem(name: "interval.endTime", value: endStr)
        ]
        guard let url = components.url else { throw URLError(.badURL) }

        var request = URLRequest(url: url)
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")

        let (data, response) = try await urlSession.data(for: request)
        guard let httpResp = response as? HTTPURLResponse, (200...299).contains(httpResp.statusCode) else {
            throw URLError(.badServerResponse)
        }
        return try UsageParser.parseGeminiMonitoringSeries(data: data)
    }

    private func fetchGcloudAccessToken() async -> String? {
        await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .utility).async {
                let home = FileManager.default.homeDirectoryForCurrentUser.path
                let candidatePaths = [
                    "/opt/homebrew/bin/gcloud",
                    "/usr/local/bin/gcloud",
                    "\(home)/google-cloud-sdk/bin/gcloud",
                    "/opt/homebrew/share/google-cloud-sdk/bin/gcloud"
                ]
                let resolvedExecutable = candidatePaths.first { FileManager.default.isExecutableFile(atPath: $0) }

                let process = Process()
                if let execPath = resolvedExecutable {
                    process.executableURL = URL(fileURLWithPath: execPath)
                    process.arguments = ["auth", "print-access-token", "--quiet"]
                } else {
                    process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
                    process.arguments = ["gcloud", "auth", "print-access-token", "--quiet"]
                }

                var env = ProcessInfo.processInfo.environment
                let extraPaths = "/opt/homebrew/bin:/usr/local/bin:\(home)/google-cloud-sdk/bin:/usr/bin:/bin"
                env["PATH"] = extraPaths + ":" + (env["PATH"] ?? "")
                env["CLOUDSDK_CORE_DISABLE_PROMPTS"] = "1"
                process.environment = env

                let outPipe = Pipe()
                process.standardOutput = outPipe
                process.standardError = Pipe()

                do {
                    try process.run()
                } catch {
                    continuation.resume(returning: nil)
                    return
                }

                let timeoutWorkItem = DispatchWorkItem {
                    if process.isRunning {
                        process.terminate()
                    }
                }
                DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + 8.0, execute: timeoutWorkItem)

                let data = outPipe.fileHandleForReading.readDataToEndOfFile()
                process.waitUntilExit()
                timeoutWorkItem.cancel()

                guard process.terminationStatus == 0 else {
                    continuation.resume(returning: nil)
                    return
                }
                let token = String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines)
                continuation.resume(returning: (token?.isEmpty == false) ? token : nil)
            }
        }
    }
}

// MARK: - Formatting Helpers
func formatTokenCount(_ count: Int) -> String {
    if count >= 1_000_000 {
        return String(format: "%.2fM", Double(count) / 1_000_000.0)
    } else if count >= 1_000 {
        return String(format: "%.1fK", Double(count) / 1_000_000.0 * 1_000.0)
    } else {
        return "\(max(0, count))"
    }
}

func formatCompactTokenCount(_ count: Int) -> String {
    if count >= 100_000_000 {
        return String(format: "%.0fM", Double(count) / 1_000_000.0)
    } else if count >= 1_000_000 {
        return String(format: "%.1fM", Double(count) / 1_000_000.0)
    } else if count >= 10_000 {
        return String(format: "%.0fK", Double(count) / 1_000.0)
    } else if count >= 1_000 {
        return String(format: "%.1fK", Double(count) / 1_000.0)
    } else {
        return "\(max(0, count))"
    }
}

func formatResetTimestamp(_ epoch: Int?) -> String? {
    guard let epoch, epoch > 0 else { return nil }
    let date = Date(timeIntervalSince1970: TimeInterval(epoch))
    let formatter = DateFormatter()
    formatter.dateFormat = "MM/dd HH:mm"
    return formatter.string(from: date)
}

func gaugeColor(for remainingRatio: Double) -> Color {
    if remainingRatio < 0.15 {
        return .red
    } else if remainingRatio < 0.35 {
        return .orange
    } else {
        return Color.primary.opacity(0.68)
    }
}

func percentageTextColor(for remainingRatio: Double) -> Color {
    if remainingRatio < 0.15 {
        return .red
    } else if remainingRatio < 0.35 {
        return .orange
    } else {
        return .primary
    }
}

func gaugeWarningSymbol(for remainingRatio: Double) -> String? {
    if remainingRatio < 0.15 {
        return "exclamationmark.octagon.fill"
    } else if remainingRatio < 0.35 {
        return "exclamationmark.triangle.fill"
    } else {
        return nil
    }
}

// MARK: - Single Period Limit Row View (Clean Tabular Design)
struct PeriodLimitRowView: View {
    let metric: PeriodUsageMetric
    let isHighlighted: Bool

    var body: some View {
        let ratio = metric.remainingRatio
        let pct = metric.remainingPercent

        HStack(spacing: 6) {
            // 1. Period Label
            Text(metric.period.label)
                .font(.system(size: 11.5, weight: isHighlighted ? .bold : .medium))
                .foregroundStyle(isHighlighted ? .primary : .secondary)
                .frame(width: 36, alignment: .leading)

            // 2. Clean Progress Bar
            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    Capsule()
                        .fill(Color.primary.opacity(0.08))
                        .frame(height: 5)
                    Capsule()
                        .fill(gaugeColor(for: ratio))
                        .frame(width: max(3, geo.size.width * ratio), height: 5)
                        .animation(.easeInOut(duration: 0.2), value: ratio)
                }
                .frame(maxHeight: .infinity, alignment: .center)
            }
            .frame(height: 12)

            // 3. Remaining Amount (or Reset Time hint)
            Text("残 \(formatCompactTokenCount(metric.remainingTokens))")
                .font(.system(size: 11).monospacedDigit())
                .foregroundStyle(.secondary)
                .frame(width: 62, alignment: .trailing)

            // 4. Remaining Percentage
            Text("\(pct)%")
                .font(.system(size: 12, weight: .bold).monospacedDigit())
                .foregroundStyle(percentageTextColor(for: ratio))
                .frame(width: 36, alignment: .trailing)
        }
        .padding(.vertical, 1.5)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(metric.period.label)制限")
        .accessibilityValue("残り \(formatCompactTokenCount(metric.remainingTokens)) (\(pct)パーセント)")
    }
}

// MARK: - Provider Section View (Simple & Calm Layout)
struct ProviderUsageSection: View {
    let title: String
    let subtitle: String
    let usedCostUSD: Double
    let budgetUSD: Double
    let metrics: [PeriodUsageMetric]
    let selectedFilter: LimitPeriod?
    let highlightedPeriod: LimitPeriod?

    var displayedMetrics: [PeriodUsageMetric] {
        if let filter = selectedFilter {
            return metrics.filter { $0.period == filter }
        }
        return metrics
    }

    private var activeResetString: String? {
        for m in displayedMetrics {
            if let str = formatResetTimestamp(m.resetTimestamp) {
                return "\(m.period.label)リセット \(str)"
            }
        }
        return nil
    }

    var body: some View {
        if displayedMetrics.isEmpty {
            EmptyView()
        } else {
            VStack(alignment: .leading, spacing: 6) {
                // Section Header
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    Text(title)
                        .font(.system(size: 12.5, weight: .bold))
                        .foregroundStyle(.primary)

                    if !subtitle.isEmpty {
                        Text(subtitle)
                            .font(.system(size: 11))
                            .foregroundStyle(.tertiary)
                    }

                    Spacer()

                    if let resetInfo = activeResetString {
                        Text(resetInfo)
                            .font(.system(size: 11).monospacedDigit())
                            .foregroundStyle(.secondary)
                    } else if usedCostUSD > 0 || budgetUSD > 0 {
                        Text(String(format: "$%.2f", usedCostUSD))
                            .font(.system(size: 11).monospacedDigit())
                            .foregroundStyle(.secondary)
                    }
                }

                // Period Rows
                VStack(spacing: 2) {
                    ForEach(displayedMetrics) { metric in
                        PeriodLimitRowView(
                            metric: metric,
                            isHighlighted: highlightedPeriod == metric.period && selectedFilter == nil
                        )
                    }
                }
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 7)
            .background(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(Color.primary.opacity(0.04))
            )
        }
    }
}

// MARK: - Settings View (Simple & Readable)
struct SettingsPopoverView: View {
    @ObservedObject var monitor: UsageMonitor
    var onOpenSetupWizard: (() -> Void)? = nil
    var onOpenHelp: (() -> Void)? = nil
    var onClose: (() -> Void)? = nil
    @State private var revealAdminKey: Bool = false
    @State private var selectedTab: Int = 0

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            // Top Bar
            HStack {
                if let onClose {
                    Button {
                        onClose()
                    } label: {
                        HStack(spacing: 4) {
                            Image(systemName: "chevron.left")
                            Text("戻る")
                        }
                        .font(.system(size: 13, weight: .medium))
                        .padding(.horizontal, 8)
                        .padding(.vertical, 4)
                        .background(
                            RoundedRectangle(cornerRadius: 6, style: .continuous)
                                .fill(Color.primary.opacity(0.08))
                        )
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                }

                Text("設定")
                    .font(.system(size: 15, weight: .bold))

                if let onOpenSetupWizard {
                    Button {
                        onOpenSetupWizard()
                    } label: {
                        HStack(spacing: 4) {
                            Image(systemName: "sparkles")
                            Text("初期セットアップ")
                        }
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(.tint)
                        .padding(.horizontal, 7)
                        .padding(.vertical, 4)
                        .background(
                            RoundedRectangle(cornerRadius: 5, style: .continuous)
                                .fill(Color.accentColor.opacity(0.1))
                        )
                    }
                    .buttonStyle(.plain)
                    .help("サービス検出・パス設定ウィザードを開く")
                }

                if let onOpenHelp {
                    Button {
                        onOpenHelp()
                    } label: {
                        HStack(spacing: 4) {
                            Image(systemName: "questionmark.circle")
                            Text("ヘルプ")
                        }
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(.secondary)
                        .padding(.horizontal, 7)
                        .padding(.vertical, 4)
                        .background(
                            RoundedRectangle(cornerRadius: 5, style: .continuous)
                                .fill(Color.primary.opacity(0.06))
                        )
                    }
                    .buttonStyle(.plain)
                    .help("アプリの説明やQ&Aを見る")
                }

                Spacer()

                HStack(spacing: 4) {
                    Text("メニューバー:")
                        .font(.system(size: 12.5))
                        .foregroundStyle(.secondary)
                    Picker("", selection: $monitor.menuBarPeriodMode) {
                        Text("最小残量").tag("min")
                        Text("2時間").tag("2h")
                        Text("5時間").tag("5h")
                        Text("1日").tag("1d")
                        Text("週次").tag("7d")
                        Text("月次").tag("30d")
                    }
                    .labelsHidden()
                    .frame(width: 100)
                }
            }

            Picker("", selection: $selectedTab) {
                Text("基本 (OpenAI / Gemini)").tag(0)
                Text("AIサービス (\(monitor.customSubscriptions.count))").tag(1)
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .controlSize(.regular)

            if selectedTab == 0 {
                builtInSettingsView
            } else {
                customSubscriptionsSettingsView
            }

            Divider()

            HStack {
                Text("ローカルログ自動集計対応")
                    .font(.system(size: 12.5))
                    .foregroundStyle(.secondary)
                Spacer()
                Button {
                    monitor.sanitizeSettings()
                    Task {
                        await monitor.refresh()
                    }
                    onClose?()
                } label: {
                    Text("完了")
                        .font(.system(size: 13, weight: .semibold))
                        .padding(.horizontal, 12)
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.regular)
            }
        }
        .onAppear {
            NSApplication.shared.activate(ignoringOtherApps: true)
        }
    }

    @ViewBuilder
    private var builtInSettingsView: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                // OpenAI Group
                VStack(alignment: .leading, spacing: 10) {
                    Toggle("OpenAI / Codex", isOn: $monitor.showOpenAISection)
                        .font(.system(size: 14, weight: .bold))

                    builtInPeriodToggleRow(isOpenAI: true, csv: monitor.openaiEnabledPeriodsCSV)

                    if monitor.isBuiltInPeriodEnabled(csv: monitor.openaiEnabledPeriodsCSV, period: .twoHours) {
                        limitInputRow(label: "2時間上限", value: $monitor.openaiTokenLimit2h)
                    }
                    if monitor.isBuiltInPeriodEnabled(csv: monitor.openaiEnabledPeriodsCSV, period: .fiveHours) {
                        limitInputRow(label: "5時間上限", value: $monitor.openaiTokenLimit5h)
                    }
                    if monitor.isBuiltInPeriodEnabled(csv: monitor.openaiEnabledPeriodsCSV, period: .daily) {
                        limitInputRow(label: "1日上限", value: $monitor.openaiTokenLimitDaily)
                    }
                    if monitor.isBuiltInPeriodEnabled(csv: monitor.openaiEnabledPeriodsCSV, period: .weekly) {
                        limitInputRow(label: "週次上限", value: $monitor.openaiTokenLimitWeekly)
                    }
                    if monitor.isBuiltInPeriodEnabled(csv: monitor.openaiEnabledPeriodsCSV, period: .monthly) {
                        limitInputRow(label: "月次上限", value: $monitor.openaiTokenLimit)
                    }

                    HStack(spacing: 6) {
                        if revealAdminKey {
                            TextField("OpenAI Admin Key (任意)", text: $monitor.openaiAdminKey)
                                .textFieldStyle(.roundedBorder)
                                .font(.system(size: 12))
                        } else {
                            SecureField("OpenAI Admin Key (任意)", text: $monitor.openaiAdminKey)
                                .textFieldStyle(.roundedBorder)
                                .font(.system(size: 12))
                        }
                        Button {
                            revealAdminKey.toggle()
                        } label: {
                            Image(systemName: revealAdminKey ? "eye.slash" : "eye")
                                .font(.system(size: 12))
                        }
                        .buttonStyle(.borderless)
                    }
                }
                .padding(12)
                .background(RoundedRectangle(cornerRadius: 8).fill(Color.primary.opacity(0.04)))

                // Gemini Group
                VStack(alignment: .leading, spacing: 10) {
                    Toggle("Google Gemini", isOn: $monitor.showGeminiSection)
                        .font(.system(size: 14, weight: .bold))

                    builtInPeriodToggleRow(isOpenAI: false, csv: monitor.geminiEnabledPeriodsCSV)

                    if monitor.isBuiltInPeriodEnabled(csv: monitor.geminiEnabledPeriodsCSV, period: .twoHours) {
                        limitInputRow(label: "2時間上限", value: $monitor.geminiTokenLimit2h)
                    }
                    if monitor.isBuiltInPeriodEnabled(csv: monitor.geminiEnabledPeriodsCSV, period: .fiveHours) {
                        limitInputRow(label: "5時間上限", value: $monitor.geminiTokenLimit5h)
                    }
                    if monitor.isBuiltInPeriodEnabled(csv: monitor.geminiEnabledPeriodsCSV, period: .daily) {
                        limitInputRow(label: "1日上限", value: $monitor.geminiTokenLimitDaily)
                    }
                    if monitor.isBuiltInPeriodEnabled(csv: monitor.geminiEnabledPeriodsCSV, period: .weekly) {
                        limitInputRow(label: "週次上限", value: $monitor.geminiTokenLimitWeekly)
                    }
                    if monitor.isBuiltInPeriodEnabled(csv: monitor.geminiEnabledPeriodsCSV, period: .monthly) {
                        limitInputRow(label: "月次上限", value: $monitor.geminiTokenLimit)
                    }

                    TextField("GCP Project ID (任意)", text: $monitor.gcpProjectId)
                        .textFieldStyle(.roundedBorder)
                        .font(.system(size: 12))
                }
                .padding(12)
                .background(RoundedRectangle(cornerRadius: 8).fill(Color.primary.opacity(0.04)))
            }
            .padding(.trailing, 4)
        }
        .frame(maxHeight: 360)
    }

    @ViewBuilder
    private func builtInPeriodToggleRow(isOpenAI: Bool, csv: String) -> some View {
        HStack(spacing: 6) {
            Text("表示枠")
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
            Spacer()
            ForEach(LimitPeriod.allCases) { period in
                let isOn = monitor.isBuiltInPeriodEnabled(csv: csv, period: period)
                Button {
                    monitor.setBuiltInPeriod(isOpenAI: isOpenAI, period: period, enabled: !isOn)
                } label: {
                    Text(period.label)
                        .font(.system(size: 12, weight: isOn ? .semibold : .regular))
                        .foregroundStyle(isOn ? .primary : .secondary)
                        .padding(.horizontal, 7)
                        .padding(.vertical, 4)
                        .background(
                            RoundedRectangle(cornerRadius: 5, style: .continuous)
                                .fill(isOn ? Color.primary.opacity(0.14) : Color.primary.opacity(0.04))
                        )
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
        }
    }

    @ViewBuilder
    private var customSubscriptionsSettingsView: some View {
        VStack(alignment: .leading, spacing: 10) {
            // Row 1: Primary AI Services + Auto-detect
            HStack(spacing: 5) {
                Button("+ Grok") { monitor.addSubscription(.grokbotPreset()) }
                Button("+ Claude") { monitor.addSubscription(.claudePreset()) }
                Button("+ Cursor") { monitor.addSubscription(.cursorPreset()) }
                Button("+ Windsurf") { monitor.addSubscription(.windsurfPreset()) }
                Button("+ Copilot") { monitor.addSubscription(.copilotPreset()) }
            }
            .controlSize(.small)
            .font(.system(size: 12))

            // Row 2: Extended AI Services + Custom + Auto-detect
            HStack(spacing: 5) {
                Button("+ Devin") { monitor.addSubscription(.devinPreset()) }
                Button("+ Perplexity") { monitor.addSubscription(.perplexityPreset()) }
                Button("+ DeepSeek") { monitor.addSubscription(.deepseekPreset()) }
                Button("+ Poe") { monitor.addSubscription(.poePreset()) }
                Button("+ 新規") { monitor.addSubscription(.blankCustom()) }
                Spacer()
                Button("自動検出") {
                    monitor.autoAddDetectedSubscriptions()
                }
                .help("このMacにインストールされているAIツールを自動追加します")
            }
            .controlSize(.small)
            .font(.system(size: 12))

            if monitor.customSubscriptions.isEmpty {
                Text("上のボタンから監視したいAIサービスを追加できます。")
                    .font(.system(size: 13))
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .center)
                    .padding(.vertical, 32)
            } else {
                ScrollView {
                    VStack(alignment: .leading, spacing: 12) {
                        ForEach($monitor.customSubscriptions) { $sub in
                            customSubscriptionEditorCard(sub: $sub)
                        }
                    }
                    .padding(.trailing, 4)
                }
                .frame(maxHeight: 300)
            }
        }
    }

    @ViewBuilder
    private func customSubscriptionEditorCard(sub: Binding<CustomSubscriptionConfig>) -> some View {
        let currentSub = sub.wrappedValue
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                Toggle("", isOn: sub.isEnabled)
                    .labelsHidden()
                    .controlSize(.regular)
                TextField("名前", text: sub.name)
                    .textFieldStyle(.roundedBorder)
                    .font(.system(size: 13.5, weight: .bold))
                TextField("略称", text: sub.shortName)
                    .textFieldStyle(.roundedBorder)
                    .font(.system(size: 13))
                    .frame(width: 56)
                Toggle("メニューバー", isOn: sub.showInMenuBar)
                    .font(.system(size: 12.5))
                    .controlSize(.small)
                Button {
                    monitor.removeSubscription(id: currentSub.id)
                } label: {
                    Image(systemName: "trash")
                        .font(.system(size: 13))
                        .foregroundStyle(.secondary)
                        .padding(4)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }

            HStack(spacing: 6) {
                Text("表示枠")
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                Spacer()
                ForEach(LimitPeriod.allCases) { period in
                    let isOn = currentSub.isPeriodEnabled(period)
                    Button {
                        sub.wrappedValue.setPeriod(period, enabled: !isOn)
                    } label: {
                        Text(period.label)
                            .font(.system(size: 12, weight: isOn ? .semibold : .regular))
                            .foregroundStyle(isOn ? .primary : .secondary)
                            .padding(.horizontal, 7)
                            .padding(.vertical, 4)
                            .background(
                                RoundedRectangle(cornerRadius: 5, style: .continuous)
                                    .fill(isOn ? Color.primary.opacity(0.14) : Color.primary.opacity(0.04))
                            )
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                }
            }

            if currentSub.isPeriodEnabled(.twoHours) {
                periodPairRow(label: "2時間 (使用 / 上限)", used: sub.manualUsed2h, limit: sub.limit2h)
            }
            if currentSub.isPeriodEnabled(.fiveHours) {
                periodPairRow(label: "5時間 (使用 / 上限)", used: sub.manualUsed5h, limit: sub.limit5h)
            }
            if currentSub.isPeriodEnabled(.daily) {
                periodPairRow(label: "1日 (使用 / 上限)", used: sub.manualUsedDaily, limit: sub.limitDaily)
            }
            if currentSub.isPeriodEnabled(.weekly) {
                periodPairRow(label: "週次 (使用 / 上限)", used: sub.manualUsedWeekly, limit: sub.limitWeekly)
            }
            if currentSub.isPeriodEnabled(.monthly) {
                periodPairRow(label: "月次 (使用 / 上限)", used: sub.manualUsedMonthly, limit: sub.limitMonthly)
            }

            HStack {
                Text("月額料金 ($)")
                    .font(.system(size: 12.5))
                    .foregroundStyle(.secondary)
                Spacer()
                TextField("USD", value: sub.usedCostUSD, format: .number)
                    .textFieldStyle(.roundedBorder)
                    .font(.system(size: 12.5))
                    .frame(width: 90)
            }
        }
        .padding(12)
        .background(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(Color.primary.opacity(0.04))
        )
    }

    @ViewBuilder
    private func periodPairRow(label: String, used: Binding<Int>, limit: Binding<Int>) -> some View {
        HStack(spacing: 6) {
            Text(label)
                .font(.system(size: 12.5))
                .foregroundStyle(.secondary)
            Spacer()
            TextField("使用", value: used, format: .number)
                .textFieldStyle(.roundedBorder)
                .font(.system(size: 12))
                .frame(width: 90)
            Text("/")
                .foregroundStyle(.secondary)
            TextField("上限", value: limit, format: .number)
                .textFieldStyle(.roundedBorder)
                .font(.system(size: 12))
                .frame(width: 90)
        }
    }

    @ViewBuilder
    private func limitInputRow(label: String, value: Binding<Int>) -> some View {
        HStack {
            Text(label)
                .font(.system(size: 12.5))
                .foregroundStyle(.secondary)
            Spacer()
            TextField("Tokens", value: value, format: .number)
                .textFieldStyle(.roundedBorder)
                .font(.system(size: 12))
                .frame(width: 130)
        }
    }
}

// MARK: - Window Accessor for Reliable Floating Window Configuration
final class FirstMouseHostingHelperView: NSView {
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool {
        true
    }
}

struct DesktopWidgetWindowAccessor: NSViewRepresentable {
    var allowBackgroundDrag: Bool = true

    func makeNSView(context: Context) -> NSView {
        let view = FirstMouseHostingHelperView()
        DispatchQueue.main.async {
            if let window = view.window {
                Self.configure(window: window, allowBackgroundDrag: allowBackgroundDrag)
            }
        }
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        DispatchQueue.main.async {
            if let window = nsView.window {
                Self.configure(window: window, allowBackgroundDrag: allowBackgroundDrag)
            }
        }
    }

    static func configure(window: NSWindow, allowBackgroundDrag: Bool) {
        window.level = .floating
        window.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        window.isMovableByWindowBackground = allowBackgroundDrag
        window.backgroundColor = .clear
        window.isOpaque = false
        window.hasShadow = true
        window.titleVisibility = .hidden
        window.titlebarAppearsTransparent = true
        window.standardWindowButton(.closeButton)?.isHidden = true
        window.standardWindowButton(.miniaturizeButton)?.isHidden = true
        window.standardWindowButton(.zoomButton)?.isHidden = true
        window.setFrameAutosaveName("AIMeterDesktopWidgetFrame")
        if !allowBackgroundDrag {
            NSApplication.shared.activate(ignoringOtherApps: true)
            window.makeKeyAndOrderFront(nil)
        }
    }
}

// MARK: - Main Card View (Simple, High-Legibility Design)
struct AIMeterCardView: View {
    @ObservedObject var monitor: UsageMonitor
    var isMenuBar: Bool = false
    @State private var showSettings: Bool = false
    @State private var showSetupWizard: Bool = false
    @State private var showHelp: Bool = false
    @State private var filterSelection: String = "all"
    @Environment(\.openWindow) private var openWindow

    private var isDisplayingWizard: Bool {
        showSetupWizard || !monitor.hasCompletedSetupWizard
    }

    private static let timeFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "HH:mm"
        return f
    }()

    private var selectedPeriodFilter: LimitPeriod? {
        LimitPeriod(rawValue: filterSelection)
    }

    private var highlightedMenuBarPeriod: LimitPeriod? {
        LimitPeriod(rawValue: monitor.menuBarPeriodMode)
    }

    private var enabledCustomSubscriptions: [CustomSubscriptionConfig] {
        monitor.customSubscriptions.filter(\.isEnabled)
    }

    private func hasMatchingPeriod(metrics: [PeriodUsageMetric]) -> Bool {
        if let filter = selectedPeriodFilter {
            return metrics.contains { $0.period == filter }
        }
        return true
    }

    private var isShowOpenAI: Bool {
        monitor.showOpenAISection && hasMatchingPeriod(metrics: monitor.openaiMetrics)
    }

    private var isShowGemini: Bool {
        monitor.showGeminiSection && hasMatchingPeriod(metrics: monitor.geminiMetrics)
    }

    private var visibleCustomSubscriptions: [CustomSubscriptionConfig] {
        enabledCustomSubscriptions.filter { sub in
            hasMatchingPeriod(metrics: monitor.metrics(for: sub))
        }
    }

    private var totalVisibleProvidersCount: Int {
        (isShowOpenAI ? 1 : 0) + (isShowGemini ? 1 : 0) + visibleCustomSubscriptions.count
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if showHelp {
                HelpView {
                    withAnimation(.easeInOut(duration: 0.15)) {
                        showHelp = false
                    }
                }
            } else if isDisplayingWizard {
                SetupWizardView(
                    monitor: monitor,
                    onOpenHelp: {
                        withAnimation(.easeInOut(duration: 0.15)) {
                            showHelp = true
                        }
                    },
                    onComplete: {
                        withAnimation(.easeInOut(duration: 0.15)) {
                            monitor.hasCompletedSetupWizard = true
                            showSetupWizard = false
                        }
                    }
                )
            } else if showSettings {
                SettingsPopoverView(
                    monitor: monitor,
                    onOpenSetupWizard: {
                        withAnimation(.easeInOut(duration: 0.15)) {
                            showSettings = false
                            showSetupWizard = true
                        }
                    },
                    onOpenHelp: {
                        withAnimation(.easeInOut(duration: 0.15)) {
                            showSettings = false
                            showHelp = true
                        }
                    },
                    onClose: {
                        withAnimation(.easeInOut(duration: 0.15)) {
                            showSettings = false
                        }
                    }
                )
            } else {
                // Header
                HStack(spacing: 6) {
                    Text("AIMeter")
                        .font(.system(size: 13.5, weight: .bold))
                        .foregroundStyle(.primary)

                    Spacer()

                    Button {
                        Task {
                            await monitor.refresh()
                        }
                    } label: {
                        Image(systemName: "arrow.clockwise")
                            .font(.system(size: 11, weight: .medium))
                            .foregroundStyle(.secondary)
                            .frame(width: 24, height: 22)
                            .background(
                                RoundedRectangle(cornerRadius: 5, style: .continuous)
                                    .fill(Color.primary.opacity(0.06))
                            )
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .help("更新")
                    .accessibilityLabel("今すぐ更新")

                    Button {
                        withAnimation(.easeInOut(duration: 0.15)) {
                            showHelp = true
                        }
                    } label: {
                        Image(systemName: "questionmark.circle")
                            .font(.system(size: 11, weight: .medium))
                            .foregroundStyle(.secondary)
                            .frame(width: 24, height: 22)
                            .background(
                                RoundedRectangle(cornerRadius: 5, style: .continuous)
                                    .fill(Color.primary.opacity(0.06))
                            )
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .help("ヘルプ & Q&A")
                    .accessibilityLabel("ヘルプを開く")

                    Button {
                        NSApplication.shared.activate(ignoringOtherApps: true)
                        withAnimation(.easeInOut(duration: 0.15)) {
                            showSettings = true
                        }
                    } label: {
                        HStack(spacing: 3) {
                            Image(systemName: "slider.horizontal.3")
                            Text("設定")
                        }
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(.secondary)
                        .padding(.horizontal, 7)
                        .frame(height: 22)
                        .background(
                            RoundedRectangle(cornerRadius: 5, style: .continuous)
                                .fill(Color.primary.opacity(0.06))
                        )
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .help("設定・サブスク管理")
                    .accessibilityLabel("設定を開く")
                }

                // Period Filter Bar
                Picker("", selection: $filterSelection) {
                    Text("すべて").tag("all")
                    ForEach(LimitPeriod.allCases) { period in
                        Text(period.label).tag(period.rawValue)
                    }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .controlSize(.small)

                // Provider Sections
                if totalVisibleProvidersCount == 0 {
                    VStack(spacing: 6) {
                        Image(systemName: "line.3.horizontal.decrease.circle")
                            .font(.system(size: 18))
                            .foregroundStyle(.tertiary)
                        Text("\(selectedPeriodFilter?.label ?? "")枠が設定されているサービスはありません")
                            .font(.system(size: 11.5))
                            .foregroundStyle(.secondary)
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 20)
                } else if totalVisibleProvidersCount > 2 {
                    ScrollView {
                        providerSectionsStack
                    }
                    .frame(maxHeight: 340)
                } else {
                    providerSectionsStack
                }

                // Quiet Footer
                HStack {
                    Text("\(Self.timeFormatter.string(from: monitor.lastUpdated)) 更新")
                        .font(.system(size: 10.5).monospacedDigit())
                        .foregroundStyle(.tertiary)
                    Spacer()
                    Text(String(format: "月間計 $%.2f", monitor.totalCostUSD))
                        .font(.system(size: 11.5, weight: .semibold).monospacedDigit())
                        .foregroundStyle(.secondary)
                }
                .padding(.top, 1)

                if isMenuBar {
                    Divider()
                    HStack {
                        Button("ウィジェットを表示") {
                            openWindow(id: "desktop-widget")
                        }
                        .controlSize(.small)

                        Spacer()

                        Button("終了") {
                            NSApplication.shared.terminate(nil)
                        }
                        .controlSize(.small)
                    }
                }
            }
        }
        .padding(12)
        .frame(width: showHelp ? 480 : ((isDisplayingWizard && !showHelp) ? 550 : (showSettings ? 420 : 310)))
        .background(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(.regularMaterial)
                .overlay(
                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .strokeBorder(Color.primary.opacity(0.1), lineWidth: 0.5)
                )
        )
        .background(
            Group {
                if !isMenuBar {
                    DesktopWidgetWindowAccessor(allowBackgroundDrag: !showSettings && !isDisplayingWizard && !showHelp)
                }
            }
        )
    }

    @ViewBuilder
    private var providerSectionsStack: some View {
        VStack(alignment: .leading, spacing: 6) {
            if isShowOpenAI {
                ProviderUsageSection(
                    title: "OpenAI",
                    subtitle: monitor.openaiStatus,
                    usedCostUSD: monitor.openaiCostUSD,
                    budgetUSD: monitor.openaiBudgetUSD,
                    metrics: monitor.openaiMetrics,
                    selectedFilter: selectedPeriodFilter,
                    highlightedPeriod: highlightedMenuBarPeriod
                )
            }

            if isShowGemini {
                ProviderUsageSection(
                    title: "Gemini",
                    subtitle: monitor.geminiStatus,
                    usedCostUSD: monitor.geminiCostUSD,
                    budgetUSD: monitor.geminiBudgetUSD,
                    metrics: monitor.geminiMetrics,
                    selectedFilter: selectedPeriodFilter,
                    highlightedPeriod: highlightedMenuBarPeriod
                )
            }

            ForEach(visibleCustomSubscriptions) { sub in
                ProviderUsageSection(
                    title: sub.name,
                    subtitle: monitor.customProviderLiveUsage[sub.id]?.status ?? sub.statusNote,
                    usedCostUSD: monitor.effectiveCostUSD(for: sub),
                    budgetUSD: sub.budgetUSD,
                    metrics: monitor.metrics(for: sub),
                    selectedFilter: selectedPeriodFilter,
                    highlightedPeriod: highlightedMenuBarPeriod
                )
            }
        }
    }
}

// MARK: - App Entrypoint
@main
struct AIMeterApp: App {
    @StateObject private var monitor = UsageMonitor()

    var body: some Scene {
        Window("AI Meter Widget", id: "desktop-widget") {
            AIMeterCardView(monitor: monitor, isMenuBar: false)
        }
        .windowStyle(.hiddenTitleBar)
        .windowResizability(.contentSize)

        MenuBarExtra {
            AIMeterCardView(monitor: monitor, isMenuBar: true)
        } label: {
            Text(monitor.menuBarTitle)
                .font(.system(size: 13, weight: .semibold).monospacedDigit())
        }
        .menuBarExtraStyle(.window)
    }
}
