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

// MARK: - Widget Liquid Glass Progress Bar (macOS Default Widget Harmony)
private struct WidgetLiquidProgressBar: View {
    let ratio: Double
    let color: Color
    var height: CGFloat = 5.5
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        let clamped = min(max(ratio, 0.0), 1.0)
        GeometryReader { geo in
            let w = max(height, geo.size.width * CGFloat(clamped))
            ZStack(alignment: .leading) {
                Capsule(style: .continuous)
                    .fill(Color.primary.opacity(0.10))

                ZStack(alignment: .top) {
                    Capsule(style: .continuous)
                        .fill(color)

                    Capsule(style: .continuous)
                        .fill(
                            LinearGradient(
                                colors: [Color.white.opacity(colorScheme == .dark ? 0.25 : 0.35), Color.clear],
                                startPoint: .top,
                                endPoint: .bottom
                            )
                        )
                        .frame(height: height * 0.5)
                }
                .frame(width: min(geo.size.width, w), height: height)
            }
        }
        .frame(height: height)
    }
}

private func widgetStatusColor(for remainingPct: Int) -> Color {
    if remainingPct <= 15 {
        return .red
    } else if remainingPct <= 35 {
        return .orange
    } else {
        return Color.primary.opacity(0.72)
    }
}

private func widgetPercentColor(for remainingPct: Int) -> Color {
    if remainingPct <= 15 {
        return .red
    } else if remainingPct <= 35 {
        return .orange
    } else {
        return .primary
    }
}

// MARK: - Small Widget View (最逼迫サービス)
struct SmallWidgetView: View {
    let snapshot: AIMeterWidgetSnapshot

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text("AIMeter")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                Spacer()
                if snapshot.totalCostUSD > 0 {
                    Text(String(format: "$%.1f", snapshot.totalCostUSD))
                        .font(.caption2.weight(.medium).monospacedDigit())
                        .foregroundStyle(.secondary)
                }
            }

            if let item = snapshot.mostCriticalService {
                Spacer()

                HStack(spacing: 5) {
                    Image(systemName: item.iconName)
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(.secondary)
                    Text(item.shortName)
                        .font(.subheadline.weight(.semibold))
                        .lineLimit(1)
                }

                HStack(alignment: .lastTextBaseline, spacing: 2) {
                    Text("\(item.remainingPercent)%")
                        .font(.system(size: 28, weight: .semibold).monospacedDigit())
                        .foregroundStyle(widgetPercentColor(for: item.remainingPercent))
                    Text("残")
                        .font(.caption.weight(.medium))
                        .foregroundStyle(.secondary)
                }

                WidgetLiquidProgressBar(
                    ratio: item.remainingRatio,
                    color: widgetStatusColor(for: item.remainingPercent),
                    height: 5.5
                )

                HStack {
                    Text("\(item.usedDisplay)/\(item.limitDisplay)")
                        .font(.caption2.monospacedDigit())
                        .foregroundStyle(.secondary)
                    Spacer()
                    if let reset = item.resetText {
                        Text(reset)
                            .font(.caption2)
                            .foregroundStyle(.tertiary)
                    }
                }

                Spacer()
            } else {
                Spacer()
                VStack(spacing: 4) {
                    Image(systemName: "checkmark.circle.fill")
                        .font(.system(size: 20))
                        .foregroundStyle(.secondary)
                    Text("待機中")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity)
                Spacer()
            }
        }
        .padding(12)
        .containerBackground(.ultraThinMaterial, for: .widget)
    }
}

// MARK: - Medium Widget View (主要3サービス一覧)
struct MediumWidgetView: View {
    let snapshot: AIMeterWidgetSnapshot

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            // Header
            HStack {
                Label("AIMeter", systemImage: "gauge.with.needle")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.primary)

                Spacer()

                if snapshot.totalCostUSD > 0 {
                    Text(String(format: "API換算 $%.2f", snapshot.totalCostUSD))
                        .font(.caption2.weight(.medium).monospacedDigit())
                        .foregroundStyle(.secondary)
                }

                Text(Self.timeFormatter.string(from: snapshot.updatedAt))
                    .font(.caption2.monospacedDigit())
                    .foregroundStyle(.tertiary)
            }

            Divider()
                .opacity(0.35)

            // Service Bars
            if snapshot.topServices.isEmpty {
                Spacer()
                Text("利用可能なデータがありません")
                    .font(.caption)
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
                                    .foregroundStyle(.secondary)
                                    .frame(width: 14)
                                Text(item.shortName)
                                    .font(.caption.weight(.semibold))
                                    .frame(width: 44, alignment: .leading)
                            }

                            WidgetLiquidProgressBar(
                                ratio: item.remainingRatio,
                                color: widgetStatusColor(for: item.remainingPercent),
                                height: 5.5
                            )

                            // Percent & Counts
                            HStack(spacing: 4) {
                                Text("\(item.remainingPercent)%")
                                    .font(.caption.weight(.semibold).monospacedDigit())
                                    .foregroundStyle(widgetPercentColor(for: item.remainingPercent))
                                    .frame(width: 32, alignment: .trailing)

                                Text("(\(item.usedDisplay)/\(item.limitDisplay))")
                                    .font(.caption2.monospacedDigit())
                                    .foregroundStyle(.secondary)
                                    .frame(width: 70, alignment: .trailing)
                            }
                        }
                    }
                }
            }
        }
        .padding(12)
        .containerBackground(.ultraThinMaterial, for: .widget)
    }

    private static let timeFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "HH:mm"
        return f
    }()
}

// MARK: - Large Widget View (全サービス詳細)
struct LargeWidgetView: View {
    let snapshot: AIMeterWidgetSnapshot

    var body: some View {
        VStack(alignment: .leading, spacing: 9) {
            // Header
            HStack {
                Label("AIMeter", systemImage: "gauge.with.needle")
                    .font(.subheadline.weight(.semibold))
                Spacer()
                if snapshot.totalCostUSD > 0 {
                    Text(String(format: "API換算 $%.2f", snapshot.totalCostUSD))
                        .font(.caption.weight(.medium).monospacedDigit())
                        .foregroundStyle(.secondary)
                }
                Text("\(Self.timeFormatter.string(from: snapshot.updatedAt)) 更新")
                    .font(.caption2.monospacedDigit())
                    .foregroundStyle(.tertiary)
            }

            Divider()
                .opacity(0.35)

            // Service Grid / Rows
            if snapshot.allServices.isEmpty {
                Spacer()
                Text("監視対象のサービスが設定されていません")
                    .font(.caption)
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
                                    .foregroundStyle(.secondary)
                                    .frame(width: 16)
                                Text(item.name)
                                    .font(.caption.weight(.medium))
                                    .lineLimit(1)
                                    .frame(width: 100, alignment: .leading)
                            }

                            WidgetLiquidProgressBar(
                                ratio: item.remainingRatio,
                                color: widgetStatusColor(for: item.remainingPercent),
                                height: 5.5
                            )

                            // Status Details
                            HStack(spacing: 6) {
                                Text("\(item.remainingPercent)%")
                                    .font(.caption.weight(.semibold).monospacedDigit())
                                    .foregroundStyle(widgetPercentColor(for: item.remainingPercent))
                                    .frame(width: 34, alignment: .trailing)

                                Text("\(item.usedDisplay)/\(item.limitDisplay) \(item.unit)")
                                    .font(.caption2.monospacedDigit())
                                    .foregroundStyle(.secondary)
                                    .frame(width: 85, alignment: .trailing)

                                if let reset = item.resetText {
                                    Text(reset)
                                        .font(.caption2)
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
        .containerBackground(.ultraThinMaterial, for: .widget)
    }

    private static let timeFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "HH:mm"
        return f
    }()
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
