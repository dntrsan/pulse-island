import SwiftUI

struct HomeView: View {
    @Bindable var model: AppModel
    @State private var showSettings = false

    private var sessions: [SessionInfo] {
        model.snapshot?.data(model.provider)?.sessions ?? []
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 18) {
                    hero
                    Picker("AI", selection: $model.provider) {
                        ForEach(Provider.allCases) { Text($0.name).tag($0) }
                    }
                    .pickerStyle(.segmented)

                    LimitsCard(provider: model.provider, limits: model.snapshot?.data(model.provider)?.limits)
                    sessionList
                    islandButton
                }
                .padding(16)
            }
            .background(Backdrop(tint: model.provider.color).ignoresSafeArea())
            .navigationTitle("Pulse Island")
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    connectionBadge
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button {
                        showSettings = true
                    } label: {
                        Image(systemName: "gearshape")
                    }
                }
            }
            .sheet(isPresented: $showSettings) {
                SettingsView(model: model)
                    .presentationDetents([.medium, .large])
            }
        }
    }

    /// いまアイランドに出ているものを、大きく見せる
    private var hero: some View {
        let s = model.makeState()
        return HStack(spacing: 16) {
            LiveCharacter(provider: s.provider, activity: s.activity, status: s.status, height: 52)
                .frame(width: 76, height: 64)
            VStack(alignment: .leading, spacing: 4) {
                Text(s.focusedOther ? "\(s.provider.name) · \(s.status.label)（別のセッション）" : "\(s.provider.name) · \(s.status.label)")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(s.status.color)
                Text(s.title)
                    .font(.headline)
                    .lineLimit(2)
                if let ask = s.ask {
                    Text(ask)
                        .font(.footnote)
                        .foregroundStyle(.orange)
                        .lineLimit(3)
                } else if !s.detail.isEmpty {
                    Text(s.detail)
                        .font(.footnote)
                        .foregroundStyle(.white.opacity(0.7))
                        .lineLimit(2)
                }
            }
            Spacer(minLength: 0)
        }
        .padding(16)
        .glassEffect(.regular, in: .rect(cornerRadius: 24))
    }

    private var sessionList: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("アイランドで追うセッション")
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(.white.opacity(0.7))
                .padding(.leading, 4)

            SessionRow(title: "自動（いちばん最近動いたもの）", detail: nil, status: nil, since: nil, selected: model.pin == nil) {
                model.pin = nil
            }
            ForEach(sessions) { s in
                SessionRow(title: s.title, detail: s.detail, status: s.status, since: s.sinceDate, selected: model.pin == s.id) {
                    model.pin = s.id
                }
            }
            if sessions.isEmpty {
                Text(model.snapshot == nil ? "Pulse から読み込み中…" : "ここ 2 日の \(model.provider.name) のセッションはありません")
                    .font(.footnote)
                    .foregroundStyle(.white.opacity(0.6))
                    .padding(.leading, 4)
            }
        }
    }

    private var islandButton: some View {
        VStack(spacing: 8) {
            Button {
                if model.islandRunning {
                    model.autoIsland = false
                    Task { await model.endIsland() }
                } else {
                    model.autoIsland = true
                    model.showIsland()
                }
            } label: {
                Label(model.islandRunning ? "アイランドを閉じる" : "アイランドを出す",
                      systemImage: model.islandRunning ? "xmark.circle" : "capsule.portrait")
                    .font(.headline)
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.glassProminent)
            .controlSize(.large)

            if let error = model.lastError {
                Text(error)
                    .font(.caption)
                    .foregroundStyle(.orange)
            }
            if !model.keepAlive {
                Text("常駐がオフなので、アプリを閉じるとアイランドは止まります")
                    .font(.caption)
                    .foregroundStyle(.white.opacity(0.6))
            }
        }
    }

    private var connectionBadge: some View {
        let (text, color): (String, Color) = switch model.connection {
        case .online: ("接続中", .green)
        case .connecting: ("つないでいます", .yellow)
        case .offline: ("オフライン", .red)
        case .unpaired: ("未登録", .gray)
        }
        return HStack(spacing: 6) {
            Circle().fill(color).frame(width: 8, height: 8)
            Text(text).font(.caption.weight(.semibold))
        }
    }
}

struct SessionRow: View {
    let title: String
    let detail: String?
    let status: SessionStatus?
    let since: Date?
    let selected: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 12) {
                Circle()
                    .fill(status?.color ?? .white.opacity(0.5))
                    .frame(width: 10, height: 10)
                VStack(alignment: .leading, spacing: 2) {
                    Text(title)
                        .font(.subheadline.weight(.semibold))
                        .lineLimit(1)
                    HStack(spacing: 6) {
                        if let status { Text(status.label) }
                        if let detail, !detail.isEmpty { Text(detail).lineLimit(1) }
                    }
                    .font(.caption)
                    .foregroundStyle(.white.opacity(0.65))
                }
                Spacer(minLength: 8)
                if let since, status?.isBusy == true || status?.needsYou == true {
                    Text(since, style: .timer)
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(.white.opacity(0.7))
                }
                Image(systemName: selected ? "checkmark.circle.fill" : "circle")
                    .foregroundStyle(selected ? Color.orange : .white.opacity(0.4))
            }
            .foregroundStyle(.white)
            .padding(.horizontal, 14)
            .padding(.vertical, 12)
        }
        .buttonStyle(.plain)
        .glassEffect(.regular.interactive(), in: .rect(cornerRadius: 18))
    }
}

/// リミットの丸いメーター
struct LimitsCard: View {
    let provider: Provider
    let limits: Limits?

    var body: some View {
        HStack(spacing: 18) {
            gauge("5時間", limits?.fiveHour)
            gauge("週", limits?.week)
            VStack(alignment: .leading, spacing: 4) {
                Text(title)
                    .font(.subheadline.weight(.semibold))
                Text(note)
                    .font(.caption)
                    .foregroundStyle(.white.opacity(0.65))
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 0)
        }
        .padding(16)
        .glassEffect(.regular, in: .rect(cornerRadius: 24))
    }

    private var title: String {
        guard let limits else { return "\(provider.name) のリミット" }
        return limits.isEstimate ? "\(provider.name) のリミット（目安）" : "\(provider.name) のリミット"
    }

    private var note: String {
        guard let limits else {
            return provider == .antigravity
                ? "Antigravity のリミットは、認証用のトークンが要る API にしかないので出していません"
                : "まだ記録がありません"
        }
        if limits.isEstimate {
            return "公式の % が古いので、直近のトークン量をこれまでの最大と比べた値です"
        }
        if let reset = limits.fiveHour?.resetDate {
            return "5時間枠は \(reset.formatted(date: .omitted, time: .shortened)) にリセット"
        }
        if let at = limits.at {
            return "\(Date(timeIntervalSince1970: at / 1000).formatted(.relative(presentation: .named))) の値"
        }
        return ""
    }

    private func gauge(_ label: String, _ w: LimitWindow?) -> some View {
        VStack(spacing: 6) {
            Gauge(value: min(100, w?.pct ?? 0), in: 0...100) {
                EmptyView()
            } currentValueLabel: {
                Text(w.map { "\(Int($0.pct.rounded()))" } ?? "—")
                    .font(.system(.body, design: .rounded).weight(.bold))
            }
            .gaugeStyle(.accessoryCircularCapacity)
            .tint(color(w?.pct))
            .scaleEffect(1.15)
            Text(label)
                .font(.caption2.weight(.semibold))
                .foregroundStyle(.white.opacity(0.7))
        }
    }

    private func color(_ pct: Double?) -> Color {
        guard let pct else { return .gray }
        return pct >= 90 ? .red : pct >= 70 ? .orange : provider.color
    }
}
