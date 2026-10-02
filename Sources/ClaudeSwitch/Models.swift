import Foundation

/// restore_sessions.py --json 的输出结构。
struct SessionsSnapshot: Decodable {
    let currentAccountId: String
    let accounts: [AccountInfo]
    let sessions: [SessionInfo]
    let candidates: [SessionInfo]
}

struct AccountInfo: Decodable, Identifiable {
    let accountId: String
    let orgId: String
    let sessionCount: Int
    let isCurrent: Bool
    var id: String { accountId }
}

struct SessionInfo: Decodable, Identifiable, Hashable {
    let sessionId: String
    let cliSessionId: String
    let title: String
    let cwd: String
    let lastActivityAt: Double
    let accountId: String
    let interrupted: Bool
    let accountIds: [String]?   // 该会话出现在哪些账户目录里（只在 sessions 列表中提供）
    var id: String { sessionId }

    var lastActivity: Date { Date(timeIntervalSince1970: lastActivityAt / 1000) }
}

/// Desktop 自己写的 plan-usage-history.json 里某个组织最近一次采样。
struct UsageSample {
    let at: Date
    let fiveHour: Int   // 5 小时窗口已用 %
    let sevenDay: Int   // 7 天窗口已用 %
}
