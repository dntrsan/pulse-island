import AppIntents
import Foundation

/// ウィジェットのボタンからアイランドを出し直す（8 時間で消えたときなど）。
/// LiveActivityIntent はアプリ本体のプロセスで動くので、アプリを開かずにライブアクティビティを始められる
struct ShowIslandIntent: LiveActivityIntent {
    static var title: LocalizedStringResource = "アイランドを出す"

    init() {}

    @MainActor
    func perform() async throws -> some IntentResult {
        #if MAIN_APP
        AppModel.shared.autoIsland = true
        AppModel.shared.start()
        #endif
        return .result()
    }
}
