import Foundation

/// 联网查到的某个账号的实时额度与账期。缓存到 ClaudeSwitch/usage_cache.json，重开程序后仍显示上次结果。
struct LiveUsage: Codable {
    var accountId: String
    var email: String?
    var plan: String?             // 如 claude_pro
    var fiveHour: Int?
    var fiveHourResetsAt: Date?
    var sevenDay: Int?
    var sevenDayResetsAt: Date?
    var nextChargeDate: String?   // 下次扣费日 YYYY-MM-DD
    var nextChargeAt: Date?       // 下次扣费的精确时刻
    var appStore: Bool?           // 通过苹果 App Store 订阅：Anthropic 接口里没有扣费日
    var fullResets: Int?          // 还能用的重置卡：同时清 5 小时与每周额度（Full Reset）
    var sessionResets: Int?       // 还能用的重置卡：只清 5 小时额度
    var resetGrants: [ResetGrant]? // 每一批重置卡的明细（张数与到期时间）；旧缓存没有，刷新后才有
    var fetchedAt: Date
    var identityCheckedAt: Date?  // 上次核对「目录里登录的确实是这个账号」的时间
    var planClickedAt: Date?      // 上次点头像手动查询的时间，10 分钟内不再查
    var chargeCheckedAt: Date?    // 上次查账期的时间
}

/// 一批重置卡：同一次发放的卡共用一个到期时间。
struct ResetGrant: Codable {
    var full: Bool        // true 为 Full Reset，false 为只清 5 小时的卡
    var left: Int         // 这批还剩几张
    var endsAt: Date?     // 到期时间，接口没给就是不过期
}

enum LiveUsageService {
    enum Failure: Error, CustomStringConvertible {
        case noProfile, wrongAccount(String), http(String, Int)
        var description: String {
            switch self {
            case .noProfile: return "这个账号还没保存登录态，点「登录添加」后才能联网刷新"
            case .wrongAccount(let e): return "登录目录里实际是另一个账号（\(e)），已停止，请检查账号对应关系"
            case .http(let p, let c): return c == 401 || c == 403 ? "登录已失效（\(p) 返回 \(c)），需要重新登录" : "\(p) 返回 \(c)"
            }
        }
    }

    /// 点头像时可勾选的查询项，每项 1 个请求。
    enum Part: String, CaseIterable { case plan, charge, usage }

    /// 自动刷新：平时只查用量（1 个请求）；账户身份与邮箱、账期按北京时间每个自然日各查一次，
    /// 过了扣费日或缺精确扣费时刻（旧缓存）时补查账期。请求依次发出，不并发。
    static func fetch(accountId: String, orgId: String, profileDir: URL, previous: LiveUsage?) async throws -> LiveUsage {
        let key = try CookieReader.sessionKey(profileDir: profileDir)
        let now = Date()
        var r = previous ?? LiveUsage(accountId: accountId, fetchedAt: now)

        if !checkedToday(r.identityCheckedAt, now: now) {
            try await checkAccount(&r, orgId: orgId, sessionKey: key, now: now)
        }
        try await loadUsage(&r, orgId: orgId, sessionKey: key, now: now)

        let today = String(ISO8601DateFormatter().string(from: now).prefix(10))
        // App Store 订阅本来就没有扣费日，不因缺扣费日重复查，只按自然日查
        let chargeMissing = r.appStore == nil || (r.nextChargeDate != nil && r.nextChargeAt == nil)
        if !checkedToday(r.chargeCheckedAt, now: now) || chargeMissing || (r.nextChargeDate.map { $0 < today } ?? false) {
            _ = await loadCharge(&r, orgId: orgId, sessionKey: key, now: now)
        }
        return r
    }

    /// 点头像手动查：只发勾选的几项。没勾套餐类型时，若今天还没核对过身份，仍先核对一次，防止目录里登录的是别的账号。
    static func fetch(parts: Set<Part>, accountId: String, orgId: String, profileDir: URL, previous: LiveUsage?) async throws -> LiveUsage {
        let key = try CookieReader.sessionKey(profileDir: profileDir)
        let now = Date()
        var r = previous ?? LiveUsage(accountId: accountId, fetchedAt: now)
        if parts.contains(.plan) || !checkedToday(r.identityCheckedAt, now: now) {
            try await checkAccount(&r, orgId: orgId, sessionKey: key, now: now)
        }
        if parts.contains(.charge) {
            let code = await loadCharge(&r, orgId: orgId, sessionKey: key, now: now)
            guard code == 200 else { throw Failure.http("账期", code) }
        }
        if parts.contains(.usage) { try await loadUsage(&r, orgId: orgId, sessionKey: key, now: now) }
        return r
    }

    private static let beijing: Calendar = {
        var c = Calendar(identifier: .gregorian)
        c.timeZone = TimeZone(identifier: "Asia/Shanghai")!
        return c
    }()

    /// 按北京时间算，d 是否和 now 在同一天：昨天查过的，今天第一次刷新就再查。
    private static func checkedToday(_ d: Date?, now: Date) -> Bool {
        d.map { beijing.isDate($0, inSameDayAs: now) } ?? false
    }

    /// 请求用量：5 小时与每周额度；cedar_ember=1 让同一个请求顺带返回重置卡，不额外发请求。
    private static func loadUsage(_ r: inout LiveUsage, orgId: String, sessionKey key: String, now: Date) async throws {
        let (code, j) = await ClaudeWeb.get("/api/organizations/\(orgId)/usage?cedar_ember=1", sessionKey: key)
        guard code == 200, let usage = j as? [String: Any] else { throw Failure.http("用量", code) }
        let grants = resetCards(usage["cedar_ember"], now: now)
        r.resetGrants = grants
        r.fullResets = grants.filter(\.full).reduce(0) { $0 + $1.left }
        r.sessionResets = grants.filter { !$0.full }.reduce(0) { $0 + $1.left }
        let five = usage["five_hour"] as? [String: Any], seven = usage["seven_day"] as? [String: Any]
        r.fiveHour = number(five?["utilization"]); r.fiveHourResetsAt = date(five?["resets_at"])
        r.sevenDay = number(seven?["utilization"]); r.sevenDayResetsAt = date(seven?["resets_at"])
        r.fetchedAt = now
    }

    /// 请求账期：下次扣费日与是否 App Store 订阅。返回状态码，自动刷新时失败不算错。
    private static func loadCharge(_ r: inout LiveUsage, orgId: String, sessionKey key: String, now: Date) async -> Int {
        let (code, j) = await ClaudeWeb.get("/api/organizations/\(orgId)/subscription_details", sessionKey: key)
        guard code == 200, let sub = j as? [String: Any] else { return code == 200 ? -1 : code }
        r.nextChargeDate = sub["next_charge_date"] as? String
        r.nextChargeAt = date(sub["next_charge_at"])
        r.appStore = (sub["subscription_details_url"] as? String)?.contains("apps.apple.com") ?? false
        r.chargeCheckedAt = now
        return code
    }

    /// 请求 /api/account：确认登录的是这个账号，更新邮箱与套餐。
    private static func checkAccount(_ r: inout LiveUsage, orgId: String, sessionKey key: String, now: Date) async throws {
        let (code, j) = await ClaudeWeb.get("/api/account", sessionKey: key)
        guard code == 200, let acct = j as? [String: Any] else { throw Failure.http("账户信息", code) }
        let email = acct["email_address"] as? String
        if let uuid = acct["uuid"] as? String, uuid != r.accountId { throw Failure.wrongAccount(email ?? uuid) }
        r.email = email
        r.plan = ((acct["memberships"] as? [[String: Any]])?
            .compactMap { $0["organization"] as? [String: Any] }
            .first { ($0["uuid"] as? String) == orgId })?["analytics_subscription_plan"] as? String
        r.identityCheckedAt = now
    }

    /// 识别某个登录目录里登录的是哪个账号（添加账号后自动命名用）。
    static func whoami(profileDir: URL) async -> (uuid: String, email: String?, orgId: String?)? {
        guard let key = try? CookieReader.sessionKey(profileDir: profileDir) else { return nil }
        let (code, j) = await ClaudeWeb.get("/api/account", sessionKey: key)
        guard code == 200, let acct = j as? [String: Any], let uuid = acct["uuid"] as? String else { return nil }
        let org = (acct["memberships"] as? [[String: Any]])?
            .compactMap { ($0["organization"] as? [String: Any])?["uuid"] as? String }.first
        return (uuid, acct["email_address"] as? String, org)
    }

    /// 按 claude.ai 用量页的规则数重置卡：未暂停、未过期的卡按剩余次数计；
    /// clears 只有 five_hour 的是 5 小时卡，同时含 five_hour 和其他窗口的是 Full Reset，只清每周的不计。
    private static func resetCards(_ v: Any?, now: Date) -> [ResetGrant] {
        guard let ce = v as? [String: Any], ce["eligible"] as? Bool == true,
              let grants = ce["grants"] as? [[String: Any]] else { return [] }
        var list: [ResetGrant] = []
        for g in grants where g["paused"] as? Bool != true {
            let end = date(g["ends_at"])
            if let end, end <= now { continue }
            let left = number(g["resets_left"]) ?? 0
            guard left > 0, let clears = g["clears"] as? [String], clears.contains("five_hour") else { continue }
            list.append(ResetGrant(full: clears != ["five_hour"], left: left, endsAt: end))
        }
        // 先 Full 后 5 小时，同类里先到期的在前
        return list.sorted { ($0.full ? 0 : 1, $0.endsAt ?? .distantFuture) < ($1.full ? 0 : 1, $1.endsAt ?? .distantFuture) }
    }

    private static func number(_ v: Any?) -> Int? {
        (v as? NSNumber)?.intValue
    }

    private static func date(_ v: Any?) -> Date? {
        guard let s = v as? String else { return nil }
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f.date(from: s) ?? ISO8601DateFormatter().date(from: s)
    }

    // MARK: 缓存

    private static var cacheFile: URL { Paths.toolDir.appendingPathComponent("usage_cache.json") }

    static func loadCache() -> [String: LiveUsage] {
        guard let d = try? Data(contentsOf: cacheFile) else { return [:] }
        let dec = JSONDecoder(); dec.dateDecodingStrategy = .iso8601
        return (try? dec.decode([String: LiveUsage].self, from: d)) ?? [:]
    }

    static func saveCache(_ c: [String: LiveUsage]) {
        try? FileManager.default.createDirectory(at: Paths.toolDir, withIntermediateDirectories: true)
        let enc = JSONEncoder(); enc.dateEncodingStrategy = .iso8601; enc.outputFormatting = [.prettyPrinted, .sortedKeys]
        try? enc.encode(c).write(to: cacheFile, options: .atomic)
    }
}
