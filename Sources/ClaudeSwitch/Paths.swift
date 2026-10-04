import Foundation

/// 所有路径集中在这里。工具自己的数据写 ~/Library/Application Support/ClaudeSwitch/；
/// 对 Claude Desktop 目录的改动只经由 scripts/claude_profiles.sh 完成。
enum Paths {
    static let home = FileManager.default.homeDirectoryForCurrentUser
    static let appSupport = home.appendingPathComponent("Library/Application Support")
    static let claudeDir = appSupport.appendingPathComponent("Claude")
    static let usageHistory = claudeDir.appendingPathComponent("plan-usage-history.json")
    static let toolDir = appSupport.appendingPathComponent("ClaudeSwitch")
    static let settingsFile = toolDir.appendingPathComponent("settings.json")
    static let profilesDir = toolDir.appendingPathComponent("profiles")
    static let stateDir = toolDir.appendingPathComponent("state")
    static let backupLatest = toolDir.appendingPathComponent("backup/LATEST")
    static let cliConfig = home.appendingPathComponent(".claude.json")

    static let desktopBundleId = "com.anthropic.claudefordesktop"

    /// 随工具分发的两个脚本：打包后在 .app 的 Resources 里，源码直接运行时取仓库的 scripts/。
    static let scriptsDir: URL = {
        if let r = Bundle.main.resourceURL, FileManager.default.fileExists(atPath: r.appendingPathComponent("claude_profiles.sh").path) {
            return r
        }
        return URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("scripts")
    }()
    static var profilesScript: String { scriptsDir.appendingPathComponent("claude_profiles.sh").path }
    static var restoreScript: String { scriptsDir.appendingPathComponent("restore_sessions.py").path }
}

/// 用户可改的设置。字段缺失时用默认值，保证旧版 settings.json 升级后别名不丢。
struct Settings: Codable {
    var pythonPath = "/usr/bin/python3"
    var aliases: [String: String] = [:]   // 账户ID -> 你起的名字
    var emails: [String: String] = [:]    // 账户ID -> 邮箱（从 Claude Code 命令行配置里收集到的）
    var orgs: [String: String] = [:]      // 账户ID -> 组织ID（联网识别账号时记下，供还没用过 Code 页的账号使用）
    var pendingAddTarget: String?         // 正在添加（等待登录）的账户ID
    var purchases: [String: String] = [:] // 账户ID -> App Store 订阅的购买时间（北京时间，「2026-09-15」或「2026-09-15 14:30」）

    init() {}

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let d = Settings()
        pythonPath = try c.decodeIfPresent(String.self, forKey: .pythonPath) ?? d.pythonPath
        aliases = try c.decodeIfPresent([String: String].self, forKey: .aliases) ?? [:]
        emails = try c.decodeIfPresent([String: String].self, forKey: .emails) ?? [:]
        orgs = try c.decodeIfPresent([String: String].self, forKey: .orgs) ?? [:]
        pendingAddTarget = try c.decodeIfPresent(String.self, forKey: .pendingAddTarget)
        purchases = try c.decodeIfPresent([String: String].self, forKey: .purchases) ?? [:]
    }

    static func load() -> Settings {
        guard let data = try? Data(contentsOf: Paths.settingsFile),
              let s = try? JSONDecoder().decode(Settings.self, from: data) else { return Settings() }
        return s
    }

    func save() {
        try? FileManager.default.createDirectory(at: Paths.toolDir, withIntermediateDirectories: true)
        let enc = JSONEncoder()
        enc.outputFormatting = [.prettyPrinted, .sortedKeys]
        try? enc.encode(self).write(to: Paths.settingsFile, options: .atomic)
    }
}
