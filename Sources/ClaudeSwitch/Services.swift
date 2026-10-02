import AppKit
import Foundation

/// 读 Desktop 本地的用量采样文件（只读）。只有当前登录账号会被 Desktop 持续更新，
/// 其他账号显示的是它们上次在用时的快照，界面上会标出采样时间。
enum UsageReader {
    static func latestByOrg() -> [String: UsageSample] {
        guard let data = try? Data(contentsOf: Paths.usageHistory),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let samples = obj["samples"] as? [[String: Any]] else { return [:] }
        var out: [String: UsageSample] = [:]
        for s in samples {
            guard let org = s["org"] as? String, let t = s["t"] as? Double,
                  let u = s["u"] as? [String: Any] else { continue }
            let sample = UsageSample(at: Date(timeIntervalSince1970: t / 1000),
                                     fiveHour: u["fh"] as? Int ?? 0, sevenDay: u["sd"] as? Int ?? 0)
            if let old = out[org], old.at >= sample.at { continue }
            out[org] = sample
        }
        return out
    }
}

/// 会话列表与同步全部委托给 scripts/restore_sessions.py，保持单一实现。
enum SessionService {
    struct RunResult { let ok: Bool; let output: String }

    static func run(_ args: [String], settings: Settings) -> RunResult {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: settings.pythonPath)
        p.arguments = [Paths.restoreScript] + args
        let pipe = Pipe()
        p.standardOutput = pipe
        p.standardError = pipe
        do { try p.run() } catch {
            return RunResult(ok: false, output: "无法启动 \(settings.pythonPath)：\(error.localizedDescription)")
        }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        return RunResult(ok: p.terminationStatus == 0, output: String(decoding: data, as: UTF8.self))
    }

    static func snapshot(current: String?, settings: Settings) -> (SessionsSnapshot?, String?) {
        let r = run(["--json"] + (current.map { ["--to=\($0)"] } ?? []), settings: settings)
        guard r.ok, let snap = try? JSONDecoder().decode(SessionsSnapshot.self, from: Data(r.output.utf8)) else {
            return (nil, r.output.isEmpty ? "会话脚本无输出" : r.output)
        }
        return (snap, nil)
    }

    static func snapshot(target accountId: String, settings: Settings) -> SessionsSnapshot? {
        let r = run(["--json", "--to=\(accountId)"], settings: settings)
        return r.ok ? try? JSONDecoder().decode(SessionsSnapshot.self, from: Data(r.output.utf8)) : nil
    }

    static func copy(_ sessions: [SessionInfo], to accountId: String, settings: Settings) -> RunResult {
        run(["--to=\(accountId)"] + sessions.map { $0.cliSessionId }, settings: settings)
    }

    static func undo(settings: Settings) -> RunResult { run(["--undo"], settings: settings) }
}

/// 让 Desktop 正常退出（等同 ⌘Q）再重新打开，用于让会话列表的改动生效。
enum DesktopControl {
    static var isRunning: Bool {
        !NSRunningApplication.runningApplications(withBundleIdentifier: Paths.desktopBundleId).isEmpty
    }

    static func quitAndRelaunch(completion: @escaping (Bool) -> Void) {
        let apps = NSRunningApplication.runningApplications(withBundleIdentifier: Paths.desktopBundleId)
        apps.forEach { $0.terminate() }
        DispatchQueue.global().async {
            for _ in 0..<60 where isRunning { Thread.sleep(forTimeInterval: 0.5) }
            let stopped = !isRunning
            DispatchQueue.main.async {
                if stopped { launch() }
                completion(stopped)
            }
        }
    }

    static func launch() {
        guard let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: Paths.desktopBundleId) else { return }
        NSWorkspace.shared.openApplication(at: url, configuration: NSWorkspace.OpenConfiguration())
    }
}

/// 账号目录布局的当前状态，直接读 claude_profiles.sh 维护的状态文件。
struct ProfileState {
    var initialized = false          // 已备份且会话目录已共享
    var current: String?             // Claude/ 当前是哪个账户（state/current）
    var parked: Set<String> = []     // 已停放、可以直接切换过去的账户
    var pendingAdd = false           // 已停放原账号、正在等待登录新账号

    static func load() -> ProfileState {
        let fm = FileManager.default
        var s = ProfileState()
        let sessionsLink = Paths.claudeDir.appendingPathComponent("claude-code-sessions").path
        let isLink = (try? fm.destinationOfSymbolicLink(atPath: sessionsLink)) != nil
        s.initialized = fm.fileExists(atPath: Paths.backupLatest.path) && isLink
        s.current = (try? String(contentsOf: Paths.stateDir.appendingPathComponent("current")))?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        s.parked = Set((try? fm.contentsOfDirectory(atPath: Paths.profilesDir.path)) ?? [])
        s.pendingAdd = s.current == nil && fm.fileExists(atPath: Paths.stateDir.appendingPathComponent("last_parked").path)
        return s
    }
}

/// 调用 scripts/claude_profiles.sh。所有对 Claude 数据目录的改动都走这里，便于按回退手册撤销。
enum ProfileService {
    static func run(_ args: [String], settings: Settings) -> SessionService.RunResult {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/bin/bash")
        p.arguments = [Paths.profilesScript] + args
        var env = ProcessInfo.processInfo.environment
        env["RESTORE_PYTHON"] = settings.pythonPath
        env["RESTORE_SCRIPT"] = Paths.restoreScript
        p.environment = env
        let pipe = Pipe()
        p.standardOutput = pipe
        p.standardError = pipe
        do { try p.run() } catch {
            return .init(ok: false, output: "无法运行 \(Paths.profilesScript)：\(error.localizedDescription)")
        }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        return .init(ok: p.terminationStatus == 0, output: String(decoding: data, as: UTF8.self))
    }

    /// 依次执行多条子命令，任何一条失败就停下。
    static func runChain(_ steps: [[String]], settings: Settings) -> SessionService.RunResult {
        var out = ""
        for step in steps {
            let r = run(step, settings: settings)
            out += r.output
            if !r.ok { return .init(ok: false, output: out) }
        }
        return .init(ok: true, output: out)
    }
}

/// 从 Claude Code 命令行的配置里收集「账户ID → 邮箱」。只读 oauthAccount 里的这两个字段，
/// 不碰任何令牌。命令行登录过哪个账号就能认出哪个，收集到的会存进设置，换号后也不会丢。
enum EmailHarvester {
    static func harvest() -> (String, String)? {
        guard let data = try? Data(contentsOf: Paths.cliConfig),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let acct = obj["oauthAccount"] as? [String: Any],
              let id = acct["accountUuid"] as? String, let email = acct["emailAddress"] as? String else { return nil }
        return (id, email)
    }
}

/// 在独立进程里跑 claude_profiles.sh：输出写到 ClaudeSwitch/last_run.log，菜单栏程序退出也不会中断。
/// 结束时日志末尾写一行 __DONE__ <退出码>，菜单栏程序轮询这个文件显示进度。
enum DetachedRun {
    static var logFile: URL { Paths.toolDir.appendingPathComponent("last_run.log") }

    static func start(_ args: [String], settings: Settings) -> Bool {
        try? FileManager.default.createDirectory(at: Paths.toolDir, withIntermediateDirectories: true)
        FileManager.default.createFile(atPath: logFile.path, contents: Data())
        guard let fh = try? FileHandle(forWritingTo: logFile) else { return false }
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/bin/bash")
        // 子进程输出到文件而不是管道：父进程退出时不会因为管道断开被系统结束
        p.arguments = ["-c", "\"$0\" \"$@\"; echo \"__DONE__ $?\"", Paths.profilesScript] + args
        var env = ProcessInfo.processInfo.environment
        env["RESTORE_PYTHON"] = settings.pythonPath
        env["RESTORE_SCRIPT"] = Paths.restoreScript
        p.environment = env
        p.standardOutput = fh
        p.standardError = fh
        p.standardInput = FileHandle.nullDevice
        do { try p.run() } catch { return false }
        return true
    }

    /// (是否结束, 是否成功, 去掉结束标记后的日志)
    static func poll() -> (done: Bool, ok: Bool, log: String) {
        let text = (try? String(contentsOf: logFile)) ?? ""
        guard let r = text.range(of: "__DONE__ ") else { return (false, false, text) }
        let code = text[r.upperBound...].trimmingCharacters(in: .whitespacesAndNewlines)
        return (true, code == "0", String(text[..<r.lowerBound]))
    }
}
