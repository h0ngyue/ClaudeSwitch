#!/bin/bash
# 编译并打包成 build/ClaudeSwitch.app（菜单栏应用，无 Dock 图标）。
# 用法：scripts/build_app.sh        之后 open build/ClaudeSwitch.app
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

swift build -c release
APP="$ROOT/build/ClaudeSwitch.app"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp .build/release/ClaudeSwitch "$APP/Contents/MacOS/ClaudeSwitch"
# 切换脚本与会话同步脚本随 .app 分发，程序从 Resources 里调用
cp scripts/claude_profiles.sh scripts/restore_sessions.py "$APP/Contents/Resources/"
chmod +x "$APP/Contents/Resources/claude_profiles.sh" "$APP/Contents/Resources/restore_sessions.py"
cat > "$APP/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleIdentifier</key><string>local.claudeswitch</string>
    <key>CFBundleName</key><string>ClaudeSwitch</string>
    <key>CFBundleExecutable</key><string>ClaudeSwitch</string>
    <key>CFBundlePackageType</key><string>APPL</string>
    <key>CFBundleShortVersionString</key><string>0.1.0</string>
    <key>LSMinimumSystemVersion</key><string>14.0</string>
    <key>LSUIElement</key><true/>
</dict>
</plist>
PLIST
codesign --force --sign - "$APP" >/dev/null
echo "已生成 $APP"
