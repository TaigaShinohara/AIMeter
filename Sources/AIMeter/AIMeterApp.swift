import SwiftUI
import AppKit
import Foundation

// MARK: - Local JSON Model
struct LocalUsageData: Codable {
    var openaiUsedTokens: Int?
    var openaiCostUSD: Double?
    var geminiUsedTokens: Int?
    var geminiCostUSD: Double?
    var updatedAt: String?
}

// MARK: - Usage Monitor
@MainActor
final class UsageMonitor: ObservableObject {
    @AppStorage("openaiAdminKey") var openaiAdminKey: String = ""
    @AppStorage("openaiTokenLimit") var openaiTokenLimit: Int = 5_000_000
    @AppStorage("openaiBudgetUSD") var openaiBudgetUSD: Double = 20.0
    @AppStorage("gcpProjectId") var gcpProjectId: String = ""
    @AppStorage("geminiTokenLimit") var geminiTokenLimit: Int = 10_000_000
    @AppStorage("geminiBudgetUSD") var geminiBudgetUSD: Double = 20.0

    @Published var openaiUsedTokens: Int = 0
    @Published var openaiCostUSD: Double = 0.0
    @Published var openaiStatus: String = "ローカル参照"

    @Published var geminiUsedTokens: Int = 0
    @Published var geminiCostUSD: Double = 0.0
    @Published var geminiStatus: String = "ローカル参照"

    @Published var lastUpdated: Date = Date()
    @Published var isRefreshing: Bool = false

    private var timer: Timer?

    init() {
        Task {
            await refresh()
        }
        timer = Timer.scheduledTimer(withTimeInterval: 60.0, repeats: true) { [weak self] _ in
            guard let self else { return }
            Task { @MainActor in
                await self.refresh()
            }
        }
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

    var menuBarTitle: String {
        let gptPct = Int((openaiRemainingRatio * 100).rounded())
        let gemPct = Int((geminiRemainingRatio * 100).rounded())
        return String(format: "GPT:%d%% Gem:%d%%", gptPct, gemPct)
    }

    func refresh() async {
        guard !isRefreshing else { return }
        isRefreshing = true
        defer {
            lastUpdated = Date()
            isRefreshing = false
        }

        // 1. Load local JSON first
        let localData = loadLocalJSON()
        if let localData {
            if let tokens = localData.openaiUsedTokens { openaiUsedTokens = tokens }
            if let cost = localData.openaiCostUSD { openaiCostUSD = cost }
            if let tokens = localData.geminiUsedTokens { geminiUsedTokens = tokens }
            if let cost = localData.geminiCostUSD { geminiCostUSD = cost }
            openaiStatus = "ローカルJSON"
            geminiStatus = "ローカルJSON"
        } else {
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

    private func loadLocalJSON() -> LocalUsageData? {
        let url = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".ai_meter_usage.json")
        guard let data = try? Data(contentsOf: url) else { return nil }
        return try? JSONDecoder().decode(LocalUsageData.self, from: data)
    }

    private func startOfMonthUnixTimestamp() -> Int {
        let calendar = Calendar.current
        let now = Date()
        let components = calendar.dateComponents([.year, .month], from: now)
        let startOfMonth = calendar.date(from: components) ?? now
        return Int(startOfMonth.timeIntervalSince1970)
    }

    private func fetchOpenAIUsage(apiKey: String) async {
        let startTime = startOfMonthUnixTimestamp()
        guard let usageURL = URL(string: "https://api.openai.com/v1/organization/usage/completions?start_time=\(startTime)&bucket_width=1d&limit=31"),
              let costsURL = URL(string: "https://api.openai.com/v1/organization/costs?start_time=\(startTime)&bucket_width=1d&limit=31") else {
            return
        }

        var usageReq = URLRequest(url: usageURL)
        usageReq.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")

        var costsReq = URLRequest(url: costsURL)
        costsReq.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")

        let finalUsageReq = usageReq
        let finalCostsReq = costsReq

        do {
            async let usageResult = URLSession.shared.data(for: finalUsageReq)
            async let costsResult = URLSession.shared.data(for: finalCostsReq)

            let (usageData, usageResp) = try await usageResult
            let (costsData, costsResp) = try await costsResult

            guard let httpUsage = usageResp as? HTTPURLResponse, (200...299).contains(httpUsage.statusCode) else {
                openaiStatus = "APIエラー (ローカル維持)"
                return
            }

            if let json = try JSONSerialization.jsonObject(with: usageData) as? [String: Any],
               let buckets = json["data"] as? [[String: Any]] {
                var totalTokens = 0
                for bucket in buckets {
                    if let results = bucket["results"] as? [[String: Any]] {
                        for res in results {
                            let input = res["input_tokens"] as? Int ?? 0
                            let output = res["output_tokens"] as? Int ?? 0
                            totalTokens += (input + output)
                        }
                    }
                }
                self.openaiUsedTokens = totalTokens
            }

            if let httpCosts = costsResp as? HTTPURLResponse, (200...299).contains(httpCosts.statusCode),
               let json = try JSONSerialization.jsonObject(with: costsData) as? [String: Any],
               let buckets = json["data"] as? [[String: Any]] {
                var totalCost = 0.0
                for bucket in buckets {
                    if let results = bucket["results"] as? [[String: Any]] {
                        for res in results {
                            if let amountObj = res["amount"] as? [String: Any],
                               let val = amountObj["value"] as? Double {
                                totalCost += val
                            }
                        }
                    }
                }
                self.openaiCostUSD = totalCost
            }

            openaiStatus = "OpenAI API連携中"
        } catch {
            openaiStatus = "接続失敗 (ローカル維持)"
        }
    }

    private func fetchGeminiUsage(projectId: String) async {
        guard let token = await fetchGcloudAccessToken() else {
            geminiStatus = "gcloud未認証 (ローカル参照)"
            return
        }

        let startTime = Date(timeIntervalSince1970: TimeInterval(startOfMonthUnixTimestamp()))
        let isoFormatter = ISO8601DateFormatter()
        let startStr = isoFormatter.string(from: startTime)
        let endStr = isoFormatter.string(from: Date())

        let filter = #"metric.type="serviceruntime.googleapis.com/api/request_count" AND resource.labels.service="generativelanguage.googleapis.com""#
        guard var components = URLComponents(string: "https://monitoring.googleapis.com/v3/projects/\(projectId)/timeSeries") else {
            return
        }
        components.queryItems = [
            URLQueryItem(name: "filter", value: filter),
            URLQueryItem(name: "interval.startTime", value: startStr),
            URLQueryItem(name: "interval.endTime", value: endStr)
        ]
        guard let url = components.url else { return }

        var request = URLRequest(url: url)
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")

        do {
            let (data, response) = try await URLSession.shared.data(for: request)
            guard let httpResp = response as? HTTPURLResponse, (200...299).contains(httpResp.statusCode) else {
                geminiStatus = "Cloud API未取得 (ローカル維持)"
                return
            }
            if let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
               let series = json["timeSeries"] as? [[String: Any]] {
                var count = 0
                for item in series {
                    if let points = item["points"] as? [[String: Any]] {
                        for pt in points {
                            if let valObj = pt["value"] as? [String: Any] {
                                if let intVal = valObj["int64Value"] as? String, let parsed = Int(intVal) {
                                    count += parsed
                                } else if let numVal = valObj["int64Value"] as? Int {
                                    count += numVal
                                }
                            }
                        }
                    }
                }
                if count > 0 {
                    // Preserve local token count if higher or update status
                    geminiStatus = "GCP Monitoring (\(count) reqs)"
                } else {
                    geminiStatus = "GCP連携済 (ローカル併用)"
                }
            } else {
                geminiStatus = "GCP連携済 (ローカル併用)"
            }
        } catch {
            geminiStatus = "GCP失敗 (ローカル参照)"
        }
    }

    private func fetchGcloudAccessToken() async -> String? {
        await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .utility).async {
                let process = Process()
                process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
                process.arguments = ["gcloud", "auth", "print-access-token"]
                let pipe = Pipe()
                process.standardOutput = pipe
                process.standardError = Pipe()
                do {
                    try process.run()
                    process.waitUntilExit()
                    guard process.terminationStatus == 0 else {
                        continuation.resume(returning: nil)
                        return
                    }
                    let data = pipe.fileHandleForReading.readDataToEndOfFile()
                    let token = String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines)
                    continuation.resume(returning: (token?.isEmpty == false) ? token : nil)
                } catch {
                    continuation.resume(returning: nil)
                }
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
        return "\(count)"
    }
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

// MARK: - Provider Section View
struct ProviderUsageSection: View {
    let title: String
    let iconName: String
    let usedCostUSD: Double
    let budgetUSD: Double
    let remainingTokens: Int
    let tokenLimit: Int
    let remainingRatio: Double
    let status: String

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

            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    Capsule()
                        .fill(Color.primary.opacity(0.12))
                        .frame(height: 8)
                    Capsule()
                        .fill(gaugeColor(for: remainingRatio))
                        .frame(width: max(4, geo.size.width * remainingRatio), height: 8)
                        .animation(.easeInOut(duration: 0.25), value: remainingRatio)
                }
            }
            .frame(height: 8)

            HStack {
                Text("残り: \(formatTokenCount(remainingTokens)) / \(formatTokenCount(tokenLimit)) (\(Int((remainingRatio * 100).rounded()))%)")
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundStyle(.secondary)
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

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("AIMeter 設定")
                .font(.headline)

            Divider()

            VStack(alignment: .leading, spacing: 6) {
                Text("OpenAI 設定").font(.subheadline.bold())
                TextField("Admin Key (sk-admin-...)", text: $monitor.openaiAdminKey)
                    .textFieldStyle(.roundedBorder)
                HStack {
                    Text("月間上限トークン:")
                    Spacer()
                    TextField("Tokens", value: $monitor.openaiTokenLimit, format: .number)
                        .textFieldStyle(.roundedBorder)
                        .frame(width: 110)
                }
                HStack {
                    Text("月間予算 ($):")
                    Spacer()
                    TextField("USD", value: $monitor.openaiBudgetUSD, format: .number)
                        .textFieldStyle(.roundedBorder)
                        .frame(width: 110)
                }
            }

            Divider()

            VStack(alignment: .leading, spacing: 6) {
                Text("Gemini / GCP 設定").font(.subheadline.bold())
                TextField("GCP Project ID", text: $monitor.gcpProjectId)
                    .textFieldStyle(.roundedBorder)
                HStack {
                    Text("月間上限トークン:")
                    Spacer()
                    TextField("Tokens", value: $monitor.geminiTokenLimit, format: .number)
                        .textFieldStyle(.roundedBorder)
                        .frame(width: 110)
                }
                HStack {
                    Text("月間予算 ($):")
                    Spacer()
                    TextField("USD", value: $monitor.geminiBudgetUSD, format: .number)
                        .textFieldStyle(.roundedBorder)
                        .frame(width: 110)
                }
            }

            Divider()

            HStack {
                Text("ローカルファイル: ~/.ai_meter_usage.json")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                Spacer()
                Button("反映して更新") {
                    Task {
                        await monitor.refresh()
                    }
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.small)
            }
        }
        .padding(14)
        .frame(width: 300)
    }
}

// MARK: - Main Card View
struct AIMeterCardView: View {
    @ObservedObject var monitor: UsageMonitor
    var isMenuBar: Bool = false
    @State private var showSettings: Bool = false

    private static let timeFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "HH:mm:ss"
        return f
    }()

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
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

                Button {
                    showSettings.toggle()
                } label: {
                    Image(systemName: "gearshape.fill")
                        .font(.system(size: 12, weight: .semibold))
                }
                .buttonStyle(.plain)
                .help("設定")
                .popover(isPresented: $showSettings, arrowEdge: .bottom) {
                    SettingsPopoverView(monitor: monitor)
                }
            }

            // OpenAI Section
            ProviderUsageSection(
                title: "OpenAI (GPT)",
                iconName: "sparkles",
                usedCostUSD: monitor.openaiCostUSD,
                budgetUSD: monitor.openaiBudgetUSD,
                remainingTokens: monitor.openaiRemainingTokens,
                tokenLimit: monitor.openaiTokenLimit,
                remainingRatio: monitor.openaiRemainingRatio,
                status: monitor.openaiStatus
            )

            // Gemini Section
            ProviderUsageSection(
                title: "Google Gemini",
                iconName: "bolt.horizontal.circle.fill",
                usedCostUSD: monitor.geminiCostUSD,
                budgetUSD: monitor.geminiBudgetUSD,
                remainingTokens: monitor.geminiRemainingTokens,
                tokenLimit: monitor.geminiTokenLimit,
                remainingRatio: monitor.geminiRemainingRatio,
                status: monitor.geminiStatus
            )

            // Footer
            HStack {
                Text("更新: \(Self.timeFormatter.string(from: monitor.lastUpdated))")
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundStyle(.secondary)
                Spacer()
                Text(String(format: "当月合計: $%.2f", monitor.totalCostUSD))
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

                    Spacer()

                    Button("終了") {
                        NSApplication.shared.terminate(nil)
                    }
                    .controlSize(.small)
                }
            }
        }
        .padding(14)
        .frame(width: 310)
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
                .onAppear {
                    configureDesktopWidgetWindow()
                }
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

    private func configureDesktopWidgetWindow() {
        DispatchQueue.main.async {
            for window in NSApplication.shared.windows {
                if window.identifier?.rawValue.contains("desktop-widget") == true || window.title == "AI Meter Widget" {
                    window.level = .floating
                    window.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
                    window.isMovableByWindowBackground = true
                    window.backgroundColor = .clear
                    window.isOpaque = false
                    window.hasShadow = true
                    window.standardWindowButton(.closeButton)?.isHidden = true
                    window.standardWindowButton(.miniaturizeButton)?.isHidden = true
                    window.standardWindowButton(.zoomButton)?.isHidden = true
                }
            }
        }
    }
}
