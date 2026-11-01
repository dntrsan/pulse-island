import ActivityKit
import AppIntents
import SwiftUI
import WidgetKit

/// Dynamic Island とロック画面
///  - 左：AI ごとのキャラ。作業の種類に合わせて動く（Claude はドット絵の子）
///  - 右：作業中はこのターンの経過時間、返事待ちは「返答」、終わったら ✓
///  - 長押し：タイトル、いまやっていること（または質問）、リミット
struct IslandLiveActivity: Widget {
    var body: some WidgetConfiguration {
        ActivityConfiguration(for: IslandAttributes.self) { context in
            LockScreenIsland(state: context.state, anchor: context.attributes.startedAt)
                .activityBackgroundTint(Color.black.opacity(0.6))
                .activitySystemActionForegroundColor(.white)
        } dynamicIsland: { context in
            DynamicIsland {
                DynamicIslandExpandedRegion(.leading) {
                    IslandCharacter(state: context.state, anchor: context.attributes.startedAt, height: 30)
                        .padding(.leading, 6)
                        .padding(.top, 4)
                }
                DynamicIslandExpandedRegion(.trailing) {
                    TrailingStatus(state: context.state, large: true)
                        .padding(.trailing, 6)
                        .padding(.top, 4)
                }
                DynamicIslandExpandedRegion(.center) {
                    VStack(spacing: 1) {
                        Text(headline(context.state))
                            .font(.caption2.weight(.semibold))
                            .foregroundStyle(context.state.status.color)
                        Text(context.state.title)
                            .font(.subheadline.weight(.semibold))
                            .lineLimit(1)
                    }
                }
                DynamicIslandExpandedRegion(.bottom) {
                    IslandDetail(state: context.state)
                        .padding(.horizontal, 6)
                }
            } compactLeading: {
                IslandCharacter(state: context.state, anchor: context.attributes.startedAt, height: 18)
                    .padding(.leading, 2)
            } compactTrailing: {
                TrailingStatus(state: context.state, large: false)
            } minimal: {
                IslandCharacter(state: context.state, anchor: context.attributes.startedAt, height: 12)
            }
            .keylineTint(context.state.status.needsYou ? .orange : context.state.provider.color)
        }
    }
}

/// アイランドとロック画面のキャラ。作業中と返事待ちは iOS の時計で動かし（FrameCharacter）、
/// ほかの状態や、設定で動かさないときは止まった絵にする
struct IslandCharacter: View {
    let state: IslandAttributes.ContentState
    let anchor: Date
    let height: CGFloat

    var body: some View {
        if state.animate != false, FrameCharacter.animates(state.status) {
            FrameCharacter(provider: state.provider, activity: state.activity, status: state.status, anchor: anchor, height: height)
        } else {
            CharacterView(provider: state.provider, activity: state.activity, status: state.status, tick: 0, height: height)
        }
    }
}

private func headline(_ s: IslandAttributes.ContentState) -> String {
    let label = s.status.needsYou || !s.status.isBusy ? s.status.label : s.activity.label
    return s.focusedOther ? "\(s.provider.name) · \(label)（別のセッション）" : "\(s.provider.name) · \(label)"
}

/// 右側：経過時間・返答待ち・完了
struct TrailingStatus: View {
    let state: IslandAttributes.ContentState
    let large: Bool

    var body: some View {
        Group {
            if state.status.needsYou {
                Text(large ? "返答待ち" : "返答")
                    .foregroundStyle(.orange)
            } else if state.status.isBusy, let since = state.since {
                Text(timerInterval: since...Date.distantFuture, countsDown: false)
                    .monospacedDigit()
                    .multilineTextAlignment(.trailing)
                    .foregroundStyle(state.status == .stalled ? .yellow : .white)
            } else if state.status == .done {
                Image(systemName: "checkmark.circle.fill")
                    .foregroundStyle(.mint)
            } else if state.status == .offline {
                Image(systemName: "wifi.slash")
                    .foregroundStyle(.red)
            } else {
                Text("待機")
                    .foregroundStyle(.white.opacity(0.6))
            }
        }
        .font(large ? .headline : .caption.weight(.semibold))
        .frame(maxWidth: large ? 90 : 46, alignment: .trailing)
    }
}

/// 長押ししたときの下半分とロック画面で共通の中身
struct IslandDetail: View {
    let state: IslandAttributes.ContentState

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if let ask = state.ask {
                HStack(alignment: .top, spacing: 8) {
                    Image(systemName: "hand.raised.fill")
                        .foregroundStyle(.orange)
                    Text(ask)
                        .font(.footnote)
                        .lineLimit(3)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .padding(10)
                .background(Color.orange.opacity(0.2), in: .rect(cornerRadius: 12))
            } else if !state.detail.isEmpty {
                HStack(spacing: 6) {
                    Image(systemName: state.activity.symbol)
                        .foregroundStyle(state.provider.color)
                    Text(state.detail)
                        .lineLimit(1)
                }
                .font(.caption)
                .foregroundStyle(.white.opacity(0.85))
            }

            if let plan = state.plan, plan.total > 0 {
                HStack(spacing: 6) {
                    Text("タスク \(plan.done)/\(plan.total)")
                        .font(.caption2.weight(.semibold))
                        .monospacedDigit()
                    ProgressView(value: Double(plan.done), total: Double(plan.total))
                        .tint(state.provider.color)
                }
                .foregroundStyle(.white.opacity(0.85))
            }

            HStack(spacing: 12) {
                LimitBar(label: "5時間", pct: state.fiveHour, tint: state.provider.color, estimate: state.limitIsEstimate)
                LimitBar(label: "週", pct: state.week, tint: state.provider.color, estimate: state.limitIsEstimate)
            }

            if state.othersWaiting > 0 {
                Text("ほかに返事待ちが \(state.othersWaiting) 件あります")
                    .font(.caption2)
                    .foregroundStyle(.orange)
            }
        }
    }
}

struct LockScreenIsland: View {
    let state: IslandAttributes.ContentState
    let anchor: Date

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .center, spacing: 12) {
                IslandCharacter(state: state, anchor: anchor, height: 34)
                    .frame(minWidth: 40)
                VStack(alignment: .leading, spacing: 2) {
                    Text(headline(state))
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(state.status.color)
                    Text(state.title)
                        .font(.headline)
                        .foregroundStyle(.white)
                        .lineLimit(1)
                }
                Spacer(minLength: 4)
                TrailingStatus(state: state, large: true)
            }
            IslandDetail(state: state)
        }
        .padding(14)
    }
}
