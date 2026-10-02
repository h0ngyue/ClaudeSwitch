import Foundation

/// 自检：`ClaudeSwitch --probe [账号目录]` 用该目录的登录 cookie 调几个 claude.ai 接口，
/// 打印状态码与字段结构（敏感字段打码），用于确认接口可用。不打印 cookie 本身。
enum Probe {
    static func run(profileDir: URL) async {
        setvbuf(stdout, nil, _IOLBF, 0)
        print("读取钥匙串与 cookie…")
        let key: String
        do { key = try CookieReader.sessionKey(profileDir: profileDir) } catch {
            print("❌ \(error)"); return
        }
        print("cookie：已读到（长度 \(key.count)）")
        let (c1, acct) = await ClaudeWeb.get("/api/account", sessionKey: key)
        print("\n/api/account → \(c1)"); dump(acct)
        let (c2, orgs) = await ClaudeWeb.get("/api/organizations", sessionKey: key)
        print("\n/api/organizations → \(c2)"); dump(orgs)
        let orgIds = (orgs as? [[String: Any]] ?? []).compactMap { $0["uuid"] as? String }
        for org in orgIds {
            for path in ["/usage", "/subscription_details", "/rate_limits"] {
                let (c, j) = await ClaudeWeb.get("/api/organizations/\(org)\(path)", sessionKey: key)
                print("\n/api/organizations/\(org.prefix(8))…\(path) → \(c)"); dump(j)
            }
        }
    }

    private static let secretWords = ["token", "key", "secret", "card", "payment", "phone", "stripe", "address"]

    private static func dump(_ v: Any?, indent: String = "  ", depth: Int = 0) {
        guard depth < 4 else { print(indent + "…"); return }
        if let d = v as? [String: Any] {
            for k in d.keys.sorted() {
                let lower = k.lowercased()
                if secretWords.contains(where: { lower.contains($0) }) && !lower.contains("email") {
                    print("\(indent)\(k): <已打码>"); continue
                }
                if let child = d[k], child is [String: Any] || child is [Any] {
                    print("\(indent)\(k):"); dump(child, indent: indent + "  ", depth: depth + 1)
                } else {
                    print("\(indent)\(k): \(String(describing: d[k]!).prefix(80))")
                }
            }
        } else if let a = v as? [Any] {
            print("\(indent)[\(a.count) 项]")
            for item in a.prefix(3) { dump(item, indent: indent + "  ", depth: depth + 1) }
        } else if let v {
            print(indent + String(describing: v).prefix(200))
        }
    }
}
