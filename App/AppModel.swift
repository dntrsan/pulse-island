import ActivityKit
import Foundation
import Observation
import WidgetKit

/// アプリの中心。Pulse を見に行き、選んだセッションをライブアクティビティに映す。
/// 無料の Apple ID ではプッシュ通知が使えないので、アプリを裏で動かし続けて（KeepAlive）自分で書き換える
@MainActor
@Observable
final class AppModel {
    static let shared = AppModel()

    enum Connection: Equatable {
        case unpaired, connecting, online
        case offline(String)
    }

    private enum K {
        static let url = "pulse.url"
        static let provider = "island.provider"
        static let pin = "island.pin"
        static let keepAlive = "island.keepAlive"
        static let alertReplies = "island.alertReplies"
        static let alertDone = "island.alertDone"
        static let autoIsland = "island.auto"
        static let token = "pulse-token"
    }

    // MARK: - 設定（端末に保存）

    var baseURLText: String {
        didSet { defaults.set(baseURLText, forKey: K.url) }
    }
    var provider: Provider {
        didSet {
            defaults.set(provider.rawValue, forKey: K.provider)
            if oldValue != provider { pin = nil }
            refreshIsland()
        }
    }
    /// アイランドで追うセッション。nil なら自動（その AI でいちばん最近動いたもの）
    var pin: String? {
        didSet {
            defaults.set(pin, forKey: K.pin)
            refreshIsland()
        }
    }
    /// 裏で常駐する（無音の音声を流し続ける）
    var keepAlive: Bool {
        didSet {
            defaults.set(keepAlive, forKey: K.keepAlive)
            applyKeepAlive()
        }
    }
    /// 急がない質問（次の一手の確認など）でもアイランドを大きくする
    var alertReplies: Bool {
        didSet { defaults.set(alertReplies, forKey: K.alertReplies) }
    }
    /// 作業が終わったときもアイランドを大きくする
    var alertDone: Bool {
        didSet { defaults.set(alertDone, forKey: K.alertDone) }
    }
    /// アプリを開いたら自動でアイランドを出す（閉じるボタンでオフになる）
    var autoIsland: Bool {
        didSet { defaults.set(autoIsland, forKey: K.autoIsland) }
    }

    // MARK: - 状態

    private(set) var snapshot: IslandSnapshot?
    private(set) var connection: Connection
    private(set) var tick = 0
    private(set) var islandRunning = false
    private(set) var lastError: String?

    @ObservationIgnored private var token: String?
    @ObservationIgnored private var pollTask: Task<Void, Never>?
    @ObservationIgnored private var pollGen = 0
    @ObservationIgnored private var pollRunning: Int?
    @ObservationIgnored private var animTask: Task<Void, Never>?
    @ObservationIgnored private var activity: Activity<IslandAttributes>?
    @ObservationIgnored private var lastState: IslandAttributes.ContentState?
    @ObservationIgnored private var seenAsks: Set<String>?
    @ObservationIgnored private var lastStatus: [String: SessionStatus] = [:]
    @ObservationIgnored private var lastWidgetReload = Date.distantPast
    @ObservationIgnored private var lastLimits: [Limits?] = []
    @ObservationIgnored private let audio = KeepAlive()
    @ObservationIgnored private let defaults = UserDefaults.standard

    private init() {
        let d = UserDefaults.standard
        baseURLText = d.string(forKey: K.url) ?? ""
        provider = Provider(rawValue: d.string(forKey: K.provider) ?? "") ?? .claude
        pin = d.string(forKey: K.pin)
        keepAlive = d.object(forKey: K.keepAlive) as? Bool ?? true
        alertReplies = d.object(forKey: K.alertReplies) as? Bool ?? true
        alertDone = d.object(forKey: K.alertDone) as? Bool ?? false
        autoIsland = d.object(forKey: K.autoIsland) as? Bool ?? true
        token = Keychain.get(K.token)
        connection = token == nil ? .unpaired : .connecting
        if let a = Activity<IslandAttributes>.activities.first {
            activity = a
            islandRunning = true
            watch(a)
        }
    }

    var isPaired: Bool { connection != .unpaired }

    // MARK: - ペアリング

    func pair(urlText: String, code: String) async throws {
        guard let base = PulseClient.normalize(urlText) else { throw PulseError.badURL }
        let digits = code.filter(\.isNumber)
        let token = try await PulseClient.pair(base: base, code: digits, name: "iPhone（Pulse Island）")
        Keychain.set(token, for: K.token)
        self.token = token
        baseURLText = base.absoluteString
        lastError = nil
        connection = .connecting
        start()
    }

    /// この iPhone の鍵を消す（PC 側の登録は Pulse の画面で解除する）
    func unpair() {
        pollTask?.cancel()
        pollTask = nil
        pollRunning = nil
        audio.stop()
        Keychain.set(nil, for: K.token)
        token = nil
        snapshot = nil
        seenAsks = nil
        connection = .unpaired
        Task { await endIsland() }
    }

    // MARK: - 動かす

    /// 起動したとき・アプリが前に出たときに呼ぶ
    func start() {
        guard token != nil else { return }
        applyKeepAlive()
        if pollRunning == nil { startPolling() }
        if animTask == nil {
            animTask = Task { [weak self] in await self?.animLoop() }
        }
        if autoIsland { showIsland() }
    }

    private func applyKeepAlive() {
        if keepAlive && token != nil { audio.start() } else { audio.stop() }
    }

    private func startPolling() {
        pollGen += 1
        let gen = pollGen
        pollTask?.cancel()
        pollRunning = gen
        pollTask = Task { [weak self] in
            await self?.pollLoop(gen)
            if self?.pollRunning == gen { self?.pollRunning = nil }
        }
    }

    private func pollLoop(_ gen: Int) async {
        var failures = 0
        while !Task.isCancelled && gen == pollGen {
            guard let token, let base = PulseClient.normalize(baseURLText) else { return }
            do {
                // 続けて失敗しているときは待たずに今の状態をもらう
                let snap = try await PulseClient(base: base, token: token).island(wait: failures == 0 ? snapshot?.v : nil)
                guard gen == pollGen else { return }
                failures = 0
                lastError = nil
                connection = .online
                apply(snap)
            } catch is CancellationError {
                return
            } catch PulseError.unauthorized {
                lastError = PulseError.unauthorized.errorDescription
                Keychain.set(nil, for: K.token)
                self.token = nil
                connection = .unpaired
                refreshIsland()
                return
            } catch {
                failures += 1
                lastError = error.localizedDescription
                if failures >= 2 {
                    connection = .offline(error.localizedDescription)
                    refreshIsland()
                }
                try? await Task.sleep(for: .seconds(min(15, 2 * failures)))
            }
        }
    }

    /// 作業中と返事待ちの間だけ、2 秒ごとにキャラのコマを進める
    private func animLoop() async {
        while !Task.isCancelled {
            try? await Task.sleep(for: .seconds(2))
            guard let s = lastState, s.status.isBusy || s.status.needsYou else { continue }
            tick &+= 1
            refreshIsland()
        }
    }

    // MARK: - Pulse の要約を受け取ったとき

    private func apply(_ snap: IslandSnapshot) {
        let first = seenAsks == nil
        snapshot = snap
        var alert: (title: String, body: String)?

        // 新しく返事を求められたら、アイランドを大きくする
        var asks = Set<String>()
        for (p, s) in snap.allSessions {
            guard let a = s.ask else { continue }
            asks.insert(a.key)
            if !first, seenAsks?.contains(a.key) == false, wantsAlert(s) {
                let what = s.status == .waiting ? "承認" : "返事"
                alert = ("\(p.name) が\(what)を待っています", a.text ?? s.title)
            }
        }
        seenAsks = asks

        // 作業が終わったとき（設定でオンのときだけ）
        for (p, s) in snap.allSessions {
            let prev = lastStatus[s.id]
            lastStatus[s.id] = s.status
            if alertDone, !first, alert == nil, prev?.isBusy == true, s.status == .done {
                alert = ("\(p.name) の作業が終わりました", s.title)
            }
        }

        refreshIsland(alert: alert)
        reloadWidgetsIfNeeded(snap)
    }

    private func wantsAlert(_ s: SessionInfo) -> Bool {
        s.status == .waiting || s.ask?.blocking == true || alertReplies
    }

    /// リミットが変わったら、ウィジェットにも読み直してもらう（10 分に 1 回まで）
    private func reloadWidgetsIfNeeded(_ snap: IslandSnapshot) {
        let limits = Provider.allCases.map { snap.data($0)?.limits }
        guard limits != lastLimits, Date.now.timeIntervalSince(lastWidgetReload) > 600 else { return }
        lastLimits = limits
        lastWidgetReload = .now
        WidgetCenter.shared.reloadAllTimelines()
    }

    // MARK: - アイランドに出すもの

    /// 選んだ AI のなかで追うセッション
    func chosenSession(in snap: IslandSnapshot) -> SessionInfo? {
        let list = snap.data(provider)?.sessions ?? []
        if let pin, let s = list.first(where: { $0.id == pin }) { return s }
        return list.first(where: { $0.status.isBusy || $0.status.needsYou }) ?? list.first
    }

    /// 返事を待っているセッションがあれば、選んだものより優先して出す
    private func focus(in snap: IslandSnapshot) -> (provider: Provider, session: SessionInfo?, other: Bool) {
        let chosen = chosenSession(in: snap)
        if chosen?.status.needsYou != true,
           let waiting = snap.allSessions
               .filter({ $0.session.status.needsYou && wantsAlert($0.session) })
               .max(by: { ($0.session.lastTs ?? 0) < ($1.session.lastTs ?? 0) }) {
            return (waiting.provider, waiting.session, true)
        }
        return (provider, chosen, false)
    }

    func makeState() -> IslandAttributes.ContentState {
        var s = IslandAttributes.ContentState.empty
        s.provider = provider
        s.tick = tick
        switch connection {
        case .unpaired:
            s.status = .offline
            s.title = "アプリでペアリングしてください"
            return s
        case .offline(let message):
            s.status = .offline
            s.title = "Pulse につながりません"
            s.detail = message
            return s
        default:
            break
        }
        guard let snap = snapshot else {
            s.title = "Pulse に接続中…"
            return s
        }
        let f = focus(in: snap)
        let limits = snap.data(f.provider)?.limits
        s.provider = f.provider
        s.fiveHour = limits?.fiveHour?.pct
        s.week = limits?.week?.pct
        s.limitIsEstimate = limits?.isEstimate ?? false
        s.othersWaiting = snap.allSessions.filter { $0.session.status.needsYou && $0.session.id != f.session?.id }.count
        guard let session = f.session else {
            s.title = "\(f.provider.name) のセッションはありません"
            return s
        }
        s.title = session.title
        s.status = session.status
        s.activity = session.activity
        s.detail = session.detail ?? ""
        s.since = session.sinceDate
        s.ask = session.status.needsYou ? (session.ask?.text ?? session.detail) : nil
        s.plan = session.plan
        s.focusedOther = f.other
        return s
    }

    func refreshIsland(alert: (title: String, body: String)? = nil) {
        let state = makeState()
        guard state != lastState || alert != nil else { return }
        lastState = state
        guard let activity else { return }
        let content = ActivityContent(state: state, staleDate: nil)
        let config = alert.map {
            AlertConfiguration(
                title: LocalizedStringResource(stringLiteral: $0.title),
                body: LocalizedStringResource(stringLiteral: $0.body),
                sound: .default
            )
        }
        Task { await activity.update(content, alertConfiguration: config) }
    }

    // MARK: - ライブアクティビティを出す・閉じる

    func showIsland() {
        guard ActivityAuthorizationInfo().areActivitiesEnabled else {
            lastError = "設定でライブアクティビティがオフになっています"
            return
        }
        if let a = Activity<IslandAttributes>.activities.first(where: { $0.activityState == .active || $0.activityState == .stale }) {
            if activity?.id != a.id { watch(a) }
            activity = a
            islandRunning = true
            lastState = nil
            refreshIsland()
            return
        }
        let state = makeState()
        do {
            let a = try Activity.request(
                attributes: IslandAttributes(startedAt: .now),
                content: ActivityContent(state: state, staleDate: nil),
                pushType: nil
            )
            activity = a
            lastState = state
            islandRunning = true
            watch(a)
        } catch {
            lastError = "アイランドを出せませんでした（\(error.localizedDescription)）"
        }
    }

    func endIsland() async {
        activity = nil
        islandRunning = false
        for a in Activity<IslandAttributes>.activities {
            await a.end(nil, dismissalPolicy: .immediate)
        }
    }

    /// 8 時間たった・スワイプで消されたなどで終わったら覚えておく（次にアプリを開いたとき出し直す）
    private func watch(_ a: Activity<IslandAttributes>) {
        Task { [weak self] in
            for await st in a.activityStateUpdates where st == .ended || st == .dismissed {
                if self?.activity?.id == a.id {
                    self?.activity = nil
                    self?.islandRunning = false
                }
                break
            }
        }
    }
}
