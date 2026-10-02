import SwiftUI

/// ClaudeSwitch：Claude Desktop 多账号的菜单栏工具。
/// 展示各账号额度（可联网刷新）、近期会话同步，以及账号添加与一次重启的切换；
/// 账号添加与切换在独立进程中执行，菜单栏程序退出也不会中断。工程说明与回退方法见 README.md。
///
/// 自检：`ClaudeSwitch --snapshot out.png` 用真实数据离屏渲染一次面板并退出，不常驻。
@main
struct Entry {
    static func main() {
        let args = CommandLine.arguments
        if let i = args.firstIndex(of: "--snapshot"), i + 1 < args.count {
            MainActor.assumeIsolated { Snapshot.render(to: args[i + 1]) }
            return
        }
        if let i = args.firstIndex(of: "--probe") {
            let dir = i + 1 < args.count ? URL(fileURLWithPath: args[i + 1]) : Paths.claudeDir
            let sem = DispatchSemaphore(value: 0)
            Task.detached { await Probe.run(profileDir: dir); sem.signal() }
            sem.wait()
            return
        }
        ClaudeSwitchApp.main()
    }
}

struct ClaudeSwitchApp: App {
    @StateObject private var model = AppModel()

    var body: some Scene {
        MenuBarExtra {
            PanelView().environmentObject(model)
        } label: {
            Image(systemName: "person.2.circle")
            if model.jobTitle != nil {
                Text("处理中…")
            } else if model.profile.pendingAdd {
                Text("等待登录")
            } else if let cur = model.currentAccount {
                let r = model.readings(cur).five
                let stale = r.resetsAt.map { $0 <= Date() && (r.at ?? .distantPast) < $0 } ?? false
                if let pct = stale ? 0 : r.pct { Text("\(pct)%") }
            }
        }
        .menuBarExtraStyle(.window)
    }
}

@MainActor
enum Snapshot {
    static func render(to path: String) {
        let model = AppModel(autoRefresh: false)
        model.refreshUsage()
        let (snap, err) = SessionService.snapshot(current: nil, settings: model.settings)
        model.snapshot = snap
        model.errorText = err
        model.selected = Set((snap?.candidates ?? []).filter { $0.interrupted }.map { $0.id })
        // 自检用：用环境变量模拟已停放账号、切换目标、等待登录三种状态
        let env = ProcessInfo.processInfo.environment
        if env["CS_SNAP_LIVE"] == "1", let cur = model.currentAccount {
            // 走与刷新按钮相同的取数函数，只请求当前账号
            let sem = DispatchSemaphore(value: 0)
            var result: Result<LiveUsage, Error>?
            Task.detached {
                do { result = .success(try await LiveUsageService.fetch(accountId: cur.accountId, orgId: cur.orgId, profileDir: Paths.claudeDir, previous: nil)) }
                catch { result = .failure(error) }
                sem.signal()
            }
            sem.wait()
            switch result {
            case .success(let r)?: model.live[cur.accountId] = r; print("联网刷新成功：5h \(r.fiveHour ?? -1)% 7d \(r.sevenDay ?? -1)% 扣费 \(r.nextChargeDate ?? "-")")
            case .failure(let e)?: model.refreshError[cur.accountId] = String(describing: e); print("联网刷新失败：\(e)")
            case nil: break
            }
        }
        if let parked = env["CS_SNAP_PARKED"] { model.profile.parked = Set(parked.split(separator: ",").map(String.init)) }
        if env["CS_SNAP_PENDING"] == "1" { model.profile.pendingAdd = true; model.settings.pendingAddTarget = env["CS_SNAP_TARGET"] }
        else if let t = env["CS_SNAP_TARGET"] {
            model.switchTarget = t
            model.targetSnapshot = SessionService.snapshot(target: t, settings: model.settings)
            model.selected = Set((model.targetSnapshot?.candidates ?? []).prefix(2).map { $0.id })
        }
        // 用真实 AppKit 视图渲染（含 ScrollView 等原生控件），与菜单栏里看到的一致
        _ = NSApplication.shared
        let view = NSHostingView(rootView: PanelView().environmentObject(model))
        view.frame = NSRect(origin: .zero, size: view.fittingSize)
        let window = NSWindow(contentRect: view.frame, styleMask: [.borderless], backing: .buffered, defer: false)
        window.contentView = view
        view.layoutSubtreeIfNeeded()
        RunLoop.main.run(until: Date().addingTimeInterval(0.5))
        guard let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { print("渲染失败"); exit(1) }
        view.cacheDisplay(in: view.bounds, to: rep)
        guard let png = rep.representation(using: .png, properties: [:]) else { print("渲染失败"); exit(1) }
        try? png.write(to: URL(fileURLWithPath: path))
        print("已写出 \(path)，账号 \(snap?.accounts.count ?? 0) 个，会话 \(snap?.sessions.count ?? 0) 个，错误：\(err ?? "无")")
    }
}
