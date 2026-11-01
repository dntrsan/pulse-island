import SwiftUI

/// PC の Claude Pulse とつなぐ画面
struct PairingView: View {
    @Bindable var model: AppModel
    @State private var url = ""
    @State private var code = ""
    @State private var busy = false
    @State private var message: String?

    var body: some View {
        ZStack {
            Backdrop().ignoresSafeArea()
            ScrollView {
                VStack(spacing: 22) {
                    LiveCharacter(provider: .claude, activity: .think, status: .working, height: 64)
                        .padding(.top, 40)

                    Text("Pulse Island")
                        .font(.largeTitle.bold())

                    Text("PC の Claude Pulse とつなぎます。\nPC の Pulse で「端末を追加」を押し、\n出てきた 6 桁のコードを入れてください。")
                        .font(.callout)
                        .multilineTextAlignment(.center)
                        .foregroundStyle(.white.opacity(0.8))

                    VStack(spacing: 12) {
                        TextField("Pulse の URL（https://〜.ts.net）", text: $url)
                            .textInputAutocapitalization(.never)
                            .autocorrectionDisabled()
                            .keyboardType(.URL)
                            .padding(14)
                            .glassEffect(.regular, in: .rect(cornerRadius: 16))
                        TextField("6 桁のコード", text: $code)
                            .keyboardType(.numberPad)
                            .font(.title3.monospacedDigit())
                            .padding(14)
                            .glassEffect(.regular, in: .rect(cornerRadius: 16))
                    }

                    if let message {
                        Text(message)
                            .font(.footnote)
                            .foregroundStyle(.orange)
                            .multilineTextAlignment(.center)
                    }

                    Button {
                        Task { await pair() }
                    } label: {
                        Text(busy ? "つないでいます…" : "つなぐ")
                            .font(.headline)
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.glassProminent)
                    .controlSize(.large)
                    .disabled(busy || url.isEmpty || code.filter(\.isNumber).count < 6)

                    Text("iPhone の Tailscale をオンにしておいてください。")
                        .font(.caption)
                        .foregroundStyle(.white.opacity(0.6))
                }
                .padding(24)
            }
        }
        .onAppear {
            if url.isEmpty { url = model.baseURLText }
            message = model.lastError
        }
    }

    private func pair() async {
        busy = true
        defer { busy = false }
        do {
            try await model.pair(urlText: url, code: code)
        } catch {
            message = error.localizedDescription
        }
    }
}
