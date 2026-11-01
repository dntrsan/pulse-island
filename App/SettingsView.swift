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

                Section("アイランドを大きくして知らせる") {
                    Toggle("急がない質問でも知らせる", isOn: $model.alertReplies)
                    Toggle("作業が終わったときも知らせる", isOn: $model.alertDone)
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
