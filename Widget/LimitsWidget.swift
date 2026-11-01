import AppIntents
import SwiftUI
import WidgetKit

// ホーム画面とロック画面の、リミットのウィジェット。
// 無料の Apple ID ではアプリとウィジェットでデータを共有できない（App Groups が使えない）ので、
// ウィジェットは自分で Pulse に聞きに行く。最初の 1 回だけ、設定に URL と 6 桁のコードを入れて登録する。

struct LimitsConfig: WidgetConfigurationIntent {
    static var title: LocalizedStringResource = "Pulse とつなぐ"
    static var description = IntentDescription("Pulse の URL と、PC の Pulse で出した 6 桁のコードを入れてください（最初の 1 回だけ）。")

    @Parameter(title: "Pulse の URL")
    var url: String?

    @Parameter(title: "ペアリングコード")
    var code: String?

    init() {}
}

struct LimitsEntry: TimelineEntry {
    struct Row: Hashable {
        let provider: Provider
        let fiveHour: Double?
        let week: Double?
        let estimate: Bool
        let busy: Int
        let waiting: Int
    }

    let date: Date
    let rows: [Row]
    let message: String?

    static let sample = LimitsEntry(date: .now, rows: [
        Row(provider: .claude, fiveHour: 32, week: 18, estimate: false, busy: 1, waiting: 0),
        Row(provider: .codex, fiveHour: 8, week: 14, estimate: false, busy: 0, waiting: 0),
        Row(provider: .antigravity, fiveHour: nil, week: nil, estimate: false, busy: 0, waiting: 0),
    ], message: nil)

    static func note(_ text: String) -> LimitsEntry {
        LimitsEntry(date: .now, rows: [], message: text)
    }
}

struct LimitsProvider: AppIntentTimelineProvider {
    func placeholder(in context: Context) -> LimitsEntry { .sample }

    func snapshot(for configuration: LimitsConfig, in context: Context) async -> LimitsEntry {
        context.isPreview ? .sample : await load(configuration)
    }

    func timeline(for configuration: LimitsConfig, in context: Context) async -> Timeline<LimitsEntry> {
        Timeline(entries: [await load(configuration)], policy: .after(.now.addingTimeInterval(15 * 60)))
    }

    private func load(_ config: LimitsConfig) async -> LimitsEntry {
        guard let base = PulseClient.normalize(config.url) else {
            return .note("長押しして「ウィジェットを編集」から、Pulse の URL とコードを入れてください")
        }
        let key = "widget-token|\(base.absoluteString)"
        var token = Keychain.get(key)
        if token == nil, let code = config.code?.filter(\.isNumber), code.count == 6 {
            token = try? await PulseClient.pair(base: base, code: code, name: "iPhone（ウィジェット）")
            if let token { Keychain.set(token, for: key) }
        }
        guard let token else {
            return .note("PC の Pulse で 6 桁のコードを出して、ウィジェットの設定に入れてください")
        }
        do {
            let snap = try await PulseClient(base: base, token: token).island(wait: nil)
            return LimitsEntry(date: .now, rows: Provider.allCases.map { p in
                let d = snap.data(p)
                let sessions = d?.sessions ?? []
                return .init(
                    provider: p,
                    fiveHour: d?.limits?.fiveHour?.pct,
                    week: d?.limits?.week?.pct,
                    estimate: d?.limits?.isEstimate ?? false,
                    busy: sessions.filter { $0.status.isBusy }.count,
                    waiting: sessions.filter { $0.status.needsYou }.count
                )
            }, message: nil)
        } catch PulseError.unauthorized {
            Keychain.set(nil, for: key)
            return .note("登録が外れました。新しいコードをウィジェットの設定に入れてください")
        } catch {
            return .note("Pulse につながりません（Tailscale はオンですか？）")
        }
    }
}

struct LimitsWidget: Widget {
    var body: some WidgetConfiguration {
        AppIntentConfiguration(kind: "Limits", intent: LimitsConfig.self, provider: LimitsProvider()) { entry in
            LimitsWidgetView(entry: entry)
        }
        .configurationDisplayName("AI のリミット")
        .description("Claude・Codex・Antigravity の 5 時間枠と週枠")
        .supportedFamilies([.systemSmall, .systemMedium, .accessoryRectangular, .accessoryCircular])
    }
}

struct LimitsWidgetView: View {
    let entry: LimitsEntry
    @Environment(\.widgetFamily) private var family

    var body: some View {
        Group {
            if let message = entry.message {
                Text(message)
                    .font(.caption)
                    .foregroundStyle(.white.opacity(0.85))
            } else {
                switch family {
                case .accessoryCircular: circular
                case .accessoryRectangular: rectangular
                case .systemSmall: small
                default: medium
                }
            }
        }
        .containerBackground(for: .widget) {
            LinearGradient(
                colors: [Color(red: 0.10, green: 0.08, blue: 0.16), Color(red: 0.17, green: 0.09, blue: 0.12)],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )
        }
    }

    private func row(_ p: Provider) -> LimitsEntry.Row? {
        entry.rows.first { $0.provider == p }
    }

    private var circular: some View {
        let claude = row(.claude)
        return Gauge(value: min(100, claude?.fiveHour ?? 0), in: 0...100) {
            Text("5h")
        } currentValueLabel: {
            Text(claude?.fiveHour.map { "\(Int($0.rounded()))" } ?? "—")
        }
        .gaugeStyle(.accessoryCircularCapacity)
        .widgetAccentable()
    }

    private var rectangular: some View {
        VStack(alignment: .leading, spacing: 2) {
            ForEach([Provider.claude, .codex], id: \.self) { p in
                let r = row(p)
                Text("\(p.name)  5h \(pct(r?.fiveHour))  週 \(pct(r?.week))")
                    .font(.caption.monospacedDigit())
                    .lineLimit(1)
            }
            if waitingTotal > 0 {
                Text("返事待ち \(waitingTotal) 件")
                    .font(.caption2.weight(.bold))
                    .widgetAccentable()
            }
        }
    }

    private var waitingTotal: Int {
        entry.rows.reduce(0) { $0 + $1.waiting }
    }

    private var small: some View {
        VStack(alignment: .leading, spacing: 10) {
            ForEach([Provider.claude, .codex], id: \.self) { p in
                providerBlock(p, compact: true)
            }
        }
    }

    private var medium: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("AI のリミット")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.white.opacity(0.7))
                Spacer()
                Button(intent: ShowIslandIntent()) {
                    Label("アイランド", systemImage: "capsule.portrait")
                        .font(.caption2.weight(.semibold))
                }
                .buttonStyle(.plain)
                .foregroundStyle(.orange)
            }
            HStack(alignment: .top, spacing: 14) {
                ForEach(Provider.allCases) { p in
                    providerBlock(p, compact: false)
                }
            }
        }
    }

    private func providerBlock(_ p: Provider, compact: Bool) -> some View {
        let r = row(p)
        return VStack(alignment: .leading, spacing: 5) {
            HStack(spacing: 6) {
                CharacterView(provider: p, activity: .other, status: (r?.waiting ?? 0) > 0 ? .waiting : (r?.busy ?? 0) > 0 ? .working : .idle, tick: 0, height: 14)
                Text(p.name)
                    .font(.caption.weight(.bold))
                    .lineLimit(1)
                    .minimumScaleFactor(0.7)
                if let r, r.waiting > 0 {
                    Image(systemName: "hand.raised.fill").font(.caption2).foregroundStyle(.orange)
                } else if let r, r.busy > 0 {
                    Circle().fill(.green).frame(width: 6, height: 6)
                }
            }
            .foregroundStyle(.white)
            if p == .antigravity && r?.fiveHour == nil {
                Text("リミットなし")
                    .font(.caption2)
                    .foregroundStyle(.white.opacity(0.5))
            } else {
                LimitBar(label: "5時間", pct: r?.fiveHour, tint: p.color, estimate: r?.estimate ?? false)
                LimitBar(label: "週", pct: r?.week, tint: p.color, estimate: false)
            }
        }
    }

    private func pct(_ v: Double?) -> String {
        v.map { "\(Int($0.rounded()))%" } ?? "—"
    }
}
