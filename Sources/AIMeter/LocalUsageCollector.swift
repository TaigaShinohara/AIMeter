import Foundation
import SQLite3

// MARK: - Native Local Usage Collector
/// Scans local AI tool sessions and storage directly on macOS with zero external Python dependency.
enum LocalUsageCollector {

    static let targetURL: URL = {
        FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".ai_meter_usage.json")
    }()

    private static let isoFormatterFractional: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f
    }()

    private static let isoFormatterStandard: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime]
        return f
    }()

    static func parseISODate(_ str: String) -> Date? {
        if let d = isoFormatterFractional.date(from: str) { return d }
        if let d = isoFormatterStandard.date(from: str) { return d }
        // Fallback for timestamps missing Z or non-standard
        let cleaned = str.replacingOccurrences(of: "Z", with: "+00:00")
        if let d = isoFormatterFractional.date(from: cleaned) { return d }
        if let d = isoFormatterStandard.date(from: cleaned) { return d }
        return nil
    }

    static func calculateCutoffs(now: Date = Date()) -> [String: Date] {
        return [
            "2h": now.addingTimeInterval(-2 * 3600),
            "5h": now.addingTimeInterval(-5 * 3600),
            "1d": now.addingTimeInterval(-24 * 3600),
            "7d": now.addingTimeInterval(-7 * 86400),
            "30d": now.addingTimeInterval(-30 * 86400)
        ]
    }

    // MARK: - Validation Result Struct
    struct ProviderPathScanResult: Equatable {
        var isValid: Bool
        var message: String
        var previewCount: Int
        var statusNote: String?
    }

    // MARK: - Main Entrypoint
    @discardableResult
    static func collectAndSave(targetFileURL: URL? = nil, customPaths: [String: String] = [:]) async -> LocalUsageData {
        let now = Date()
        let cutoffs = calculateCutoffs(now: now)
        let destination = targetFileURL ?? targetURL

        // Run collector on utility queue
        return await Task.detached(priority: .utility) {
            var existingProviders: [String: CustomProviderUsageJSON] = [:]
            if let existingData = try? Data(contentsOf: destination),
               let existingRoot = try? JSONSerialization.jsonObject(with: existingData) as? [String: Any],
               let provs = existingRoot["providers"] as? [String: Any] {
                let decoder = JSONDecoder()
                for (k, v) in provs {
                    if let d = try? JSONSerialization.data(withJSONObject: v),
                       let parsed = try? decoder.decode(CustomProviderUsageJSON.self, from: d) {
                        existingProviders[k] = parsed
                    }
                }
            }

            let codex = collectCodex(now: now, cutoffs: cutoffs, customPath: customPaths["openai"] ?? customPaths["codex"])
            let gemini = collectGemini(now: now, cutoffs: cutoffs, customPath: customPaths["gemini"])
            let claude = collectClaude(now: now, cutoffs: cutoffs, customPath: customPaths["claude"])
            let grok = collectGrokBot(now: now, cutoffs: cutoffs, customPath: customPaths["grokbot"])
            let copilot = collectCopilot(now: now, cutoffs: cutoffs, customPath: customPaths["copilot"])
            let windsurf = collectWindsurf(customPath: customPaths["windsurf"])
            let cursor = collectCursor(now: now, cutoffs: cutoffs, customPath: customPaths["cursor"])

            existingProviders["claude"] = claude
            if let grok { existingProviders["grokbot"] = grok }
            if let copilot { existingProviders["copilot"] = copilot }
            if let windsurf { existingProviders["windsurf"] = windsurf }
            if let cursor { existingProviders["cursor"] = cursor }

            var detected = detectInstalledProviders()
            for (pid, cp) in customPaths where !cp.isEmpty {
                if !detected.contains(pid) {
                    detected.append(pid)
                }
            }

            let isoNow = isoFormatterStandard.string(from: now)
            let payload = LocalUsageData(
                openaiUsedTokens: codex.used.monthly ?? 0,
                openaiCostUSD: codex.cost,
                geminiUsedTokens: gemini.used.monthly ?? 0,
                geminiCostUSD: gemini.cost,
                openaiUsedByPeriod: codex.used,
                geminiUsedByPeriod: gemini.used,
                openaiServerUsedPercentByPeriod: codex.serverPct,
                openaiResetAtByPeriod: codex.resetAt,
                openaiPlanType: codex.planType,
                openaiCreditBalance: codex.creditBalance,
                providers: existingProviders,
                detectedProviders: detected,
                source: "local_logs_native",
                updatedAt: isoNow
            )

            saveAtomically(payload: payload, to: destination)
            return payload
        }.value
    }

    // MARK: - Path Validation Helper
    static func validateAndScan(providerId: String, path: String) -> ProviderPathScanResult {
        let expanded = (path as NSString).expandingTildeInPath
        guard FileManager.default.fileExists(atPath: expanded) else {
            return ProviderPathScanResult(isValid: false, message: "指定されたファイルまたはディレクトリが存在しません", previewCount: 0, statusNote: nil)
        }

        let now = Date()
        let cutoffs = calculateCutoffs(now: now)

        switch providerId.lowercased() {
        case "windsurf":
            if let ws = collectWindsurf(customPath: expanded) {
                let msgs = ws.usedByPeriod?.monthly ?? 0
                return ProviderPathScanResult(
                    isValid: true,
                    message: "正常に読み込みました (\(msgs.formatted()) メッセージ)",
                    previewCount: msgs,
                    statusNote: ws.status
                )
            } else {
                return ProviderPathScanResult(isValid: false, message: "Windsurfの有効な state.vscdb が見つかりませんでした", previewCount: 0, statusNote: nil)
            }
        case "claude":
            let c = collectClaude(now: now, cutoffs: cutoffs, customPath: expanded)
            let tokens = c.usedByPeriod?.monthly ?? 0
            if tokens > 0 {
                return ProviderPathScanResult(
                    isValid: true,
                    message: "正常に読み込みました (\(tokens.formatted()) tokens)",
                    previewCount: tokens,
                    statusNote: c.status
                )
            } else {
                return ProviderPathScanResult(isValid: true, message: "ディレクトリを確認しました（直近30日のログ: 0 tokens）", previewCount: 0, statusNote: c.status)
            }
        case "cursor":
            if let cur = collectCursor(now: now, cutoffs: cutoffs, customPath: expanded) {
                let reqs = cur.usedByPeriod?.monthly ?? 0
                return ProviderPathScanResult(isValid: true, message: "正常に読み込みました (\(reqs) リクエスト)", previewCount: reqs, statusNote: cur.status)
            } else {
                return ProviderPathScanResult(isValid: false, message: "Cursorの有効なログが見つかりませんでした", previewCount: 0, statusNote: nil)
            }
        case "copilot":
            if let cop = collectCopilot(now: now, cutoffs: cutoffs, customPath: expanded) {
                let reqs = cop.usedByPeriod?.monthly ?? 0
                return ProviderPathScanResult(isValid: true, message: "正常に読み込みました (\(reqs) リクエスト)", previewCount: reqs, statusNote: cop.status)
            } else {
                return ProviderPathScanResult(isValid: false, message: "Copilotの有効な events.jsonl が見つかりませんでした", previewCount: 0, statusNote: nil)
            }
        case "openai", "codex":
            let cod = collectCodex(now: now, cutoffs: cutoffs, customPath: expanded)
            let tokens = cod.used.monthly ?? 0
            return ProviderPathScanResult(
                isValid: true,
                message: "正常に読み込みました (\(tokens.formatted()) tokens)",
                previewCount: tokens,
                statusNote: cod.planType ?? "実ログ"
            )
        case "gemini":
            let gem = collectGemini(now: now, cutoffs: cutoffs, customPath: expanded)
            let tokens = gem.used.monthly ?? 0
            return ProviderPathScanResult(
                isValid: true,
                message: "正常に読み込みました (\(tokens.formatted()) tokens)",
                previewCount: tokens,
                statusNote: "実ログ"
            )
        default:
            return ProviderPathScanResult(isValid: true, message: "パスを確認しました", previewCount: 0, statusNote: nil)
        }
    }

    // MARK: - Save Atomically with 0600 Permissions
    static func saveAtomically(payload: LocalUsageData, to fileURL: URL) {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        guard let data = try? encoder.encode(payload) else { return }

        let tempURL = fileURL.deletingLastPathComponent().appendingPathComponent(".ai_meter_usage.\(UUID().uuidString).tmp")
        do {
            try data.write(to: tempURL, options: [.atomic])
            let perms: [FileAttributeKey: Any] = [.posixPermissions: 0o600]
            try? FileManager.default.setAttributes(perms, ofItemAtPath: tempURL.path)
            if FileManager.default.fileExists(atPath: fileURL.path) {
                _ = try FileManager.default.replaceItemAt(fileURL, withItemAt: tempURL)
            } else {
                try FileManager.default.moveItem(at: tempURL, to: fileURL)
            }
            try? FileManager.default.setAttributes(perms, ofItemAtPath: fileURL.path)
        } catch {
            try? FileManager.default.removeItem(at: tempURL)
        }
    }

    // MARK: - 1. Codex / OpenAI
    private static func collectCodex(now: Date, cutoffs: [String: Date], customPath: String? = nil) -> (
        used: ProviderPeriodUsageJSON,
        raw: ProviderPeriodUsageJSON,
        cost: Double,
        serverPct: ProviderPeriodPercentJSON?,
        resetAt: ProviderPeriodUsageJSON?,
        planType: String?,
        creditBalance: Double?
    ) {
        var usedCounts = ["2h": 0, "5h": 0, "1d": 0, "7d": 0, "30d": 0]
        var rawCounts = ["2h": 0, "5h": 0, "1d": 0, "7d": 0, "30d": 0]
        var cost30d: Double = 0.0

        var latestRL: [String: Any]?
        var latestRLTimestamp = ""

        let cutoff30d = cutoffs["30d"] ?? now.addingTimeInterval(-30 * 86400)
        let codexBase: URL
        if let cp = customPath, !cp.isEmpty {
            codexBase = URL(fileURLWithPath: (cp as NSString).expandingTildeInPath)
        } else {
            codexBase = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".codex/sessions")
        }

        if FileManager.default.fileExists(atPath: codexBase.path) {
            let fileEnumerator = FileManager.default.enumerator(
                at: codexBase,
                includingPropertiesForKeys: [.contentModificationDateKey],
                options: [.skipsHiddenFiles]
            )

            while let fileURL = fileEnumerator?.nextObject() as? URL {
                guard fileURL.pathExtension == "jsonl" else { continue }
                guard let attrs = try? fileURL.resourceValues(forKeys: [.contentModificationDateKey]),
                      let mdate = attrs.contentModificationDate,
                      mdate >= cutoff30d else { continue }

                guard let fileData = try? Data(contentsOf: fileURL),
                      let fileContent = String(data: fileData, encoding: .utf8) else { continue }

                var prevTuple: (inp: Int, cached: Int, out: Int)?

                fileContent.enumerateLines { line, _ in
                    guard line.contains("\"token_count\"") else { return }
                    guard let lineData = line.data(using: .utf8),
                          let obj = try? JSONSerialization.jsonObject(with: lineData) as? [String: Any],
                          let payload = obj["payload"] as? [String: Any],
                          payload["type"] as? String == "token_count" else { return }

                    let tsStr = obj["timestamp"] as? String ?? ""
                    if let rl = payload["rate_limits"] as? [String: Any], tsStr > latestRLTimestamp {
                        latestRLTimestamp = tsStr
                        latestRL = rl
                    }

                    guard let info = payload["info"] as? [String: Any],
                          let tot = info["total_token_usage"] as? [String: Any],
                          !tsStr.isEmpty,
                          let dt = parseISODate(tsStr) else { return }

                    let curIn = tot["input_tokens"] as? Int ?? 0
                    let curCached = tot["cached_input_tokens"] as? Int ?? 0
                    let curOut = tot["output_tokens"] as? Int ?? 0
                    let curTuple = (inp: curIn, cached: curCached, out: curOut)

                    let dIn: Int
                    let dCached: Int
                    let dOut: Int

                    if let prev = prevTuple {
                        if prev == curTuple { return }
                        dIn = max(0, curIn - prev.inp)
                        dCached = max(0, curCached - prev.cached)
                        dOut = max(0, curOut - prev.out)
                    } else {
                        dIn = curIn
                        dCached = curCached
                        dOut = curOut
                    }
                    prevTuple = curTuple

                    let uncachedIn = max(0, dIn - dCached)
                    let effective = uncachedIn + dOut + Int(Double(dCached) * 0.10)
                    let rawTot = dIn + dOut

                    for (k, cutoffDate) in cutoffs {
                        if dt >= cutoffDate {
                            usedCounts[k, default: 0] += effective
                            rawCounts[k, default: 0] += rawTot
                        }
                    }

                    if dt >= cutoff30d {
                        cost30d += (Double(uncachedIn) * 2.50 + Double(dCached) * 0.25 + Double(dOut) * 10.0) / 1_000_000.0
                    }
                }
            }
        }

        var planType: String?
        var creditBalance: Double?
        var serverPctDict: [String: Double] = [:]
        var resetAtDict: [String: Int] = [:]

        if let rl = latestRL {
            planType = rl["plan_type"] as? String
            if let creds = rl["credits"] as? [String: Any], let bal = creds["balance"] as? Double {
                creditBalance = round(bal * 100) / 100.0
            }

            for slotKey in ["primary", "secondary"] {
                guard let slot = rl[slotKey] as? [String: Any] else { continue }
                let winMin = slot["window_minutes"] as? Int ?? 0
                let usedPct = (slot["used_percent"] as? NSNumber)?.doubleValue
                let resetsAt = (slot["resets_at"] as? NSNumber)?.intValue

                let periodKey: String?
                switch winMin {
                case 90...150: periodKey = "2h"
                case 240...360: periodKey = "5h"
                case 1380...1500: periodKey = "1d"
                case 9500...10500: periodKey = "7d"
                case 40000...: periodKey = "30d"
                default: periodKey = nil
                }

                if let pk = periodKey {
                    if let pct = usedPct { serverPctDict[pk] = pct }
                    if let r = resetsAt { resetAtDict[pk] = r }
                }
            }
        }

        let usedJSON = ProviderPeriodUsageJSON(
            twoHours: usedCounts["2h"],
            fiveHours: usedCounts["5h"],
            daily: usedCounts["1d"],
            weekly: usedCounts["7d"],
            monthly: usedCounts["30d"]
        )
        let rawJSON = ProviderPeriodUsageJSON(
            twoHours: rawCounts["2h"],
            fiveHours: rawCounts["5h"],
            daily: rawCounts["1d"],
            weekly: rawCounts["7d"],
            monthly: rawCounts["30d"]
        )
        let serverPctJSON = serverPctDict.isEmpty ? nil : ProviderPeriodPercentJSON(
            twoHours: serverPctDict["2h"],
            fiveHours: serverPctDict["5h"],
            daily: serverPctDict["1d"],
            weekly: serverPctDict["7d"],
            monthly: serverPctDict["30d"]
        )
        let resetAtJSON = resetAtDict.isEmpty ? nil : ProviderPeriodUsageJSON(
            twoHours: resetAtDict["2h"],
            fiveHours: resetAtDict["5h"],
            daily: resetAtDict["1d"],
            weekly: resetAtDict["7d"],
            monthly: resetAtDict["30d"]
        )

        return (
            used: usedJSON,
            raw: rawJSON,
            cost: round(cost30d * 100) / 100.0,
            serverPct: serverPctJSON,
            resetAt: resetAtJSON,
            planType: planType,
            creditBalance: creditBalance
        )
    }

    // MARK: - 2. Gemini
    private static func collectGemini(now: Date, cutoffs: [String: Date], customPath: String? = nil) -> (
        used: ProviderPeriodUsageJSON,
        raw: ProviderPeriodUsageJSON,
        cost: Double
    ) {
        var usedCounts = ["2h": 0, "5h": 0, "1d": 0, "7d": 0, "30d": 0]
        var rawCounts = ["2h": 0, "5h": 0, "1d": 0, "7d": 0, "30d": 0]
        var cost30d: Double = 0.0

        let cutoff30d = cutoffs["30d"] ?? now.addingTimeInterval(-30 * 86400)
        let agBrainBase: URL
        if let cp = customPath, !cp.isEmpty {
            agBrainBase = URL(fileURLWithPath: (cp as NSString).expandingTildeInPath)
        } else {
            agBrainBase = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".gemini/antigravity/brain")
        }

        if FileManager.default.fileExists(atPath: agBrainBase.path) {
            let fileEnumerator = FileManager.default.enumerator(
                at: agBrainBase,
                includingPropertiesForKeys: [.contentModificationDateKey],
                options: [.skipsHiddenFiles]
            )

            while let fileURL = fileEnumerator?.nextObject() as? URL {
                guard fileURL.lastPathComponent == "transcript.jsonl" || fileURL.lastPathComponent == "transcript_full.jsonl" else { continue }
                guard let attrs = try? fileURL.resourceValues(forKeys: [.contentModificationDateKey]),
                      let mdate = attrs.contentModificationDate,
                      mdate >= cutoff30d else { continue }

                guard let fileData = try? Data(contentsOf: fileURL),
                      let fileContent = String(data: fileData, encoding: .utf8) else { continue }

                fileContent.enumerateLines { line, _ in
                    guard line.contains("\"created_at\"") else { return }
                    guard let lineData = line.data(using: .utf8),
                          let obj = try? JSONSerialization.jsonObject(with: lineData) as? [String: Any],
                          let tsStr = obj["created_at"] as? String,
                          let dt = parseISODate(tsStr) else { return }

                    let inp = obj["input_tokens"] as? Int ?? 0
                    let cached = obj["cache_read_tokens"] as? Int ?? 0
                    let out = obj["output_tokens"] as? Int ?? 0

                    let effective: Int
                    let rawTot: Int
                    let stepCost: Double

                    if inp + cached + out > 0 {
                        effective = inp + out + Int(Double(cached) * 0.10)
                        rawTot = inp + cached + out
                        stepCost = (Double(inp) * 1.25 + Double(cached) * 0.3125 + Double(out) * 5.0) / 1_000_000.0
                    } else {
                        let content = (obj["content"] as? String ?? "") + (obj["thinking"] as? String ?? "")
                        let est = max(1, content.count / 4)
                        effective = est
                        rawTot = est
                        stepCost = (Double(est) * 2.0) / 1_000_000.0
                    }

                    for (k, cutoffDate) in cutoffs {
                        if dt >= cutoffDate {
                            usedCounts[k, default: 0] += effective
                            rawCounts[k, default: 0] += rawTot
                        }
                    }

                    if dt >= cutoff30d {
                        cost30d += stepCost
                    }
                }
            }
        }

        // Gemini tmp chats
        let chatsBase = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".gemini/tmp")
        if FileManager.default.fileExists(atPath: chatsBase.path) {
            let fileEnumerator = FileManager.default.enumerator(
                at: chatsBase,
                includingPropertiesForKeys: [.contentModificationDateKey],
                options: [.skipsHiddenFiles]
            )
            while let fileURL = fileEnumerator?.nextObject() as? URL {
                guard fileURL.pathExtension == "json", fileURL.path.contains("/chats/") else { continue }
                guard let attrs = try? fileURL.resourceValues(forKeys: [.contentModificationDateKey]),
                      let mdate = attrs.contentModificationDate,
                      mdate >= cutoff30d else { continue }

                guard let fileData = try? Data(contentsOf: fileURL),
                      let root = try? JSONSerialization.jsonObject(with: fileData) as? [String: Any],
                      let messages = root["messages"] as? [[String: Any]] else { continue }

                for msg in messages {
                    guard let tsStr = msg["timestamp"] as? String,
                          let dt = parseISODate(tsStr),
                          let tokens = msg["tokens"] as? [String: Any] else { continue }

                    let tot = tokens["total"] as? Int ?? 0
                    let cached = tokens["cached"] as? Int ?? 0
                    let out = tokens["output"] as? Int ?? 0
                    let inp = tokens["input"] as? Int ?? 0
                    let uncachedIn = max(0, inp - cached)
                    let effective = uncachedIn + out + Int(Double(cached) * 0.10)

                    for (k, cutoffDate) in cutoffs {
                        if dt >= cutoffDate {
                            usedCounts[k, default: 0] += effective
                            rawCounts[k, default: 0] += tot
                        }
                    }

                    if dt >= cutoff30d {
                        cost30d += (Double(uncachedIn) * 1.25 + Double(cached) * 0.3125 + Double(out) * 5.0) / 1_000_000.0
                    }
                }
            }
        }

        let usedJSON = ProviderPeriodUsageJSON(
            twoHours: usedCounts["2h"],
            fiveHours: usedCounts["5h"],
            daily: usedCounts["1d"],
            weekly: usedCounts["7d"],
            monthly: usedCounts["30d"]
        )
        let rawJSON = ProviderPeriodUsageJSON(
            twoHours: rawCounts["2h"],
            fiveHours: rawCounts["5h"],
            daily: rawCounts["1d"],
            weekly: rawCounts["7d"],
            monthly: rawCounts["30d"]
        )

        return (
            used: usedJSON,
            raw: rawJSON,
            cost: round(cost30d * 100) / 100.0
        )
    }

    // MARK: - 3. Claude
    private static func collectClaude(now: Date, cutoffs: [String: Date], customPath: String? = nil) -> CustomProviderUsageJSON {
        var usedCounts = ["2h": 0, "5h": 0, "1d": 0, "7d": 0, "30d": 0]
        var cost30d: Double = 0.0

        let cutoff30d = cutoffs["30d"] ?? now.addingTimeInterval(-30 * 86400)
        let claudeBase: URL
        if let cp = customPath, !cp.isEmpty {
            claudeBase = URL(fileURLWithPath: (cp as NSString).expandingTildeInPath)
        } else {
            claudeBase = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".claude")
        }

        for dirName in ["projects", "sessions", ""] {
            let subDir = dirName.isEmpty ? claudeBase : claudeBase.appendingPathComponent(dirName)
            guard FileManager.default.fileExists(atPath: subDir.path) else { continue }

            let fileEnumerator = FileManager.default.enumerator(
                at: subDir,
                includingPropertiesForKeys: [.contentModificationDateKey],
                options: [.skipsHiddenFiles]
            )

            while let fileURL = fileEnumerator?.nextObject() as? URL {
                guard fileURL.pathExtension == "jsonl" else { continue }
                guard let attrs = try? fileURL.resourceValues(forKeys: [.contentModificationDateKey]),
                      let mdate = attrs.contentModificationDate,
                      mdate >= cutoff30d else { continue }

                guard let fileData = try? Data(contentsOf: fileURL),
                      let fileContent = String(data: fileData, encoding: .utf8) else { continue }

                fileContent.enumerateLines { line, _ in
                    guard line.contains("usage") else { return }
                    guard let lineData = line.data(using: .utf8),
                          let obj = try? JSONSerialization.jsonObject(with: lineData) as? [String: Any] else { return }

                    let tsStr = (obj["timestamp"] as? String) ?? (obj["createdAt"] as? String) ?? ""
                    guard let dt = parseISODate(tsStr) else { return }

                    let msg = obj["message"] as? [String: Any]
                    let usage = (msg?["usage"] as? [String: Any]) ?? (obj["usage"] as? [String: Any]) ?? [:]

                    let inp = usage["input_tokens"] as? Int ?? 0
                    let cached = usage["cache_read_input_tokens"] as? Int ?? 0
                    let out = usage["output_tokens"] as? Int ?? 0
                    let effective = inp + out + Int(Double(cached) * 0.10)
                    guard effective > 0 else { return }

                    for (k, cutoffDate) in cutoffs {
                        if dt >= cutoffDate {
                            usedCounts[k, default: 0] += effective
                        }
                    }

                    if dt >= cutoff30d {
                        cost30d += (Double(inp) * 3.0 + Double(cached) * 0.30 + Double(out) * 15.0) / 1_000_000.0
                    }
                }
            }
        }

        var statusLabel = "Pro"
        let claudeJSONPath = claudeBase.appendingPathComponent(".claude.json")
        let defaultClaudeJSON = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".claude.json")
        let targetJSON = FileManager.default.fileExists(atPath: claudeJSONPath.path) ? claudeJSONPath : defaultClaudeJSON

        if let cData = try? Data(contentsOf: targetJSON),
           let cObj = try? JSONSerialization.jsonObject(with: cData) as? [String: Any] {
            if let tier = cObj["claudeMaxTier"] as? String, tier != "not_max" {
                statusLabel = "Max (\(tier))"
            }
            if usedCounts["30d"] == 0, let projDict = cObj["projects"] as? [String: Any] {
                var totEff = 0
                var totCost: Double = 0.0
                for (_, pv) in projDict {
                    guard let pObj = pv as? [String: Any] else { continue }
                    let inp = pObj["lastTotalInputTokens"] as? Int ?? 0
                    let out = pObj["lastTotalOutputTokens"] as? Int ?? 0
                    let cw = pObj["lastTotalCacheCreationInputTokens"] as? Int ?? 0
                    let cr = pObj["lastTotalCacheReadInputTokens"] as? Int ?? 0
                    totEff += inp + out + cw + Int(Double(cr) * 0.10)
                    totCost += (pObj["lastCost"] as? NSNumber)?.doubleValue ?? 0.0
                }
                if totEff > 0 {
                    usedCounts["30d"] = totEff
                    usedCounts["7d"] = totEff
                }
                if totCost > 0 {
                    cost30d = max(cost30d, totCost)
                }
            }
        }

        let usedJSON = ProviderPeriodUsageJSON(
            twoHours: usedCounts["2h"],
            fiveHours: usedCounts["5h"],
            daily: usedCounts["1d"],
            weekly: usedCounts["7d"],
            monthly: usedCounts["30d"]
        )

        return CustomProviderUsageJSON(
            usedByPeriod: usedJSON,
            serverUsedPercentByPeriod: nil,
            resetAtByPeriod: nil,
            costUSD: cost30d > 0 ? round(cost30d * 100) / 100.0 : 20.0,
            status: statusLabel
        )
    }

    // MARK: - 4. GrokBot
    private static func collectGrokBot(now: Date, cutoffs: [String: Date], customPath: String? = nil) -> CustomProviderUsageJSON? {
        let appSupport: URL
        if let cp = customPath, !cp.isEmpty {
            appSupport = URL(fileURLWithPath: (cp as NSString).expandingTildeInPath)
        } else {
            appSupport = FileManager.default.homeDirectoryForCurrentUser
                .appendingPathComponent("Library/Application Support/Grok Bot/sand-client-persistence")
        }
        let dotGrok = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".grokbot")

        if !FileManager.default.fileExists(atPath: appSupport.path) && !FileManager.default.fileExists(atPath: dotGrok.path) {
            return nil
        }

        var usedCounts = ["2h": 0, "5h": 0, "1d": 0, "7d": 0, "30d": 0]
        var serverPctDict: [String: Double] = [:]
        var resetAtDict: [String: Int] = [:]
        var costUSD: Double = 0.0
        var planLabel = "Grok Bot"

        if FileManager.default.fileExists(atPath: appSupport.path) {
            if let items = try? FileManager.default.contentsOfDirectory(atPath: appSupport.path) {
                for fn in items where fn.hasSuffix(".blob") {
                    let fp = appSupport.appendingPathComponent(fn)
                    guard let data = try? Data(contentsOf: fp),
                          let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                          let val = root["value"] as? [String: Any] else { continue }

                    // Base32 key decode to detect cache type
                    let b32 = fn.replacingOccurrences(of: ".blob", with: "").uppercased()
                    let decKey = decodeBase32(b32)

                    if decKey.contains("weekly-usage.cache") {
                        if let reading = val["reading"] as? [String: Any],
                           let usage = reading["usage"] as? [String: Any] {
                            if let pct = (usage["percentUsed"] as? NSNumber)?.doubleValue {
                                serverPctDict["7d"] = round(pct * 100) / 100.0
                            }
                            if let resetMs = (usage["nextResetMs"] as? NSNumber)?.int64Value {
                                resetAtDict["7d"] = Int(resetMs / 1000)
                            }
                            if let onDemand = usage["onDemand"] as? [String: Any],
                               let cents = (onDemand["usedCents"] as? NSNumber)?.doubleValue {
                                costUSD = max(costUSD, round((cents / 100.0) * 100) / 100.0)
                            }
                            if let lbl = usage["grokPlanLabel"] as? String, !lbl.isEmpty {
                                planLabel = lbl
                            }
                        }
                    } else if decKey.contains("transcript.replicas.") {
                        if let entries = val["entries"] as? [[String: Any]] {
                            for entry in entries {
                                guard let tsMs = (entry["timestampMs"] as? NSNumber)?.doubleValue else { continue }
                                let dt = Date(timeIntervalSince1970: tsMs / 1000.0)
                                let content = (entry["content"] as? String) ?? (entry["message"] as? String) ?? ""
                                let est = max(1, content.count / 3)
                                for (k, cutoffDate) in cutoffs {
                                    if dt >= cutoffDate {
                                        usedCounts[k, default: 0] += est
                                    }
                                }
                            }
                        }
                    }
                }
            }
        }

        if let pct = serverPctDict["7d"], usedCounts["7d"] == 0 {
            usedCounts["7d"] = Int(10_000_000.0 * (pct / 100.0))
            usedCounts["30d"] = max(usedCounts["30d"] ?? 0, usedCounts["7d"] ?? 0)
        }

        let usedJSON = ProviderPeriodUsageJSON(
            twoHours: usedCounts["2h"],
            fiveHours: usedCounts["5h"],
            daily: usedCounts["1d"],
            weekly: usedCounts["7d"],
            monthly: usedCounts["30d"]
        )
        let serverPctJSON = serverPctDict.isEmpty ? nil : ProviderPeriodPercentJSON(
            twoHours: serverPctDict["2h"],
            fiveHours: serverPctDict["5h"],
            daily: serverPctDict["1d"],
            weekly: serverPctDict["7d"],
            monthly: serverPctDict["30d"]
        )
        let resetAtJSON = resetAtDict.isEmpty ? nil : ProviderPeriodUsageJSON(
            twoHours: resetAtDict["2h"],
            fiveHours: resetAtDict["5h"],
            daily: resetAtDict["1d"],
            weekly: resetAtDict["7d"],
            monthly: resetAtDict["30d"]
        )

        return CustomProviderUsageJSON(
            usedByPeriod: usedJSON,
            serverUsedPercentByPeriod: serverPctJSON,
            resetAtByPeriod: resetAtJSON,
            costUSD: costUSD > 0 ? costUSD : 30.0,
            status: planLabel
        )
    }

    // MARK: - 5. Windsurf (SQLite3)
    private static func collectWindsurf(customPath: String? = nil) -> CustomProviderUsageJSON? {
        let dbPath: URL
        if let cp = customPath, !cp.isEmpty {
            let u = URL(fileURLWithPath: (cp as NSString).expandingTildeInPath)
            if u.pathExtension == "vscdb" {
                dbPath = u
            } else {
                dbPath = u.appendingPathComponent("state.vscdb")
            }
        } else {
            dbPath = FileManager.default.homeDirectoryForCurrentUser
                .appendingPathComponent("Library/Application Support/Windsurf/User/globalStorage/state.vscdb")
        }

        guard FileManager.default.fileExists(atPath: dbPath.path) else { return nil }

        var db: OpaquePointer?
        let flags = SQLITE_OPEN_READONLY | SQLITE_OPEN_URI
        guard sqlite3_open_v2(dbPath.path, &db, flags, nil) == SQLITE_OK, let database = db else {
            return nil
        }
        defer { sqlite3_close(database) }

        var stmt: OpaquePointer?
        let sql = "SELECT value FROM ItemTable WHERE key='windsurf.settings.cachedPlanInfo'"
        guard sqlite3_prepare_v2(database, sql, -1, &stmt, nil) == SQLITE_OK, let statement = stmt else {
            return nil
        }
        defer { sqlite3_finalize(statement) }

        guard sqlite3_step(statement) == SQLITE_ROW,
              let cString = sqlite3_column_text(statement, 0) else {
            return nil
        }

        let jsonString = String(cString: cString)
        guard let data = jsonString.data(using: .utf8),
              let info = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return nil
        }

        let planName = (info["planName"] as? String) ?? "Pro"
        let usage = (info["usage"] as? [String: Any]) ?? [:]
        let usedMsgs = (usage["usedMessages"] as? NSNumber)?.intValue ?? 0
        let totalMsgs = (usage["messages"] as? NSNumber)?.intValue ?? 50000

        var usedCounts = ["2h": 0, "5h": 0, "1d": 0, "7d": 0, "30d": 0]
        usedCounts["30d"] = usedMsgs
        usedCounts["7d"] = min(usedMsgs, Int(Double(usedMsgs) * 0.35))
        usedCounts["1d"] = min(usedMsgs, Int(Double(usedMsgs) * 0.08))

        let pct30d = totalMsgs > 0 ? round((Double(usedMsgs) / Double(totalMsgs)) * 10000.0) / 100.0 : 0.0

        let usedJSON = ProviderPeriodUsageJSON(
            twoHours: usedCounts["2h"],
            fiveHours: usedCounts["5h"],
            daily: usedCounts["1d"],
            weekly: usedCounts["7d"],
            monthly: usedCounts["30d"]
        )
        let serverPctJSON = pct30d > 0 ? ProviderPeriodPercentJSON(
            twoHours: nil, fiveHours: nil, daily: nil, weekly: nil, monthly: pct30d
        ) : nil

        return CustomProviderUsageJSON(
            usedByPeriod: usedJSON,
            serverUsedPercentByPeriod: serverPctJSON,
            resetAtByPeriod: nil,
            costUSD: 20.0,
            status: "Windsurf \(planName)"
        )
    }

    // MARK: - 6. GitHub Copilot
    private static func collectCopilot(now: Date, cutoffs: [String: Date], customPath: String? = nil) -> CustomProviderUsageJSON? {
        let copilotBase: URL
        if let cp = customPath, !cp.isEmpty {
            copilotBase = URL(fileURLWithPath: (cp as NSString).expandingTildeInPath)
        } else {
            copilotBase = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".copilot/session-state")
        }
        guard FileManager.default.fileExists(atPath: copilotBase.path) else { return nil }

        var usedCounts = ["2h": 0, "5h": 0, "1d": 0, "7d": 0, "30d": 0]
        let cutoff30d = cutoffs["30d"] ?? now.addingTimeInterval(-30 * 86400)

        let fileEnumerator = FileManager.default.enumerator(
            at: copilotBase,
            includingPropertiesForKeys: [.contentModificationDateKey],
            options: [.skipsHiddenFiles]
        )

        while let fileURL = fileEnumerator?.nextObject() as? URL {
            guard fileURL.lastPathComponent == "events.jsonl" else { continue }
            guard let attrs = try? fileURL.resourceValues(forKeys: [.contentModificationDateKey]),
                  let mdate = attrs.contentModificationDate,
                  mdate >= cutoff30d else { continue }

            guard let fileData = try? Data(contentsOf: fileURL),
                  let content = String(data: fileData, encoding: .utf8) else { continue }

            var sessionReqByPeriod = ["2h": 0, "5h": 0, "1d": 0, "7d": 0, "30d": 0]
            var snapCost: Double = 0.0
            var snapDate: Date?

            content.enumerateLines { line, _ in
                guard let lineData = line.data(using: .utf8),
                      let obj = try? JSONSerialization.jsonObject(with: lineData) as? [String: Any],
                      let evType = obj["type"] as? String else { return }

                let tsStr = obj["timestamp"] as? String ?? ""
                let dt = parseISODate(tsStr)

                if evType == "user.message", let dt {
                    for (k, cutoffDate) in cutoffs {
                        if dt >= cutoffDate {
                            sessionReqByPeriod[k, default: 0] += 1
                        }
                    }
                } else if evType == "session.usage_checkpoint" {
                    if let data = obj["data"] as? [String: Any],
                       let snap = data["accountingSnapshot"] as? [String: Any],
                       let cost = (snap["totalPremiumRequestCost"] as? NSNumber)?.doubleValue {
                        snapCost = max(snapCost, cost)
                        if let dt { snapDate = dt }
                    }
                }
            }

            for (k, cutoffDate) in cutoffs {
                if snapCost > 0, let sd = snapDate, sd >= cutoffDate {
                    usedCounts[k, default: 0] += max(Int(snapCost.rounded()), sessionReqByPeriod[k] ?? 0)
                } else {
                    usedCounts[k, default: 0] += sessionReqByPeriod[k] ?? 0
                }
            }
        }

        let usedJSON = ProviderPeriodUsageJSON(
            twoHours: usedCounts["2h"],
            fiveHours: usedCounts["5h"],
            daily: usedCounts["1d"],
            weekly: usedCounts["7d"],
            monthly: usedCounts["30d"]
        )

        return CustomProviderUsageJSON(
            usedByPeriod: usedJSON,
            serverUsedPercentByPeriod: nil,
            resetAtByPeriod: nil,
            costUSD: 10.0,
            status: "Premium Reqs"
        )
    }

    // MARK: - 7. Cursor
    private static func collectCursor(now: Date, cutoffs: [String: Date], customPath: String? = nil) -> CustomProviderUsageJSON? {
        let cursorAppSupport: URL
        if let cp = customPath, !cp.isEmpty {
            cursorAppSupport = URL(fileURLWithPath: (cp as NSString).expandingTildeInPath)
        } else {
            cursorAppSupport = FileManager.default.homeDirectoryForCurrentUser
                .appendingPathComponent("Library/Application Support/Cursor")
        }
        let dotCursor = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".cursor")

        if !FileManager.default.fileExists(atPath: cursorAppSupport.path) && !FileManager.default.fileExists(atPath: dotCursor.path) {
            return nil
        }

        var usedCounts = ["2h": 0, "5h": 0, "1d": 0, "7d": 0, "30d": 0]
        let candidateDirs = [
            cursorAppSupport.appendingPathComponent("AgentStores/cursor_agent_stores/.control"),
            cursorAppSupport
        ]
        let pinsDir = candidateDirs.first(where: { FileManager.default.fileExists(atPath: $0.path) }) ?? cursorAppSupport

        if FileManager.default.fileExists(atPath: pinsDir.path) {
            let fileEnumerator = FileManager.default.enumerator(
                at: pinsDir,
                includingPropertiesForKeys: [.contentModificationDateKey],
                options: [.skipsHiddenFiles]
            )

            while let fileURL = fileEnumerator?.nextObject() as? URL {
                guard fileURL.pathExtension == "json" else { continue }
                guard let attrs = try? fileURL.resourceValues(forKeys: [.contentModificationDateKey]),
                      let mdate = attrs.contentModificationDate else { continue }

                for (k, cutoffDate) in cutoffs {
                    if mdate >= cutoffDate {
                        usedCounts[k, default: 0] += 1
                    }
                }
            }
        }

        let usedJSON = ProviderPeriodUsageJSON(
            twoHours: usedCounts["2h"],
            fiveHours: usedCounts["5h"],
            daily: usedCounts["1d"],
            weekly: usedCounts["7d"],
            monthly: usedCounts["30d"]
        )

        return CustomProviderUsageJSON(
            usedByPeriod: usedJSON,
            serverUsedPercentByPeriod: nil,
            resetAtByPeriod: nil,
            costUSD: 20.0,
            status: "Pro / Agent"
        )
    }

    // MARK: - Installed Providers Detection
    static func detectInstalledProviders() -> [String] {
        var detected: [String] = []
        let home = FileManager.default.homeDirectoryForCurrentUser
        let appSupport = home.appendingPathComponent("Library/Application Support")

        let checks: [(String, [URL])] = [
            ("grokbot", [home.appendingPathComponent(".grokbot"), appSupport.appendingPathComponent("Grok Bot")]),
            ("claude", [home.appendingPathComponent(".claude"), home.appendingPathComponent(".claude.json"), appSupport.appendingPathComponent("Claude")]),
            ("windsurf", [home.appendingPathComponent(".windsurf"), home.appendingPathComponent(".codeium"), appSupport.appendingPathComponent("Windsurf")]),
            ("copilot", [home.appendingPathComponent(".copilot")]),
            ("cursor", [home.appendingPathComponent(".cursor"), appSupport.appendingPathComponent("Cursor")]),
            ("trae", [home.appendingPathComponent(".trae-aicc"), appSupport.appendingPathComponent("Trae")])
        ]

        for (pid, paths) in checks {
            if paths.contains(where: { FileManager.default.fileExists(atPath: $0.path) }) {
                detected.append(pid)
            }
        }
        return detected
    }

    // MARK: - Simple Base32 Decoder
    private static func decodeBase32(_ input: String) -> String {
        let alphabet = "ABCDEFGHIJKLMNOPQRSTUVWXYZ234567"
        var bits = 0
        var value = 0
        var outputData = Data()

        for char in input {
            guard let idx = alphabet.firstIndex(of: char) else { continue }
            let val = alphabet.distance(from: alphabet.startIndex, to: idx)
            value = (value << 5) | val
            bits += 5
            if bits >= 8 {
                bits -= 8
                outputData.append(UInt8((value >> bits) & 0xFF))
            }
        }
        return String(data: outputData, encoding: .utf8) ?? ""
    }
}
