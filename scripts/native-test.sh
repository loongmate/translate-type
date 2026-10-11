#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
PROBE="$PWD/.build/NativeProbe.app"
REPORT="$PWD/.build/native-result.txt"
mkdir -p "$PROBE/Contents/MacOS"
swiftc Tests/NativeProbe.swift -framework AppKit -framework Carbon -o "$PROBE/Contents/MacOS/NativeProbe"
cat > "$PROBE/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>CFBundleExecutable</key><string>NativeProbe</string>
<key>CFBundleIdentifier</key><string>com.translatetype.NativeProbe</string>
<key>CFBundleName</key><string>方寸输入法本机验证</string>
<key>CFBundlePackageType</key><string>APPL</string>
<key>NSPrincipalClass</key><string>NSApplication</string>
</dict></plist>
PLIST
codesign --force --sign - "$PROBE"
rm -f "$REPORT"
open -n -a "$PROBE" --args --report "$REPORT"
for ((attempt=0; attempt<20; attempt++)); do
    if [ -f "$REPORT" ]; then
        cat "$REPORT"
        if rg -q '^NATIVE IMK INTEGRATION PASSED:' "$REPORT"; then exit 0; fi
        if rg -q '^SKIP:' "$REPORT"; then exit 77; fi
        if rg -q 'Input source select|输入源未注册' "$REPORT"; then
            echo '请在系统设置中添加「方寸输入法」，首次安装可能需要重新登录，然后再次验证。' >&2
        else
            echo '输入源可选，但文本客户端验收失败；需要继续排查，不能视作通过。' >&2
        fi
        exit 1
    fi
    sleep 1
done
echo '系统输入会话验证未在 20 秒内完成；不能视作通过。' >&2
exit 1
