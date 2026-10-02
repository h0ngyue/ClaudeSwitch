import SwiftUI

// 视觉参考 cc-switch：浅底 + 白色圆角卡片 + 细阴影 + 彩色头像 + 绿色「当前使用」徽标。

private let palette: [Color] = [.orange, .blue, .purple, .teal, .pink, .indigo]

private func avatarColor(_ id: String) -> Color {
    // hashValue 每次启动随机，用字符码求和保证颜色稳定
    palette[id.unicodeScalars.reduce(0) { $0 + Int($1.value) } % palette.count]
}

private func usageColor(_ pct: Int) -> Color {
    pct >= 85 ? .red : (pct >= 60 ? .orange : .green)
}

private func relative(_ d: Date) -> String {
    if abs(d.timeIntervalSinceNow) < 10 { return "刚刚" }
    let f = RelativeDateTimeFormatter()
    f.locale = Locale(identifier: "zh_CN")
    f.unitsStyle = .short
    return f.localizedString(for: d, relativeTo: Date())
}

struct Card<Content: View>: View {
    @ViewBuilder var content: Content
    var body: some View {
        content
            .padding(12)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(RoundedRectangle(cornerRadius: 10).fill(Color(nsColor: .controlBackgroundColor)))
            .overlay(RoundedRectangle(cornerRadius: 10).stroke(Color.primary.opacity(0.06)))
            .shadow(color: .black.opacity(0.05), radius: 2, y: 1)
    }
}

/// 自绘按钮：prominent 为蓝底白字，否则浅灰底。
struct PillButtonStyle: ButtonStyle {
    var prominent = false
    @Environment(\.isEnabled) private var enabled
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.caption.weight(.medium))
            .padding(.horizontal, 10).padding(.vertical, 5)
            .background(RoundedRectangle(cornerRadius: 6)
                .fill(prominent ? Color.accentColor : Color.primary.opacity(0.07)))
            .foregroundStyle(prominent ? Color.white : Color.primary)
            .opacity(enabled ? (configuration.isPressed ? 0.7 : 1) : 0.4)
    }
}

struct IconButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .frame(width: 26, height: 26)
            .background(RoundedRectangle(cornerRadius: 6).fill(Color.primary.opacity(configuration.isPressed ? 0.12 : 0.05)))
            .foregroundStyle(.secondary)
    }
}

/// 布局照 Desktop 设置页的「Plan usage limits」：上一行左边名称、右边重置时间 + 已用百分比，下一行整宽进度条。
/// 进度条颜色按已用比例由绿到橙到红。重置倒计时用上次联网查到的重置时刻在本地每分钟重算，不联网；
/// 过了重置时刻、手上的数值又是重置前取得的，按 0% 显示（额度窗口已重新开始），点刷新可拿到准确值。
struct UsageBar: View {
    let label: String
    let reading: AppModel.Reading
    /// 给了窗口长度（每周额度传 7 天）就在下面多画一行「时间已过多少」，方便和用量对比快慢。
    var window: TimeInterval? = nil
    var body: some View {
        TimelineView(.everyMinute) { ctx in
            let resetsAt = reading.resetsAt
            // 数值取得时间早于重置时刻、而现在已过重置时刻，说明这个值属于上一个窗口
            let passed = resetsAt.map { $0 <= ctx.date && (reading.at ?? .distantPast) < $0 } ?? false
            let shown = passed ? 0 : reading.pct
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 8) {
                    Text(label).font(.callout)
                    Spacer(minLength: 4)
                    if let r = resetsAt { Text(resetText(r, now: ctx.date)).font(.caption).foregroundStyle(.secondary) }
                    Text(shown.map { "\($0)%" } ?? "—").font(.callout.monospacedDigit()).foregroundStyle(.secondary)
                }
                GeometryReader { g in
                    ZStack(alignment: .leading) {
                        Capsule().fill(Color.primary.opacity(0.08))
                        Capsule().fill(usageColor(shown ?? 0).gradient)
                            .frame(width: g.size.width * CGFloat(min(shown ?? 0, 100)) / 100)
                    }
                }
                .frame(height: 6)
                if let w = window, let r = resetsAt, !passed {
                    timeProgress(elapsed: elapsedPct(resetsAt: r, window: w, now: ctx.date), used: shown ?? 0)
                }
            }
        }
    }

    /// 窗口从「重置时刻往前推一个窗口长度」开始，算现在走过了多少。
    private func elapsedPct(resetsAt: Date, window: TimeInterval, now: Date) -> Int {
        let done = window - resetsAt.timeIntervalSince(now)
        return max(0, min(100, Int((done / window * 100).rounded())))
    }

    /// 灰色细条表示时间进度，右侧写用量比时间快还是慢。
    private func timeProgress(elapsed: Int, used: Int) -> some View {
        let diff = used - elapsed
        let pace = diff > 5 ? "比时间快 \(diff)%" : (diff < -5 ? "比时间慢 \(-diff)%" : "和时间同步")
        return VStack(alignment: .leading, spacing: 3) {
            HStack(spacing: 8) {
                Text("本周时间已过").font(.caption).foregroundStyle(.secondary)
                Spacer(minLength: 4)
                Text("用量" + pace).font(.caption).foregroundStyle(diff > 5 ? Color.orange : Color.secondary)
                Text("\(elapsed)%").font(.caption.monospacedDigit()).foregroundStyle(.secondary)
            }
            GeometryReader { g in
                ZStack(alignment: .leading) {
                    Capsule().fill(Color.primary.opacity(0.08))
                    Capsule().fill(Color.secondary.opacity(0.6))
                        .frame(width: g.size.width * CGFloat(elapsed) / 100)
                }
            }
            .frame(height: 3)
        }
        .padding(.top, 2)
    }

    /// 一天内写「x 小时 y 分后重置」，更远写「周一 08:00 重置（2 天 16 小时后）」。
    private func resetText(_ d: Date, now: Date) -> String {
        let s = Int(d.timeIntervalSince(now))
        if s <= 0 { return "已重置，点刷新更新" }
        let day = s / 86400, h = s % 86400 / 3600, m = s % 3600 / 60
        if day == 0 { return h > 0 ? "\(h) 小时 \(m) 分后重置" : "\(max(m, 1)) 分钟后重置" }
        let f = DateFormatter()
        f.locale = Locale(identifier: "zh_CN")
        f.dateFormat = "EEE HH:mm"
        return "\(f.string(from: d)) 重置（\(day) 天 \(h) 小时后）"
    }
}

struct AccountCard: View {
    @EnvironmentObject var model: AppModel
    let account: AccountInfo
    @State private var editing = false
    @State private var draft = ""

    private var id: String { account.accountId }
    private var isCurrent: Bool { id == model.currentAccountId }
    private var isTarget: Bool { id == model.switchTarget }

    var body: some View {
        let sample = model.usage[account.orgId]
        let liveData = model.live[id]
        Card {
            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 10) {
                    Circle().fill(avatarColor(id).opacity(0.18))
                        .overlay(Text(model.avatarText(id)).font(.headline).foregroundStyle(avatarColor(id)))
                        .frame(width: 30, height: 30)
                    VStack(alignment: .leading, spacing: 1) {
                        HStack(spacing: 6) {
                            if editing {
                                TextField("名字", text: $draft, onCommit: {
                                    model.rename(id, to: draft); editing = false
                                }).textFieldStyle(.roundedBorder).frame(width: 170)
                            } else {
                                Text(model.displayName(id)).font(.headline).lineLimit(1)
                                Button { draft = model.displayName(id); editing = true } label: {
                                    Image(systemName: "pencil").font(.caption)
                                }.buttonStyle(.plain).foregroundStyle(.secondary).help("改名字（清空回车恢复显示邮箱）")
                            }
                            if isCurrent { badge("当前使用", .green) }
                            if isTarget { badge("切换目标", .blue) }
                        }
                        Text(model.subtitle(id)).font(.caption2).foregroundStyle(.secondary).lineLimit(1)
                    }
                    Spacer(minLength: 4)
                    refreshButton
                    actionButton
                }
                Text(planTitle(liveData)).font(.callout).foregroundStyle(.secondary).padding(.top, 2)
                let r = model.readings(account)
                UsageBar(label: "会话限额", reading: r.five)
                UsageBar(label: "每周 · 所有模型", reading: r.seven, window: 7 * 24 * 3600)
                Text(footer(sample, liveData)).font(.caption2).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                if let err = model.refreshError[id] {
                    Text(err).font(.caption2).foregroundStyle(.red).fixedSize(horizontal: false, vertical: true)
                }
            }
        }
        .overlay(RoundedRectangle(cornerRadius: 10).stroke(Color.accentColor, lineWidth: isTarget ? 1.5 : 0))
    }

    private func badge(_ text: String, _ color: Color) -> some View {
        Text(text).font(.caption2.bold()).padding(.horizontal, 6).padding(.vertical, 2)
            .background(Capsule().fill(color.opacity(0.15))).foregroundStyle(color)
    }

    private var refreshButton: some View {
        Button { model.refreshAccount(account) } label: {
            if model.refreshing.contains(id) {
                ProgressView().controlSize(.mini)
            } else {
                Image(systemName: "arrow.clockwise").font(.caption)
            }
        }
        .buttonStyle(IconButtonStyle())
        .disabled(model.refreshing.contains(id))
        .help("联网刷新这个账号的额度、重置时间与账期（只请求这一个账号）")
    }

    @ViewBuilder private var actionButton: some View {
        if isCurrent {
            EmptyView()
        } else if model.profile.parked.contains(id) {
            if isTarget {
                Button("取消") { model.cancelSwitch() }.buttonStyle(PillButtonStyle())
            } else {
                Button("切换") { model.beginSwitch(id) }.buttonStyle(PillButtonStyle(prominent: true))
                    .disabled(model.busy || model.profile.pendingAdd)
                    .help("先在下方勾选要带过去的会话，再点底部的切换按钮，只重启一次 Desktop")
            }
        } else {
            Button("登录添加") { model.beginAdd(id) }.buttonStyle(PillButtonStyle())
                .disabled(model.busy || model.profile.pendingAdd)
                .help("这个账号还没保存登录态：需要在空白 Desktop 里登录一次，之后就能一键切换")
        }
    }

    private func footer(_ s: UsageSample?, _ l: LiveUsage?) -> String {
        let f = DateFormatter()
        if let l {
            var parts: [String] = []
            if let d = l.nextChargeDate { parts.append("下次扣费 \(d)") }
            parts.append("会话 \(account.sessionCount) 个")
            f.dateFormat = "HH:mm:ss"
            parts.append("联网刷新于 \(f.string(from: l.fetchedAt))（\(relative(l.fetchedAt))）")
            return parts.joined(separator: " · ")
        }
        var parts = ["会话 \(account.sessionCount) 个", s.map { "本地采样于\(relative($0.at))" } ?? "暂无用量采样"]
        parts.append(model.profileDir(id) == nil ? "还没保存登录态，登录添加后可联网刷新" : "点刷新按钮联网获取实时额度")
        return parts.joined(separator: " · ")
    }

    /// 「套餐用量限额 · Pro」，套餐名来自联网查到的账户信息，没查过就不写。
    private func planTitle(_ l: LiveUsage?) -> String {
        guard let p = l?.plan, !p.isEmpty else { return "套餐用量限额" }
        return "套餐用量限额 · " + p.replacingOccurrences(of: "claude_", with: "").capitalized
    }
}

struct SessionRow: View {
    @EnvironmentObject var model: AppModel
    let session: SessionInfo

    var body: some View {
        let canSync = model.candidateIds.contains(session.id)
        HStack(alignment: .top, spacing: 8) {
            if canSync {
                let on = model.selected.contains(session.id)
                Button {
                    if on { model.selected.remove(session.id) } else { model.selected.insert(session.id) }
                } label: {
                    Image(systemName: on ? "checkmark.square.fill" : "square")
                        .foregroundStyle(on ? Color.accentColor : Color.secondary)
                }.buttonStyle(.plain).frame(width: 16)
            } else {
                Image(systemName: "checkmark.circle").foregroundStyle(.tertiary).frame(width: 16)
            }
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(session.title).lineLimit(1)
                    if session.interrupted {
                        Text("被额度打断").font(.caption2.bold()).padding(.horizontal, 5).padding(.vertical, 1)
                            .background(Capsule().fill(Color.red.opacity(0.12))).foregroundStyle(.red)
                    }
                }
                Text("\(relative(session.lastActivity)) · \((session.accountIds ?? [session.accountId]).map(model.displayName).joined(separator: "、")) · \(URL(fileURLWithPath: session.cwd).lastPathComponent)")
                    .font(.caption2).foregroundStyle(.secondary).lineLimit(1)
            }
            Spacer(minLength: 0)
            Text(session.cliSessionId.prefix(8)).font(.caption2.monospaced()).foregroundStyle(.tertiary)
                .textSelection(.enabled)
        }
        .help(canSync ? "目标账号没有这个会话，可同步" : "目标账号已能看到这个会话")
    }
}

struct PanelView: View {
    @EnvironmentObject var model: AppModel

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            header
            if let title = model.jobTitle { jobCard(title) }
            if model.profile.pendingAdd && model.jobTitle == nil { pendingAddCard }
            ForEach(model.orderedAccounts) { AccountCard(account: $0) }
            HStack {
                Spacer()
                Button { model.beginAdd(nil) } label: { Label("添加账号", systemImage: "plus") }
                    .buttonStyle(PillButtonStyle())
                    .disabled(model.busy || model.profile.pendingAdd)
                    .help("保存当前账号的登录态，打开空白 Desktop 登录另一个账号；之后可一键切换")
            }
            sessionsCard
            if let msg = model.message { noticeCard(msg, color: .primary) { model.message = nil } }
            if let err = model.errorText { noticeCard(err, color: .red) { model.errorText = nil } }
        }
        .padding(14)
        .frame(width: 440)
        .background(Color(nsColor: .windowBackgroundColor))
    }

    private var header: some View {
        HStack {
            Text("Claude Switch").font(.title3.bold()).foregroundStyle(.blue)
            if model.busy { ProgressView().controlSize(.small) }
            Spacer()
            Button { model.refresh() } label: { Image(systemName: "list.bullet.rectangle") }.help("刷新近期会话列表")
            Button { NSWorkspace.shared.open(Paths.toolDir) } label: { Image(systemName: "folder") }
                .help("打开工具数据目录（设置、日志、备份）")
            Button { NSApp.terminate(nil) } label: { Image(systemName: "power") }.help("退出 ClaudeSwitch")
        }
        .buttonStyle(IconButtonStyle())
    }

    private func noticeCard(_ text: String, color: Color, dismiss: @escaping () -> Void) -> some View {
        Card {
            HStack(alignment: .top) {
                Text(text).font(.caption).foregroundStyle(color).textSelection(.enabled)
                Spacer()
                Button(action: dismiss) { Image(systemName: "xmark").font(.caption2) }.buttonStyle(.plain)
                    .foregroundStyle(.secondary)
            }
        }
    }

    /// 后台操作进行中：显示标题与最近几行输出。
    private func jobCard(_ title: String) -> some View {
        Card {
            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 8) {
                    ProgressView().controlSize(.small)
                    Text(title).font(.headline)
                }
                Text("在独立进程中执行，关掉这个面板或退出 ClaudeSwitch 都不会中断。")
                    .font(.caption2).foregroundStyle(.secondary)
                let lines = model.jobLog.split(separator: "\n").suffix(4).joined(separator: "\n")
                if !lines.isEmpty {
                    Text(lines).font(.caption2.monospaced()).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
    }

    /// 停放了原账号、等待在空白 Desktop 里登录新账号时显示。
    private var pendingAddCard: some View {
        let target = model.settings.pendingAddTarget
        let choices = (model.snapshot?.accounts ?? []).map { $0.accountId }
            .filter { !model.profile.parked.contains($0) }
        return Card {
            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 8) {
                    ProgressView().controlSize(.small)
                    Text("等待你在 Desktop 里登录").font(.headline)
                }
                Text("Desktop 现在显示的是登录页。请在里面登录\(target.map { "「\(model.displayName($0))」" } ?? "要添加的账号")，登录成功后工具会自动识别并保存（每 2 秒检查一次，登录信息写入磁盘可能要十几秒），不需要点任何按钮。")
                    .font(.caption).fixedSize(horizontal: false, vertical: true)
                Text("登录后一分钟还没反应，再用下面的按钮：").font(.caption2).foregroundStyle(.secondary)
                Button("立即识别") { model.confirmAddedAuto() }
                    .buttonStyle(PillButtonStyle()).disabled(model.busy)
                VStack(alignment: .leading, spacing: 6) {
                    ForEach(choices, id: \.self) { acct in
                        Button("已登录：\(model.displayName(acct))") { model.confirmAdded(acct) }
                            .buttonStyle(PillButtonStyle())
                    }
                }
                HStack {
                    Spacer()
                    Button("放弃添加，放回原账号") { model.cancelAdd() }.buttonStyle(PillButtonStyle())
                }
            }
        }
    }

    private var sessionList: some View {
        VStack(alignment: .leading, spacing: 8) {
            ForEach(model.snapshot?.sessions ?? []) { SessionRow(session: $0) }
        }
    }

    private var sessionsCard: some View {
        let target = model.switchTarget
        return Card {
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Text("近期会话").font(.headline)
                    Text("\(model.snapshot?.sessions.count ?? 0) 个未归档").font(.caption).foregroundStyle(.secondary)
                    Spacer()
                }
                Text(target == nil
                     ? "方框 = 当前账号还看不到、可以同步过来的会话；灰色对勾 = 当前账号已经有了。勾选后点「同步」，再点「重启 Desktop」生效。"
                     : "勾选要带给「\(model.displayName(target!))」的会话，然后点底部「切换」，同步和换号在一次重启里完成。")
                    .font(.caption2).foregroundStyle(target == nil ? Color.secondary : Color.blue)
                    .fixedSize(horizontal: false, vertical: true)
                // ScrollView 在菜单栏面板里只给 maxHeight 会被压成 0 高，必须给确定高度
                ScrollView { sessionList }
                    .frame(height: min(CGFloat(model.snapshot?.sessions.count ?? 0) * 46 + 4, 320))
                Divider()
                if let target {
                    HStack {
                        Button(model.selected.isEmpty ? "切换（只重启一次）" : "切换并同步 \(model.selected.count) 个会话（只重启一次）") { model.confirmSwitch() }
                            .buttonStyle(PillButtonStyle(prominent: true))
                            .disabled(model.busy)
                        Spacer()
                        Button("取消") { model.cancelSwitch() }.buttonStyle(PillButtonStyle())
                    }
                } else {
                    HStack {
                        Button("同步选中到当前账号（\(model.selected.count)）") { model.syncSelected() }
                            .buttonStyle(PillButtonStyle(prominent: true))
                            .disabled(model.selected.isEmpty || model.busy)
                        Button("撤销上次同步") { model.undoLastSync() }.buttonStyle(PillButtonStyle()).disabled(model.busy)
                        Spacer()
                        Button("重启 Desktop") { model.restartDesktop() }
                            .buttonStyle(PillButtonStyle())
                            .disabled(model.busy)
                    }
                }
            }
        }
    }
}
