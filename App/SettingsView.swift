import SwiftUI

struct SettingsView: View {
    @Bindable var model: AppModel
    @Environment(\.dismiss) private var dismiss
    @State private var confirmUnpair = false

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Toggle("裏で常駐する", isOn: $model.keepAlive)
                } footer: {
                    Text("無音の音声を流し続けて、アプリを閉じてもアイランドを書き換えられるようにします。電池を少し使います。アプリを上にスワイプして消すと止まります。")
                }

                Section {
                    Toggle("キャラを動かす", isOn: $model.animate)
                } header: {
                    Text("アイランドのキャラ")
                } footer: {
                    Text("iOS が毎秒進める時計の表示に、コマを描いたフォントを使って動かします。アプリが眠っていても動き、アイランドの書き換えの回数も使いません。キャラの代わりに数字が出るなど崩れて見えるときは、オフにしてください。")
                }

                Section("アイランドを大きくして知らせる") {
                    Toggle("急がない質問でも知らせる", isOn: $model.alertReplies)
                    Toggle("作業が終わったときも知らせる", isOn: $model.alertDone)
                }

                Section {
                    LabeledContent("常駐用の音声", value: model.keepAlive ? (model.audioPlaying ? "流れている" : "止まっている") : "オフ")
                    LabeledContent("最後に受け取った", value: model.lastReceived.map { AppModel.stamp($0) } ?? "—")
                    LabeledContent("アイランドの書き換え", value: "\(model.sentCount) 回" + (model.lastSentAt.map { "（最後 \(AppModel.stamp($0))）" } ?? ""))
                    ForEach(Array(model.diary.prefix(50).enumerated()), id: \.offset) { _, line in
                        Text(line)
                            .font(.caption.monospacedDigit())
                            .foregroundStyle(.secondary)
                    }
                    if !model.diary.isEmpty {
                        Button("記録を消す") { model.clearDiary() }
                    }
                } header: {
                    Text("記録")
                } footer: {
                    Text("アイランドが止まったときは、ここを見ると何が起きていたかが分かります（新しい順）。書き換えの回数は、このアプリを起動してからのものです。")
                }

                Section {
                    LabeledContent("Pulse", value: model.baseURLText)
                    LabeledContent("状態", value: connectionText)
                    Button("ペアリングを外す", role: .destructive) {
                        confirmUnpair = true
                    }
                } header: {
                    Text("接続")
                } footer: {
                    Text("この iPhone の鍵を消します。PC 側の登録は Pulse の画面の「端末」から解除してください。")
                }
            }
            .navigationTitle("設定")
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("閉じる") { dismiss() }
                }
            }
            .confirmationDialog("ペアリングを外しますか？", isPresented: $confirmUnpair, titleVisibility: .visible) {
                Button("外す", role: .destructive) {
                    model.unpair()
                    dismiss()
                }
            }
        }
    }

    private var connectionText: String {
        switch model.connection {
        case .online: "接続中"
        case .connecting: "つないでいます"
        case .offline(let message): message
        case .unpaired: "未登録"
        }
    }
}
