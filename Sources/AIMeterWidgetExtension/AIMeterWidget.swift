import WidgetKit
import SwiftUI
import AIMeterCore

// MARK: - Timeline Entry
struct AIMeterWidgetEntry: TimelineEntry {
    let date: Date
    let snapshot: AIMeterWidgetSnapshot
}

// MARK: - Timeline Provider
struct AIMeterTimelineProvider: TimelineProvider {
    typealias Entry = AIMeterWidgetEntry

    func placeholder(in context: Context) -> AIMeterWidgetEntry {
        AIMeterWidgetEntry(date: Date(), snapshot: .placeholder())
    }

    func getSnapshot(in context: Context, completion: @escaping (AIMeterWidgetEntry) -> Void) {
        if context.isPreview {
            completion(AIMeterWidgetEntry(date: Date(), snapshot: .placeholder()))
        } else {
            let snap = SharedStore.createCurrentSnapshot()
            completion(AIMeterWidgetEntry(date: Date(), snapshot: snap.hasData ? snap : .placeholder()))
        }
    }

    func getTimeline(in context: Context, completion: @escaping (Timeline<AIMeterWidgetEntry>) -> Void) {
        let currentDate = Date()
        let snap = SharedStore.createCurrentSnapshot()
        let entry = AIMeterWidgetEntry(date: currentDate, snapshot: snap.hasData ? snap : .placeholder())

        // 15分後に定期リロード（メインアプリ更新時にも WidgetCenter.shared.reloadAllTimelines() で即時更新）
        let nextUpdate = Calendar.current.date(byAdding: .minute, value: 15, to: currentDate) ?? currentDate.addingTimeInterval(900)
        let timeline = Timeline(entries: [entry], policy: .after(nextUpdate))
        completion(timeline)
    }
}

// MARK: - Small Widget View (最逼迫サービス)
struct SmallWidgetView: View {
    let snapshot: AIMeterWidgetSnapshot

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text("AI Meter")
                    .font(.system(size: 11, weight: .bold))
                    .foregroundStyle(.secondary)
                Spacer()
                if snapshot.totalCostUSD > 0 {
                    Text(String(format: "$%.1f", snapshot.totalCostUSD))
                        .font(.system(size: 10, weight: .semibold).monospacedDigit())
                        .foregroundStyle(.secondary)
                }
            }

            if let item = snapshot.mostCriticalService {
                Spacer()

                HStack(spacing: 5) {
                    Image(systemName: item.iconName)
                        .font(.system(size: 13, weight: .medium))
                        .foregroundStyle(statusColor(for: item.remainingPercent))
                    Text(item.shortName)
                        .font(.system(size: 13, weight: .bold))
                        .lineLimit(1)
                }

                HStack(alignment: .lastTextBaseline, spacing: 2) {
                    Text("\(item.remainingPercent)%")
                        .font(.system(size: 28, weight: .bold, design: .rounded).monospacedDigit())
                        .foregroundStyle(statusColor(for: item.remainingPercent))
                    Text("残")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(.secondary)
                }

                // Progress Bar
                GeometryReader { geo in
                    ZStack(alignment: .leading) {
                        Capsule()
                            .fill(Color.primary.opacity(0.12))
                            .frame(height: 5)
                        Capsule()
                            .fill(statusColor(for: item.remainingPercent))
                            .frame(width: max(3, geo.size.width * CGFloat(item.remainingRatio)), height: 5)
                    }
                }
                .frame(height: 5)

                HStack {
                    Text("\(item.usedDisplay)/\(item.limitDisplay)")
                        .font(.system(size: 9.5).monospacedDigit())
                        .foregroundStyle(.secondary)
                    Spacer()
                    if let reset = item.resetText {
                        Text(reset)
                            .font(.system(size: 9.5, weight: .medium))
                            .foregroundStyle(.tertiary)
                    }
                }

                Spacer()
            } else {
                Spacer()
                VStack(spacing: 4) {
                    Image(systemName: "checkmark.circle.fill")
                        .font(.system(size: 20))
                        .foregroundStyle(.green)
                    Text("待機中")
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity)
                Spacer()
            }
        }
        .padding(12)
        .containerBackground(for: .widget) {
            Color.clear
        }
    }

    private func statusColor(for remainingPct: Int) -> Color {
        if remainingPct <= 15 {
            return .red
        } else if remainingPct <= 35 {
            return .orange
        } else if remainingPct <= 60 {
            return .yellow
        } else {
            return .green
        }
    }
}

// MARK: - Medium Widget View (主要3サービス一覧)
struct MediumWidgetView: View {
    let snapshot: AIMeterWidgetSnapshot

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            // Header
            HStack {
                Label("AI Meter", systemImage: "speedometer")
                    .font(.system(size: 11.5, weight: .bold))
                    .foregroundStyle(.primary)

                Spacer()

                if snapshot.totalCostUSD > 0 {
                    Text(String(format: "API換算: $%.2f", snapshot.totalCostUSD))
                        .font(.system(size: 10.5, weight: .semibold).monospacedDigit())
                        .foregroundStyle(.secondary)
                }

                Text(Self.timeFormatter.string(from: snapshot.updatedAt))
                    .font(.system(size: 9.5).monospacedDigit())
                    .foregroundStyle(.tertiary)
            }

            Divider()

            // Service Bars
            if snapshot.topServices.isEmpty {
                Spacer()
                Text("利用可能なデータがありません")
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity)
                Spacer()
            } else {
                VStack(spacing: 7) {
                    ForEach(snapshot.topServices) { item in
                        HStack(spacing: 8) {
                            HStack(spacing: 4) {
                                Image(systemName: item.iconName)
                                    .font(.system(size: 11))
                                    .foregroundStyle(statusColor(for: item.remainingPercent))
                                    .frame(width: 14)
                                Text(item.shortName)
                                    .font(.system(size: 11, weight: .semibold))
                                    .frame(width: 44, alignment: .leading)
                            }

                            // Progress Bar
                            GeometryReader { geo in
                                ZStack(alignment: .leading) {
                                    Capsule()
                                        .fill(Color.primary.opacity(0.12))
                                        .frame(height: 6)
                                    Capsule()
                                        .fill(statusColor(for: item.remainingPercent))
                                        .frame(width: max(3, geo.size.width * CGFloat(item.remainingRatio)), height: 6)
                                }
                            }
                            .frame(height: 6)

                            // Percent & Counts
                            HStack(spacing: 4) {
                                Text("\(item.remainingPercent)%")
                                    .font(.system(size: 11, weight: .bold, design: .rounded).monospacedDigit())
                                    .foregroundStyle(statusColor(for: item.remainingPercent))
                                    .frame(width: 32, alignment: .trailing)

                                Text("(\(item.usedDisplay)/\(item.limitDisplay))")
                                    .font(.system(size: 9.5).monospacedDigit())
                                    .foregroundStyle(.secondary)
                                    .frame(width: 70, alignment: .trailing)
                            }
                        }
                    }
                }
            }
        }
        .padding(12)
        .containerBackground(for: .widget) {
            Color.clear
        }
    }

    private static let timeFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "HH:mm"
        return f
    }()

    private func statusColor(for remainingPct: Int) -> Color {
        if remainingPct <= 15 {
            return .red
        } else if remainingPct <= 35 {
            return .orange
        } else if remainingPct <= 60 {
            return .yellow
        } else {
            return .green
        }
    }
}

// MARK: - Large Widget View (全サービス詳細)
struct LargeWidgetView: View {
    let snapshot: AIMeterWidgetSnapshot

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            // Header
            HStack {
                Label("AI Meter Status", systemImage: "speedometer")
                    .font(.system(size: 12.5, weight: .bold))
                Spacer()
                if snapshot.totalCostUSD > 0 {
                    Text(String(format: "API換算合計: $%.2f", snapshot.totalCostUSD))
                        .font(.system(size: 11, weight: .semibold).monospacedDigit())
                        .foregroundStyle(.secondary)
                }
                Text("\(Self.timeFormatter.string(from: snapshot.updatedAt)) 更新")
                    .font(.system(size: 10).monospacedDigit())
                    .foregroundStyle(.tertiary)
            }

            Divider()

            // Service Grid / Rows
            if snapshot.allServices.isEmpty {
                Spacer()
                Text("監視対象のサービスが設定されていません")
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity)
                Spacer()
            } else {
                VStack(spacing: 8) {
                    ForEach(snapshot.allServices.prefix(6)) { item in
                        HStack(spacing: 8) {
                            HStack(spacing: 5) {
                                Image(systemName: item.iconName)
                                    .font(.system(size: 11.5))
                                    .foregroundStyle(statusColor(for: item.remainingPercent))
                                    .frame(width: 16)
                                Text(item.name)
                                    .font(.system(size: 11, weight: .medium))
                                    .lineLimit(1)
                                    .frame(width: 100, alignment: .leading)
                            }

                            // Progress
                            GeometryReader { geo in
                                ZStack(alignment: .leading) {
                                    Capsule()
                                        .fill(Color.primary.opacity(0.12))
                                        .frame(height: 6)
                                    Capsule()
                                        .fill(statusColor(for: item.remainingPercent))
                                        .frame(width: max(3, geo.size.width * CGFloat(item.remainingRatio)), height: 6)
                                }
                            }
                            .frame(height: 6)

                            // Status Details
                            HStack(spacing: 6) {
                                Text("\(item.remainingPercent)%")
                                    .font(.system(size: 11.5, weight: .bold, design: .rounded).monospacedDigit())
                                    .foregroundStyle(statusColor(for: item.remainingPercent))
                                    .frame(width: 34, alignment: .trailing)

                                Text("\(item.usedDisplay)/\(item.limitDisplay) \(item.unit)")
                                    .font(.system(size: 9.5).monospacedDigit())
                                    .foregroundStyle(.secondary)
                                    .frame(width: 85, alignment: .trailing)

                                if let reset = item.resetText {
                                    Text(reset)
                                        .font(.system(size: 9.5))
                                        .foregroundStyle(.tertiary)
                                        .frame(width: 60, alignment: .trailing)
                                }
                            }
                        }
                    }
                }
            }

            Spacer()
        }
        .padding(14)
        .containerBackground(for: .widget) {
            Color.clear
        }
    }

    private static let timeFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "HH:mm"
        return f
    }()

    private func statusColor(for remainingPct: Int) -> Color {
        if remainingPct <= 15 {
            return .red
        } else if remainingPct <= 35 {
            return .orange
        } else if remainingPct <= 60 {
            return .yellow
        } else {
            return .green
        }
    }
}

// MARK: - Entry View Router
struct AIMeterWidgetEntryView: View {
    @Environment(\.widgetFamily) var family
    let entry: AIMeterWidgetEntry

    var body: some View {
        switch family {
        case .systemSmall:
            SmallWidgetView(snapshot: entry.snapshot)
        case .systemMedium:
            MediumWidgetView(snapshot: entry.snapshot)
        case .systemLarge, .systemExtraLarge:
            LargeWidgetView(snapshot: entry.snapshot)
        default:
            SmallWidgetView(snapshot: entry.snapshot)
        }
    }
}

// MARK: - Main Widget Definition
@main
struct AIMeterWidget: Widget {
    let kind: String = "com.local.AIMeter.widget"

    var body: some WidgetConfiguration {
        StaticConfiguration(kind: kind, provider: AIMeterTimelineProvider()) { entry in
            AIMeterWidgetEntryView(entry: entry)
        }
        .configurationDisplayName("AI Meter")
        .description("AIツールの残り枠・トークン使用量をデスクトップに表示します。")
        .supportedFamilies([.systemSmall, .systemMedium, .systemLarge])
    }
}
