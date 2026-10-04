import SwiftUI

// 视觉参考 cc-switch：浅底 + 白色圆角卡片 + 细阴影 + 彩色头像 + 绿色「当前使用」徽标。

private let palette: [Color] = [.orange, .blue, .purple, .teal, .pink, .indigo]

private func avatarColor(_ id: String) -> Color {
    // hashValue 每次启动随机，用字符码求和保证颜色稳定
    palette[id.unicodeScalars.reduce(0) { $0 + Int($1.value) } % palette.count]
}

/// 按剩余比例着色：50% 以上绿，20%~50% 橙，20% 以下红。
private func remainingColor(_ pct: Int) -> Color {
    pct < 20 ? .red : (pct < 50 ? .orange : .green)
}

/// 周额度不到一天就重置时的提示色：真青色。系统 .cyan 深色下偏天蓝，这里自己定；浅色模式加深保证白底可读。
private let soonResetColor = Color(nsColor: NSColor(name: nil) { a in
    a.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
        ? NSColor(srgbRed: 0.30, green: 0.87, blue: 0.80, alpha: 1)
        : NSColor(srgbRed: 0.00, green: 0.55, blue: 0.52, alpha: 1)
})

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

/// 布局照 Desktop 设置页的「Plan usage limits」：上一行左边名称、右边重置时间 + 剩余百分比，下一行整宽进度条。
/// 进度条表示剩余额度：满额是整条绿色，用掉的部分从右往左缩短，剩余低于 50% 变橙、低于 20% 变红。
/// 紧挨着下面一条更细的浅灰条表示这个窗口剩余的时间，同样从满格往左缩；窗口还没开始计时（用量 0、没有重置时间）
/// 或已过重置时刻时按满格显示。鼠标悬停时这一块加浅色底表示选中，标题行右侧换成一行说明：剩余时间与用量快慢。
/// 说明画在面板自身的视图里，不另开弹窗，不抢焦点。
/// 重置倒计时用上次联网查到的重置时刻在本地每分钟重算，不联网；数值取得后已过重置时刻的，
/// 按剩余 100% 显示并标「推断」（规则见 AppModel.Reading.shown），点刷新可拿到准确值。
struct UsageBar: View {
    let label: String
    let reading: AppModel.Reading
    /// 悬停说明贴哪个角：左栏贴左上往右展开，右栏贴右上往左展开，都朝卡片中间伸，不出卡片边
    var infoAlignment: Alignment = .topTrailing
    private var window: TimeInterval { reading.window }
    @State private var hovering = false

    var body: some View {
        TimelineView(.everyMinute) { ctx in
            let shown = reading.shown(at: ctx.date)
            let resetsAt = shown.resetsAt, left = shown.left
            // 没开始计时：已推断重置，或用量为 0 且接口没给重置时间（第一次使用后才开始计时）
            let notStarted = shown.inferred || (resetsAt == nil && left == 100)
            let timeLeft = notStarted ? 100 : resetsAt.map { 100 - elapsedPct(resetsAt: $0, now: ctx.date) }
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 8) {
                    Text(label).font(.callout).lineLimit(1).fixedSize()
                    Spacer(minLength: 4)
                    if let r = resetsAt { resetText(r, now: ctx.date).font(.caption).lineLimit(1) }
                    if shown.inferred { InferredTag() }
                    Text(left.map { "剩余 \($0)%" } ?? "—").font(.callout.monospacedDigit()).foregroundStyle(.secondary).fixedSize()
                }
                bar(CGFloat(left ?? 0), fill: AnyShapeStyle(remainingColor(left ?? 0).gradient), height: 4)
                    .padding(.top, 1)
                if let t = timeLeft {
                    // 跟随明暗模式的浅灰：深色下偏白，浅色下中灰
                    bar(CGFloat(t), fill: AnyShapeStyle(Color.primary.opacity(0.5)), height: 3)
                }
            }
            .padding(.horizontal, 6).padding(.vertical, 4)
            .background(RoundedRectangle(cornerRadius: 6).fill(Color.primary.opacity(hovering ? 0.06 : 0)))
            .padding(.horizontal, -6).padding(.vertical, -4)
            .contentShape(Rectangle())
            .onHover { hovering = $0 }
            .overlay(alignment: infoAlignment) {
                if hovering, let t = timeLeft {
                    paceInfo(timeLeft: t, left: left ?? 100, notStarted: notStarted, inferred: shown.inferred)
                        .offset(y: -3)
                        .allowsHitTesting(false)
                }
            }
        }
        .zIndex(hovering ? 1 : 0)
    }

    private func bar(_ pct: CGFloat, fill: AnyShapeStyle, height: CGFloat) -> some View {
        GeometryReader { g in
            ZStack(alignment: .leading) {
                Capsule().fill(Color.primary.opacity(0.08))
                Capsule().fill(fill).frame(width: g.size.width * min(pct, 100) / 100)
            }
        }
        .frame(height: height)
    }

    /// 窗口从「重置时刻往前推一个窗口长度」开始，算现在走过了多少。
    private func elapsedPct(resetsAt: Date, now: Date) -> Int {
        let done = window - resetsAt.timeIntervalSince(now)
        return max(0, min(100, Int((done / window * 100).rounded())))
    }

    /// 悬停说明：一行写剩余时间、剩余额度和用量快慢。
    private func paceInfo(timeLeft: Int, left: Int, notStarted: Bool, inferred: Bool) -> some View {
        let diff = timeLeft - left   // 剩余额度比剩余时间少多少，即用得比时间快多少
        let pace = diff > 5 ? "用量比时间快 \(diff)%" : (diff < -5 ? "用量比时间慢 \(-diff)%" : "用量和时间同步")
        let span = window > 24 * 3600 ? "本周" : "本次 5 小时"
        let text = inferred ? inferredText()
            : notStarted ? "\(span)窗口还没开始计时，第一次使用后开始" : "\(span)剩余时间 \(timeLeft)% · 剩余额度 \(left)% · "
        return HStack(spacing: 0) {
            Text(text)
            if !notStarted { Text(pace).bold().foregroundStyle(diff > 5 ? Color.orange : Color.primary) }
        }
        .font(.caption)
        .padding(.horizontal, 8).padding(.vertical, 5)
        .background(RoundedRectangle(cornerRadius: 6).fill(Color(nsColor: .windowBackgroundColor)))
        .overlay(RoundedRectangle(cornerRadius: 6).stroke(Color.primary.opacity(0.15)))
        .shadow(color: .black.opacity(0.2), radius: 4, y: 2)
        .fixedSize()
    }

    /// 「推断：10-01 14:20 查到已用 63%，之后已过重置时刻，点刷新取准确值」
    private func inferredText() -> String {
        let f = DateFormatter()
        f.dateFormat = "MM-dd HH:mm"
        let when = reading.at.map { f.string(from: $0) + " " } ?? ""
        return "推断：\(when)查到已用 \(reading.pct ?? 0)%，之后已过重置时刻，点刷新取准确值"
    }

    /// 统一写成「绝对时间 重置（相对时间）」：一天内只写时分，更远加星期。
    /// 周额度括号里的相对时间用主色（深色下是白色）更显眼，不到一天换青色（soonResetColor）提示快重置了；
    /// 5 小时额度总在一天以内，括号保持灰色，免得面板太花。
    private func resetText(_ d: Date, now: Date) -> Text {
        let s = Int(d.timeIntervalSince(now))
        if s <= 0 { return Text("已重置，点刷新更新").foregroundStyle(.secondary) }
        let day = s / 86400, h = s % 86400 / 3600, m = s % 3600 / 60
        let f = DateFormatter()
        f.locale = Locale(identifier: "zh_CN")
        f.dateFormat = day == 0 ? "HH:mm" : "EEE HH:mm"
        let rel = day > 0 ? "\(day) 天 \(h) 小时后" : (h > 0 ? "\(h) 小时 \(m) 分后" : "\(max(m, 1)) 分钟后")
        let weekly = window > 24 * 3600
        let relColor: Color = !weekly ? .secondary : day == 0 ? soonResetColor : .primary
        return Text("\(f.string(from: d)) 重置（").foregroundStyle(.secondary)
            + Text(rel).foregroundStyle(relColor)
            + Text("）").foregroundStyle(.secondary)
    }
}

/// 灰色「推断」小标签：数值不是查到的，是按规则推出来的。
struct InferredTag: View {
    var body: some View {
        Text("推断").font(.caption2).padding(.horizontal, 5).padding(.vertical, 1)
            .background(Capsule().fill(Color.primary.opacity(0.08))).foregroundStyle(.secondary)
    }
}

struct AccountCard: View {
    @EnvironmentObject var model: AppModel
    let account: AccountInfo
    @State private var editing = false
    @State private var draft = ""
    @State private var cardsHover = false   // 悬停在重置卡上：整张账号卡浮到上层，明细不被下一张卡挡住
    @State private var buyDate = Date()      // 编辑中的 App Store 购买时间：选择器里的钟点按北京时间理解
    @State private var buyHasTime = false

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
                                TextField("名字", text: $draft, onCommit: { commitEdit(liveData) })
                                    .textFieldStyle(.roundedBorder).frame(width: 170)
                                Button("完成") { commitEdit(liveData) }.buttonStyle(PillButtonStyle(prominent: true))
                            } else {
                                Text(model.displayName(id)).font(.headline).lineLimit(1)
                                Button { beginEdit() } label: {
                                    Image(systemName: "pencil").font(.caption)
                                }.buttonStyle(.plain).foregroundStyle(.secondary)
                                .help(needsPurchase(liveData) ? "改名字、填 App Store 购买时间（清空名字回车恢复显示邮箱）" : "改名字（清空回车恢复显示邮箱）")
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
                if editing && needsPurchase(liveData) { purchaseEditor }
                // 左边套餐与账号信息，右边重置卡
                HStack(alignment: .center, spacing: 8) {
                    let info = footer(sample, liveData)
                    HStack(alignment: .firstTextBaseline, spacing: 4) {
                        Text(planTitle(liveData)).font(.callout).foregroundStyle(.secondary).fixedSize()
                        if let e = info.expiry {
                            Text("· " + e).font(.caption2).foregroundStyle(.secondary).fixedSize()
                            if let why = info.inferredFrom {
                                InferredTag().help(why)
                            }
                        }
                        Text("· " + info.rest).font(.caption2).foregroundStyle(.secondary)
                            .lineLimit(1).truncationMode(.head).help(info.rest)
                    }
                    Spacer(minLength: 8)
                    if let l = liveData { ResetCards(live: l, hovering: $cardsHover) }
                }
                .padding(.top, 2)
                .zIndex(1)
                let r = model.readings(account)
                // 左周额度、右 5 小时：周额度的重置说明更长，占得宽一些（约 1.2 : 1）
                HStack(alignment: .top, spacing: 14) {
                    UsageBar(label: "每周 · 所有模型", reading: r.seven, infoAlignment: .topLeading)
                        .frame(maxWidth: .infinity)
                    UsageBar(label: "会话限额", reading: r.five)
                        .frame(width: 262)
                }
                if let err = model.refreshError[id] {
                    Text(err).font(.caption2).foregroundStyle(.red).fixedSize(horizontal: false, vertical: true)
                }
            }
        }
        .overlay(RoundedRectangle(cornerRadius: 10).stroke(Color.accentColor, lineWidth: isTarget ? 1.5 : 0))
        .zIndex(cardsHover ? 1 : 0)
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
                    .help("先在右侧勾选要带过去的会话，再点会话栏底部的切换按钮，只重启一次 Desktop")
            }
        } else {
            Button("登录添加") { model.beginAdd(id) }.buttonStyle(PillButtonStyle())
                .disabled(model.busy || model.profile.pendingAdd)
                .help("这个账号还没保存登录态：需要在空白 Desktop 里登录一次，之后就能一键切换")
        }
    }

    /// App Store 订阅、接口里查不到到期日：编辑时让填购买时间来推断。
    private func needsPurchase(_ l: LiveUsage?) -> Bool { l?.appStore == true && l?.nextChargeDate == nil }

    /// 填购买时间那一行：只填日期也行，勾上「精确到时分」再填钟点，都按北京时间。
    private var purchaseEditor: some View {
        HStack(spacing: 8) {
            Text("App Store 购买时间（北京时间）").font(.caption).foregroundStyle(.secondary)
            DatePicker("", selection: $buyDate, in: ...Date(),
                       displayedComponents: buyHasTime ? [.date, .hourAndMinute] : [.date])
                .labelsHidden().datePickerStyle(.field).fixedSize()
            Toggle("精确到时分", isOn: $buyHasTime).toggleStyle(.checkbox).font(.caption)
            Spacer(minLength: 4)
            if model.settings.purchases[id] != nil {
                Button("清除") { model.setPurchase(id, nil); editing = false }.buttonStyle(PillButtonStyle())
            }
        }
        .help("苹果按月订阅在购买日期的同一天续费，下个月没有这一天就在月底续；填了时分倒计时精确到小时，只填日期精确到天")
    }

    private static let purchaseFormat = "yyyy-MM-dd HH:mm"

    private func beginEdit() {
        draft = model.displayName(id)
        // 存的是北京时间的钟点字符串；按本机时区读进选择器，只为了让选择器显示同样的钟点
        let p = model.settings.purchases[id]
        let f = DateFormatter()
        f.dateFormat = (p?.count ?? 0) > 10 ? Self.purchaseFormat : "yyyy-MM-dd"
        buyDate = p.flatMap(f.date) ?? Date()
        buyHasTime = (p?.count ?? 0) > 10
        editing = true
    }

    private func commitEdit(_ l: LiveUsage?) {
        model.rename(id, to: draft)
        if needsPurchase(l) {
            let f = DateFormatter()
            f.dateFormat = buyHasTime ? Self.purchaseFormat : "yyyy-MM-dd"
            model.setPurchase(id, f.string(from: buyDate))
        }
        editing = false
    }

    /// 套餐行的信息：expiry 是「10-15 到期（8 天 3 小时后）」，推断出来的带上依据；rest 放不下时截掉开头，悬停可看全文。
    private func footer(_ s: UsageSample?, _ l: LiveUsage?) -> (expiry: String?, inferredFrom: String?, rest: String) {
        if let l {
            var expiry: String?, why: String?
            var parts: [String] = []
            if let d = l.nextChargeDate {
                expiry = "\(d.suffix(5)) 到期" + (chargeCountdown(l).map { "（\($0)）" } ?? "")
            } else if l.appStore == true {
                if let p = model.settings.purchases[id], let r = AppModel.inferredRenewal(p) {
                    let f = DateFormatter()
                    f.timeZone = TimeZone(identifier: "Asia/Shanghai")
                    f.dateFormat = "MM-dd"
                    expiry = "\(f.string(from: r.at)) 到期（\(r.hasTime ? untilText(r.at) : daysUntil(r.at, in: f.timeZone))）"
                    why = "App Store 订阅查不到到期日，按你填的购买时间 \(p)（北京时间）推断：每月购买日同一天续费，没有这一天的月份在月底续"
                } else {
                    parts.append("App Store 订阅 · 点铅笔填购买时间")
                }
            }
            parts.append("\(account.sessionCount) 个 Code 会话")
            let f = DateFormatter()
            f.dateFormat = "HH:mm"
            // Desktop 写进本地的用量采样同样可信：比联网结果新时，刷新时间跟着它走
            let updated = max(l.fetchedAt, s?.at ?? .distantPast)
            parts.append("\(f.string(from: updated)) 刷新")
            return (expiry, why, parts.joined(separator: " · "))
        }
        var parts = ["\(account.sessionCount) 个 Code 会话", s.map { "本地采样 \(relative($0.at))" } ?? "暂无用量采样"]
        parts.append(model.profileDir(id) == nil ? "未保存登录态" : "点刷新获取实时额度")
        return (nil, nil, parts.joined(separator: " · "))
    }

    /// 只知道日期时按自然日算：「N 天后」「今天」。
    private func daysUntil(_ d: Date, in tz: TimeZone? = nil) -> String {
        var cal = Calendar.current
        if let tz { cal.timeZone = tz }
        let n = cal.dateComponents([.day], from: cal.startOfDay(for: Date()), to: cal.startOfDay(for: d)).day ?? 0
        return n > 0 ? "\(n) 天后" : n == 0 ? "今天" : "已到期"
    }

    /// 到期倒计时：有精确时刻就精确到小时；旧缓存只有日期时按自然日算「N 天后」，不必等联网刷新。
    private func chargeCountdown(_ l: LiveUsage) -> String? {
        if let at = l.nextChargeAt { return untilText(at) }
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd"
        guard let d = l.nextChargeDate, let day = f.date(from: d) else { return nil }
        return daysUntil(day)
    }

    /// 「12 天 14 小时后」「5 小时后」；已过写「已过期」。
    private func untilText(_ d: Date) -> String {
        let s = Int(d.timeIntervalSinceNow)
        if s <= 0 { return "已到期" }
        let day = s / 86400, h = s % 86400 / 3600
        return day > 0 ? "\(day) 天 \(h) 小时后" : "\(max(h, 1)) 小时后"
    }

    /// 「套餐用量限额 · Pro」，套餐名来自联网查到的账户信息，没查过就不写。
    private func planTitle(_ l: LiveUsage?) -> String {
        guard let p = l?.plan, !p.isEmpty else { return "套餐用量限额" }
        return "套餐用量限额 · " + p.replacingOccurrences(of: "claude_", with: "").capitalized
    }
}

/// 一张小卡片图标：Full Reset 紫色，只清 5 小时的蓝绿色。
struct ResetChip: View {
    let full: Bool
    var body: some View {
        Text(full ? "FULL" : "5H").font(.system(size: 9, weight: .heavy, design: .rounded))
        .foregroundStyle(.white)
        .padding(.horizontal, 5).frame(height: 16)
        .background(
            RoundedRectangle(cornerRadius: 4)
                .fill(LinearGradient(colors: full ? [Color(red: 0.62, green: 0.40, blue: 0.95), Color(red: 0.40, green: 0.30, blue: 0.85)]
                                                  : [Color(red: 0.20, green: 0.75, blue: 0.80), Color(red: 0.18, green: 0.50, blue: 0.85)],
                                     startPoint: .topLeading, endPoint: .bottomTrailing))
                // 上半部一层淡白高光，像卡面反光
                .overlay(RoundedRectangle(cornerRadius: 4)
                    .fill(LinearGradient(colors: [.white.opacity(0.28), .clear], startPoint: .top, endPoint: .center)))
                .overlay(RoundedRectangle(cornerRadius: 4).stroke(.white.opacity(0.25), lineWidth: 0.5))
        )
        .shadow(color: .black.opacity(0.15), radius: 1, y: 0.5)
    }
}

/// 「重置卡：[FULL] ×1 [5H] ×2」，没有卡不显示。悬停时在下方列出每批卡的张数与到期时间。
struct ResetCards: View {
    let live: LiveUsage
    @Binding var hovering: Bool

    var body: some View {
        let full = live.fullResets ?? 0, five = live.sessionResets ?? 0
        if full + five > 0 {
            HStack(spacing: 4) {
                Text("重置卡：").font(.caption).foregroundStyle(.secondary)
                if full > 0 { chip(true, full) }
                if five > 0 { chip(false, five).padding(.leading, full > 0 ? 4 : 0) }
            }
            .fixedSize()
            .contentShape(Rectangle())
            .onHover { hovering = $0 }
            .overlay(alignment: .topTrailing) {
                if hovering { detail.offset(y: 22).allowsHitTesting(false) }
            }
        }
    }

    private func chip(_ full: Bool, _ n: Int) -> some View {
        HStack(spacing: 2) {
            ResetChip(full: full)
            Text("×\(n)").font(.caption.monospacedDigit()).foregroundStyle(.secondary)
        }
    }

    private var detail: some View {
        VStack(alignment: .leading, spacing: 5) {
            if let grants = live.resetGrants {
                ForEach(Array(grants.enumerated()), id: \.offset) { _, g in
                    HStack(spacing: 6) {
                        ResetChip(full: g.full)
                        Text("\(g.left) 张 · " + expiry(g.endsAt))
                    }
                }
            } else {
                Text("点刷新后可看每张卡的到期时间")
            }
            Text("FULL 同时清 5 小时与每周额度，5H 只清 5 小时额度").foregroundStyle(.secondary)
        }
        .font(.caption)
        .padding(.horizontal, 8).padding(.vertical, 6)
        .background(RoundedRectangle(cornerRadius: 6).fill(Color(nsColor: .windowBackgroundColor)))
        .overlay(RoundedRectangle(cornerRadius: 6).stroke(Color.primary.opacity(0.15)))
        .shadow(color: .black.opacity(0.2), radius: 4, y: 2)
        .fixedSize()
    }

    /// 「11-03 14:00 到期（29 天后）」
    private func expiry(_ d: Date?) -> String {
        guard let d else { return "不过期" }
        let f = DateFormatter()
        f.dateFormat = "MM-dd HH:mm"
        let s = Int(d.timeIntervalSinceNow)
        let day = s / 86400, h = s % 86400 / 3600
        let rel = s <= 0 ? "已过期" : day > 0 ? "\(day) 天后" : "\(max(h, 1)) 小时后"
        return "\(f.string(from: d)) 到期（\(rel)）"
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

private struct HeightKey: PreferenceKey {
    static var defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) { value = max(value, nextValue()) }
}

/// 左列账号、右列会话：账号多了会话栏不再把底部的切换 / 重启按钮挤出屏幕。
struct PanelView: View {
    @EnvironmentObject var model: AppModel
    /// 左列实际高度，右列会话列表按它定高，两列底部大致对齐
    @State private var leftHeight: CGFloat = 0

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            header
            HStack(alignment: .top, spacing: 12) {
                VStack(alignment: .leading, spacing: 12) {
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
                    if let msg = model.message { noticeCard(msg, color: .primary) { model.message = nil } }
                    if let err = model.errorText { noticeCard(err, color: .red) { model.errorText = nil } }
                }
                .frame(width: 624)
                .background(GeometryReader { Color.clear.preference(key: HeightKey.self, value: $0.size.height) })
                sessionsCard.frame(width: 400)
            }
        }
        .onPreferenceChange(HeightKey.self) { leftHeight = $0 }
        .padding(14)
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
        .focusEffectDisabled()   // 面板打开时不给第一个按钮画焦点框
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
                // ScrollView 在菜单栏面板里只给 maxHeight 会被压成 0 高，必须给确定高度；
                // 高度跟左列走（减去本卡片标题、说明、按钮约 150），左列很矮时至少留 260
                ScrollView { sessionList }
                    .frame(height: min(CGFloat(model.snapshot?.sessions.count ?? 0) * 46 + 4, max(leftHeight - 150, 260)))
                Divider()
                if target != nil {
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
