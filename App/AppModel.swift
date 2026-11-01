import ActivityKit
import Foundation
import Observation
import WidgetKit

/// アプリの中心。Pulse を見に行き、選んだセッションをライブアクティビティに映す。
/// 無料の Apple ID ではプッシュ通知が使えないので、アプリを裏で動かし続けて（KeepAlive）自分で書き換える。
/// iOS 18 からは書き換えに間隔と回数の制限があるので、キャラのコマは書き換えでは進めず（FrameCharacter が
/// iOS の時計で進める）、中身の変化も急ぎでなければ間をあけてまとめる
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
        static let animate = "island.animate"
        static let diary = "island.diary"
        static let lastBeat = "island.lastBeat"
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
    /// アイランドのキャラを動かす（コマを描いたフォントが崩れて見えるときに切る）
    var animate: Bool {
        didSet {
            defaults.set(animate, forKey: K.animate)
            refreshIsland()
        }
    }

    // MARK: - 状態

    private(set) var snapshot: IslandSnapshot?
    private(set) var connection: Connection
    private(set) var islandRunning = false
    private(set) var lastError: String?
    /// 裏での動きの記録（新しい順）。アイランドが止まったとき、何が起きていたかを設定画面で見るため
    private(set) var diary: [String]
    private(set) var lastReceived: Date?
    private(set) var lastSentAt: Date?
    private(set) var sentCount = 0
    /// アプリの画面でコマを進める時計の起点
    let anchor = Date.now

    @ObservationIgnored private var token: String?
    @ObservationIgnored private var pollTask: Task<Void, Never>?
    @ObservationIgnored private var pollGen = 0
    @ObservationIgnored private var pollRunning: Int?
    @ObservationIgnored private var beatTask: Task<Void, Never>?
    @ObservationIgnored private var activity: Activity<IslandAttributes>?
    /// 最後にアイランドへ送った中身
    @ObservationIgnored private var lastSent: IslandAttributes.ContentState?
    @ObservationIgnored private var flushTask: Task<Void, Never>?
    @ObservationIgnored private var flushAt: Date?
    @ObservationIgnored private var seenAsks: Set<String>?
    @ObservationIgnored private var lastStatus: [String: SessionStatus] = [:]
    @ObservationIgnored private var lastWidgetReload = Date.distantPast
    @ObservationIgnored private var lastLimits: [Limits?] = []
    @ObservationIgnored private let audio: KeepAlive
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
        animate = d.object(forKey: K.animate) as? Bool ?? true
        diary = d.stringArray(forKey: K.diary) ?? []
        token = Keychain.get(K.token)
        connection = token == nil ? .unpaired : .connecting
        audio = KeepAlive()
        audio.onEvent = { [weak self] in self?.note($0) }
        if let last = d.object(forKey: K.lastBeat) as? Date {
            note("アプリが起動した（前のアプリが最後に動いていたのは \(Self.stamp(last))）")
        } else {
            note("アプリが起動した")
        }
        if let a = Activity<IslandAttributes>.activities.first {
            activity = a
            islandRunning = true
            watch(a)
        }
    }

    var isPaired: Bool { connection != .unpaired }
    var audioPlaying: Bool { audio.isPlaying }

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
        if beatTask == nil {
            beatTask = Task { [weak self] in await self?.heartbeat() }
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
                if case .offline = connection { note("Pulse にまたつながった") }
                failures = 0
                lastError = nil
                lastReceived = .now
                connection = .online
                apply(snap)
            } catch is CancellationError {
                return
            } catch PulseError.unauthorized {
                note("Pulse に鍵を断られた（ペアリングが外れた）")
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
                    if failures == 2 { note("Pulse につながらない（\(error.localizedDescription)）") }
                    connection = .offline(error.localizedDescription)
                    refreshIsland()
                }
                try? await Task.sleep(for: .seconds(min(15, 2 * failures)))
            }
        }
    }

    /// 5 秒ごとに、裏で眠らされていなかったかと、常駐用の音声が止まっていないかを見回る
    private func heartbeat() async {
        var last = Date.now
        while !Task.isCancelled {
            try? await Task.sleep(for: .seconds(5))
            let now = Date.now
            let gap = now.timeIntervalSince(last)
            if gap > 30 {
                note("裏で止まっていた（\(Self.stamp(last)) から \(Self.span(gap))）")
            }
            last = now
            defaults.set(now, forKey: K.lastBeat)
            if keepAlive, token != nil { audio.ensureRunning() }
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

        if let alert { note("知らせた：\(alert.title)") }
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
        s.animate = animate
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
        // 1% 未満の揺れで書き換えないように丸める
        s.fiveHour = limits?.fiveHour?.pct.rounded()
        s.week = limits?.week?.pct.rounded()
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

    /// アイランドを今の中身に書き換える。返事待ち・完了・切断などの変化はすぐ、
    /// ほかの変化は前の書き換えから 15 秒、文言とリミットだけの変化は 60 秒あけて、まとめて送る
    func refreshIsland(alert: (title: String, body: String)? = nil) {
        guard let activity else { return }
        let state = makeState()
        guard state != lastSent || alert != nil else { return }
        if alert == nil, let lastSent, let lastSentAt {
            let wait = Self.minGap(from: lastSent, to: state) - Date.now.timeIntervalSince(lastSentAt)
            if wait > 0 {
                scheduleFlush(in: wait)
                return
            }
        }
        flushTask?.cancel()
        flushTask = nil
        flushAt = nil
        lastSent = state
        lastSentAt = .now
        sentCount += 1
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

    private static func minGap(from old: IslandAttributes.ContentState, to new: IslandAttributes.ContentState) -> TimeInterval {
        if old.status != new.status || old.provider != new.provider || old.ask != new.ask
            || old.focusedOther != new.focusedOther || old.animate != new.animate {
            return 0
        }
        var minor = old
        minor.detail = new.detail
        minor.fiveHour = new.fiveHour
        minor.week = new.week
        minor.limitIsEstimate = new.limitIsEstimate
        return minor == new ? 60 : 15
    }

    /// 間をあけた書き換えを予約する。すでにもっと早い予約があればそれに任せる
    private func scheduleFlush(in wait: TimeInterval) {
        let at = Date.now.addingTimeInterval(wait)
        if let flushAt, flushAt <= at { return }
        flushTask?.cancel()
        flushAt = at
        flushTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(wait))
            guard !Task.isCancelled, let self else { return }
            self.flushTask = nil
            self.flushAt = nil
            self.refreshIsland()
        }
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
            // 今の中身で必ず書き直す
            lastSent = nil
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
            lastSent = state
            lastSentAt = .now
            islandRunning = true
            watch(a)
            note("アイランドを出した")
        } catch {
            lastError = "アイランドを出せませんでした（\(error.localizedDescription)）"
            note(lastError ?? "")
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
                    self?.note(st == .dismissed ? "アイランドが消された" : "アイランドが終わった（8 時間たったなど）")
                }
                break
            }
        }
    }

    // MARK: - 記録

    /// 記録に 1 行足す（新しい順に 80 行まで、端末に保存）
    func note(_ text: String) {
        diary.insert("\(Self.stamp(.now))  \(text)", at: 0)
        if diary.count > 80 { diary.removeLast(diary.count - 80) }
        defaults.set(diary, forKey: K.diary)
    }

    func clearDiary() {
        diary = []
        defaults.removeObject(forKey: K.diary)
    }

    private static let stampFormat: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "ja_JP")
        f.dateFormat = "M/d HH:mm:ss"
        return f
    }()

    static func stamp(_ date: Date) -> String { stampFormat.string(from: date) }

    static func span(_ seconds: TimeInterval) -> String {
        if seconds < 120 { return "\(Int(seconds)) 秒" }
        if seconds < 7200 { return "\(Int(seconds / 60)) 分" }
        return String(format: "%.1f 時間", seconds / 3600)
    }
}
