import SwiftUI
import AppKit
import Foundation
import Security

// MARK: - Local JSON Model
struct LocalUsageData: Codable, Equatable {
    var openaiUsedTokens: Int?
    var openaiCostUSD: Double?
    var geminiUsedTokens: Int?
    var geminiCostUSD: Double?
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

    static func parseOpenAIUsagePage(data: Data) throws -> (tokens: Int, nextPage: String?) {
        guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw URLError(.cannotParseResponse)
        }
        var totalTokens = 0
        if let buckets = json["data"] as? [[String: Any]] {
            for bucket in buckets {
                if let results = bucket["results"] as? [[String: Any]] {
                    for res in results {
                        let input = parseIntValue(res["input_tokens"])
                        let output = parseIntValue(res["output_tokens"])
                        totalTokens += (input + output)
                    }
                }
            }
        }
        let hasMore = (json["has_more"] as? Bool) ?? true
        let nextPage = hasMore ? (json["next_page"] as? String) : nil
        return (totalTokens, (nextPage?.isEmpty == false) ? nextPage : nil)
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
    @AppStorage("openaiAdminKey") var legacyOpenaiAdminKey: String = ""
    @Published var openaiAdminKey: String = "" {
        didSet {
            KeychainHelper.save(key: "openaiAdminKey", value: openaiAdminKey)
        }
    }
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
    private var wakeObserver: NSObjectProtocol?
    private let urlSession: URLSession

    init() {
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 15.0
        config.timeoutIntervalForResource = 30.0
        self.urlSession = URLSession(configuration: config)

        // Migrate plaintext @AppStorage key to Keychain if present
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
        if openaiTokenLimit < 1 { openaiTokenLimit = 1 }
        if openaiBudgetUSD < 0 { openaiBudgetUSD = 0 }
        if geminiTokenLimit < 1 { geminiTokenLimit = 1 }
        if geminiBudgetUSD < 0 { geminiBudgetUSD = 0 }
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
        sanitizeSettings()
        defer {
            lastUpdated = Date()
            isRefreshing = false
        }

        // 1. Reset and load local JSON first
        let localData = loadLocalJSON()
        if let localData {
            openaiUsedTokens = max(0, localData.openaiUsedTokens ?? 0)
            openaiCostUSD = max(0.0, localData.openaiCostUSD ?? 0.0)
            geminiUsedTokens = max(0, localData.geminiUsedTokens ?? 0)
            geminiCostUSD = max(0.0, localData.geminiCostUSD ?? 0.0)
            openaiStatus = "ローカルJSON"
            geminiStatus = "ローカルJSON"
        } else {
            openaiUsedTokens = 0
            openaiCostUSD = 0.0
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

    func loadLocalJSON(from customURL: URL? = nil) -> LocalUsageData? {
        let url = customURL ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".ai_meter_usage.json")
        guard let data = try? Data(contentsOf: url) else { return nil }
        return try? JSONDecoder().decode(LocalUsageData.self, from: data)
    }

    private func fetchOpenAIUsage(apiKey: String) async {
        let startTime = UsageParser.startOfMonthUnixTimestamp()

        do {
            let totalTokens = try await fetchPaginatedOpenAIUsage(apiKey: apiKey, startTime: startTime)
            self.openaiUsedTokens = totalTokens

            if let totalCost = try? await fetchPaginatedOpenAICosts(apiKey: apiKey, startTime: startTime) {
                self.openaiCostUSD = totalCost
            }
            openaiStatus = "OpenAI API連携中"
        } catch {
            openaiStatus = "API/接続失敗 (ローカル維持)"
        }
    }

    private func fetchPaginatedOpenAIUsage(apiKey: String, startTime: Int) async throws -> Int {
        var totalTokens = 0
        var nextPage: String? = nil
        var pageCount = 0

        repeat {
            pageCount += 1
            var components = URLComponents(string: "https://api.openai.com/v1/organization/usage/completions")
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

            let parsed = try UsageParser.parseOpenAIUsagePage(data: data)
            totalTokens += parsed.tokens
            nextPage = parsed.nextPage
        } while nextPage != nil && pageCount < 10

        return totalTokens
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
            geminiStatus = "gcloud未認証 (ローカル参照)"
            return
        }

        let startTime = Date(timeIntervalSince1970: TimeInterval(UsageParser.startOfMonthUnixTimestamp()))
        let isoFormatter = ISO8601DateFormatter()
        let startStr = isoFormatter.string(from: startTime)
        let endStr = isoFormatter.string(from: Date())

        // 1. Query Vertex AI / Gemini token_count metric first
        let tokenFilter = #"metric.type="aiplatform.googleapis.com/publisher/online_serving/token_count""#
        let requestCountFilter = #"metric.type="serviceruntime.googleapis.com/api/request_count" AND (resource.labels.service="generativelanguage.googleapis.com" OR resource.labels.service="aiplatform.googleapis.com")"#

        do {
            if let tokenCount = try? await queryCloudMonitoring(
                projectId: projectId,
                token: token,
                filter: tokenFilter,
                startStr: startStr,
                endStr: endStr
            ), tokenCount > 0 {
                self.geminiUsedTokens = tokenCount
                geminiStatus = "GCPトークン連携中"
                return
            }

            let reqCount = try await queryCloudMonitoring(
                projectId: projectId,
                token: token,
                filter: requestCountFilter,
                startStr: startStr,
                endStr: endStr
            )
            if reqCount > 0 {
                geminiStatus = "GCP (\(reqCount) reqs / ローカル併用)"
            } else {
                geminiStatus = "GCP連携済 (ローカル併用)"
            }
        } catch {
            geminiStatus = "Cloud API未取得 (ローカル維持)"
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

                // Timeout after 8 seconds to prevent UI/refresh deadlock
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
        let pct = Int((remainingRatio * 100).rounded())
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
            .accessibilityElement(children: .ignore)
            .accessibilityLabel("\(title) 残りトークン割合")
            .accessibilityValue("\(pct)パーセント")

            HStack(spacing: 4) {
                if let warningSymbol = gaugeWarningSymbol(for: remainingRatio) {
                    Image(systemName: warningSymbol)
                        .font(.system(size: 10))
                        .foregroundStyle(gaugeColor(for: remainingRatio))
                        .accessibilityHidden(true)
                }
                Text("残り: \(formatTokenCount(remainingTokens)) / \(formatTokenCount(tokenLimit)) (\(pct)%)")
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
        .accessibilityElement(children: .combine)
    }
}

// MARK: - Settings Popover View
struct SettingsPopoverView: View {
    @ObservedObject var monitor: UsageMonitor
    @State private var revealAdminKey: Bool = false

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("AIMeter 設定")
                .font(.headline)

            Divider()

            VStack(alignment: .leading, spacing: 6) {
                Text("OpenAI 設定 (Keychain保護)").font(.subheadline.bold())
                HStack(spacing: 4) {
                    if revealAdminKey {
                        TextField("Admin Key (sk-admin-...)", text: $monitor.openaiAdminKey)
                            .textFieldStyle(.roundedBorder)
                    } else {
                        SecureField("Admin Key (sk-admin-...)", text: $monitor.openaiAdminKey)
                            .textFieldStyle(.roundedBorder)
                    }
                    Button {
                        revealAdminKey.toggle()
                    } label: {
                        Image(systemName: revealAdminKey ? "eye.slash" : "eye")
                            .font(.system(size: 11))
                    }
                    .buttonStyle(.borderless)
                    .help(revealAdminKey ? "キーを隠す" : "キーを表示")
                }
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
        .frame(width: 310)
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
    @Environment(\.openWindow) private var openWindow

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
