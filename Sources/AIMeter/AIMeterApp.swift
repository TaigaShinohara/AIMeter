import SwiftUI
import AppKit
import Foundation
import Security
import ServiceManagement
import AIMeterCore

// MARK: - Notifications
extension Notification.Name {
    static let showDesktopWidgetRequest = Notification.Name("com.local.AIMeter.showDesktopWidgetRequest")
}

// MARK: - Launch at Login Manager
@MainActor
final class LaunchAtLoginManager: ObservableObject {
    static let shared = LaunchAtLoginManager()

    @Published var isEnabled: Bool = false

    init() {
        refresh()
    }

    func refresh() {
        if #available(macOS 13.0, *) {
            isEnabled = (SMAppService.mainApp.status == .enabled)
        }
    }

    func setEnabled(_ enable: Bool) {
        if #available(macOS 13.0, *) {
            do {
                if enable {
                    if SMAppService.mainApp.status != .enabled {
                        try SMAppService.mainApp.register()
                    }
                } else {
                    if SMAppService.mainApp.status == .enabled {
                        try SMAppService.mainApp.unregister()
                    }
                }
                isEnabled = (SMAppService.mainApp.status == .enabled)
            } catch {
                print("[AIMeter] Failed to update Launch at Login: \(error)")
                refresh()
            }
        }
    }
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

// MARK: - Usage Monitor
@MainActor
final class UsageMonitor: ObservableObject {
    @AppStorage("didCalibrateRealLimitsV1") var didCalibrateRealLimitsV1: Bool = false
    @AppStorage("didAutoSeedLocalProvidersV2") var didAutoSeedLocalProvidersV2: Bool = false
    @AppStorage("didMigrateHonestCostsV3") var didMigrateHonestCostsV3: Bool = false
    @AppStorage("hasCompletedSetupWizard") var hasCompletedSetupWizard: Bool = true
    @AppStorage("autoShowWidgetOnLaunch") var autoShowWidgetOnLaunch: Bool = true
    @Published var hasAutoOpenedWidgetOnLaunch: Bool = false
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
    @AppStorage("showOpenAIInMenuBar") var showOpenAIInMenuBar: Bool = true
    @AppStorage("showGeminiInMenuBar") var showGeminiInMenuBar: Bool = true
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
    @AppStorage("menuBarDisplayMode") var menuBarDisplayMode: String = "smart"
    @AppStorage("isDetailedView") var isDetailedView: Bool = false
    @AppStorage("isWidgetPinned") var isWidgetPinned: Bool = true
    @Published var isDesktopWidgetOpen: Bool = false

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
        isDetailedView = true
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

    var activeBottlenecks: [ServiceBottleneck] {
        var list: [ServiceBottleneck] = []
        if showOpenAISection && showOpenAIInMenuBar, !openaiMetrics.isEmpty {
            if let minMetric = openaiMetrics.min(by: { $0.remainingRatio < $1.remainingRatio }) {
                list.append(ServiceBottleneck(
                    id: "openai",
                    name: "OpenAI",
                    shortName: "GPT",
                    iconName: "brain.head.profile",
                    remainingPercent: minMetric.remainingPercent,
                    remainingRatio: minMetric.remainingRatio,
                    bottleneckPeriod: minMetric.period
                ))
            }
        }
        if showGeminiSection && showGeminiInMenuBar, !geminiMetrics.isEmpty {
            if let minMetric = geminiMetrics.min(by: { $0.remainingRatio < $1.remainingRatio }) {
                list.append(ServiceBottleneck(
                    id: "gemini",
                    name: "Gemini",
                    shortName: "Gem",
                    iconName: "sparkle",
                    remainingPercent: minMetric.remainingPercent,
                    remainingRatio: minMetric.remainingRatio,
                    bottleneckPeriod: minMetric.period
                ))
            }
        }
        for sub in customSubscriptions where sub.isEnabled && sub.showInMenuBar {
            let m = metrics(for: sub)
            if let minMetric = m.min(by: { $0.remainingRatio < $1.remainingRatio }) {
                list.append(ServiceBottleneck(
                    id: sub.id,
                    name: sub.name,
                    shortName: sub.shortName,
                    iconName: sub.iconName,
                    remainingPercent: minMetric.remainingPercent,
                    remainingRatio: minMetric.remainingRatio,
                    bottleneckPeriod: minMetric.period
                ))
            }
        }
        return list.sorted(by: { $0.remainingRatio < $1.remainingRatio })
    }

    var menuBarTitle: String {
        let bottlenecks = activeBottlenecks
        guard !bottlenecks.isEmpty else {
            return "AIMeter"
        }

        let mode = MenuBarDisplayMode(rawValue: menuBarDisplayMode) ?? .smart
        switch mode {
        case .smart:
            if let first = bottlenecks.first {
                let prefix = first.remainingPercent < 15 ? "⚠️ " : ""
                return "\(prefix)\(first.shortName) 残\(first.remainingPercent)%"
            }
            return "AIMeter"
        case .compact:
            let topTwo = bottlenecks.prefix(2)
            return topTwo.map { "\($0.shortName) 残\($0.remainingPercent)%" }.joined(separator: " · ")
        case .iconOnly:
            if let first = bottlenecks.first {
                return "残\(first.remainingPercent)%"
            }
            return "AIMeter"
        case .all:
            var segments: [String] = []
            if showOpenAISection && showOpenAIInMenuBar {
                let gptPct = Int((activeRatio(for: openaiMetrics) * 100).rounded())
                segments.append("GPT:\(gptPct)%")
            }
            if showGeminiSection && showGeminiInMenuBar {
                let gemPct = Int((activeRatio(for: geminiMetrics) * 100).rounded())
                segments.append("Gem:\(gemPct)%")
            }
            for sub in customSubscriptions where sub.isEnabled && sub.showInMenuBar {
                let pct = Int((activeRatio(for: metrics(for: sub)) * 100).rounded())
                segments.append("\(sub.shortName):\(pct)%")
            }
            return segments.isEmpty ? "AIMeter" : segments.joined(separator: " ")
        }
    }

    func refresh() async {
        guard !isRefreshing else { return }
        isRefreshing = true
        sanitizeSettings()
        defer {
            lastUpdated = Date()
            isRefreshing = false
            SharedStore.reloadWidgetTimelines()
        }

        await runLocalCollectorScript()

        let localData = loadLocalJSON()
        if let localData {
            let monthlyOpenAI = max(0, localData.openaiUsedByPeriod?.monthly ?? localData.openaiUsedTokens ?? 0)
            openaiUsedTokens = monthlyOpenAI
            openaiUsedWeekly = max(0, localData.openaiUsedByPeriod?.weekly ?? 0)
            openaiUsedDaily = max(0, localData.openaiUsedByPeriod?.daily ?? 0)
            openaiUsed5h = max(0, localData.openaiUsedByPeriod?.fiveHours ?? 0)
            openaiUsed2h = max(0, localData.openaiUsedByPeriod?.twoHours ?? 0)
            openaiServerPct = localData.openaiServerUsedPercentByPeriod
            openaiResetAt = localData.openaiResetAtByPeriod
            openaiCostUSD = max(0.0, localData.openaiCostUSD ?? 0.0)

            let monthlyGemini = max(0, localData.geminiUsedByPeriod?.monthly ?? localData.geminiUsedTokens ?? 0)
            geminiUsedTokens = monthlyGemini
            geminiUsedWeekly = max(0, localData.geminiUsedByPeriod?.weekly ?? 0)
            geminiUsedDaily = max(0, localData.geminiUsedByPeriod?.daily ?? 0)
            geminiUsed5h = max(0, localData.geminiUsedByPeriod?.fiveHours ?? 0)
            geminiUsed2h = max(0, localData.geminiUsedByPeriod?.twoHours ?? 0)
            geminiCostUSD = max(0.0, localData.geminiCostUSD ?? 0.0)

            customProviderLiveUsage = localData.providers ?? [:]
            detectedProviderIds = localData.detectedProviders ?? []

            // Automatically seed and clean up detected local accounts on first V2/V3 run
            if !didAutoSeedLocalProvidersV2 || !didMigrateHonestCostsV3 {
                var seenBaseIds = Set<String>()
                var cleaned: [CustomSubscriptionConfig] = []
                for var item in customSubscriptions {
                    let base = item.id.split(separator: "_").first.map(String.init) ?? item.id
                    if !base.hasPrefix("custom") {
                        if seenBaseIds.contains(base) {
                            continue
                        }
                        seenBaseIds.insert(base)
                        item.id = base
                    }
                    if base == "copilot" && item.manualUsedMonthly == 80 {
                        item.manualUsedDaily = 0
                        item.manualUsedWeekly = 0
                        item.manualUsedMonthly = 0
                    }
                    // Clear legacy hardcoded preset costs (10/20/30)
                    if item.usedCostUSD == item.budgetUSD && (item.usedCostUSD == 10.0 || item.usedCostUSD == 20.0 || item.usedCostUSD == 30.0) {
                        item.usedCostUSD = 0.0
                    }
                    // Update Windsurf periods to honest monthly only if still at legacy preset
                    if base == "windsurf" && item.enabledPeriodRawValues == ["1d", "7d", "30d"] {
                        item.enabledPeriodRawValues = ["30d"]
                    }
                    cleaned.append(item)
                }
                customSubscriptions = cleaned
                autoAddDetectedSubscriptions()
                didAutoSeedLocalProvidersV2 = true
                didMigrateHonestCostsV3 = true
                hasCompletedSetupWizard = true
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

// MARK: - Single Period Limit Row View (macOS Native HIG Design)
struct PeriodLimitRowView: View {
    let metric: PeriodUsageMetric
    let isHighlighted: Bool
    var unit: String = "tokens"

    var body: some View {
        let ratio = metric.remainingRatio
        let pct = metric.remainingPercent
        let usageText = formatCompactUsage(metric.remainingTokens, unit: unit)

        HStack(spacing: 8) {
            // 1. Period Label
            Text(metric.period.label)
                .font(.caption.weight(isHighlighted ? .bold : .medium))
                .foregroundStyle(isHighlighted ? .primary : .secondary)
                .frame(width: 38, alignment: .leading)

            // 2. Native macOS Progress Bar
            ProgressView(value: min(max(ratio, 0.0), 1.0), total: 1.0)
                .progressViewStyle(.linear)
                .tint(gaugeColor(for: ratio))
                .controlSize(.small)

            // 3. Remaining Amount with Unit
            HStack(spacing: 2) {
                Text("残 \(usageText)")
                if unit != "tokens" {
                    Text(unit)
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                }
            }
            .font(.caption.monospacedDigit())
            .foregroundStyle(.secondary)
            .lineLimit(1)
            .frame(width: 76, alignment: .trailing)

            // 4. Remaining Percentage (100%でも改行されない幅と設定)
            Text("\(pct)%")
                .font(.callout.weight(.semibold).monospacedDigit())
                .foregroundStyle(percentageTextColor(for: ratio))
                .lineLimit(1)
                .minimumScaleFactor(0.8)
                .frame(width: 48, alignment: .trailing)
        }
        .padding(.vertical, 2)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(metric.period.label)制限")
        .accessibilityValue("残り \(usageText) \(unit) (\(pct)パーセント)")
    }
}

// MARK: - Provider Section View (macOS Native Control Center Style Tile)
struct ProviderUsageSection: View {
    let title: String
    let subtitle: String
    let usedCostUSD: Double
    let budgetUSD: Double
    let metrics: [PeriodUsageMetric]
    var selectedFilter: LimitPeriod? = nil
    let highlightedPeriod: LimitPeriod?
    var unit: String = "tokens"
    var isDetailed: Bool = true

    var displayedMetrics: [PeriodUsageMetric] {
        if let filter = selectedFilter {
            return metrics.filter { $0.period == filter }
        }
        if isDetailed {
            return metrics
        }
        // Progressive Disclosure (Summary mode): Show bottleneck + monthly
        guard !metrics.isEmpty else { return [] }
        if let bottleneck = metrics.min(by: { $0.remainingRatio < $1.remainingRatio }) {
            let monthly = metrics.first(where: { $0.period == .monthly })
            if let monthly, monthly.period != bottleneck.period {
                return [bottleneck, monthly]
            }
            return [bottleneck]
        }
        return metrics
    }

    private var activeResetString: String? {
        for m in displayedMetrics {
            if let str = formatResetTimestamp(m.resetTimestamp) {
                return "↻ \(m.period.shortLabel) \(str)"
            }
        }
        return nil
    }

    var body: some View {
        if displayedMetrics.isEmpty {
            EmptyView()
        } else {
            VStack(alignment: .leading, spacing: 6) {
                // Section Header (タイトル保護と右側情報のスマート配置)
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    HStack(spacing: 5) {
                        Text(title)
                            .font(.subheadline.weight(.semibold))
                            .foregroundStyle(.primary)
                            .lineLimit(1)

                        if !subtitle.isEmpty {
                            Text(subtitle)
                                .font(.caption)
                                .foregroundStyle(.tertiary)
                                .lineLimit(1)
                        }
                    }
                    .layoutPriority(1)

                    Spacer(minLength: 8)

                    if let resetInfo = activeResetString {
                        if usedCostUSD > 0 {
                            Text(String(format: "API換算 $%.2f · %@", usedCostUSD, resetInfo))
                                .font(.caption.monospacedDigit())
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                                .minimumScaleFactor(0.85)
                        } else {
                            Text(resetInfo)
                                .font(.caption.monospacedDigit())
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                                .minimumScaleFactor(0.85)
                        }
                    } else if usedCostUSD > 0 {
                        Text(String(format: "API換算 $%.2f", usedCostUSD))
                            .font(.caption.monospacedDigit())
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                }

                // Period Rows
                VStack(spacing: 3) {
                    ForEach(displayedMetrics) { metric in
                        PeriodLimitRowView(
                            metric: metric,
                            isHighlighted: highlightedPeriod == metric.period && selectedFilter == nil,
                            unit: unit
                        )
                    }
                }
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 8)
            .background(
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .fill(Color(nsColor: .controlBackgroundColor).opacity(0.6))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .strokeBorder(Color(nsColor: .separatorColor).opacity(0.35), lineWidth: 0.5)
            )
        }
    }
}

// MARK: - Window Accessor for Reliable Floating Window Configuration
final class FirstMouseHostingHelperView: NSView {
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool {
        true
    }
}

func closeDesktopWidgetWindow(monitor: UsageMonitor? = nil) {
    DispatchQueue.main.async {
        for window in NSApp.windows where window.identifier?.rawValue.contains("desktop-widget") == true || window.title == "AI Meter Widget" {
            window.close()
        }
        monitor?.isDesktopWidgetOpen = false
    }
}

func miniaturizeDesktopWidgetWindow(monitor: UsageMonitor? = nil) {
    DispatchQueue.main.async {
        for window in NSApp.windows where window.identifier?.rawValue.contains("desktop-widget") == true || window.title == "AI Meter Widget" {
            window.miniaturize(nil)
        }
        monitor?.isDesktopWidgetOpen = false
    }
}

func openOrRestoreDesktopWidgetWindow(monitor: UsageMonitor? = nil, openWindow: @escaping (String) -> Void) {
    DispatchQueue.main.async {
        var found = false
        for window in NSApp.windows where window.identifier?.rawValue.contains("desktop-widget") == true || window.title == "AI Meter Widget" {
            found = true
            if window.isMiniaturized {
                window.deminiaturize(nil)
            }
            window.makeKeyAndOrderFront(nil)
            NSApplication.shared.activate(ignoringOtherApps: true)
        }
        if !found {
            openWindow("desktop-widget")
        }
        monitor?.isDesktopWidgetOpen = true
    }
}

struct DesktopWidgetWindowAccessor: NSViewRepresentable {
    var allowBackgroundDrag: Bool = true
    var isPinned: Bool = true
    var onVisibilityChange: ((Bool) -> Void)? = nil

    func makeNSView(context: Context) -> NSView {
        let view = FirstMouseHostingHelperView()
        DispatchQueue.main.async {
            if let window = view.window {
                Self.configure(window: window, allowBackgroundDrag: allowBackgroundDrag, isPinned: isPinned)
                onVisibilityChange?(window.isVisible && !window.isMiniaturized)
            }
        }
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        DispatchQueue.main.async {
            if let window = nsView.window {
                Self.configure(window: window, allowBackgroundDrag: allowBackgroundDrag, isPinned: isPinned)
                onVisibilityChange?(window.isVisible && !window.isMiniaturized)
            }
        }
    }

    static func configure(window: NSWindow, allowBackgroundDrag: Bool, isPinned: Bool) {
        window.styleMask.insert([.titled, .fullSizeContentView, .closable, .miniaturizable, .resizable])
        window.level = isPinned ? .floating : .normal
        window.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        window.isMovableByWindowBackground = allowBackgroundDrag
        window.backgroundColor = .clear
        window.isOpaque = false
        window.hasShadow = true
        window.titleVisibility = .hidden
        window.titlebarAppearsTransparent = true
        window.titlebarSeparatorStyle = .none

        // ネイティブ macOS トラフィックライト（標準の閉じる・最小化・ズームの3連ボタン）を完全に有効化
        if let closeBtn = window.standardWindowButton(.closeButton) {
            closeBtn.isHidden = false
            closeBtn.isEnabled = true
        }
        if let miniBtn = window.standardWindowButton(.miniaturizeButton) {
            miniBtn.isHidden = false
            miniBtn.isEnabled = true
        }
        if let zoomBtn = window.standardWindowButton(.zoomButton) {
            zoomBtn.isHidden = false
            zoomBtn.isEnabled = true
        }

        window.setFrameAutosaveName("AIMeterDesktopWidgetFrame")
        if !allowBackgroundDrag {
            NSApplication.shared.activate(ignoringOtherApps: true)
            window.makeKeyAndOrderFront(nil)
        }
    }
}

func openSettingsWindow(openWindow: OpenWindowAction) {
    NSApplication.shared.activate(ignoringOtherApps: true)
    openWindow(id: "settings")
}

// MARK: - Main Card View (macOS Native HIG Design)
struct AIMeterCardView: View {
    @ObservedObject var monitor: UsageMonitor
    var isMenuBar: Bool = false
    @Environment(\.openWindow) private var openWindow

    private static let timeFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "HH:mm"
        return f
    }()

    private var highlightedMenuBarPeriod: LimitPeriod? {
        LimitPeriod(rawValue: monitor.menuBarPeriodMode)
    }

    private var visibleCustomSubscriptions: [CustomSubscriptionConfig] {
        monitor.customSubscriptions.filter(\.isEnabled)
    }

    private var totalVisibleProvidersCount: Int {
        (monitor.showOpenAISection ? 1 : 0) + (monitor.showGeminiSection ? 1 : 0) + visibleCustomSubscriptions.count
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            // Header (Finder / macOS Native Unified Toolbar Style)
            HStack(spacing: 8) {
                if !isMenuBar {
                    // ネイティブ macOS トラフィックライト（赤・黄・緑の3連）用のインセット
                    Color.clear
                        .frame(width: 72, height: 26)
                        .accessibilityHidden(true)
                }

                Text("AIMeter")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(.primary)

                Spacer()

                // macOS Native Capsule Toolbar Item Group (Finderスタイル・均等アイコン配置)
                HStack(spacing: 2) {
                    // 1. 要点 / 全枠 トグル (Finder表示切替スタイル)
                    Button {
                        withAnimation(.easeInOut(duration: 0.15)) {
                            monitor.isDetailedView.toggle()
                        }
                    } label: {
                        Image(systemName: monitor.isDetailedView ? "list.bullet" : "sparkles.rectangle.stack")
                            .font(.system(size: 11, weight: .medium))
                            .foregroundStyle(monitor.isDetailedView ? Color.accentColor : Color.secondary)
                            .frame(width: 24, height: 22)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .focusable(false)
                    .help(monitor.isDetailedView ? "全枠表示中（クリックで要点表示に短縮）" : "要点表示中（クリックで全枠を表示）")

                    Divider()
                        .frame(height: 12)

                    // 2. 更新ボタン (更新中はスピナー表示)
                    Button {
                        Task {
                            await monitor.refresh()
                        }
                    } label: {
                        Group {
                            if monitor.isRefreshing {
                                ProgressView()
                                    .controlSize(.mini)
                            } else {
                                Image(systemName: "arrow.clockwise")
                                    .font(.system(size: 11, weight: .medium))
                                    .foregroundStyle(.secondary)
                            }
                        }
                        .frame(width: 24, height: 22)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .focusable(false)
                    .disabled(monitor.isRefreshing)
                    .help("今すぐ更新")
                    .accessibilityLabel("今すぐ更新")

                    // 3. ウィジェット専用: 最前面ピン留めトグル
                    if !isMenuBar {
                        Divider()
                            .frame(height: 12)

                        Button {
                            withAnimation(.easeInOut(duration: 0.15)) {
                                monitor.isWidgetPinned.toggle()
                            }
                        } label: {
                            Image(systemName: monitor.isWidgetPinned ? "pin.fill" : "pin")
                                .font(.system(size: 11, weight: .medium))
                                .foregroundStyle(monitor.isWidgetPinned ? Color.accentColor : Color.secondary)
                                .frame(width: 24, height: 22)
                                .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .focusable(false)
                        .help(monitor.isWidgetPinned ? "最前面固定中 (クリックで解除)" : "通常ウィンドウ (クリックで最前面固定)")
                    }

                    Divider()
                        .frame(height: 12)

                    // 4. 設定ボタン (macOS標準設定ウィンドウを開く)
                    Button {
                        openSettingsWindow(openWindow: openWindow)
                    } label: {
                        Image(systemName: "gearshape")
                            .font(.system(size: 11, weight: .medium))
                            .foregroundStyle(.secondary)
                            .frame(width: 24, height: 22)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .focusable(false)
                    .help("設定を開く (⌘,)")
                    .accessibilityLabel("設定を開く")
                }
                .padding(.horizontal, 3)
                .padding(.vertical, 2)
                .background(
                    RoundedRectangle(cornerRadius: 6, style: .continuous)
                        .fill(Color(nsColor: .controlBackgroundColor).opacity(0.85))
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 6, style: .continuous)
                        .strokeBorder(Color(nsColor: .separatorColor).opacity(0.35), lineWidth: 0.5)
                )
            }
            .frame(height: 26)

            Divider()
                .opacity(0.35)
                .padding(.horizontal, -14)

            // Provider Sections
            if totalVisibleProvidersCount == 0 {
                ContentUnavailableView {
                    Label("表示するAIサービスがありません", systemImage: "slider.horizontal.3")
                } description: {
                    Text("設定からサービスを有効化してください")
                } actions: {
                    Button("設定を開く...") {
                        openSettingsWindow(openWindow: openWindow)
                    }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.small)
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 16)
            } else if isMenuBar && totalVisibleProvidersCount > 3 {
                ScrollView {
                    providerSectionsStack
                        .padding(.trailing, 2)
                }
                .frame(maxHeight: 380)
            } else if !isMenuBar && totalVisibleProvidersCount > 5 {
                ScrollView {
                    providerSectionsStack
                        .padding(.trailing, 2)
                }
                .frame(maxHeight: 520)
            } else {
                providerSectionsStack
            }

            // Quiet Footer
            HStack {
                Text("\(Self.timeFormatter.string(from: monitor.lastUpdated)) 更新")
                    .font(.caption2.monospacedDigit())
                    .foregroundStyle(.tertiary)
                Spacer()
                if monitor.totalCostUSD > 0 {
                    Text(String(format: "API換算 $%.2f", monitor.totalCostUSD))
                        .font(.caption.weight(.medium).monospacedDigit())
                        .foregroundStyle(.secondary)
                } else {
                    Text("Mac内ログ自動集計")
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                }
            }
            .padding(.top, 2)

            if isMenuBar {
                Divider()
                HStack(spacing: 8) {
                    Button(monitor.isDesktopWidgetOpen ? "ウィジェットを非表示" : "ウィジェットを表示") {
                        if monitor.isDesktopWidgetOpen {
                            closeDesktopWidgetWindow(monitor: monitor)
                        } else {
                            openOrRestoreDesktopWidgetWindow(monitor: monitor) { id in
                                openWindow(id: id)
                            }
                        }
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)

                    Spacer()

                    Button("設定...") {
                        openSettingsWindow(openWindow: openWindow)
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)

                    Button("終了") {
                        NSApplication.shared.terminate(nil)
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                }
            }
        }
        .padding(.horizontal, 14)
        .padding(.top, isMenuBar ? 14 : 9)
        .padding(.bottom, 14)
        .frame(width: 348)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .strokeBorder(Color(nsColor: .separatorColor).opacity(0.3), lineWidth: 0.5)
        )
        .background(
            Group {
                if !isMenuBar {
                    DesktopWidgetWindowAccessor(
                        allowBackgroundDrag: true,
                        isPinned: monitor.isWidgetPinned,
                        onVisibilityChange: { visible in
                            if monitor.isDesktopWidgetOpen != visible {
                                monitor.isDesktopWidgetOpen = visible
                            }
                        }
                    )
                }
            }
        )
        .onReceive(NotificationCenter.default.publisher(for: NSWindow.willCloseNotification)) { note in
            if let win = note.object as? NSWindow,
               win.identifier?.rawValue.contains("desktop-widget") == true || win.title == "AI Meter Widget" {
                monitor.isDesktopWidgetOpen = false
            }
        }
        .onAppear {
            if isMenuBar && monitor.autoShowWidgetOnLaunch && !monitor.hasAutoOpenedWidgetOnLaunch {
                monitor.hasAutoOpenedWidgetOnLaunch = true
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
                    openOrRestoreDesktopWidgetWindow(monitor: monitor) { id in
                        openWindow(id: id)
                    }
                }
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: .showDesktopWidgetRequest)) { _ in
            openOrRestoreDesktopWidgetWindow(monitor: monitor) { id in
                openWindow(id: id)
            }
        }
        .onOpenURL { _ in
            openOrRestoreDesktopWidgetWindow(monitor: monitor) { id in
                openWindow(id: id)
            }
        }
        .background(
            Group {
                Button("") {
                    openSettingsWindow(openWindow: openWindow)
                }
                .keyboardShortcut(",", modifiers: .command)
                .opacity(0)

                if !isMenuBar {
                    // メイン画面での ⌘W / ESC: ウィジェットを閉じる
                    Button("") {
                        closeDesktopWidgetWindow(monitor: monitor)
                    }
                    .keyboardShortcut("w", modifiers: .command)
                    .keyboardShortcut(.cancelAction)
                    .opacity(0)

                    // ⌘M: ウィジェットを最小化
                    Button("") {
                        miniaturizeDesktopWidgetWindow(monitor: monitor)
                    }
                    .keyboardShortcut("m", modifiers: .command)
                    .opacity(0)
                }
            }
        )
    }

    @ViewBuilder
    private var providerSectionsStack: some View {
        VStack(alignment: .leading, spacing: 6) {
            if monitor.showOpenAISection {
                ProviderUsageSection(
                    title: "OpenAI",
                    subtitle: monitor.openaiStatus,
                    usedCostUSD: monitor.openaiCostUSD,
                    budgetUSD: monitor.openaiBudgetUSD,
                    metrics: monitor.openaiMetrics,
                    highlightedPeriod: highlightedMenuBarPeriod,
                    unit: "tokens",
                    isDetailed: monitor.isDetailedView
                )
            }

            if monitor.showGeminiSection {
                ProviderUsageSection(
                    title: "Gemini",
                    subtitle: monitor.geminiStatus,
                    usedCostUSD: monitor.geminiCostUSD,
                    budgetUSD: monitor.geminiBudgetUSD,
                    metrics: monitor.geminiMetrics,
                    highlightedPeriod: highlightedMenuBarPeriod,
                    unit: "tokens",
                    isDetailed: monitor.isDetailedView
                )
            }

            ForEach(visibleCustomSubscriptions) { sub in
                let baseKey = sub.id.split(separator: "_").first.map(String.init) ?? sub.id
                let liveStatus = monitor.customProviderLiveUsage[sub.id]?.status ?? monitor.customProviderLiveUsage[baseKey]?.status
                ProviderUsageSection(
                    title: sub.name,
                    subtitle: liveStatus ?? sub.statusNote,
                    usedCostUSD: monitor.effectiveCostUSD(for: sub),
                    budgetUSD: sub.budgetUSD,
                    metrics: monitor.metrics(for: sub),
                    highlightedPeriod: highlightedMenuBarPeriod,
                    unit: providerUnit(for: sub.id),
                    isDetailed: monitor.isDetailedView
                )
            }
        }
    }
}

// MARK: - App Delegate
final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApplication.shared.setActivationPolicy(.accessory)
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        NotificationCenter.default.post(name: .showDesktopWidgetRequest, object: nil)
        return true
    }
}

// MARK: - App Entrypoint
@main
struct AIMeterApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var appDelegate
    @StateObject private var monitor = UsageMonitor()

    init() {
        NSApplication.shared.activate(ignoringOtherApps: true)
    }

    var body: some Scene {
        Window("AI Meter Widget", id: "desktop-widget") {
            AIMeterCardView(monitor: monitor, isMenuBar: false)
        }
        .windowStyle(.hiddenTitleBar)
        .windowResizability(.contentSize)

        MenuBarExtra {
            AIMeterCardView(monitor: monitor, isMenuBar: true)
        } label: {
            HStack(spacing: 3) {
                Image(systemName: "gauge.with.needle.fill")
                Text(monitor.menuBarTitle)
            }
            .font(.system(size: 13, weight: .semibold).monospacedDigit())
        }
        .menuBarExtraStyle(.window)

        Window("AIMeter 設定", id: "settings") {
            SettingsView(monitor: monitor)
        }
        .windowResizability(.contentSize)

        Settings {
            SettingsView(monitor: monitor)
        }
    }
}
