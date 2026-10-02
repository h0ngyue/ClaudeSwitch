"""把另一个 Claude 账户下的 Desktop 会话复制到当前账户的会话列表。

背景：Claude Desktop 的 Code 会话列表按账户分目录保存在
~/Library/Application Support/Claude/claude-code-sessions/<账户ID>/<组织ID>/local_*.json，
每个索引文件用 cliSessionId 指向 ~/.claude/projects/ 下真正的对话记录（账户共用）。
所以只要把索引文件复制到当前账户目录，重启 Desktop 后就能在左侧列表看到并接着跑。

当前账户目录的判定：正在运行的会话会不断刷新自己的索引文件，
因此取「最近被修改的索引文件」所在目录作为当前账户目录。
ClaudeSwitch 在 Desktop 已退出的切换中途调用时，用 --to 明确指定目标账户。

每次复制都会把新建的文件记进 ~/.claude/switch-account-resume/last_restore.json，
--undo 只删除这些由本脚本新建、且之后没被 Desktop 改过的索引文件，用于回退。

用法（从任意目录执行）：
    python3 restore_sessions.py                 # 列出可恢复的会话
    python3 restore_sessions.py 08609474         # 按会话 ID 前缀复制，可给多个
    python3 restore_sessions.py --json           # 机器可读输出（全部账户与会话）
    python3 restore_sessions.py --to=19ebadca 08609474   # 复制到指定账户（可写「账户ID/组织ID」）
    python3 restore_sessions.py --undo           # 撤销上一次复制
"""
import json
import os
import shutil
import sys
from datetime import datetime
from pathlib import Path

SESSIONS_ROOT = Path(os.environ.get(
    "CLAUDE_SESSIONS_ROOT", Path.home() / "Library/Application Support/Claude/claude-code-sessions"))
PROJECTS_ROOT = Path(os.environ.get("CLAUDE_PROJECTS_ROOT", Path.home() / ".claude/projects"))
JOURNAL = Path(os.environ.get(
    "RESTORE_JOURNAL", Path.home() / ".claude/switch-account-resume/last_restore.json"))
LIST_LIMIT = 15
LIMIT_MARKERS = ("hit your session limit", "hit your usage limit", "usage limit reached")
TODO_TEXT = """
📌 接下来你要做的两步：
  1. ⌘Q 完全退出 Claude Desktop 再打开（只关窗口不够），左侧列表才会出现恢复的会话。
  2. 点进恢复的会话，第一条消息先发 /compact，压缩完再让它继续原任务。"""


def load_index(path):
    try:
        return json.loads(path.read_text())
    except (OSError, ValueError):
        return None


def account_dirs():
    return [d for d in SESSIONS_ROOT.glob("*/*") if d.is_dir()]


def current_account_dir():
    newest = max(
        (f for d in account_dirs() for f in d.glob("local_*.json")),
        key=lambda f: f.stat().st_mtime,
        default=None,
    )
    if newest is None:
        sys.exit("没找到任何 Desktop 会话索引，确认 Claude Desktop 已登录并用过 Code 页。")
    return newest.parent


def resolve_account_dir(prefix):
    """按账户 ID 前缀找目标目录（<账户ID>/<组织ID>），必须唯一命中。
    也可以写完整的「账户ID/组织ID」：这个账号还没用过 Code 页、目录不存在时，复制时再新建。"""
    if "/" in prefix:
        return SESSIONS_ROOT / prefix
    hits = [d for d in account_dirs() if d.parent.name.startswith(prefix)]
    if len(hits) != 1:
        sys.exit("--to=%s 匹配到 %d 个账户目录，需要唯一命中。" % (prefix, len(hits)))
    return hits[0]


def fmt_ms(ms):
    if not ms:
        return "未知"
    return datetime.fromtimestamp(ms / 1000).strftime("%m-%d %H:%M")


def ended_by_limit(cli_id):
    """看对话记录末尾是否停在额度用尽的报错上。"""
    for f in PROJECTS_ROOT.glob("*/%s.jsonl" % cli_id):
        with open(f, "rb") as fh:
            fh.seek(0, os.SEEK_END)
            fh.seek(max(0, fh.tell() - 20000))
            tail = fh.read().decode("utf-8", "ignore").lower()
        return any(m in tail for m in LIMIT_MARKERS)
    return False


def candidates(cur_dir):
    """其他账户目录里、当前账户还没有的会话，按最近活动时间倒序。"""
    have = {f.name for f in cur_dir.glob("local_*.json")}
    found = {}
    for d in account_dirs():
        if d == cur_dir:
            continue
        for f in d.glob("local_*.json"):
            if f.name in have:
                continue
            j = load_index(f)
            if not j or j.get("isArchived"):
                continue
            old = found.get(f.name)
            if old is None or j.get("lastActivityAt", 0) > old[1].get("lastActivityAt", 0):
                found[f.name] = (f, j)
    return sorted(found.values(), key=lambda x: x[1].get("lastActivityAt", 0), reverse=True)


def print_list(cur_dir, items):
    print("当前账户目录：%s" % cur_dir.relative_to(SESSIONS_ROOT))
    if not items:
        print("其他账户下没有当前账户缺少的会话。")
        return
    print("可恢复的会话（按最近活动倒序，最多 %d 条）：" % LIST_LIMIT)
    for f, j in items[:LIST_LIMIT]:
        cli_id = j.get("cliSessionId", "")
        flag = " [被额度打断]" if ended_by_limit(cli_id) else ""
        print("  %s  %s  %s%s\n      目录：%s" % (
            cli_id[:8], fmt_ms(j.get("lastActivityAt")), j.get("title", "(无标题)"), flag, j.get("cwd", "")))


def session_row(f, j):
    return {
        "sessionId": j.get("sessionId", ""),
        "cliSessionId": j.get("cliSessionId", ""),
        "title": j.get("title", "(无标题)"),
        "cwd": j.get("cwd", ""),
        "lastActivityAt": j.get("lastActivityAt", 0),
        "accountId": f.parent.parent.name,
        "interrupted": ended_by_limit(j.get("cliSessionId", "")),
    }


def dump_json(cur_dir, items):
    """全部账户、全部未归档会话（不截断）与当前账户缺少的候选，供菜单栏工具渲染。"""
    accounts, sessions = [], []
    for d in account_dirs():
        files = list(d.glob("local_*.json"))
        accounts.append({"accountId": d.parent.name, "orgId": d.name,
                         "sessionCount": len(files), "isCurrent": d == cur_dir})
        for f in files:
            j = load_index(f)
            if j and not j.get("isArchived"):
                sessions.append(session_row(f, j))
    # 同一会话被同步过就会出现在多个账户目录里：按会话合并，保留最近活动的一份并列出所在账户
    merged = {}
    for s in sorted(sessions, key=lambda s: s["lastActivityAt"], reverse=True):
        if s["sessionId"] in merged:
            merged[s["sessionId"]]["accountIds"].append(s["accountId"])
        else:
            merged[s["sessionId"]] = dict(s, accountIds=[s["accountId"]])
    sessions = list(merged.values())
    out = {
        "currentAccountId": cur_dir.parent.name,
        "accounts": accounts,
        "sessions": sessions,
        "candidates": [session_row(f, j) for f, j in items],
    }
    print(json.dumps(out, ensure_ascii=False))


def write_journal(copied_paths):
    JOURNAL.parent.mkdir(parents=True, exist_ok=True)
    records = [{"path": str(p), "mtime": p.stat().st_mtime} for p in copied_paths]
    JOURNAL.write_text(json.dumps({"at": datetime.now().astimezone().isoformat(), "files": records},
                                  ensure_ascii=False, indent=1))


def already_has(cur_dir, prefix):
    for f in cur_dir.glob("local_*.json"):
        j = load_index(f) or {}
        if j.get("cliSessionId", "").startswith(prefix) or j.get("sessionId", "").startswith(prefix):
            return True
    return False


def copy_sessions(cur_dir, items, prefixes, show_todo=True):
    """返回是否全部成功；目标账户已有的会话算成功，ID 找不到或不唯一算失败。"""
    copied, failed = [], 0
    for p in prefixes:
        hits = [(f, j) for f, j in items
                if j.get("cliSessionId", "").startswith(p) or j.get("sessionId", "").startswith(p)]
        if not hits and already_has(cur_dir, p):
            print("跳过 %s：目标账户已有该会话。" % p)
            continue
        if not hits:
            print("失败 %s：没找到这个会话，ID 可能写错。" % p)
            failed += 1
            continue
        if len(hits) > 1:
            print("失败 %s：匹配到 %d 个会话，请给更长的 ID 前缀。" % (p, len(hits)))
            failed += 1
            continue
        src, j = hits[0]
        dst = cur_dir / src.name
        if dst.exists():
            print("跳过 %s：当前账户已有该会话。" % j.get("title"))
            continue
        dst.parent.mkdir(parents=True, exist_ok=True)
        shutil.copy2(src, dst)
        copied.append(dst)
        print("已复制：%s（%s）" % (j.get("title"), j.get("cliSessionId")))
    if copied:
        write_journal(copied)
        print("完成 %d 个。撤销用 --undo。" % len(copied))
        if show_todo:
            print(TODO_TEXT)
    return failed == 0


def undo_last():
    """删除上一次复制新建的索引文件；被 Desktop 改过（已在新账户里用过）的保留不删。"""
    if not JOURNAL.exists():
        sys.exit("没有可撤销的复制记录。")
    records = json.loads(JOURNAL.read_text())["files"]
    for r in records:
        p = Path(r["path"])
        if not p.exists():
            print("已不存在，跳过：%s" % p.name)
        elif abs(p.stat().st_mtime - r["mtime"]) > 1:
            print("复制后已被 Desktop 修改（说明在新账户里用过），保留：%s" % p.name)
        else:
            p.unlink()
            print("已删除：%s" % p.name)
    JOURNAL.unlink()
    print("撤销完成。⌘Q 重启 Desktop 后列表恢复原样。")


def main(argv):
    flags = [a for a in argv if a.startswith("--")]
    ids = [a for a in argv if not a.startswith("--")]
    if "--undo" in flags:
        undo_last()
        return
    to = next((a.split("=", 1)[1] for a in flags if a.startswith("--to=")), None)
    cur_dir = resolve_account_dir(to) if to else current_account_dir()
    items = candidates(cur_dir)
    if ids:
        # 指定了目标账户说明是菜单栏或切号脚本调用，重启由调用方负责，不打印手动待办
        if not copy_sessions(cur_dir, items, ids, show_todo=not to):
            sys.exit(2)
    elif "--json" in flags:
        dump_json(cur_dir, items)
    else:
        print_list(cur_dir, items)


if __name__ == "__main__":
    main(sys.argv[1:])
