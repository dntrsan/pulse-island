import SwiftUI

// アイランドの中でキャラを動かす仕組み。
// ライブアクティビティは、アプリが書き換えないかぎり止まっている。しかも iOS 18 からは書き換えに
// 間隔と回数の制限があり、2 秒ごとに書き換えると途中で止められる。
// ただし経過時間の表示（Text(timerInterval:)）だけは iOS 自身が毎秒書き換えるので、数字の形を
// コマにしたフォント（tools/make_frame_fonts.py で作る Fonts/PulseFrames-*.ttf）で表示して、
// 1 秒ごとにコマを進める。アプリが眠っていても動き、書き換えの回数も使わない。

/// 時計の最後の 1 桁（秒の 1 の位）を、コマのフォントで描く
struct FrameClock: View {
    /// PulseFrames- のあとの名前（ClaudeThink など）
    let font: String
    let anchor: Date
    /// フォントの大きさ（= コマの高さ）
    let size: CGFloat
    /// 1 コマの幅
    let width: CGFloat

    var body: some View {
        Text(timerInterval: anchor...Date.distantFuture, countsDown: false)
            .font(.custom("PulseFrames-\(font)", fixedSize: size))
            .lineLimit(1)
            .multilineTextAlignment(.trailing)
            // fixedSize() は付けない。時計の表示には決まった幅がないので、ライブアクティビティでは幅が NaN になり、
            // キャラごと描かれなくなる（実機で消えた。expo/expo#52176 と同じ）。
            // 幅は広めに渡して右に寄せ、右端の 1 コマだけを切り抜く。前の桁とコロンはフォントの中で幅 0 にしてあるが、
            // 効かなかったときも最後の桁が右端に来る
            .frame(width: width * 8, height: size, alignment: .trailing)
            .frame(width: width, height: size, alignment: .trailing)
            .clipped()
    }
}

/// フォントで動かすキャラ。作業中と返事待ちのときだけ使い、ほかは CharacterView の止まった絵にする
struct FrameCharacter: View {
    let provider: Provider
    let activity: ActivityKind
    let status: SessionStatus
    /// 時計の起点。同じ起点の時計を重ねると、体と飾りのコマがそろう
    let anchor: Date
    /// 高さ（Claude は横長、ほかは正方形）
    var height: CGFloat = 16

    static func animates(_ status: SessionStatus) -> Bool {
        status == .working || status.needsYou
    }

    /// Claude の 1 コマは横 22 マス（体 18 + 右の飾り 4）× 縦 7 マス、1 マスは幅 1 : 高さ 2
    static func claudeWidth(height: CGFloat) -> CGFloat { height * 22 / 14 }

    var body: some View {
        switch provider {
        case .claude: claude
        case .codex: codex
        case .antigravity: antigravity
        }
    }

    private var claude: some View {
        let (figure, accent) = claudeFonts
        let width = Self.claudeWidth(height: height)
        return ZStack {
            FrameClock(font: figure, anchor: anchor, size: height, width: width)
                .foregroundStyle(Provider.claude.color)
            if let accent {
                FrameClock(font: accent, anchor: anchor, size: height, width: width)
                    .foregroundStyle(status.needsYou || activity == .ask ? Color.orange : .white.opacity(0.85))
            }
        }
        .frame(width: width, height: height)
    }

    private var claudeFonts: (String, String?) {
        if status.needsYou { return ("ClaudeAsk", "ClaudeAskAccent") }
        switch activity {
        case .think: return ("ClaudeThink", "ClaudeThinkAccent")
        case .read: return ("ClaudeRead", nil)
        case .search: return ("ClaudeSearch", nil)
        case .edit: return ("ClaudeEdit", nil)
        case .shell: return ("ClaudeShell", "ClaudeShellAccent")
        case .web: return ("ClaudeWeb", nil)
        case .agent: return ("ClaudeAgent", nil)
        case .plan: return ("ClaudePlan", nil)
        case .ask: return ("ClaudeAsk", "ClaudeAskAccent")
        case .other: return ("ClaudeOther", nil)
        }
    }

    /// Codex：端末の四角は止まった絵で描き、中の記号だけをフォントで動かす
    private var codexFont: String {
        if status.needsYou { return "CodexAsk" }
        switch activity {
        case .think: return "CodexThink"
        case .edit: return "CodexEdit"
        case .read, .search: return "CodexRead"
        default: return "CodexShell"
        }
    }

    private var codex: some View {
        RoundedRectangle(cornerRadius: height * 0.28)
            .fill(Color(white: 0.14))
            .overlay {
                RoundedRectangle(cornerRadius: height * 0.28)
                    .stroke(status.needsYou ? Color.orange : Provider.codex.color.opacity(0.55), lineWidth: max(1, height * 0.07))
            }
            .overlay {
                FrameClock(font: codexFont, anchor: anchor, size: height, width: height)
                    .foregroundStyle(status.needsYou ? Color.orange : .white)
            }
            .frame(width: height, height: height)
    }

    /// Antigravity：惑星と軌道は止まった絵で描き、回る点だけをフォントで動かす。
    /// 軌道の半径と点の大きさは、フォントの中の値（半径 540 / 1400）に合わせる
    private var antigravity: some View {
        let orbit = height * 540 / 1400
        return ZStack {
            Circle()
                .stroke(.white.opacity(0.3), lineWidth: max(1, height * 0.06))
                .frame(width: orbit * 2, height: orbit * 2)
            Circle()
                .fill(LinearGradient(colors: [Provider.antigravity.color, .cyan], startPoint: .topLeading, endPoint: .bottomTrailing))
                .frame(width: height * 0.46, height: height * 0.46)
            FrameClock(font: "AntigravityOrbit", anchor: anchor, size: height, width: height)
                .foregroundStyle(status.needsYou ? Color.orange : .white)
            if status.needsYou {
                Text("!")
                    .font(.system(size: height * 0.36, weight: .heavy, design: .rounded))
                    .foregroundStyle(.white)
            }
        }
        .frame(width: height, height: height)
    }
}
