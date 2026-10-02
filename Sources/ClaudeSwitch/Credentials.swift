import AppKit
import CommonCrypto
import Foundation
import SQLite3

/// 读取某个账号登录目录里的 claude.ai 登录 cookie（sessionKey）。
///
/// Desktop 是 Electron 应用，cookie 存在 <目录>/Cookies（SQLite），用钥匙串里「Claude Safe Storage」
/// 的密码派生出的 AES 密钥加密（Chromium 在 macOS 上的标准做法）。用户已授权读取这个钥匙串条目
/// （2026-10-02）。密钥和 cookie 只留在进程内存里，不写盘、不打印、只发往 claude.ai。
enum CookieReader {
    enum Failure: Error, CustomStringConvertible {
        case keychain(String), noCookieDB, noSessionKey, decrypt
        var description: String {
            switch self {
            case .keychain(let m): return "读取钥匙串失败：\(m)"
            case .noCookieDB: return "这个账号目录里没有 Cookies 数据库"
            case .noSessionKey: return "没找到 claude.ai 的登录 cookie，可能已退出登录"
            case .decrypt: return "cookie 解密失败"
            }
        }
    }

    private static var cachedKey: Data?

    /// 通过系统自带的 security 命令读钥匙串：授权「始终允许」记在这个系统程序上，重新打包本工具也不会反复弹框。
    static func aesKey() throws -> Data {
        if let k = cachedKey { return k }
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/security")
        p.arguments = ["find-generic-password", "-w", "-s", "Claude Safe Storage"]
        let out = Pipe(), err = Pipe()
        p.standardOutput = out
        p.standardError = err
        try p.run()
        let pwData = out.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        guard p.terminationStatus == 0 else {
            throw Failure.keychain(String(decoding: err.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
                .trimmingCharacters(in: .whitespacesAndNewlines))
        }
        let password = String(decoding: pwData, as: UTF8.self).trimmingCharacters(in: .newlines)
        var key = Data(count: kCCKeySizeAES128)
        let salt = Array("saltysalt".utf8)
        let status = key.withUnsafeMutableBytes { kp in
            CCKeyDerivationPBKDF(CCPBKDFAlgorithm(kCCPBKDF2), password, password.utf8.count,
                                 salt, salt.count, CCPseudoRandomAlgorithm(kCCPRFHmacAlgSHA1), 1003,
                                 kp.bindMemory(to: UInt8.self).baseAddress, kCCKeySizeAES128)
        }
        guard status == kCCSuccess else { throw Failure.decrypt }
        cachedKey = key
        return key
    }

    /// profileDir：当前账号传 Claude/，停放的账号传 ClaudeSwitch/profiles/<账户ID>/。
    static func sessionKey(profileDir: URL) throws -> String {
        let db = profileDir.appendingPathComponent("Cookies")
        guard FileManager.default.fileExists(atPath: db.path) else { throw Failure.noCookieDB }
        // Desktop 运行时会锁库，复制到临时目录再读；复制件仍是加密的，读完即删
        let tmp = FileManager.default.temporaryDirectory.appendingPathComponent("cs-cookies-\(UUID().uuidString)")
        try FileManager.default.copyItem(at: db, to: tmp)
        defer { try? FileManager.default.removeItem(at: tmp) }

        var handle: OpaquePointer?
        guard sqlite3_open_v2(tmp.path, &handle, SQLITE_OPEN_READONLY, nil) == SQLITE_OK else { throw Failure.noCookieDB }
        defer { sqlite3_close(handle) }
        let version = Int(queryText(handle, "SELECT value FROM meta WHERE key='version'") ?? "0") ?? 0
        guard let blob = queryBlob(handle, "SELECT encrypted_value FROM cookies WHERE name='sessionKey' AND host_key LIKE '%claude.ai' ORDER BY last_access_utc DESC LIMIT 1")
        else { throw Failure.noSessionKey }
        return try decrypt(blob, dbVersion: version)
    }

    private static func decrypt(_ blob: Data, dbVersion: Int) throws -> String {
        guard blob.count > 3, blob.prefix(3) == Data("v10".utf8) else { throw Failure.decrypt }
        let cipher = blob.dropFirst(3)
        let key = try aesKey()
        let iv = Data(repeating: 0x20, count: kCCBlockSizeAES128)
        var out = Data(count: cipher.count + kCCBlockSizeAES128)
        var outLen = 0
        let outCapacity = out.count
        let status = out.withUnsafeMutableBytes { op in
            cipher.withUnsafeBytes { cp in
                key.withUnsafeBytes { kp in
                    iv.withUnsafeBytes { ip in
                        CCCrypt(CCOperation(kCCDecrypt), CCAlgorithm(kCCAlgorithmAES), CCOptions(kCCOptionPKCS7Padding),
                                kp.baseAddress, key.count, ip.baseAddress, cp.baseAddress, cipher.count,
                                op.baseAddress, outCapacity, &outLen)
                    }
                }
            }
        }
        guard status == kCCSuccess else { throw Failure.decrypt }
        var plain = out.prefix(outLen)
        // 数据库版本 ≥ 24 时明文前面多 32 字节域名摘要
        if dbVersion >= 24, plain.count > 32 { plain = plain.dropFirst(32) }
        guard let s = String(data: plain, encoding: .utf8), !s.isEmpty else { throw Failure.decrypt }
        return s
    }

    private static func queryText(_ db: OpaquePointer?, _ sql: String) -> String? {
        var st: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &st, nil) == SQLITE_OK else { return nil }
        defer { sqlite3_finalize(st) }
        guard sqlite3_step(st) == SQLITE_ROW, let c = sqlite3_column_text(st, 0) else { return nil }
        return String(cString: c)
    }

    private static func queryBlob(_ db: OpaquePointer?, _ sql: String) -> Data? {
        var st: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &st, nil) == SQLITE_OK else { return nil }
        defer { sqlite3_finalize(st) }
        guard sqlite3_step(st) == SQLITE_ROW, let p = sqlite3_column_blob(st, 0) else { return nil }
        return Data(bytes: p, count: Int(sqlite3_column_bytes(st, 0)))
    }
}

/// claude.ai 网页接口（非公开文档，Desktop 自己显示用量时调的就是这几个）。
///
/// 请求方式与 cookie 的真实主人（Claude Desktop）保持一致：User-Agent 按本机已安装的 Desktop 与 Electron
/// 版本拼出，带 claude.ai 的来源头。刻意不模仿 Claude Code 命令行的请求特征——我们持有的是 Desktop 的
/// 网页登录 cookie，套上命令行的特征反而身份与流量对不上。降低风险主要靠少发请求（见 LiveUsageService）。
enum ClaudeWeb {
    static let userAgent: String = {
        func version(_ plist: URL, _ key: String) -> String? {
            (NSDictionary(contentsOf: plist)?[key] as? String)
        }
        let app = NSWorkspace.shared.urlForApplication(withBundleIdentifier: Paths.desktopBundleId)
        let desktop = app.flatMap { version($0.appendingPathComponent("Contents/Info.plist"), "CFBundleShortVersionString") }
        let electron = app.flatMap { version($0.appendingPathComponent(
            "Contents/Frameworks/Electron Framework.framework/Resources/Info.plist"), "CFBundleVersion") }
        var ua = "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36 (KHTML, like Gecko)"
        if let desktop { ua += " Claude/\(desktop)" }
        if let electron { ua += " Electron/\(electron)" }
        return ua + " Safari/537.36"
    }()

    static func get(_ path: String, sessionKey: String) async -> (Int, Any?) {
        guard let url = URL(string: "https://claude.ai" + path) else { return (0, nil) }
        var req = URLRequest(url: url, timeoutInterval: 15)
        req.setValue("sessionKey=\(sessionKey)", forHTTPHeaderField: "Cookie")
        req.setValue("application/json", forHTTPHeaderField: "Accept")
        req.setValue(userAgent, forHTTPHeaderField: "User-Agent")
        req.setValue("https://claude.ai", forHTTPHeaderField: "Origin")
        req.setValue("https://claude.ai/", forHTTPHeaderField: "Referer")
        do {
            let (data, resp) = try await URLSession.shared.data(for: req)
            let code = (resp as? HTTPURLResponse)?.statusCode ?? 0
            return (code, try? JSONSerialization.jsonObject(with: data))
        } catch {
            return (-1, error.localizedDescription)
        }
    }
}
