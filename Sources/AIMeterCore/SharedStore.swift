import Foundation
import Darwin

#if canImport(WidgetKit)
import WidgetKit
#endif

// MARK: - Widget Presentation Data Model
public struct WidgetServiceItem: Identifiable, Equatable, Codable {
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
    public let resetTimestamp: Int?

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
        resetText: String? = nil,
        resetTimestamp: Int? = nil
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
        self.resetTimestamp = resetTimestamp
    }

    public func remainingResetText(at date: Date = Date()) -> String? {
        resetTimestamp != nil ? formatRemainingTime(from: resetTimestamp, now: date) : resetText
    }

    /// Uses the same enabled-period metrics that the host app displays.
    public static func fromMetrics(
        id: String, name: String, shortName: String, iconName: String,
        unit: String, metrics: [PeriodUsageMetric]
    ) -> WidgetServiceItem? {
        guard let metric = metrics.filter(\.isValid).min(by: { $0.remainingRatio < $1.remainingRatio }) else {
            return nil
        }
        return WidgetServiceItem(
            id: id, name: name, shortName: shortName, iconName: iconName,
            remainingPercent: metric.remainingPercent, remainingRatio: metric.remainingRatio,
            usedTokens: metric.usedTokens, limitTokens: metric.effectiveLimitTokens,
            usedDisplay: formatCompactUsage(metric.usedTokens, unit: unit),
            limitDisplay: formatCompactUsage(metric.effectiveLimitTokens, unit: unit),
            unit: unit, bottleneckPeriod: metric.period,
            resetTimestamp: metric.resetTimestamp
        )
    }
}

public struct AIMeterWidgetSnapshot: Equatable, Codable {
    public let mostCriticalService: WidgetServiceItem?
    public let topServices: [WidgetServiceItem]
    public let allServices: [WidgetServiceItem]
    public let totalCostUSD: Double
    public let updatedAt: Date?
    public let hasData: Bool
    public let updateFailed: Bool
    public let schemaVersion: Int

    public init(
        mostCriticalService: WidgetServiceItem?,
        topServices: [WidgetServiceItem],
        allServices: [WidgetServiceItem],
        totalCostUSD: Double,
        updatedAt: Date?,
        hasData: Bool,
        updateFailed: Bool = false
    ) {
        self.mostCriticalService = mostCriticalService
        self.topServices = topServices
        self.allServices = allServices
        self.totalCostUSD = totalCostUSD
        self.updatedAt = updatedAt
        self.hasData = hasData
        self.updateFailed = updateFailed
        self.schemaVersion = 1
    }

    public static func empty(updateFailed: Bool = false) -> AIMeterWidgetSnapshot {
        AIMeterWidgetSnapshot(
            mostCriticalService: nil, topServices: [], allServices: [],
            totalCostUSD: 0, updatedAt: nil, hasData: false, updateFailed: updateFailed
        )
    }

    public static func make(
        services: [WidgetServiceItem], totalCostUSD: Double, updatedAt: Date?,
        hasData: Bool, updateFailed: Bool = false
    ) -> AIMeterWidgetSnapshot {
        guard hasData else { return .empty(updateFailed: updateFailed) }
        // Keep ties deterministic without changing the host app's period choice.
        let sorted = services.sorted {
            $0.remainingRatio == $1.remainingRatio ? $0.id < $1.id : $0.remainingRatio < $1.remainingRatio
        }
        return AIMeterWidgetSnapshot(
            mostCriticalService: sorted.first, topServices: Array(sorted.prefix(3)),
            allServices: sorted, totalCostUSD: totalCostUSD, updatedAt: updatedAt,
            hasData: true, updateFailed: updateFailed
        )
    }

    /// Sample values are reserved for WidgetKit's placeholder and gallery preview.
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
        guard let data = try? BoundedInput().data(at: url),
              let snapshot = try? JSONDecoder().decode(LocalUsageData.self, from: data),
              (try? snapshot.validateNumbers()) != nil else { return nil }
        return snapshot
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

    /// Presentation cache contains only the host app's final display values.
    /// The extension does not independently interpret preferences or local logs.
    public static let widgetSnapshotFileURL = localUsageFileURL.deletingLastPathComponent()
        .appendingPathComponent(".ai_meter_widget.json")

    public static func loadWidgetSnapshot(from customURL: URL? = nil) -> AIMeterWidgetSnapshot {
        var limits = BoundedInput.Limits()
        limits.jsonBytes = 1024 * 1024
        guard let data = try? BoundedInput(limits: limits).data(at: customURL ?? widgetSnapshotFileURL),
              let snapshot = try? JSONDecoder().decode(AIMeterWidgetSnapshot.self, from: data),
              (try? validateWidgetSnapshot(snapshot)) != nil else { return .empty() }
        return snapshot
    }

    /// The exclusive 0600 temporary file is never readable with broader default
    /// permissions. Atomic rename replaces the destination itself, not symlink targets.
    public static func saveWidgetSnapshot(_ snapshot: AIMeterWidgetSnapshot, to customURL: URL? = nil) throws {
        try validateWidgetSnapshot(snapshot)
        let data = try JSONEncoder().encode(snapshot)
        guard data.count <= 1024 * 1024 else { throw BoundedInput.Failure.limit }
        let destination = customURL ?? widgetSnapshotFileURL
        let temporary = destination.deletingLastPathComponent()
            .appendingPathComponent(".ai_meter_widget.\(UUID().uuidString).tmp")
        let descriptor = Darwin.open(temporary.path, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0o600)
        guard descriptor >= 0 else { throw BoundedInput.Failure.file }
        let handle = FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
        defer {
            try? handle.close()
            try? FileManager.default.removeItem(at: temporary)
        }
        try handle.write(contentsOf: data)
        try handle.synchronize()
        guard Darwin.rename(temporary.path, destination.path) == 0 else { throw BoundedInput.Failure.file }
    }

    private static func validateWidgetSnapshot(_ snapshot: AIMeterWidgetSnapshot) throws {
        guard snapshot.schemaVersion == 1,
              snapshot.allServices.count <= 256,
              Set(snapshot.allServices.map(\.id)).count == snapshot.allServices.count,
              snapshot.topServices == Array(snapshot.allServices.prefix(3)),
              snapshot.mostCriticalService == snapshot.allServices.first else {
            throw BoundedInput.Failure.file
        }
        _ = try UsageNumber.finite(snapshot.totalCostUSD)
        if snapshot.hasData {
            guard let date = snapshot.updatedAt,
                  date.timeIntervalSince1970.isFinite,
                  (0...253_402_300_799).contains(date.timeIntervalSince1970) else {
                throw BoundedInput.Failure.file
            }
        } else {
            guard snapshot.updatedAt == nil, snapshot.allServices.isEmpty, snapshot.totalCostUSD == 0 else {
                throw BoundedInput.Failure.file
            }
        }
        var previousRatio = -Double.infinity
        for item in snapshot.allServices {
            if let reset = item.resetTimestamp {
                guard (0...253_402_300_799).contains(reset) else { throw BoundedInput.Failure.file }
            }
            _ = try UsageNumber.checked(item.usedTokens)
            _ = try UsageNumber.checked(item.limitTokens)
            guard item.remainingRatio.isFinite, (0...1).contains(item.remainingRatio),
                  item.remainingRatio >= previousRatio,
                  item.remainingPercent == Int((item.remainingRatio * 100).rounded()),
                  !item.id.isEmpty,
                  [item.id, item.name, item.shortName, item.iconName, item.usedDisplay,
                   item.limitDisplay, item.unit, item.resetText ?? ""].allSatisfy({ $0.utf8.count <= 512 }) else {
                throw BoundedInput.Failure.file
            }
            previousRatio = item.remainingRatio
        }
    }
}
