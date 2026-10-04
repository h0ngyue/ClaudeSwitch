import AppKit
import Foundation
import SwiftUI

/// 菜单栏面板的状态中心：账号、用量、会话、切换流程与操作反馈。
@MainActor
final class AppModel: ObservableObject {
    @Published var settings = Settings.load()
    @Published var snapshot: SessionsSnapshot?
    @Published var profile = ProfileState.load()
    @Published var usage: [String: UsageSample] = [:]
    @Published var live: [String: LiveUsage] = LiveUsageService.loadCache()   // 账户ID -> 联网查到的额度
    @Published var refreshing: Set<String> = []        // 正在刷新的账户ID
    @Published var refreshError: [String: String] = [:]   // 账户ID -> 上次刷新失败原因
    @Published var selected: Set<String> = []          // 勾选的会话 ID
    @Published var switchTarget: String?               // 选好要切换过去的账户ID
    @Published var targetSnapshot: SessionsSnapshot?   // 相对切换目标计算的可同步会话
    @Published var message: String?
    @Published var errorText: String?
    @Published var busy = false
    @Published var jobTitle: String?        // 正在后台进行的操作（添加 / 切换 / 放弃），菜单栏会显示
    @Published var jobLog = ""              // 后台操作的实时输出

    private var tickTimer: Timer?           // 有后台操作或等待登录时每 2 秒，平时每 5 分钟：轮询进度、检测登录、发现本地用量采样更新
    private var liveTimer: Timer?           // 每 10~15 分钟（随机）联网刷新一次当前账号
    private var detecting = false
    private var usageFileDate: Date?        // 上次读取时 plan-usage-history.json 的修改时间
    private var lastCurrentId: String?      // 上次会话刷新时认定的当前账号，用来发现换号
    private var currentKnown = false        // 程序启动后是否已经认过一次当前账号

    init(autoRefresh: Bool = true) {
        dropLegacyAliases()
        harvestEmail()
        guard autoRefresh else { return }
        refreshUsage()
        refresh()
        if !profile.pendingAdd && settings.pendingAddTarget != nil {   // 上次添加没走到停放那一步，清掉残留
            settings.pendingAddTarget = nil
            settings.save()
        }
        resumeJobIfRunning()
        armTick()
        armLiveTimer()
    }

    // MARK: 账号与命名

    /// 当前登录的账户：切号脚本记录的优先，其次按「最近被写入的会话索引」推断。
    /// 等待登录新账号期间认不出当前账号，返回 nil。
    var currentAccountId: String? {
        profile.pendingAdd ? nil : (profile.current ?? snapshot?.currentAccountId)
    }
    var currentAccount: AccountInfo? { allAccounts.first { $0.accountId == currentAccountId } }

    /// 交给会话同步脚本的目标：账号已有会话目录时用账户 ID；还没有时写「账户ID/组织ID」，复制时再新建目录。
    func restoreTarget(_ id: String) -> String {
        if snapshot?.accounts.contains(where: { $0.accountId == id }) ?? false { return id }
        if let org = settings.orgs[id] { return "\(id)/\(org)" }
        return id
    }

    /// 一个额度窗口要显示的值：联网结果与本地采样（只有当前账号会更新）谁新用谁。
    struct Reading {
        let pct: Int?               // 已用 %
        let at: Date?               // 这个数值的取得时间
        let resetsAt: Date?         // 上次联网查到的重置时刻
        let window: TimeInterval    // 窗口长度：5 小时或 7 天

        /// 按现在的时间换算出来的显示值。inferred 为真表示数值是推断的，不是查到的。
        struct Shown { let left: Int?; let resetsAt: Date?; let inferred: Bool }

        /// 数值取得之后已经过了一次重置，说明它属于上一个窗口：按剩余 100% 显示并标「推断」。
        /// 重置时刻优先用联网查到的；没有时（只有本地采样）用「取得时间 + 窗口长度」——
        /// 用量大于 0 说明取得时窗口已开始计时，最晚一个窗口长度后就会重置。
        /// 期间若在网页、手机上用过这个账号，实际会比推断的少，所以要标出来，点刷新可拿到准确值。
        func shown(at now: Date) -> Shown {
            let left = pct.map { max(0, 100 - $0) }
            guard let at else { return Shown(left: left, resetsAt: resetsAt, inferred: false) }
            // 重置时刻不晚于取得时间：数值是重置后取得的（本地采样比联网结果新），手上的重置时刻已作废
            let known = resetsAt.flatMap { $0 > at ? $0 : nil }
            let end = known ?? ((pct ?? 0) > 0 ? at.addingTimeInterval(window) : nil)
            if let end, end <= now { return Shown(left: 100, resetsAt: nil, inferred: true) }
            return Shown(left: left, resetsAt: known, inferred: false)
        }
    }

    func readings(_ account: AccountInfo) -> (five: Reading, seven: Reading) {
        let l = live[account.accountId], s = usage[account.orgId]
        let useLive = l != nil && (s == nil || l!.fetchedAt >= s!.at)
        let at = useLive ? l?.fetchedAt : s?.at
        return (Reading(pct: useLive ? l?.fiveHour : s?.fiveHour, at: at, resetsAt: l?.fiveHourResetsAt, window: 5 * 3600),
                Reading(pct: useLive ? l?.sevenDay : s?.sevenDay, at: at, resetsAt: l?.sevenDayResetsAt, window: 7 * 24 * 3600))
    }

    /// 记下联网识别到的邮箱与组织 ID。
    private func remember(_ who: (uuid: String, email: String?, orgId: String?)) {
        if let e = who.email { settings.emails[who.uuid] = e }
        if let o = who.orgId { settings.orgs[who.uuid] = o }
        settings.save()
    }

    /// 会话目录里出现过的账号，加上已保存登录态但还没用过 Code 页的账号（组织 ID 取联网识别时记下的）。
    var allAccounts: [AccountInfo] {
        var list = snapshot?.accounts ?? []
        let known = Set(list.map { $0.accountId })
        for id in ([profile.current].compactMap { $0 } + profile.parked) where !known.contains(id) {
            list.append(AccountInfo(accountId: id, orgId: settings.orgs[id] ?? "", sessionCount: 0, isCurrent: id == currentAccountId))
        }
        return list
    }

    var orderedAccounts: [AccountInfo] {
        allAccounts.sorted { a, b in
            let ac = a.accountId == currentAccountId, bc = b.accountId == currentAccountId
            return ac != bc ? ac : displayName(a.accountId) < displayName(b.accountId)
        }
    }

    func shortId(_ id: String) -> String { String(id.prefix(8)).uppercased() }

    /// 显示名：你起的名字 > 邮箱 > 账户ID 前 8 位。
    func displayName(_ id: String) -> String { settings.aliases[id] ?? settings.emails[id] ?? shortId(id) }

    func subtitle(_ id: String) -> String {
        let email = settings.emails[id]
        if settings.aliases[id] != nil { return email ?? "ID \(shortId(id))" }
        return email == nil ? "邮箱未知，可点铅笔起名" : "ID \(shortId(id))"
    }

    func avatarText(_ id: String) -> String { String(displayName(id).prefix(1)).uppercased() }

    func rename(_ id: String, to name: String) {
        let t = name.trimmingCharacters(in: .whitespaces)
        settings.aliases[id] = (t.isEmpty || t == settings.emails[id] || t == shortId(id)) ? nil : t
        settings.save()
    }

    /// 记下 App Store 订阅的购买时间（北京时间字符串），传 nil 清除。
    func setPurchase(_ id: String, _ value: String?) {
        settings.purchases[id] = value
        settings.save()
    }

    /// App Store 订阅查不到到期日时，按填的购买时间推算下一个续费时刻。
    /// 苹果的规则：按月订阅在购买日期的同一天续费；下个月没有这一天（如 1 月 31 日买）就在月底续，
    /// 之后再回到原来的日期（2 月 28 日之后是 3 月 31 日）——从购买日加 N 个月正好是这个效果。
    /// 只填了日期时按北京时间当天 0 点算，hasTime 为假，倒计时只精确到天。
    static func inferredRenewal(_ purchase: String, now: Date = Date()) -> (at: Date, hasTime: Bool)? {
        let hasTime = purchase.count > 10
        let f = DateFormatter()
        f.timeZone = TimeZone(identifier: "Asia/Shanghai")
        f.dateFormat = hasTime ? "yyyy-MM-dd HH:mm" : "yyyy-MM-dd"
        guard let start = f.date(from: purchase) else { return nil }
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = f.timeZone
        // 只有日期时，续费当天整天都还算「今天到期」
        let today = cal.startOfDay(for: now)
        for n in 1...1200 {
            guard let d = cal.date(byAdding: .month, value: n, to: start) else { return nil }
            if hasTime ? d > now : d >= today { return (d, hasTime) }
        }
        return nil
    }

    /// 早期版本会把「账号 XXXX」这种默认名误存成别名，清掉。
    private func dropLegacyAliases() {
        let legacy = settings.aliases.filter { $0.value == "账号 " + $0.key.prefix(4).uppercased() }
        guard !legacy.isEmpty else { return }
        legacy.keys.forEach { settings.aliases[$0] = nil }
        settings.save()
    }

    private func harvestEmail() {
        guard let (id, email) = EmailHarvester.harvest(), settings.emails[id] != email else { return }
        settings.emails[id] = email
        settings.save()
    }

    // MARK: 刷新

    func refreshUsage() {
        usageFileDate = Self.usageFileModified()
        usage = UsageReader.latestByOrg()
    }

    private static func usageFileModified() -> Date? {
        (try? FileManager.default.attributesOfItem(atPath: Paths.usageHistory.path))?[.modificationDate] as? Date
    }

    /// Desktop 写了新的用量采样就读进来，只看文件修改时间，不联网。Desktop 只在 24 小时内打开过
    /// 它自己的用量弹窗时才每 15 分钟采样一次，否则只在启动时采一次，所以还要靠 armLiveTimer 联网补上。
    private func reloadUsageIfChanged() {
        let m = Self.usageFileModified()
        if m != usageFileDate { refreshUsage() }
    }

    /// 换号后自动联网刷新一次新的当前账号（只请求这一个账号）：Desktop 刚登录时不一定马上写本地采样，
    /// 而且本地采样没有重置时间。程序刚启动时的第一次认定不算换号，不发请求。
    private func refreshIfCurrentChanged() {
        let cur = currentAccountId
        defer { lastCurrentId = cur; currentKnown = true }
        guard currentKnown, let cur, cur != lastCurrentId,
              let acct = currentAccount, !acct.orgId.isEmpty else { return }
        refreshAccount(acct)
    }

    /// 这个账号的登录目录：当前账号在 Claude/，停放的在 profiles/<账户ID>/，其余还没保存登录态。
    func profileDir(_ id: String) -> URL? {
        if id == currentAccountId { return Paths.claudeDir }
        if profile.parked.contains(id) { return Paths.profilesDir.appendingPathComponent(id) }
        return nil
    }

    /// 单个账号刷新：用这个账号自己的登录 cookie 联网查额度。点按钮、刚换号、当前账号定时自动刷新时发生，每次只发 1 个请求。
    func refreshAccount(_ account: AccountInfo) {
        let id = account.accountId
        guard !refreshing.contains(id) else { return }
        refreshing.insert(id)
        usage[account.orgId] = UsageReader.latestByOrg()[account.orgId]
        let dir = profileDir(id)
        Task {
            let started = Date()
            do {
                guard let dir else { throw LiveUsageService.Failure.noProfile }
                let r = try await LiveUsageService.fetch(accountId: id, orgId: account.orgId, profileDir: dir, previous: live[id])
                live[id] = r
                LiveUsageService.saveCache(live)
                refreshError[id] = nil
                if let e = r.email, settings.emails[id] != e { settings.emails[id] = e; settings.save() }
            } catch {
                refreshError[id] = String(describing: error)
            }
            // 转圈至少 0.6 秒，让你看得到刷新发生了
            let left = 0.6 - Date().timeIntervalSince(started)
            if left > 0 { try? await Task.sleep(nanoseconds: UInt64(left * 1_000_000_000)) }
            refreshing.remove(id)
        }
    }

    /// 刷新会话列表与账号目录状态（都是读本地文件）。
    func refresh() {
        harvestEmail()
        profile = ProfileState.load()
        // 当前账号已知时明确告诉脚本，否则它按「最近写入的会话」推断，新账号还没会话时会认错
        let s = settings, cur = profile.pendingAdd ? nil : profile.current.map(restoreTarget)
        let target = switchTarget.map(restoreTarget)
        Task.detached {
            let (snap, err) = SessionService.snapshot(current: cur, settings: s)
            let tsnap = target.flatMap { SessionService.snapshot(target: $0, settings: s) }
            await MainActor.run {
                self.snapshot = snap ?? self.snapshot
                self.targetSnapshot = tsnap
                if let err { self.errorText = err }   // 不覆盖上一步操作留下的报错
                self.resetSelection()
                self.reloadUsageIfChanged()
                self.refreshIfCurrentChanged()
            }
        }
    }

    // MARK: 会话

    /// 当前模式下可同步的会话：选了切换目标就相对目标计算，否则相对当前账号。
    var activeCandidates: [SessionInfo] {
        switchTarget == nil ? (snapshot?.candidates ?? []) : (targetSnapshot?.candidates ?? [])
    }
    var candidateIds: Set<String> { Set(activeCandidates.map { $0.id }) }

    /// 默认勾选被额度打断的会话，与 Skill 的挑选规则一致。
    private func resetSelection() {
        selected = Set(activeCandidates.filter { $0.interrupted }.map { $0.id })
    }

    func syncSelected() {
        let picks = activeCandidates.filter { selected.contains($0.id) }
        guard let cur = currentAccountId, !picks.isEmpty else { return }
        let to = restoreTarget(cur)
        perform { SessionService.copy(picks, to: to, settings: $0) }
    }

    func undoLastSync() { perform { SessionService.undo(settings: $0) } }

    func restartDesktop() {
        guard confirm("重启 Claude Desktop？", "等同 ⌘Q 后重新打开，正在运行的 Code 会话会中断。") else { return }
        busy = true
        message = "正在退出 Claude Desktop…"
        DesktopControl.quitAndRelaunch { ok in
            self.busy = false
            self.message = ok ? "Desktop 已重新打开。进入恢复的会话后第一句先发 /compact。"
                              : "Desktop 没有在 30 秒内退出，请手动 ⌘Q 后再打开。"
        }
    }

    // MARK: 切换（一次重启完成换号 + 同步）

    func beginSwitch(_ target: String) {
        switchTarget = target
        targetSnapshot = nil
        selected = []
        refresh()
    }

    func cancelSwitch() {
        switchTarget = nil
        targetSnapshot = nil
        resetSelection()
    }

    func confirmSwitch() {
        guard let target = switchTarget else { return }
        let picks = activeCandidates.filter { selected.contains($0.id) }
        let text = "将退出 Claude Desktop（正在运行的 Code 会话会中断），"
            + (picks.isEmpty ? "" : "把 \(picks.count) 个会话同步给它，")
            + "换成「\(displayName(target))」的登录目录后重新打开。只重启一次。\n\n回退方法见 ClaudeSwitch/回退手册.md。"
        guard confirm("切换到「\(displayName(target))」？", text) else { return }
        switchTarget = nil
        targetSnapshot = nil
        let to = restoreTarget(target)
        let org = to.contains("/") ? ["--org=" + to.split(separator: "/")[1]] : []
        startJob("正在切换到「\(displayName(target))」", ["switch", target] + org + picks.map { $0.cliSessionId })
    }

    // MARK: 添加账号（停放当前账号，在空白目录里登录一次）

    /// target 为 nil 表示添加一个工具还不认识的新账号（面板底部的「添加账号」）。
    func beginAdd(_ target: String?) {
        let name = target.map { "「\(displayName($0))」" } ?? "要添加的账号"
        guard let cur = currentAccountId else { errorText = "认不出当前登录的是哪个账号，先在 Desktop 里用一下 Code 页"; return }
        var steps = ["Claude Desktop 自动退出（正在运行的 Code 会话会中断）"]
        if !profile.initialized { steps.append("首次使用：备份 Desktop 数据目录（约 1G），整理会话目录，需要十几秒到半分钟") }
        steps += ["把当前账号「\(displayName(cur))」的登录信息保存起来",
                  "Desktop 自动重新打开，显示登录页",
                  "你在登录页登录\(name)（输入邮箱、收验证码，这是最后一次）",
                  "工具自动识别登录成功并保存，弹出通知；之后点「切换」即可直接换号"]
        let text = steps.enumerated().map { "\($0.offset + 1). \($0.element)" }.joined(separator: "\n")
            + "\n\n进度显示在菜单栏图标旁。中途想放弃：面板顶部点「放弃添加」，原账号会放回来。\n回退方法见 ClaudeSwitch/回退手册.md。"
        guard confirm("添加账号" + (target == nil ? "" : name), text) else { return }
        settings.pendingAddTarget = target
        settings.save()
        busy = true
        jobTitle = "正在核对当前账号"
        Task {
            // 用登录 cookie 核对 Claude/ 里到底是哪个账号，避免按推断结果给目录起错名字
            var alias = profile.current ?? cur
            if let who = await LiveUsageService.whoami(profileDir: Paths.claudeDir) {
                if profile.current == nil { alias = who.uuid }
                remember(who)
            }
            startJob("正在准备登录页", ["add-begin", alias])
        }
    }

    /// 等待登录期间每 2 秒在本地检查一次：登录 cookie 出现后才联网识别一次账号，然后自动保存。
    private func detectLogin() {
        guard profile.pendingAdd, jobTitle == nil, !detecting,
              (try? CookieReader.sessionKey(profileDir: Paths.claudeDir)) != nil else { return }
        detecting = true
        Task {
            defer { detecting = false }
            guard let who = await LiveUsageService.whoami(profileDir: Paths.claudeDir) else { return }
            remember(who)
            if profile.parked.contains(who.uuid) {
                errorText = "你登录的是已经保存过的账号「\(displayName(who.uuid))」。请在 Desktop 里退出登录，再登录要添加的账号。"
                return
            }
            confirmAdded(who.uuid)
        }
    }

    /// 自动识别失败时的手动兜底。
    func confirmAddedAuto() {
        busy = true
        Task {
            guard let who = await LiveUsageService.whoami(profileDir: Paths.claudeDir) else {
                busy = false
                errorText = "还没检测到登录（登录信息可能要过十几秒才写入磁盘）。稍等再试，或在下面手动选择。"
                return
            }
            remember(who)
            confirmAdded(who.uuid)
        }
    }

    func confirmAdded(_ accountId: String) {
        settings.pendingAddTarget = nil
        settings.save()
        let r = ProfileService.run(["name", accountId], settings: settings)
        if r.ok {
            message = "已添加「\(displayName(accountId))」，以后点它的「切换」即可直接换号。"
            errorText = nil
            notify("已添加「\(displayName(accountId))」，以后可以一键切换")
        } else {
            errorText = r.output
        }
        busy = false
        refresh()
    }

    func cancelAdd() {
        guard confirm("放弃添加？", "会退出 Desktop，把空白登录目录挪到 ClaudeSwitch/aborted-*（不删），原账号放回后重新打开。") else { return }
        settings.pendingAddTarget = nil
        settings.save()
        startJob("正在放弃添加并放回原账号", ["cancel-add"])
    }

    // MARK: 后台操作

    private static let jobMarker = Paths.toolDir.appendingPathComponent("job_title")

    private func startJob(_ title: String, _ args: [String]) {
        busy = true
        jobTitle = title
        jobLog = ""
        try? title.write(to: Self.jobMarker, atomically: true, encoding: .utf8)
        if !DetachedRun.start(args, settings: settings) {
            finishJob(ok: false, log: "无法启动后台操作")
        }
        armTick()
    }

    /// 菜单栏程序重开时，接上还没结束的后台操作。
    private func resumeJobIfRunning() {
        guard let title = try? String(contentsOf: Self.jobMarker) else { return }
        if DetachedRun.poll().done { try? FileManager.default.removeItem(at: Self.jobMarker); return }
        busy = true
        jobTitle = title
    }

    private func finishJob(ok: Bool, log: String) {
        try? FileManager.default.removeItem(at: Self.jobMarker)
        jobTitle = nil
        busy = false
        let out = log.trimmingCharacters(in: .whitespacesAndNewlines)
        if ok { message = out.split(separator: "\n").suffix(3).joined(separator: "\n"); errorText = nil }
        else { errorText = out }
        refresh()
    }

    private func tick() {
        reloadUsageIfChanged()
        if jobTitle != nil, FileManager.default.fileExists(atPath: Self.jobMarker.path) {
            let r = DetachedRun.poll()
            jobLog = r.log
            if r.done { finishJob(ok: r.ok, log: r.log) }
        } else {
            let wasPending = profile.pendingAdd
            profile = ProfileState.load()
            if wasPending != profile.pendingAdd { refresh() }
            detectLogin()
        }
        armTick()
    }

    /// 有后台操作或在等登录时每 2 秒看一次进度；平时没什么要盯的，每 5 分钟看一次本地用量文件即可。
    private func armTick() {
        tickTimer?.invalidate()
        let watching = jobTitle != nil || profile.pendingAdd
        tickTimer = schedule(after: watching ? 2 : 300) { $0.tick() }
    }

    /// 当前账号每 10~15 分钟联网刷新一次额度，间隔每次随机，不形成固定节奏；只查当前这一个账号。
    /// 期间刚手动刷新过或刚换号刷新过（10 分钟内）就跳过这一轮。
    private func armLiveTimer() {
        liveTimer?.invalidate()
        liveTimer = schedule(after: .random(in: 600...900)) { m in
            defer { m.armLiveTimer() }
            guard m.jobTitle == nil, !m.profile.pendingAdd,
                  let acct = m.currentAccount, !acct.orgId.isEmpty else { return }
            if let at = m.live[acct.accountId]?.fetchedAt, Date().timeIntervalSince(at) < 600 { return }
            m.refreshAccount(acct)
        }
    }

    /// 一次性定时器；加到 common 模式，面板展开时也照常触发。
    private func schedule(after seconds: TimeInterval, _ action: @escaping @MainActor (AppModel) -> Void) -> Timer {
        let t = Timer(timeInterval: seconds, repeats: false) { [weak self] _ in
            Task { @MainActor in if let self { action(self) } }
        }
        RunLoop.main.add(t, forMode: .common)
        return t
    }

    private func notify(_ text: String) {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
        p.arguments = ["-e", "display notification \"\(text)\" with title \"ClaudeSwitch\""]
        try? p.run()
    }

    // MARK: 工具

    private func confirm(_ title: String, _ text: String) -> Bool {
        NSApp.activate(ignoringOtherApps: true)
        let a = NSAlert()
        a.messageText = title
        a.informativeText = text
        a.addButton(withTitle: "确定")
        a.addButton(withTitle: "取消")
        // 菜单栏浮窗层级（popUpMenu）高于弹窗，而 runModal 期间弹窗层级被锁在 modalPanel，
        // 只能先把浮窗临时降到弹窗之下，结束后恢复，否则弹窗会被压在浮窗后面
        let lowered = NSApp.windows.filter { $0.isVisible && $0.level >= .modalPanel }.map { ($0, $0.level) }
        lowered.forEach { $0.0.level = .floating }
        defer { lowered.forEach { $0.0.level = $0.1 } }
        return a.runModal() == .alertFirstButtonReturn
    }

    private func perform(endSwitch: Bool = false, _ job: @escaping (Settings) -> SessionService.RunResult) {
        busy = true
        let s = settings
        Task.detached {
            let r = job(s)
            await MainActor.run {
                self.busy = false
                let out = r.output.trimmingCharacters(in: .whitespacesAndNewlines)
                if r.ok { self.message = out; self.errorText = nil } else { self.errorText = out }
                if endSwitch && r.ok { self.switchTarget = nil; self.targetSnapshot = nil }
                self.refresh()
            }
        }
    }
}
