import SwiftUI

@main
struct PulseIslandApp: App {
    var body: some Scene {
        WindowGroup {
            RootView()
                .preferredColorScheme(.dark)
        }
    }
}

struct RootView: View {
    @State private var model = AppModel.shared
    @Environment(\.scenePhase) private var scenePhase

    var body: some View {
        Group {
            if model.isPaired {
                HomeView(model: model)
            } else {
                PairingView(model: model)
            }
        }
        .onChange(of: scenePhase, initial: true) { _, phase in
            if phase == .active { model.start() }
        }
    }
}

/// 背景。ガラスの屈折が分かるように、AI の色をぼかして置く
struct Backdrop: View {
    var tint: Color = Provider.claude.color

    var body: some View {
        ZStack {
            LinearGradient(
                colors: [Color(red: 0.07, green: 0.06, blue: 0.12), Color(red: 0.12, green: 0.07, blue: 0.11)],
                startPoint: .top,
                endPoint: .bottom
            )
            Circle()
                .fill(tint.opacity(0.55))
                .frame(width: 320, height: 320)
                .blur(radius: 90)
                .offset(x: -110, y: -260)
            Circle()
                .fill(Color.indigo.opacity(0.5))
                .frame(width: 280, height: 280)
                .blur(radius: 90)
                .offset(x: 140, y: 240)
        }
        .animation(.easeInOut(duration: 0.8), value: tint)
    }
}

/// アプリの画面では、時計で 1 秒ごとにコマを進めて動かす
struct LiveCharacter: View {
    let provider: Provider
    let activity: ActivityKind
    let status: SessionStatus
    var height: CGFloat = 48

    var body: some View {
        TimelineView(.periodic(from: .now, by: 1)) { context in
            CharacterView(
                provider: provider,
                activity: activity,
                status: status,
                tick: Int(context.date.timeIntervalSinceReferenceDate),
                height: height
            )
        }
    }
}
