import SwiftUI

// アイランドの左に出すキャラクター。
// ここにあるのは、アプリの画面（tick を時計で進める）と、アイランドの止まった絵（完了・待機など）。
// アイランドで動かすときは FrameCharacter が、同じポーズを描いたフォントで iOS の時計に進めさせる。
// ポーズを変えたら tools/make_frame_fonts.py も合わせて直し、フォントを作り直すこと。

/// Claude のキャラ（Claude Code の起動画面にいるドット絵の子）のポーズ
struct ClawdPose: Hashable {
    enum Eyes: Hashable { case center, left, right, up, squint }
    enum Arms: Hashable { case down, up, leftUp, rightUp }
    enum Legs: Hashable { case stand, stepA, stepB }
    enum Extra: Hashable { case none, dots(Int), bang, sparkle, sleep, cursor(Bool) }

    var eyes = Eyes.center
    var arms = Arms.down
    var legs = Legs.stand
    /// 何ドット浮かせるか（0〜2）
    var lift: CGFloat = 0
    var extra = Extra.none

    /// 作業の種類とコマ番号からポーズを決める
    static func make(activity: ActivityKind, status: SessionStatus, tick: Int) -> ClawdPose {
        let even = tick % 2 == 0
        if status.needsYou {
            // 返事待ち：両手を上げてぴょんぴょん
            return ClawdPose(arms: even ? .up : .down, lift: even ? 2 : 0, extra: .bang)
        }
        switch status {
        case .done: return ClawdPose(eyes: .squint, extra: .sparkle)
        case .idle, .none, .offline: return ClawdPose(eyes: .squint, extra: .sleep)
        case .stalled: return ClawdPose()
        default: break
        }
        switch activity {
        case .think: return ClawdPose(eyes: .up, lift: even ? 1 : 0, extra: .dots(tick % 3 + 1))
        case .read: return ClawdPose(eyes: even ? .left : .right)
        case .search: return ClawdPose(eyes: [Eyes.left, .up, .right][tick % 3])
        case .edit: return ClawdPose(arms: even ? .leftUp : .rightUp)
        case .shell: return ClawdPose(legs: even ? .stepA : .stepB, extra: .cursor(even))
        case .web: return ClawdPose(eyes: .up, legs: even ? .stepA : .stepB)
        case .agent: return ClawdPose(arms: even ? .up : .down, lift: even ? 1 : 0)
        case .plan: return ClawdPose(eyes: even ? .squint : .center)
        case .ask: return ClawdPose(arms: even ? .up : .down, lift: even ? 2 : 0, extra: .bang)
        case .other: return ClawdPose(lift: even ? 1 : 0)
        }
    }
}

/// ドット絵の本体。横 18 × 縦 7 マス（上の 2 マスは浮いたときと飾りのための余白）。
/// 元はターミナルのブロック文字なので、1 マスは縦長（幅 1 : 高さ 2）
struct ClawdShape: Shape {
    static let cols = 18
    static let rows = 7
    private static let top = 2

    var pose: ClawdPose

    func path(in rect: CGRect) -> Path {
        let w = min(rect.width / CGFloat(Self.cols), rect.height / CGFloat(Self.rows) / 2)
        let h = w * 2
        var path = Path()
        for (x, y) in Self.pixels(pose) {
            path.addRect(CGRect(
                x: rect.minX + CGFloat(x) * w,
                y: rect.minY + CGFloat(y + Self.top) * h,
                width: w + 0.01,
                height: h + 0.01
            ))
        }
        return path
    }

    static func pixels(_ pose: ClawdPose) -> [(Int, Int)] {
        var on = Set<Int>()
        func add(_ x: Int, _ y: Int) { on.insert(y * 100 + x) }
        func remove(_ x: Int, _ y: Int) { on.remove(y * 100 + x) }

        // 胴体（4 段）
        for y in 0...3 { for x in 3...14 { add(x, y) } }

        // 目は胴体に空けた穴
        switch pose.eyes {
        // 上を見る目を上の段に空けると耳のように見えるので、見た目は正面と同じにして、浮き沈みで表す
        case .center, .up: remove(5, 1); remove(12, 1)
        case .left: remove(4, 1); remove(11, 1)
        case .right: remove(6, 1); remove(13, 1)
        case .squint: remove(4, 1); remove(5, 1); remove(12, 1); remove(13, 1)
        }

        // 腕
        let leftDown = [(1, 2), (2, 2)], rightDown = [(15, 2), (16, 2)]
        let leftUp = [(2, 1), (1, 0)], rightUp = [(15, 1), (16, 0)]
        let arms: [(Int, Int)]
        switch pose.arms {
        case .down: arms = leftDown + rightDown
        case .up: arms = leftUp + rightUp
        case .leftUp: arms = leftUp + rightDown
        case .rightUp: arms = leftDown + rightUp
        }
        for (x, y) in arms { add(x, y) }

        // 足（左右にずらすと歩いて見える）
        let legs: [Int]
        switch pose.legs {
        case .stand: legs = [4, 6, 11, 13]
        case .stepA: legs = [3, 5, 10, 12]
        case .stepB: legs = [5, 7, 12, 14]
        }
        for x in legs { add(x, 4) }

        return on.map { ($0 % 100, $0 / 100) }
    }
}

struct ClawdView: View {
    var pose: ClawdPose
    var height: CGFloat

    /// 1 マスの高さ（幅はその半分）
    private var px: CGFloat { height / CGFloat(ClawdShape.rows) }

    var body: some View {
        ClawdShape(pose: pose)
            .fill(Provider.claude.color)
            .frame(width: CGFloat(ClawdShape.cols) * px / 2, height: height)
            .offset(y: -pose.lift * px)
            .overlay(alignment: .topTrailing) {
                extra
                    .font(.system(size: px * 3.2, weight: .heavy, design: .rounded))
                    .foregroundStyle(extraColor)
                    .offset(x: px * 0.5, y: -px * 0.6)
            }
    }

    @ViewBuilder private var extra: some View {
        switch pose.extra {
        case .none: EmptyView()
        case .dots(let n): Text(String(repeating: "·", count: n))
        case .bang: Text("!")
        case .sparkle: Image(systemName: "sparkle")
        case .sleep: Text("z")
        case .cursor(let on): Text(on ? "_" : " ").monospaced()
        }
    }

    private var extraColor: Color {
        switch pose.extra {
        case .bang: .orange
        case .sparkle: .yellow
        default: .white.opacity(0.85)
        }
    }
}

/// Codex：黒い端末の四角に、作業に合わせた記号
struct CodexGlyph: View {
    let activity: ActivityKind
    let status: SessionStatus
    let tick: Int
    let size: CGFloat

    var body: some View {
        RoundedRectangle(cornerRadius: size * 0.28)
            .fill(Color(white: 0.14))
            .overlay {
                RoundedRectangle(cornerRadius: size * 0.28)
                    .stroke(status.needsYou ? Color.orange : Provider.codex.color.opacity(0.55), lineWidth: max(1, size * 0.07))
            }
            .overlay {
                Text(mark)
                    .font(.system(size: size * 0.42, weight: .bold, design: .monospaced))
                    .foregroundStyle(status.needsYou ? Color.orange : .white)
            }
            .frame(width: size, height: size)
            .offset(y: status.isBusy && tick % 2 == 0 ? -size * 0.06 : 0)
    }

    private var mark: String {
        if status.needsYou { return "!" }
        switch status {
        case .done: return "✓"
        case .idle, .none, .offline: return "z"
        default: break
        }
        let even = tick % 2 == 0
        switch activity {
        case .think: return String(repeating: "·", count: tick % 3 + 1)
        case .edit: return even ? "+" : "−"
        case .read, .search: return even ? "◐" : "◑"
        default: return even ? ">_" : ">"
        }
    }
}

/// Antigravity：惑星のまわりを点が回る
struct AntigravityGlyph: View {
    let activity: ActivityKind
    let status: SessionStatus
    let tick: Int
    let size: CGFloat

    var body: some View {
        ZStack {
            Circle()
                .stroke(.white.opacity(0.3), lineWidth: max(1, size * 0.06))
                .frame(width: size * 0.92, height: size * 0.92)
            Circle()
                .fill(LinearGradient(colors: [Provider.antigravity.color, .cyan], startPoint: .topLeading, endPoint: .bottomTrailing))
                .frame(width: size * 0.54, height: size * 0.54)
            Circle()
                .fill(status.needsYou ? Color.orange : .white)
                .frame(width: size * 0.2, height: size * 0.2)
                .offset(x: size * 0.46)
                .rotationEffect(.degrees(status.isBusy || status.needsYou ? Double(tick) * 90 : -45))
            if status.needsYou {
                Text("!")
                    .font(.system(size: size * 0.4, weight: .heavy, design: .rounded))
                    .foregroundStyle(.white)
            }
        }
        .frame(width: size, height: size)
    }
}

/// AI ごとのキャラを出し分ける
struct CharacterView: View {
    let provider: Provider
    let activity: ActivityKind
    let status: SessionStatus
    let tick: Int
    /// 高さ（Claude は横長、ほかは正方形）
    var height: CGFloat = 16

    var body: some View {
        Group {
            switch provider {
            case .claude:
                ClawdView(pose: ClawdPose.make(activity: activity, status: status, tick: tick), height: height)
            case .codex:
                CodexGlyph(activity: activity, status: status, tick: tick, size: height)
            case .antigravity:
                AntigravityGlyph(activity: activity, status: status, tick: tick, size: height)
            }
        }
        .animation(.easeInOut(duration: 0.6), value: tick)
    }
}
