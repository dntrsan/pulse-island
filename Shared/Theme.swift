import SwiftUI

extension Provider {
    /// それぞれの AI の色
    var color: Color {
        switch self {
        case .claude: Color(red: 0.85, green: 0.47, blue: 0.34)
        case .codex: Color(red: 0.86, green: 0.88, blue: 0.92)
        case .antigravity: Color(red: 0.30, green: 0.56, blue: 0.98)
        }
    }
}

extension SessionStatus {
    var color: Color {
        switch self {
        case .working: .green
        case .waiting, .reply: .orange
        case .stalled: .yellow
        case .done: .mint
        case .idle, .none: .gray
        case .offline: .red
        }
    }
}

/// リミットの細い棒（ライブアクティビティ・ウィジェット・アプリで共通）
struct LimitBar: View {
    let label: String
    let pct: Double?
    var tint: Color = .orange
    var estimate = false

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(spacing: 4) {
                Text(label)
                Spacer(minLength: 2)
                Text(pct.map { "\(Int($0.rounded()))%" } ?? "—")
                    .monospacedDigit()
                if estimate {
                    Text("目安")
                        .font(.system(size: 8, weight: .bold))
                        .padding(.horizontal, 3)
                        .background(.white.opacity(0.18), in: .capsule)
                }
            }
            .font(.caption2.weight(.semibold))
            .foregroundStyle(.white.opacity(0.85))
            ProgressView(value: min(1, max(0, (pct ?? 0) / 100)))
                .tint(barColor)
        }
    }

    private var barColor: Color {
        guard let pct else { return .gray }
        if pct >= 90 { return .red }
        if pct >= 70 { return .orange }
        return tint
    }
}
