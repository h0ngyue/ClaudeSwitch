#!/bin/bash
# Claude Desktop 多账号目录管理（菜单栏程序与手动操作共用的唯一实现）。
#
# 原理：Desktop 只认 ~/Library/Application Support/Claude/。把它和停放在
# ClaudeSwitch/profiles/<别名>/ 的另一个账号目录互换名字，再打开 Desktop，就是另一个账号的登录态。
# 会话索引、运行时（10G）放在 ClaudeSwitch/shared/，各账号目录里用软链指过去。
#
# 安全约定：所有操作只做「改名 / 移动 / 建软链」，从不删除用户数据；改动前要求 Desktop 已退出。
#
# 子命令：
#   status                 查看当前布局
#   quit | launch          正常退出（等同 ⌘Q）/ 打开 Desktop
#   init <当前账号别名>     首次使用：备份（没备份过才做）+ 共享 + 给当前账号命名，可重复执行
#   backup                 备份 Claude/（不含 10G 运行时）到 ClaudeSwitch/backup/
#   share                  把会话索引与运行时移到 shared/，原位置换成软链
#   park <当前账号别名>     停放当前账号，并建一个只含软链的新 Claude/ 供登录下一个账号
#   add-begin <当前账号别名> 添加账号一条龙：退出 → 初始化 → 停放当前账号 → 打开空白 Desktop 并发通知
#   cancel-add             退出 Desktop → unpark → 打开，供菜单栏「放弃添加」使用
#   unpark                 放弃本次添加：新建的 Claude/ 挪到 ClaudeSwitch/aborted-*（不删），刚停放的账号放回来
#   name <当前账号别名>     给新登录进来的账号起别名（park 之后、登录新账号并退出 Desktop 后执行）
#   swap <目标别名>         切换到已停放的账号
#   switch <目标别名> [--org=<组织ID>] [会话ID...]   一次重启完成：退出 Desktop → 把会话同步给目标账号 → 交换目录 → 打开 Desktop
#   rollback               回到使用本工具前的布局（原账号放回 Claude/，撤销软链；其他账号目录保留不删）
#   rollback --from-backup 最后手段：把当前 Claude/ 挪到一边，从备份恢复
#
# 菜单栏程序用账户 ID 作别名；手动使用时别名可以随便起。
# switch 调用的会话同步脚本路径可用 RESTORE_SCRIPT / RESTORE_PYTHON 覆盖。
# 测试时可用 CS_APPSUPPORT 指向沙箱目录，CS_SKIP_DESKTOP_CHECK=1 跳过 Desktop 运行检查。
set -euo pipefail
# 从菜单栏程序启动时没有中文语言环境，固定 UTF-8，避免中文紧跟变量时被当成变量名的一部分
export LANG=en_US.UTF-8 LC_ALL=en_US.UTF-8

AS="${CS_APPSUPPORT:-${HOME}/Library/Application Support}"
CLAUDE="${AS}/Claude"
TOOL="${AS}/ClaudeSwitch"
SHARED="${TOOL}/shared"
PROFILES="${TOOL}/profiles"
STATE="${TOOL}/state"
BACKUP="${TOOL}/backup"
SHARED_ITEMS=("claude-code-sessions" "vm_bundles" "claude-code")
BUNDLE_ID="com.anthropic.claudefordesktop"
RESTORE_PYTHON="${RESTORE_PYTHON:-/usr/bin/python3}"
RESTORE_SCRIPT="${RESTORE_SCRIPT:-$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/restore_sessions.py}"

log() { echo "[$(date '+%H:%M:%S')] $*"; mkdir -p "${TOOL}"; echo "[$(date '+%F %T')] $*" >> "${TOOL}/actions.log"; }
die() { echo "❌ $*" >&2; exit 1; }

desktop_running() {
    [ "${CS_SKIP_DESKTOP_CHECK:-0}" = "1" ] && return 1
    [ "$(osascript -e "application id \"${BUNDLE_ID}\" is running")" = "true" ]
}

require_stopped() { desktop_running && die "Claude Desktop 还在运行，先执行：$0 quit"; return 0; }

cmd_quit() {
    desktop_running || { log "Desktop 未运行"; return 0; }
    osascript -e "tell application id \"${BUNDLE_ID}\" to quit"
    for _ in $(seq 1 60); do desktop_running || { log "Desktop 已退出"; return 0; }; sleep 0.5; done
    die "Desktop 30 秒内没有退出，请手动 ⌘Q"
}

cmd_launch() {
    [ "${CS_SKIP_DESKTOP_CHECK:-0}" = "1" ] && { log "（测试模式）跳过打开 Desktop"; return 0; }
    open -b "${BUNDLE_ID}"; log "已打开 Desktop"
}

cmd_status() {
    echo "Claude/                 : $([ -d "${CLAUDE}" ] && echo 存在 || echo 不存在)"
    for it in "${SHARED_ITEMS[@]}"; do
        if [ -L "${CLAUDE}/${it}" ]; then echo "  ${it} -> $(readlink "${CLAUDE}/${it}")"
        elif [ -e "${CLAUDE}/${it}" ]; then echo "  ${it} （真实目录）"
        else echo "  ${it} （不存在）"; fi
    done
    echo "当前账号别名            : $(cat "${STATE}/current" 2>/dev/null || echo 未命名)"
    echo "使用前的原账号别名      : $(cat "${STATE}/original" 2>/dev/null || echo 未记录)"
    echo "已停放账号              : $(ls "${PROFILES}" 2>/dev/null | tr '\n' ' ')"
    echo "最近备份                : $(cat "${BACKUP}/LATEST" 2>/dev/null || echo 无)"
    echo "Desktop 运行中          : $(desktop_running && echo 是 || echo 否)"
}

cmd_backup() {
    require_stopped
    [ -d "${CLAUDE}" ] && [ ! -L "${CLAUDE}" ] || die "Claude/ 不是真实目录，拒绝备份"
    local dst="${BACKUP}/Claude-$(date +%Y%m%d-%H%M%S)"
    mkdir -p "${BACKUP}"
    # -L：软链指向的会话索引也按真实内容备份；运行时可重新下载，不备份
    rsync -aL --exclude 'vm_bundles' --exclude 'claude-code' "${CLAUDE}/" "${dst}/"
    local a b
    a=$(find -L "${CLAUDE}/claude-code-sessions" -name 'local_*.json' 2>/dev/null | wc -l | tr -d ' ')
    b=$(find "${dst}/claude-code-sessions" -name 'local_*.json' 2>/dev/null | wc -l | tr -d ' ')
    [ "${a}" = "${b}" ] || die "备份校验失败：会话索引 ${a} ≠ ${b}，备份目录 ${dst} 保留供排查"
    echo "${dst}" > "${BACKUP}/LATEST"
    log "备份完成：${dst}（会话索引 ${b} 个，$(du -sh "${dst}" | cut -f1)）"
}

cmd_share() {
    require_stopped
    [ -f "${BACKUP}/LATEST" ] || die "还没有备份，先执行：$0 backup"
    mkdir -p "${SHARED}"
    for it in "${SHARED_ITEMS[@]}"; do
        if [ -L "${CLAUDE}/${it}" ]; then log "${it} 已是软链，跳过"; continue; fi
        [ -e "${CLAUDE}/${it}" ] || { log "${it} 不存在，跳过"; continue; }
        [ -e "${SHARED}/${it}" ] && die "shared/${it} 已存在，拒绝覆盖"
        mv "${CLAUDE}/${it}" "${SHARED}/${it}"
        ln -s "${SHARED}/${it}" "${CLAUDE}/${it}"
        log "共享：${it} -> shared/${it}"
    done
}

link_shared_into() {   # 在指定账号目录里补齐指向 shared/ 的软链
    local dir="$1"
    for it in "${SHARED_ITEMS[@]}"; do
        [ -e "${SHARED}/${it}" ] || continue
        if [ -L "${dir}/${it}" ]; then continue; fi
        [ -e "${dir}/${it}" ] && die "${dir}/${it} 是真实目录，Desktop 可能把软链换掉了，停止操作"
        ln -s "${SHARED}/${it}" "${dir}/${it}"
    done
}

cmd_park() {
    local alias="${1:-}"; [ -n "${alias}" ] || die "用法：$0 park <当前账号别名>"
    require_stopped
    [ -L "${CLAUDE}/claude-code-sessions" ] || die "还没共享会话目录，先执行：$0 share"
    [ -e "${PROFILES}/${alias}" ] && die "profiles/${alias} 已存在"
    mkdir -p "${PROFILES}" "${STATE}"
    [ -f "${STATE}/original" ] || echo "${alias}" > "${STATE}/original"
    echo "${alias}" > "${STATE}/last_parked"
    mv "${CLAUDE}" "${PROFILES}/${alias}"
    mkdir "${CLAUDE}"
    link_shared_into "${CLAUDE}"
    # MCP 服务器配置复制一份过去，新账号沿用同样的 MCP（复制而非软链，各账号可独立修改）
    [ -f "${PROFILES}/${alias}/claude_desktop_config.json" ] && cp -p "${PROFILES}/${alias}/claude_desktop_config.json" "${CLAUDE}/"
    rm -f "${STATE}/current"
    log "已停放 ${alias}；新建的 Claude/ 只含共享软链，打开 Desktop 登录下一个账号后退出，再执行 name <别名>"
}

cmd_unpark() {
    require_stopped
    [ -f "${STATE}/current" ] && die "当前账号已命名，没有进行中的添加"
    local last; last=$(cat "${STATE}/last_parked" 2>/dev/null) || die "没有记录刚停放的账号"
    [ -d "${PROFILES}/${last}" ] || die "profiles/${last} 不存在"
    local aside="${TOOL}/aborted-$(date +%Y%m%d-%H%M%S)"
    [ -d "${CLAUDE}" ] && mv "${CLAUDE}" "${aside}"
    mv "${PROFILES}/${last}" "${CLAUDE}"
    echo "${last}" > "${STATE}/current"
    rm -f "${STATE}/last_parked"
    log "已放弃添加：${last} 放回 Claude/，新建目录挪到 ${aside}"
}

cmd_name() {
    local alias="${1:-}"; [ -n "${alias}" ] || die "用法：$0 name <别名>"
    [ -e "${PROFILES}/${alias}" ] && die "别名 ${alias} 已被停放账号占用"
    mkdir -p "${STATE}"; echo "${alias}" > "${STATE}/current"
    log "当前 Claude/ 命名为 ${alias}"
}

cmd_swap() {
    local target="${1:-}"; [ -n "${target}" ] || die "用法：$0 swap <目标别名>"
    require_stopped
    local cur; cur=$(cat "${STATE}/current" 2>/dev/null) || die "当前账号还没命名，先执行：$0 name <别名>"
    [ "${cur}" = "${target}" ] && { log "已经是 ${target}"; return 0; }
    [ -d "${PROFILES}/${target}" ] || die "没有停放的账号 ${target}"
    [ -e "${PROFILES}/${cur}" ] && die "profiles/${cur} 已存在，状态异常，停止"
    link_shared_into "${CLAUDE}"          # 顺带确认 Desktop 没把软链换成真实目录
    link_shared_into "${PROFILES}/${target}"
    mv "${CLAUDE}" "${PROFILES}/${cur}"
    if ! mv "${PROFILES}/${target}" "${CLAUDE}"; then
        mv "${PROFILES}/${cur}" "${CLAUDE}"; die "切换失败，已还原为 ${cur}"
    fi
    echo "${target}" > "${STATE}/current"
    log "已切换：${cur} -> ${target}"
}

cmd_init() {
    local alias="${1:-}"; [ -n "${alias}" ] || die "用法：$0 init <当前账号别名>"
    require_stopped
    # 还没共享过（使用本工具前的原始布局）就每次重新备份，确保备份是改动前最新的状态
    [ -L "${CLAUDE}/claude-code-sessions" ] || cmd_backup
    cmd_share
    if [ -f "${STATE}/current" ]; then log "当前账号已命名为 $(cat "${STATE}/current")，不重复命名"
    else cmd_name "${alias}"; fi
}

notify() { [ "${CS_SKIP_DESKTOP_CHECK:-0}" = "1" ] && return 0; osascript -e "display notification \"$1\" with title \"ClaudeSwitch\"" >/dev/null 2>&1 || true; }

cmd_add_begin() {
    local alias="${1:-}"; [ -n "${alias}" ] || die "用法：$0 add-begin <当前账号别名>"
    cmd_quit
    cmd_init "${alias}"
    cmd_park "${alias}"
    cmd_launch
    notify "Desktop 已打开登录页，请登录要添加的账号；登录成功后会自动识别"
}

cmd_switch() {
    local target="${1:-}"; [ -n "${target}" ] || die "用法：$0 switch <目标别名> [会话ID...]"
    shift
    [ -d "${PROFILES}/${target}" ] || die "没有停放的账号 ${target}"
    local to="${target}"   # 目标账号还没用过 Code 页时，菜单栏会用 --org= 告诉同步脚本它的组织 ID
    case "${1:-}" in --org=*) to="${target}/${1#--org=}"; shift ;; esac
    cmd_quit
    if [ $# -gt 0 ]; then
        log "同步 $# 个会话给 ${target}"
        "${RESTORE_PYTHON}" "${RESTORE_SCRIPT}" "--to=${to}" "$@" || die "会话同步失败，未切换账号（Desktop 已退出，可直接 launch 回原账号）"
    fi
    cmd_swap "${target}"
    cmd_launch
    notify "已切换账号，Desktop 正在打开"
}

cmd_rollback() {
    require_stopped
    if [ "${1:-}" = "--from-backup" ]; then
        local src; src=$(cat "${BACKUP}/LATEST" 2>/dev/null) || die "没有备份记录"
        local aside="${TOOL}/rollback-moved-$(date +%Y%m%d-%H%M%S)"
        [ -d "${CLAUDE}" ] && mv "${CLAUDE}" "${aside}" && log "当前 Claude/ 挪到 ${aside}（未删除）"
        rsync -a "${src}/" "${CLAUDE}/"
        for it in vm_bundles claude-code; do   # 运行时不在备份里，从共享区或挪开的目录拿回来
            if [ -d "${SHARED}/${it}" ]; then mv "${SHARED}/${it}" "${CLAUDE}/${it}"
            elif [ -d "${aside}/${it}" ] && [ ! -L "${aside}/${it}" ]; then mv "${aside}/${it}" "${CLAUDE}/${it}"; fi
        done
        log "已从备份恢复：${src}；缺少的运行时 Desktop 启动时会自动下载"
        return 0
    fi
    local orig cur
    orig=$(cat "${STATE}/original" 2>/dev/null || true)
    cur=$(cat "${STATE}/current" 2>/dev/null || true)
    if [ -n "${orig}" ] && [ -d "${PROFILES}/${orig}" ]; then
        local keep="${cur:-unnamed-$(date +%H%M%S)}"
        [ -e "${PROFILES}/${keep}" ] && keep="${keep}-$(date +%H%M%S)"
        [ -d "${CLAUDE}" ] && mv "${CLAUDE}" "${PROFILES}/${keep}"
        mv "${PROFILES}/${orig}" "${CLAUDE}"
        log "原账号 ${orig} 放回 Claude/，原当前目录停放为 profiles/${keep}（保留）"
    fi
    for it in "${SHARED_ITEMS[@]}"; do
        if [ -L "${CLAUDE}/${it}" ] && [ -d "${SHARED}/${it}" ]; then
            rm "${CLAUDE}/${it}"; mv "${SHARED}/${it}" "${CLAUDE}/${it}"; log "撤销共享：${it}"
        fi
    done
    rm -f "${STATE}/current" "${STATE}/original"
    log "回滚完成。profiles/ 下其他账号的登录目录保留，确认不需要后可手动删除。"
}

case "${1:-status}" in
    status) cmd_status ;;
    quit) cmd_quit ;;
    launch) cmd_launch ;;
    init) cmd_init "${2:-}" ;;
    backup) cmd_backup ;;
    share) cmd_share ;;
    park) cmd_park "${2:-}" ;;
    name) cmd_name "${2:-}" ;;
    unpark) cmd_unpark ;;
    add-begin) cmd_add_begin "${2:-}" ;;
    cancel-add) cmd_quit; cmd_unpark; cmd_launch ;;
    swap) cmd_swap "${2:-}" ;;
    switch) shift; cmd_switch "$@" ;;
    rollback) cmd_rollback "${2:-}" ;;
    *) die "未知子命令：$1" ;;
esac
