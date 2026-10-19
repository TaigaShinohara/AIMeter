import SwiftUI
import AppKit
import Foundation
import Security

// MARK: - Limit Period Type
enum LimitPeriod: String, CaseIterable, Codable, Identifiable {
    case fiveHours = "5h"
    case daily = "1d"
    case weekly = "7d"
    case monthly = "30d"

    var id: String { rawValue }

    var label: String {
        switch self {
        case .fiveHours: return "5時間"
        case .daily: return "1日"
        case .weekly: return "週次"
        case .monthly: return "月次"
        }
    }

    var shortLabel: String {
        switch self {
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
        max(0, effectiveLimitTokens - usedTokens)
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

// MARK: - Local JSON Model
struct ProviderPeriodUsageJSON: Codable, Equatable {
    var fiveHours: Int?
    var daily: Int?
    var weekly: Int?
    var monthly: Int?

    enum CodingKeys: String, CodingKey {
        case fiveHours = "5h"
        case daily = "1d"
        case weekly = "7d"
        case monthly = "30d"
    }
}

struct ProviderPeriodPercentJSON: Codable, Equatable {
    var fiveHours: Double?
    var daily: Double?
    var weekly: Double?
    var monthly: Double?

    enum CodingKeys: String, CodingKey {
        case fiveHours = "5h"
        case daily = "1d"
        case weekly = "7d"
        case monthly = "30d"
    }
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
    @AppStorage("openaiAdminKey") var legacyOpenaiAdminKey: String = ""
    @Published var openaiAdminKey: String = "" {
        didSet {
            KeychainHelper.save(key: "openaiAdminKey", value: openaiAdminKey)
        }
    }

    // OpenAI Token Limits per Period (calibrated for real Codex/OpenAI usage)
    @AppStorage("openaiTokenLimit5h") var openaiTokenLimit5h: Int = 40_000_000
    @AppStorage("openaiTokenLimitDaily") var openaiTokenLimitDaily: Int = 80_000_000
    @AppStorage("openaiTokenLimitWeekly") var openaiTokenLimitWeekly: Int = 290_000_000
    @AppStorage("openaiTokenLimit") var openaiTokenLimit: Int = 800_000_000
    @AppStorage("openaiBudgetUSD") var openaiBudgetUSD: Double = 600.0

    // Gemini Token Limits per Period (calibrated for real Antigravity/Gemini usage)
    @AppStorage("gcpProjectId") var gcpProjectId: String = ""
    @AppStorage("geminiTokenLimit5h") var geminiTokenLimit5h: Int = 1_500_000
    @AppStorage("geminiTokenLimitDaily") var geminiTokenLimitDaily: Int = 4_000_000
    @AppStorage("geminiTokenLimitWeekly") var geminiTokenLimitWeekly: Int = 15_000_000
    @AppStorage("geminiTokenLimit") var geminiTokenLimit: Int = 40_000_000
    @AppStorage("geminiBudgetUSD") var geminiBudgetUSD: Double = 20.0

    // MenuBar Display Period Mode ("min" = bottleneck or LimitPeriod.rawValue)
    @AppStorage("menuBarPeriodMode") var menuBarPeriodMode: String = "min"

    // OpenAI Used Tokens per Period
    @Published var openaiUsed5h: Int = 0
    @Published var openaiUsedDaily: Int = 0
    @Published var openaiUsedWeekly: Int = 0
    @Published var openaiUsedTokens: Int = 0 // Monthly
    @Published var openaiServerPct: ProviderPeriodPercentJSON? = nil
    @Published var openaiResetAt: ProviderPeriodUsageJSON? = nil
    @Published var openaiCostUSD: Double = 0.0
    @Published var openaiStatus: String = "実ログ集計中"

    // Gemini Used Tokens per Period
    @Published var geminiUsed5h: Int = 0
    @Published var geminiUsedDaily: Int = 0
    @Published var geminiUsedWeekly: Int = 0
    @Published var geminiUsedTokens: Int = 0 // Monthly
    @Published var geminiCostUSD: Double = 0.0
    @Published var geminiStatus: String = "実ログ集計中"

    @Published var lastUpdated: Date = Date()
    @Published var isRefreshing: Bool = false

    private var timer: Timer?
    private var wakeObserver: NSObjectProtocol?
    private let urlSession: URLSession

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

        // One-time upgrade from initial mock defaults to real-usage scale
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

    func sanitizeSettings() {
        if openaiTokenLimit5h < 1 { openaiTokenLimit5h = 1 }
        if openaiTokenLimitDaily < 1 { openaiTokenLimitDaily = 1 }
        if openaiTokenLimitWeekly < 1 { openaiTokenLimitWeekly = 1 }
        if openaiTokenLimit < 1 { openaiTokenLimit = 1 }
        if openaiBudgetUSD < 0 { openaiBudgetUSD = 0 }

        if geminiTokenLimit5h < 1 { geminiTokenLimit5h = 1 }
        if geminiTokenLimitDaily < 1 { geminiTokenLimitDaily = 1 }
        if geminiTokenLimitWeekly < 1 { geminiTokenLimitWeekly = 1 }
        if geminiTokenLimit < 1 { geminiTokenLimit = 1 }
        if geminiBudgetUSD < 0 { geminiBudgetUSD = 0 }
    }

    var openaiMetrics: [PeriodUsageMetric] {
        [
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
    }

    var geminiMetrics: [PeriodUsageMetric] {
        [
            PeriodUsageMetric(period: .fiveHours, usedTokens: geminiUsed5h, limitTokens: geminiTokenLimit5h),
            PeriodUsageMetric(period: .daily, usedTokens: geminiUsedDaily, limitTokens: geminiTokenLimitDaily),
            PeriodUsageMetric(period: .weekly, usedTokens: geminiUsedWeekly, limitTokens: geminiTokenLimitWeekly),
            PeriodUsageMetric(period: .monthly, usedTokens: geminiUsedTokens, limitTokens: geminiTokenLimit)
        ]
    }

    var openaiRemainingTokens: Int {
        max(0, openaiTokenLimit - openaiUsedTokens)
    }

    var openaiRemainingRatio: Double {
        guard openaiTokenLimit > 0 else { return 0 }
        return min(1.0, max(0.0, Double(openaiRemainingTokens) / Double(openaiTokenLimit)))
    }

    var geminiRemainingTokens: Int {
        max(0, geminiTokenLimit - geminiUsedTokens)
    }

    var geminiRemainingRatio: Double {
        guard geminiTokenLimit > 0 else { return 0 }
        return min(1.0, max(0.0, Double(geminiRemainingTokens) / Double(geminiTokenLimit)))
    }

    var totalCostUSD: Double {
        openaiCostUSD + geminiCostUSD
    }

    func activeRatio(for metrics: [PeriodUsageMetric]) -> Double {
        if menuBarPeriodMode == "min" {
            return metrics.map(\.remainingRatio).min() ?? 0.0
        }
        if let period = LimitPeriod(rawValue: menuBarPeriodMode),
           let matched = metrics.first(where: { $0.period == period }) {
            return matched.remainingRatio
        }
        return metrics.last?.remainingRatio ?? 0.0
    }

    var menuBarTitle: String {
        let gptPct = Int((activeRatio(for: openaiMetrics) * 100).rounded())
        let gemPct = Int((activeRatio(for: geminiMetrics) * 100).rounded())
        let suffix: String
        if menuBarPeriodMode == "min" {
            suffix = "min"
        } else if let period = LimitPeriod(rawValue: menuBarPeriodMode) {
            suffix = period.shortLabel
        } else {
            suffix = "1m"
        }
        return String(format: "GPT:%d%% Gem:%d%% (%@)", gptPct, gemPct, suffix)
    }

    func refresh() async {
        guard !isRefreshing else { return }
        isRefreshing = true
        sanitizeSettings()
        defer {
            lastUpdated = Date()
            isRefreshing = false
        }

        // 0. Automatically run local log collector script to update ~/.ai_meter_usage.json from ~/.codex and ~/.gemini
        await runLocalCollectorScript()

        // 1. Load local JSON
        let localData = loadLocalJSON()
        if let localData {
            let monthlyOpenAI = max(0, localData.openaiUsedByPeriod?.monthly ?? localData.openaiUsedTokens ?? 0)
            openaiUsedTokens = monthlyOpenAI
            openaiUsedWeekly = max(0, localData.openaiUsedByPeriod?.weekly ?? min(monthlyOpenAI, Int(Double(monthlyOpenAI) * 0.45)))
            openaiUsedDaily = max(0, localData.openaiUsedByPeriod?.daily ?? min(openaiUsedWeekly, Int(Double(monthlyOpenAI) * 0.12)))
            openaiUsed5h = max(0, localData.openaiUsedByPeriod?.fiveHours ?? min(openaiUsedDaily, Int(Double(monthlyOpenAI) * 0.05)))
            openaiServerPct = localData.openaiServerUsedPercentByPeriod
            openaiResetAt = localData.openaiResetAtByPeriod
            openaiCostUSD = max(0.0, localData.openaiCostUSD ?? 0.0)

            let monthlyGemini = max(0, localData.geminiUsedByPeriod?.monthly ?? localData.geminiUsedTokens ?? 0)
            geminiUsedTokens = monthlyGemini
            geminiUsedWeekly = max(0, localData.geminiUsedByPeriod?.weekly ?? min(monthlyGemini, Int(Double(monthlyGemini) * 0.40)))
            geminiUsedDaily = max(0, localData.geminiUsedByPeriod?.daily ?? min(geminiUsedWeekly, Int(Double(monthlyGemini) * 0.10)))
            geminiUsed5h = max(0, localData.geminiUsedByPeriod?.fiveHours ?? min(geminiUsedDaily, Int(Double(monthlyGemini) * 0.04)))
            geminiCostUSD = max(0.0, localData.geminiCostUSD ?? 0.0)

            if let plan = localData.openaiPlanType, !plan.isEmpty {
                openaiStatus = "Codex (\(plan)) 実ログ"
            } else {
                openaiStatus = "ローカル実ログ"
            }
            geminiStatus = "Antigravity/CLI実ログ"
        } else {
            openaiUsed5h = 0
            openaiUsedDaily = 0
            openaiUsedWeekly = 0
            openaiUsedTokens = 0
            openaiServerPct = nil
            openaiResetAt = nil
            openaiCostUSD = 0.0

            geminiUsed5h = 0
            geminiUsedDaily = 0
            geminiUsedWeekly = 0
            geminiUsedTokens = 0
            geminiCostUSD = 0.0

            openaiStatus = "未設定 (JSONなし)"
            geminiStatus = "未設定 (JSONなし)"
        }

        // 2. Fetch OpenAI API if openaiAdminKey is provided
        let trimmedOpenAIKey = openaiAdminKey.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmedOpenAIKey.isEmpty {
            await fetchOpenAIUsage(apiKey: trimmedOpenAIKey)
        }

        // 3. Fetch Gemini Cloud Monitoring API if gcpProjectId is provided
        let trimmedProjectId = gcpProjectId.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmedProjectId.isEmpty {
            await fetchGeminiUsage(projectId: trimmedProjectId)
        }
    }

    private func runLocalCollectorScript() async {
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            DispatchQueue.global(qos: .utility).async {
                let bundledScript = Bundle.main.path(forResource: "update_usage", ofType: "py")
                let fallbackScript = "/Volumes/SSD-1TB/Projects/Apps/AIMeter/scripts/update_usage.py"
                let scriptPath: String?
                if let b = bundledScript, FileManager.default.fileExists(atPath: b) {
                    scriptPath = b
                } else if FileManager.default.fileExists(atPath: fallbackScript) {
                    scriptPath = fallbackScript
                } else {
                    scriptPath = nil
                }

                guard let resolvedScript = scriptPath else {
                    continuation.resume()
                    return
                }

                let process = Process()
                process.executableURL = URL(fileURLWithPath: "/usr/bin/python3")
                process.arguments = [resolvedScript]
                process.standardOutput = Pipe()
                process.standardError = Pipe()

                do {
                    try process.run()
                } catch {
                    continuation.resume()
                    return
                }

                let timeoutWorkItem = DispatchWorkItem {
                    if process.isRunning {
                        process.terminate()
                    }
                }
                DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + 10.0, execute: timeoutWorkItem)

                process.waitUntilExit()
                timeoutWorkItem.cancel()
                continuation.resume()
            }
        }
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
            }

            if let totalCost = try? await fetchPaginatedOpenAICosts(apiKey: apiKey, startTime: monthStart) {
                self.openaiCostUSD = totalCost
            }
            openaiStatus = "OpenAI API連携中"
        } catch {
            openaiStatus = "API失敗 (実ログ維持)"
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
            geminiStatus = "gcloud未認証 (実ログ参照)"
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

                if let w = try? await queryCloudMonitoring(projectId: projectId, token: token, filter: tokenFilter, startStr: weekStartStr, endStr: endStr) {
                    self.geminiUsedWeekly = w
                }
                if let d = try? await queryCloudMonitoring(projectId: projectId, token: token, filter: tokenFilter, startStr: dayStartStr, endStr: endStr) {
                    self.geminiUsedDaily = d
                }
                if let h = try? await queryCloudMonitoring(projectId: projectId, token: token, filter: tokenFilter, startStr: fiveHStartStr, endStr: endStr) {
                    self.geminiUsed5h = h
                }

                geminiStatus = "GCPトークン連携中"
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
                geminiStatus = "GCP (\(reqCount) reqs / 実ログ併用)"
            } else {
                geminiStatus = "GCP連携済 (実ログ併用)"
            }
        } catch {
            geminiStatus = "Cloud API未取得 (実ログ維持)"
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
        return .green
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

// MARK: - Single Period Limit Row View
struct PeriodLimitRowView: View {
    let metric: PeriodUsageMetric
    let isHighlighted: Bool

    var body: some View {
        let ratio = metric.remainingRatio
        let pct = metric.remainingPercent

        VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: 4) {
                HStack(spacing: 2) {
                    Text(metric.period.label)
                        .font(.system(size: 10, weight: isHighlighted ? .bold : .semibold))
                        .foregroundStyle(isHighlighted ? .primary : .secondary)
                    if metric.serverUsedPercent != nil {
                        Image(systemName: "checkmark.seal.fill")
                            .font(.system(size: 8))
                            .foregroundStyle(.cyan)
                            .help("サーバー公式レート制限値と同期済み")
                    }
                }
                .frame(width: 44, alignment: .leading)

                GeometryReader { geo in
                    ZStack(alignment: .leading) {
                        Capsule()
                            .fill(Color.primary.opacity(0.12))
                            .frame(height: 6)
                        Capsule()
                            .fill(gaugeColor(for: ratio))
                            .frame(width: max(3, geo.size.width * ratio), height: 6)
                            .animation(.easeInOut(duration: 0.25), value: ratio)
                    }
                }
                .frame(height: 6)

                HStack(spacing: 2) {
                    if let warningSymbol = gaugeWarningSymbol(for: ratio) {
                        Image(systemName: warningSymbol)
                            .font(.system(size: 9))
                            .foregroundStyle(gaugeColor(for: ratio))
                    }
                    Text("\(formatTokenCount(metric.remainingTokens))/\(formatTokenCount(metric.effectiveLimitTokens))")
                        .font(.system(size: 10, design: .monospaced))
                        .foregroundStyle(.secondary)
                    Text(String(format: "%3d%%", pct))
                        .font(.system(size: 10, weight: .semibold, design: .monospaced))
                        .foregroundStyle(gaugeColor(for: ratio))
                        .frame(width: 32, alignment: .trailing)
                }
            }

            if let resetStr = formatResetTimestamp(metric.resetTimestamp) {
                HStack {
                    Spacer()
                    Text("リセット: \(resetStr)")
                        .font(.system(size: 9, design: .monospaced))
                        .foregroundStyle(.secondary.opacity(0.85))
                }
            }
        }
        .padding(.vertical, 2)
        .padding(.horizontal, 4)
        .background(
            RoundedRectangle(cornerRadius: 5, style: .continuous)
                .fill(isHighlighted ? Color.primary.opacity(0.06) : Color.clear)
        )
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(metric.period.label)制限")
        .accessibilityValue("残り \(formatTokenCount(metric.remainingTokens)) / 上限 \(formatTokenCount(metric.effectiveLimitTokens)) (\(pct)パーセント)")
    }
}

// MARK: - Provider Section View
struct ProviderUsageSection: View {
    let title: String
    let iconName: String
    let usedCostUSD: Double
    let budgetUSD: Double
    let metrics: [PeriodUsageMetric]
    let selectedFilter: LimitPeriod?
    let highlightedPeriod: LimitPeriod?
    let status: String

    var displayedMetrics: [PeriodUsageMetric] {
        if let filter = selectedFilter {
            return metrics.filter { $0.period == filter }
        }
        return metrics
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Label(title, systemImage: iconName)
                    .font(.system(size: 13, weight: .semibold))
                Spacer()
                Text(String(format: "$%.2f / $%.2f", usedCostUSD, budgetUSD))
                    .font(.system(size: 12, weight: .medium, design: .monospaced))
                    .foregroundStyle(.primary)
            }

            VStack(spacing: 3) {
                ForEach(displayedMetrics) { metric in
                    PeriodLimitRowView(
                        metric: metric,
                        isHighlighted: highlightedPeriod == metric.period && selectedFilter == nil
                    )
                }
            }

            HStack {
                if let minMetric = metrics.min(by: { $0.remainingRatio < $1.remainingRatio }) {
                    Text("最小残量枠: \(minMetric.period.label) (\(minMetric.remainingPercent)%)")
                        .font(.system(size: 10, design: .monospaced))
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Text(status)
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
        }
        .padding(10)
        .background(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(Color.primary.opacity(0.05))
        )
    }
}

// MARK: - Settings Popover View
struct SettingsPopoverView: View {
    @ObservedObject var monitor: UsageMonitor
    @State private var revealAdminKey: Bool = false

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("AIMeter 制限・API設定")
                .font(.headline)

            HStack {
                Text("メニューバー表示基準:")
                    .font(.caption)
                Spacer()
                Picker("", selection: $monitor.menuBarPeriodMode) {
                    Text("最小残量 (min)").tag("min")
                    Text("5時間 (5h)").tag("5h")
                    Text("1日 (1d)").tag("1d")
                    Text("週次 (7d)").tag("7d")
                    Text("月次 (30d)").tag("30d")
                }
                .labelsHidden()
                .frame(width: 135)
            }

            Divider()

            // OpenAI Settings
            VStack(alignment: .leading, spacing: 5) {
                Text("OpenAI / Codex 設定 (Keychain保護)").font(.subheadline.bold())
                HStack(spacing: 4) {
                    if revealAdminKey {
                        TextField("Admin Key (任意 / 未設定時はCodex実ログ)", text: $monitor.openaiAdminKey)
                            .textFieldStyle(.roundedBorder)
                    } else {
                        SecureField("Admin Key (任意 / 未設定時はCodex実ログ)", text: $monitor.openaiAdminKey)
                            .textFieldStyle(.roundedBorder)
                    }
                    Button {
                        revealAdminKey.toggle()
                    } label: {
                        Image(systemName: revealAdminKey ? "eye.slash" : "eye")
                            .font(.system(size: 11))
                    }
                    .buttonStyle(.borderless)
                }

                limitInputRow(label: "5時間上限トークン:", value: $monitor.openaiTokenLimit5h)
                limitInputRow(label: "1日上限トークン:", value: $monitor.openaiTokenLimitDaily)
                limitInputRow(label: "週次上限トークン:", value: $monitor.openaiTokenLimitWeekly)
                limitInputRow(label: "月次上限トークン:", value: $monitor.openaiTokenLimit)

                HStack {
                    Text("月間予算目安 ($):").font(.caption)
                    Spacer()
                    TextField("USD", value: $monitor.openaiBudgetUSD, format: .number)
                        .textFieldStyle(.roundedBorder)
                        .frame(width: 105)
                }
            }

            Divider()

            // Gemini Settings
            VStack(alignment: .leading, spacing: 5) {
                Text("Gemini / Antigravity 設定").font(.subheadline.bold())
                TextField("GCP Project ID (任意 / 未設定時は実ログ)", text: $monitor.gcpProjectId)
                    .textFieldStyle(.roundedBorder)

                limitInputRow(label: "5時間上限トークン:", value: $monitor.geminiTokenLimit5h)
                limitInputRow(label: "1日上限トークン:", value: $monitor.geminiTokenLimitDaily)
                limitInputRow(label: "週次上限トークン:", value: $monitor.geminiTokenLimitWeekly)
                limitInputRow(label: "月次上限トークン:", value: $monitor.geminiTokenLimit)

                HStack {
                    Text("月間予算目安 ($):").font(.caption)
                    Spacer()
                    TextField("USD", value: $monitor.geminiBudgetUSD, format: .number)
                        .textFieldStyle(.roundedBorder)
                        .frame(width: 105)
                }
            }

            Divider()

            HStack {
                Text("自動集計: ~/.codex & ~/.gemini")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                Spacer()
                Button("反映して更新") {
                    monitor.sanitizeSettings()
                    Task {
                        await monitor.refresh()
                    }
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.small)
            }
        }
        .padding(14)
        .frame(width: 325)
    }

    @ViewBuilder
    private func limitInputRow(label: String, value: Binding<Int>) -> some View {
        HStack {
            Text(label).font(.caption)
            Spacer()
            TextField("Tokens", value: value, format: .number)
                .textFieldStyle(.roundedBorder)
                .frame(width: 105)
        }
    }
}

// MARK: - Window Accessor for Reliable Floating Window Configuration
struct DesktopWidgetWindowAccessor: NSViewRepresentable {
    func makeNSView(context: Context) -> NSView {
        let view = NSView()
        DispatchQueue.main.async {
            if let window = view.window {
                Self.configure(window: window)
            }
        }
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        DispatchQueue.main.async {
            if let window = nsView.window {
                Self.configure(window: window)
            }
        }
    }

    static func configure(window: NSWindow) {
        window.level = .floating
        window.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        window.isMovableByWindowBackground = true
        window.backgroundColor = .clear
        window.isOpaque = false
        window.hasShadow = true
        window.titleVisibility = .hidden
        window.titlebarAppearsTransparent = true
        window.standardWindowButton(.closeButton)?.isHidden = true
        window.standardWindowButton(.miniaturizeButton)?.isHidden = true
        window.standardWindowButton(.zoomButton)?.isHidden = true
        window.setFrameAutosaveName("AIMeterDesktopWidgetFrame")
    }
}

// MARK: - Main Card View
struct AIMeterCardView: View {
    @ObservedObject var monitor: UsageMonitor
    var isMenuBar: Bool = false
    @State private var showSettings: Bool = false
    @State private var filterSelection: String = "all"
    @Environment(\.openWindow) private var openWindow

    private static let timeFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "HH:mm:ss"
        return f
    }()

    private var selectedPeriodFilter: LimitPeriod? {
        LimitPeriod(rawValue: filterSelection)
    }

    private var highlightedMenuBarPeriod: LimitPeriod? {
        LimitPeriod(rawValue: monitor.menuBarPeriodMode)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            // Header
            HStack {
                HStack(spacing: 6) {
                    Image(systemName: "gauge.with.dots.needle.67percent")
                        .foregroundStyle(.cyan)
                    Text("AI Meter")
                        .font(.system(size: 14, weight: .bold))
                }
                Spacer()
                Button {
                    Task {
                        await monitor.refresh()
                    }
                } label: {
                    Image(systemName: monitor.isRefreshing ? "arrow.triangle.2.circlepath.circle.fill" : "arrow.clockwise")
                        .font(.system(size: 12, weight: .semibold))
                }
                .buttonStyle(.plain)
                .help("今すぐ更新")
                .accessibilityLabel("今すぐ更新")

                Button {
                    showSettings.toggle()
                } label: {
                    Image(systemName: "gearshape.fill")
                        .font(.system(size: 12, weight: .semibold))
                }
                .buttonStyle(.plain)
                .help("設定")
                .accessibilityLabel("設定を開く")
                .popover(isPresented: $showSettings, arrowEdge: .bottom) {
                    SettingsPopoverView(monitor: monitor)
                }
            }

            // Period Filter Tabs (All / 5h / 1d / Weekly / Monthly)
            Picker("表示枠", selection: $filterSelection) {
                Text("全枠").tag("all")
                ForEach(LimitPeriod.allCases) { period in
                    Text(period.label).tag(period.rawValue)
                }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .controlSize(.small)

            // OpenAI Section
            ProviderUsageSection(
                title: "OpenAI (GPT / Codex)",
                iconName: "sparkles",
                usedCostUSD: monitor.openaiCostUSD,
                budgetUSD: monitor.openaiBudgetUSD,
                metrics: monitor.openaiMetrics,
                selectedFilter: selectedPeriodFilter,
                highlightedPeriod: highlightedMenuBarPeriod,
                status: monitor.openaiStatus
            )

            // Gemini Section
            ProviderUsageSection(
                title: "Google Gemini",
                iconName: "bolt.horizontal.circle.fill",
                usedCostUSD: monitor.geminiCostUSD,
                budgetUSD: monitor.geminiBudgetUSD,
                metrics: monitor.geminiMetrics,
                selectedFilter: selectedPeriodFilter,
                highlightedPeriod: highlightedMenuBarPeriod,
                status: monitor.geminiStatus
            )

            // Footer
            HStack {
                Text("更新: \(Self.timeFormatter.string(from: monitor.lastUpdated))")
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundStyle(.secondary)
                Spacer()
                Text(String(format: "30日相当: $%.2f", monitor.totalCostUSD))
                    .font(.system(size: 12, weight: .bold, design: .monospaced))
            }

            if isMenuBar {
                Divider()
                HStack {
                    Button("今すぐ更新") {
                        Task {
                            await monitor.refresh()
                        }
                    }
                    .controlSize(.small)

                    Button("ウィジェット表示") {
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
        .padding(14)
        .frame(width: 335)
        .background(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .fill(.ultraThinMaterial)
                .overlay(
                    RoundedRectangle(cornerRadius: 16, style: .continuous)
                        .strokeBorder(Color.primary.opacity(0.15), lineWidth: 1)
                )
        )
    }
}

// MARK: - App Entrypoint
@main
struct AIMeterApp: App {
    @StateObject private var monitor = UsageMonitor()

    var body: some Scene {
        Window("AI Meter Widget", id: "desktop-widget") {
            AIMeterCardView(monitor: monitor, isMenuBar: false)
                .background(DesktopWidgetWindowAccessor())
        }
        .windowStyle(.hiddenTitleBar)
        .windowResizability(.contentSize)

        MenuBarExtra {
            AIMeterCardView(monitor: monitor, isMenuBar: true)
        } label: {
            Text(monitor.menuBarTitle)
                .font(.system(size: 12, weight: .medium, design: .monospaced))
        }
        .menuBarExtraStyle(.window)
    }
}
