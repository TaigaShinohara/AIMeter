import XCTest
import AIMeterCore

final class WidgetSnapshotTests: XCTestCase {
    private var root: URL!
    private var cache: URL { root.appendingPathComponent("widget.json") }
    private let updatedAt = Date(timeIntervalSince1970: 1_792_400_000)

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try FileManager.default.removeItem(at: root)
    }

    private func item(_ id: String = "gemini", used: Int = 60) throws -> WidgetServiceItem {
        try XCTUnwrap(WidgetServiceItem.fromMetrics(
            id: id, name: id, shortName: id, iconName: "cpu", unit: "tokens",
            metrics: [PeriodUsageMetric(period: .weekly, usedTokens: used, limitTokens: 100)]
        ))
    }

    func testMissingCorruptAndLegacyCachesRemainEmptyWithoutSampleValues() throws {
        for bytes in [nil, Data("{bad".utf8), Data("{\"openaiUsedByPeriod\":{\"5h\":50}}".utf8)] {
            if let bytes { try bytes.write(to: cache) }
            let snapshot = SharedStore.loadWidgetSnapshot(from: cache)
            XCTAssertFalse(snapshot.hasData)
            XCTAssertTrue(snapshot.allServices.isEmpty)
            XCTAssertNil(snapshot.updatedAt)
            XCTAssertEqual(snapshot.totalCostUSD, 0)
        }
    }

    func testRoundTripKeepsHostValuesAndWritesPrivateFile() throws {
        let snapshot = AIMeterWidgetSnapshot.make(
            services: [try item("cursor", used: 40), try item("gemini", used: 80)],
            totalCostUSD: 2.75, updatedAt: updatedAt, hasData: true, updateFailed: true
        )
        try SharedStore.saveWidgetSnapshot(snapshot, to: cache)
        XCTAssertEqual(SharedStore.loadWidgetSnapshot(from: cache), snapshot)
        let attributes = try FileManager.default.attributesOfItem(atPath: cache.path)
        XCTAssertEqual((attributes[.posixPermissions] as? NSNumber)?.intValue, 0o600)
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: root.path), ["widget.json"])
        let replacement = AIMeterWidgetSnapshot.make(
            services: [try item("gemini", used: 10)], totalCostUSD: 1,
            updatedAt: updatedAt.addingTimeInterval(60), hasData: true
        )
        try SharedStore.saveWidgetSnapshot(replacement, to: cache)
        XCTAssertEqual(SharedStore.loadWidgetSnapshot(from: cache), replacement)
    }

    func testEmptyServiceSelectionIsDistinctFromNoSuccessfulData() throws {
        let disabled = AIMeterWidgetSnapshot.make(
            services: [], totalCostUSD: 0, updatedAt: updatedAt, hasData: true
        )
        try SharedStore.saveWidgetSnapshot(disabled, to: cache)
        let read = SharedStore.loadWidgetSnapshot(from: cache)
        XCTAssertTrue(read.hasData)
        XCTAssertTrue(read.allServices.isEmpty)
        XCTAssertEqual(read.updatedAt, updatedAt)

        let noData = AIMeterWidgetSnapshot.make(
            services: [try item()], totalCostUSD: 20, updatedAt: updatedAt,
            hasData: false, updateFailed: true
        )
        XCTAssertEqual(noData, .empty(updateFailed: true))
        try SharedStore.saveWidgetSnapshot(noData, to: cache)
        XCTAssertEqual(SharedStore.loadWidgetSnapshot(from: cache), noData)
    }

    func testMalformedPresentationCannotSupplyMetersOrFalseUpdateTime() throws {
        let snapshot = AIMeterWidgetSnapshot.make(
            services: [try item()], totalCostUSD: 1, updatedAt: updatedAt, hasData: true
        )
        let data = try JSONEncoder().encode(snapshot)
        let original = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        for (key, value) in [("schemaVersion", 2 as Any), ("totalCostUSD", -1),
                             ("updatedAt", "invalid"), ("hasData", false),
                             ("allServices", [] as [Any])] {
            var invalid = original
            invalid[key] = value
            try JSONSerialization.data(withJSONObject: invalid).write(to: cache)
            XCTAssertFalse(SharedStore.loadWidgetSnapshot(from: cache).hasData, key)
        }
        var invalid = original
        var services = try XCTUnwrap(invalid["allServices"] as? [[String: Any]])
        services[0]["remainingRatio"] = 2.0
        invalid["allServices"] = services
        try JSONSerialization.data(withJSONObject: invalid).write(to: cache)
        XCTAssertFalse(SharedStore.loadWidgetSnapshot(from: cache).hasData)
    }

    func testInvalidWritePreservesPreviousCacheAndSymlinkTarget() throws {
        let previous = AIMeterWidgetSnapshot.make(
            services: [try item()], totalCostUSD: 2, updatedAt: updatedAt, hasData: true
        )
        try SharedStore.saveWidgetSnapshot(previous, to: cache)
        let invalid = AIMeterWidgetSnapshot.make(
            services: [try item()], totalCostUSD: -1, updatedAt: updatedAt, hasData: true
        )
        XCTAssertThrowsError(try SharedStore.saveWidgetSnapshot(invalid, to: cache))
        XCTAssertEqual(SharedStore.loadWidgetSnapshot(from: cache), previous)

        let target = root.appendingPathComponent("unrelated.txt")
        let original = Data("unchanged".utf8)
        try original.write(to: target)
        try FileManager.default.removeItem(at: cache)
        try FileManager.default.createSymbolicLink(at: cache, withDestinationURL: target)
        XCTAssertFalse(SharedStore.loadWidgetSnapshot(from: cache).hasData)
        try SharedStore.saveWidgetSnapshot(previous, to: cache)
        XCTAssertEqual(try Data(contentsOf: target), original)
        XCTAssertEqual(SharedStore.loadWidgetSnapshot(from: cache), previous)
    }

    func testMetricsUseServerPercentAndOnlySuppliedEnabledPeriods() throws {
        let metrics = [
            PeriodUsageMetric(period: .fiveHours, usedTokens: 50, limitTokens: 100, serverUsedPercent: 20),
            PeriodUsageMetric(period: .weekly, usedTokens: 5, limitTokens: 100, serverUsedPercent: 95)
        ]
        let selected = try XCTUnwrap(WidgetServiceItem.fromMetrics(
            id: "openai", name: "Codex", shortName: "OAI", iconName: "cpu", unit: "tokens", metrics: metrics
        ))
        XCTAssertEqual(selected.bottleneckPeriod, .weekly)
        XCTAssertEqual(selected.remainingPercent, 5)
        let enabled = try XCTUnwrap(WidgetServiceItem.fromMetrics(
            id: "openai", name: "Codex", shortName: "OAI", iconName: "cpu", unit: "tokens", metrics: [metrics[0]]
        ))
        XCTAssertEqual(enabled.bottleneckPeriod, .fiveHours)
        XCTAssertEqual(enabled.remainingPercent, 80)
        XCTAssertNil(WidgetServiceItem.fromMetrics(
            id: "openai", name: "Codex", shortName: "OAI", iconName: "cpu", unit: "tokens", metrics: []
        ))
    }
    func testResetCountdownUsesCurrentTimeAfterHostStops() throws {
        let reset = Int(updatedAt.timeIntervalSince1970) + 4800
        let item = try XCTUnwrap(WidgetServiceItem.fromMetrics(
            id: "claude", name: "Claude", shortName: "Cld", iconName: "cpu", unit: "tokens",
            metrics: [.init(period: .fiveHours, usedTokens: 20, limitTokens: 100, resetTimestamp: reset)]
        ))
        let snapshot = AIMeterWidgetSnapshot.make(services: [item], totalCostUSD: 0,
                                                  updatedAt: updatedAt, hasData: true)
        try SharedStore.saveWidgetSnapshot(snapshot, to: cache)
        let restored = try XCTUnwrap(SharedStore.loadWidgetSnapshot(from: cache).mostCriticalService)
        XCTAssertNil(restored.resetText)
        XCTAssertEqual(restored.remainingResetText(at: updatedAt), "あと1時間20分")
        XCTAssertEqual(restored.remainingResetText(at: updatedAt.addingTimeInterval(3600)), "あと20分")
        XCTAssertEqual(restored.remainingResetText(at: updatedAt.addingTimeInterval(5000)), "即時リセット")
    }

}
