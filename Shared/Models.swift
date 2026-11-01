import ActivityKit
import Foundation

enum Provider: String, Codable, CaseIterable, Identifiable, Hashable {
    case claude, codex, antigravity

    var id: String { rawValue }

    var name: String {
        switch self {
        case .claude: "Claude"
        case .codex: "Codex"
        case .antigravity: "Antigravity"
        }
    }
}

enum SessionStatus: String, Codable, Hashable {
    case working, waiting, reply, stalled, done, idle, offline, none

    init(from decoder: Decoder) throws {
        let raw = try decoder.singleValueContainer().decode(String.self)
        self = SessionStatus(rawValue: raw) ?? .idle
    }

    /// 自分（ユーザー）の返事を待っている
    var needsYou: Bool { self == .waiting || self == .reply }
    /// 手を動かしている最中
    var isBusy: Bool { self == .working || self == .stalled }

    var label: String {
        switch self {
        case .working: "作業中"
        case .waiting: "承認待ち"
        case .reply: "返答待ち"
        case .stalled: "止まっている"
        case .done: "完了"
        case .idle: "待機中"
        case .offline: "つながっていない"
        case .none: "セッションなし"
        }
    }
}

enum ActivityKind: String, Codable, Hashable {
    case think, read, edit, shell, search, web, agent, plan, ask, other

    init(from decoder: Decoder) throws {
        let raw = try decoder.singleValueContainer().decode(String.self)
        self = ActivityKind(rawValue: raw) ?? .other
    }

    var label: String {
        switch self {
        case .think: "考え中"
        case .read: "読んでいる"
        case .edit: "書いている"
        case .shell: "コマンド実行中"
        case .search: "探している"
        case .web: "Web を見ている"
        case .agent: "手分けしている"
        case .plan: "計画を立てている"
        case .ask: "返事を待っている"
        case .other: "作業中"
        }
    }

    var symbol: String {
        switch self {
        case .think: "brain"
        case .read: "doc.text"
        case .edit: "pencil"
        case .shell: "terminal"
        case .search: "magnifyingglass"
        case .web: "globe"
        case .agent: "person.2"
        case .plan: "checklist"
        case .ask: "hand.raised.fill"
        case .other: "sparkles"
        }
    }
}

// MARK: - Pulse の /api/island

struct IslandSnapshot: Decodable {
    let v: String
    let at: Double
    let providers: [String: ProviderData]

    func data(_ provider: Provider) -> ProviderData? { providers[provider.rawValue] }

    /// 全部の AI のセッションを、どの AI のものか付きで並べる
    var allSessions: [(provider: Provider, session: SessionInfo)] {
        Provider.allCases.flatMap { p in (data(p)?.sessions ?? []).map { (p, $0) } }
    }
}

struct ProviderData: Decodable {
    let name: String
    let limits: Limits?
    let sessions: [SessionInfo]
}

struct Limits: Codable, Hashable {
    let fiveHour: LimitWindow?
    let week: LimitWindow?
    let at: Double?
    let kind: String?
    let plan: String?

    /// Claude の「目安」（トークン量をこれまでの最大と比べたもの）
    var isEstimate: Bool { kind == "relative" }
}

struct LimitWindow: Codable, Hashable {
    let pct: Double
    let resetsAt: Double?

    var resetDate: Date? { resetsAt.map { Date(timeIntervalSince1970: $0 / 1000) } }
}

struct SessionInfo: Decodable, Identifiable, Hashable {
    let id: String
    let title: String
    let project: String?
    let status: SessionStatus
    let activity: ActivityKind
    let detail: String?
    let since: Double?
    let lastTs: Double?
    let toolCount: Int?
    let ask: AskInfo?
    let plan: PlanInfo?

    var sinceDate: Date? { since.map { Date(timeIntervalSince1970: $0 / 1000) } }
    var lastDate: Date? { lastTs.map { Date(timeIntervalSince1970: $0 / 1000) } }
}

struct AskInfo: Decodable, Hashable {
    let key: String
    let kind: String?
    let blocking: Bool?
    let text: String?
}

struct PlanInfo: Codable, Hashable {
    let done: Int
    let total: Int
}

// MARK: - ライブアクティビティ

struct IslandAttributes: ActivityAttributes {
    struct ContentState: Codable, Hashable {
        var provider: Provider
        var title: String
        var status: SessionStatus
        var activity: ActivityKind
        var detail: String
        /// いまのターンが始まった時刻（右側の経過時間に使う）
        var since: Date?
        /// キャラを動かすか（アプリの設定。ウィジェットからはアプリの設定を読めないので、ここで渡す）。
        /// 前の版のアイランドには無い値なので、無ければ動かす
        var animate: Bool?
        var ask: String?
        /// 表示中のほかに、返事を待っているセッションの数
        var othersWaiting: Int
        var fiveHour: Double?
        var week: Double?
        var limitIsEstimate: Bool
        var plan: PlanInfo?
        /// 選んだセッションではなく、返事を待っている別のセッションを出している
        var focusedOther: Bool

        static let empty = ContentState(
            provider: .claude, title: "Pulse Island", status: .none, activity: .other, detail: "",
            since: nil, animate: true, ask: nil, othersWaiting: 0, fiveHour: nil, week: nil,
            limitIsEstimate: false, plan: nil, focusedOther: false
        )
    }

    var startedAt: Date
}
