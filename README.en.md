# ClaudeSwitch

English | [中文](README.md)

A small macOS menu bar app that **switches Claude Desktop between multiple Claude subscription accounts in one click, and brings your Code sessions along so you can keep working on the new account.**

## What problem does it solve

If you have several Claude Pro / Max accounts and do your work in Claude Desktop, you probably know these pains:

- **Switching accounts is tedious.** Desktop only holds one login at a time. Switching means logging out, typing your email, and waiting for a verification code.
- **Your sessions disappear after switching.** The Code session list is stored per account. When one account runs out of quota mid-task and you switch, the session isn't in the sidebar anymore, so you can't just continue.
- **You can't see which account still has quota** without logging into each one.

ClaudeSwitch puts all of this in one menu bar panel:

- **Quota overview**: for every account, how much of the 5-hour and weekly limits you have left, when each resets, and the next billing date. Same layout as Desktop's settings page. Under each limit, a thin gray bar shows how much time is left in that window; hover to see whether your usage is ahead of or behind the clock.
- **One-click switching**: log in to each account once inside the tool; after that, switching needs no verification code.
- **Sessions follow you**: the panel lists recent sessions from all accounts. Tick the ones you want, click "switch and sync", and **Desktop restarts only once**. The sessions show up in the new account's sidebar, ready to continue.
- **Everything is reversible**: syncs can be undone and directory changes can be rolled back. See the [rollback guide](回退手册.md) (Chinese).

## Install

Requires macOS 14+, Claude Desktop, and Xcode Command Line Tools (for `swift` and `python3`; run `xcode-select --install` if missing).

```bash
git clone https://github.com/h0ngyue/ClaudeSwitch.git
```

```bash
cd ClaudeSwitch && scripts/build_app.sh
```

```bash
open build/ClaudeSwitch.app
```

You can drag `build/ClaudeSwitch.app` into Applications. A two-person icon appears in the menu bar, showing how much of the current account's 5-hour limit is left.

The first time you click refresh, macOS asks whether `security` may access "Claude Safe Storage" in your keychain. Click "Always Allow". The "How it works" section explains why.

## How to use

1. **Add an account**: click "添加账号" (Add account) and follow the dialog. The tool quits Desktop (and backs up its data folder the first time), saves the current account, and reopens Desktop on a blank login page. Log in to another account there; the tool detects and saves it automatically. **You do this once per account.**
2. **Switch**: click "切换" (Switch) on the target account → tick the sessions to bring along under "近期会话" (Recent sessions) → click the button at the bottom to switch and sync. Ticking nothing is fine too; that's a plain switch.
3. **Pull sessions in without switching**: tick sessions from other accounts, click "同步选中到当前账号" (Sync to current account), then "重启 Desktop" (Restart Desktop).
4. **Check quota**: click the refresh button on each account. Bars show what's left (green above 50%, orange 20–50%, red below 20%). Reset countdowns update locally every minute without any network request; after a switch the new account refreshes once automatically.

> Switching and adding accounts both quit Desktop, which interrupts any running Code session. Let your current task reach a stopping point first.

## Read this before syncing sessions: token cost

**The first time you continue a synced session on the new account, Claude re-reads the entire conversation history.**

- The transcripts themselves are shared across accounts, which is why the new account sees the full context.
- But **the prompt cache is not shared across accounts**. On the original account most of the history hits the cache each turn and is cheap. On the new account, the first message sends the whole history as fresh, full-price input.
- Example: a long session that has grown to 150k tokens. Typing "continue" on the new account costs about 150k input tokens just to read the history, which takes a noticeable bite out of the new account's 5-hour limit.
- After that first read, the new account builds its own cache and later turns cost the usual amount.

How to save tokens:

1. **Only sync sessions you actually need to continue.** Don't select everything. By default the tool only ticks sessions that were cut off by a usage limit.
2. **If the old account still has quota, run `/compact` before switching.** A compacted session is short and cheap to re-read on the new account.
3. **If the old account is already out of quota**: open the session on the new account and make `/compact` your very first message, not "continue". Compacting reads the history once too, but only once; every turn after that is cheap.
4. **For very long or derailed sessions, don't sync at all.** Ask the AI (or write yourself) a short handoff summary and start a fresh session on the new account.
5. **Never run the same session on two accounts at the same time.** Both write to the same transcript and can overwrite each other.

## How it works

- **Switching**: Desktop only reads one data folder, `~/Library/Application Support/Claude/`. The tool keeps a separate copy of that folder per account. To switch, it quits Desktop, swaps the folders, and reopens Desktop. That's why each account only needs one login.
- **Session sync**: the Code session list is just a set of small index files under `claude-code-sessions/<accountId>/<orgId>/`, a few KB each. The actual transcripts live in `~/.claude/projects/` and are shared by all accounts. Syncing copies index files into the target account's folder; transcripts are never copied or modified.
- **Disk space**: the session index folder and Desktop's runtime (about 10 GB) live in a shared area, and each account folder symlinks to them, so nothing is stored once per account.
- **Quota**: Desktop stores its login cookie encrypted, with the key in the keychain item "Claude Safe Storage". The tool reads that key, decrypts the selected account's cookie, and calls the same claude.ai usage endpoint that Desktop's settings page uses. The key and cookie stay in memory only: never written to disk, never printed, sent only to claude.ai.

## Risks and caveats

- **This is an unofficial tool**, not affiliated with Anthropic. The claude.ai endpoints it uses are undocumented and may change at any time, and a change to Desktop's data folder layout could break it.
- **Whether using multiple accounts is allowed under the terms of service is your call, at your own risk.** The tool keeps requests to a minimum: no background polling, requests go out only when you click an account's refresh button or right after switching to an account, and only for that account, a normal refresh sends a single request, and request headers match Desktop's.
- **It never deletes your data.** The scripts only rename, move, and create symlinks. Before the first account is added, the data folder is backed up (excluding the 10 GB runtime).
- The UI is Chinese-only for now.

## Rolling back

See the [rollback guide](回退手册.md) (Chinese): undoing a sync, abandoning an account add, restoring the original layout, and restoring from backup. The main commands:

```bash
scripts/claude_profiles.sh status
```

```bash
scripts/claude_profiles.sh quit && scripts/claude_profiles.sh rollback && scripts/claude_profiles.sh launch
```

## Where data lives

All of the tool's own data is under `~/Library/Application Support/ClaudeSwitch/`:

| Path | Contents |
|---|---|
| `profiles/` | data folders of accounts not currently in use |
| `shared/` | session index and Desktop runtime shared by all accounts |
| `backup/` | backup taken before the first account was added |
| `state/` | which account is current |
| `settings.json` | names you gave accounts, detected emails |
| `usage_cache.json` | last fetched quota (no cookies) |
| `actions.log` | log of every operation |

## How is this different from cc-switch and similar tools

Tools like cc-switch switch the API provider or token used by the Claude Code CLI; they can't touch Claude Desktop's login. ClaudeSwitch does one thing: switch the account Claude Desktop itself is logged into, and bring your sessions along.

## License

[MIT](LICENSE)
