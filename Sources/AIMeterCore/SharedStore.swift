import Foundation

#if canImport(WidgetKit)
import WidgetKit
#endif

// MARK: - Widget Presentation Data Model
public struct WidgetServiceItem: Identifiable, Equatable {
    public let id: String
    public let name: String
    public let shortName: String
    public let iconName: String
    public let remainingPercent: Int
    public let remainingRatio: Double
    public let usedTokens: Int
    public let limitTokens: Int
    public let usedDisplay: String
    public let limitDisplay: String
    public let unit: String
    public let bottleneckPeriod: LimitPeriod
    public let resetText: String?

    public init(
        id: String,
        name: String,
        shortName: String,
        iconName: String,
        remainingPercent: Int,
        remainingRatio: Double,
        usedTokens: Int,
        limitTokens: Int,
        usedDisplay: String,
        limitDisplay: String,
        unit: String,
        bottleneckPeriod: LimitPeriod,
        resetText: String? = nil
    ) {
        self.id = id
        self.name = name
        self.shortName = shortName
        self.iconName = iconName
        self.remainingPercent = remainingPercent
        self.remainingRatio = remainingRatio
        self.usedTokens = usedTokens
        self.limitTokens = limitTokens
        self.usedDisplay = usedDisplay
        self.limitDisplay = limitDisplay
        self.unit = unit
        self.bottleneckPeriod = bottleneckPeriod
        self.resetText = resetText
    }
}

public struct AIMeterWidgetSnapshot: Equatable {
    public let mostCriticalService: WidgetServiceItem?
    public let topServices: [WidgetServiceItem]
    public let allServices: [WidgetServiceItem]
    public let totalCostUSD: Double
    public let updatedAt: Date
    public let hasData: Bool

    public init(
        mostCriticalService: WidgetServiceItem?,
        topServices: [WidgetServiceItem],
        allServices: [WidgetServiceItem],
        totalCostUSD: Double,
        updatedAt: Date,
        hasData: Bool
    ) {
        self.mostCriticalService = mostCriticalService
        self.topServices = topServices
        self.allServices = allServices
        self.totalCostUSD = totalCostUSD
        self.updatedAt = updatedAt
        self.hasData = hasData
    }

    public static func placeholder() -> AIMeterWidgetSnapshot {
        let claude = WidgetServiceItem(
            id: "claude",
            name: "Anthropic Claude",
            shortName: "Cld",
            iconName: "brain.head.profile",
            remainingPercent: 32,
            remainingRatio: 0.32,
            usedTokens: 1_020_000,
            limitTokens: 1_500_000,
            usedDisplay: "1.0M",
            limitDisplay: "1.5M",
            unit: "tokens",
            bottleneckPeriod: .fiveHours,
            resetText: "あと1時間20分"
        )
        let cursor = WidgetServiceItem(
            id: "cursor",
            name: "Cursor",
            shortName: "Cur",
            iconName: "terminal.fill",
            remainingPercent: 68,
            remainingRatio: 0.68,
            usedTokens: 16,
            limitTokens: 50,
            usedDisplay: "16",
            limitDisplay: "50",
            unit: "req",
            bottleneckPeriod: .daily,
            resetText: nil
        )
        let codex = WidgetServiceItem(
            id: "openai",
            name: "OpenAI Codex",
            shortName: "OAI",
            iconName: "cpu",
            remainingPercent: 85,
            remainingRatio: 0.85,
            usedTokens: 6_000_000,
            limitTokens: 40_000_000,
            usedDisplay: "6.0M",
            limitDisplay: "40M",
            unit: "tokens",
            bottleneckPeriod: .fiveHours,
            resetText: nil
        )

        return AIMeterWidgetSnapshot(
            mostCriticalService: claude,
            topServices: [claude, cursor, codex],
            allServices: [claude, cursor, codex],
            totalCostUSD: 14.50,
            updatedAt: Date(),
            hasData: true
        )
    }
}

// MARK: - Shared Store
public enum SharedStore {
    public static let localUsageFileURL: URL = {
        if let pw = getpwuid(getuid()), let home = pw.pointee.pw_dir {
            let homePath = FileManager.default.string(withFileSystemRepresentation: home, length: strlen(home))
            return URL(fileURLWithPath: homePath).appendingPathComponent(".ai_meter_usage.json")
        }
        return FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".ai_meter_usage.json")
    }()

    public static func loadLocalUsageData(from customURL: URL? = nil) -> LocalUsageData? {
        let url = customURL ?? localUsageFileURL
        guard let data = try? Data(contentsOf: url) else { return nil }
        return try? JSONDecoder().decode(LocalUsageData.self, from: data)
    }

    public static func loadCustomSubscriptionsFromUserDefaults() -> [CustomSubscriptionConfig] {
        let raw = UserDefaults.standard.string(forKey: "customSubscriptionsJSON") ?? "[]"
        guard let data = raw.data(using: .utf8),
              let list = try? JSONDecoder().decode([CustomSubscriptionConfig].self, from: data) else {
            return []
        }
        return list
    }

    public static func reloadWidgetTimelines() {
        #if canImport(WidgetKit)
        WidgetCenter.shared.reloadAllTimelines()
        #endif
    }

    /// Builds a snapshot from the current local file and subscription configurations.
    public static func createCurrentSnapshot(customURL: URL? = nil) -> AIMeterWidgetSnapshot {
        guard let data = loadLocalUsageData(from: customURL) else {
            return AIMeterWidgetSnapshot(
                mostCriticalService: nil,
                topServices: [],
                allServices: [],
                totalCostUSD: 0,
                updatedAt: Date(),
                hasData: false
            )
        }

        var subscriptions = loadCustomSubscriptionsFromUserDefaults()
        if subscriptions.isEmpty {
            // Provide sensible defaults if not set yet
            subscriptions = [
                .claudePreset(),
                .cursorPreset(),
                .grokbotPreset(),
                .windsurfPreset(),
                .copilotPreset()
            ]
        }

        var items: [WidgetServiceItem] = []
        var totalCost: Double = 0.0

        if let oCost = data.openaiCostUSD { totalCost += oCost }
        if let gCost = data.geminiCostUSD { totalCost += gCost }

        // Process OpenAI / Codex
        let oaiUsed5h = data.openaiUsedByPeriod?.fiveHours ?? 0
        let oaiLimit5h = UserDefaults.standard.integer(forKey: "openaiTokenLimit5h") > 0 ? UserDefaults.standard.integer(forKey: "openaiTokenLimit5h") : 40_000_000
        let oaiMetric = PeriodUsageMetric(
            period: .fiveHours,
            usedTokens: oaiUsed5h,
            limitTokens: oaiLimit5h,
            serverUsedPercent: data.openaiServerUsedPercentByPeriod?.fiveHours,
            resetTimestamp: data.openaiResetAtByPeriod?.fiveHours
        )
        let oaiItem = WidgetServiceItem(
            id: "openai",
            name: "OpenAI Codex",
            shortName: "OAI",
            iconName: "cpu",
            remainingPercent: oaiMetric.remainingPercent,
            remainingRatio: oaiMetric.remainingRatio,
            usedTokens: oaiUsed5h,
            limitTokens: oaiMetric.effectiveLimitTokens,
            usedDisplay: formatCompactTokenCount(oaiUsed5h),
            limitDisplay: formatCompactTokenCount(oaiMetric.effectiveLimitTokens),
            unit: "tokens",
            bottleneckPeriod: .fiveHours,
            resetText: formatRemainingTime(from: oaiMetric.resetTimestamp)
        )
        items.append(oaiItem)

        // Process Custom Providers from JSON
        if let providers = data.providers {
            for sub in subscriptions where sub.isEnabled {
                guard let pData = providers[sub.id] else { continue }
                if let c = pData.costUSD { totalCost += c }

                // Find the tightest / lowest remaining metric among enabled periods
                var bottleneckMetric: PeriodUsageMetric?
                for periodRaw in sub.enabledPeriodRawValues {
                    guard let p = LimitPeriod(rawValue: periodRaw) else { continue }
                    let used: Int
                    let limit: Int
                    switch p {
                    case .twoHours:
                        used = pData.usedByPeriod?.twoHours ?? sub.manualUsed2h
                        limit = sub.limit2h
                    case .fiveHours:
                        used = pData.usedByPeriod?.fiveHours ?? sub.manualUsed5h
                        limit = sub.limit5h
                    case .daily:
                        used = pData.usedByPeriod?.daily ?? sub.manualUsedDaily
                        limit = sub.limitDaily
                    case .weekly:
                        used = pData.usedByPeriod?.weekly ?? sub.manualUsedWeekly
                        limit = sub.limitWeekly
                    case .monthly:
                        used = pData.usedByPeriod?.monthly ?? sub.manualUsedMonthly
                        limit = sub.limitMonthly
                    }

                    var srvPct: Double?
                    var srvReset: Int?
                    switch p {
                    case .twoHours:
                        srvPct = pData.serverUsedPercentByPeriod?.twoHours
                        srvReset = pData.resetAtByPeriod?.twoHours
                    case .fiveHours:
                        srvPct = pData.serverUsedPercentByPeriod?.fiveHours
                        srvReset = pData.resetAtByPeriod?.fiveHours
                    case .daily:
                        srvPct = pData.serverUsedPercentByPeriod?.daily
                        srvReset = pData.resetAtByPeriod?.daily
                    case .weekly:
                        srvPct = pData.serverUsedPercentByPeriod?.weekly
                        srvReset = pData.resetAtByPeriod?.weekly
                    case .monthly:
                        srvPct = pData.serverUsedPercentByPeriod?.monthly
                        srvReset = pData.resetAtByPeriod?.monthly
                    }

                    let metric = PeriodUsageMetric(
                        period: p,
                        usedTokens: used,
                        limitTokens: limit,
                        serverUsedPercent: srvPct,
                        resetTimestamp: srvReset
                    )

                    if let curr = bottleneckMetric {
                        if metric.remainingRatio < curr.remainingRatio {
                            bottleneckMetric = metric
                        }
                    } else {
                        bottleneckMetric = metric
                    }
                }

                if let bMetric = bottleneckMetric {
                    let u = providerUnit(for: sub.id)
                    let item = WidgetServiceItem(
                        id: sub.id,
                        name: sub.name,
                        shortName: sub.shortName,
                        iconName: sub.iconName,
                        remainingPercent: bMetric.remainingPercent,
                        remainingRatio: bMetric.remainingRatio,
                        usedTokens: bMetric.usedTokens,
                        limitTokens: bMetric.effectiveLimitTokens,
                        usedDisplay: formatCompactUsage(bMetric.usedTokens, unit: u),
                        limitDisplay: formatCompactUsage(bMetric.effectiveLimitTokens, unit: u),
                        unit: u,
                        bottleneckPeriod: bMetric.period,
                        resetText: formatRemainingTime(from: bMetric.resetTimestamp)
                    )
                    items.append(item)
                }
            }
        }

        // Sort items by lowest remaining percent first (most critical)
        items.sort { $0.remainingRatio < $1.remainingRatio }

        let critical = items.first
        let top3 = Array(items.prefix(3))

        let updateDate: Date
        if let ts = data.updatedAt, let d = ISO8601DateFormatter().date(from: ts) {
            updateDate = d
        } else {
            updateDate = Date()
        }

        return AIMeterWidgetSnapshot(
            mostCriticalService: critical,
            topServices: top3,
            allServices: items,
            totalCostUSD: totalCost,
            updatedAt: updateDate,
            hasData: true
        )
    }
}
