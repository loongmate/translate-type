#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
PROBE="$PWD/.build/ModeIconProbe.app"
REPORT="$PWD/.build/mode-icon-result.txt"
mkdir -p "$PROBE/Contents/MacOS"
swiftc Tests/ModeIconProbe.swift -framework AppKit -framework Carbon -o "$PROBE/Contents/MacOS/ModeIconProbe"
cat > "$PROBE/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>CFBundleExecutable</key><string>ModeIconProbe</string>
<key>CFBundleIdentifier</key><string>com.fangcun.ModeIconProbe</string>
<key>CFBundleName</key><string>方寸中英文图标验证</string>
<key>CFBundlePackageType</key><string>APPL</string>
</dict></plist>
PLIST
codesign --force --sign - "$PROBE"
rm -f "$REPORT"
open -n -a "$PROBE" --args "$REPORT"
for ((attempt=0; attempt<20; attempt++)); do
    if [ -f "$REPORT" ]; then
        cat "$REPORT"
        if rg -q '^MODE ICON INTEGRATION PASSED:' "$REPORT"; then exit 0; fi
        if rg -q '^SKIP:' "$REPORT"; then exit 77; fi
        exit 1
    fi
    sleep 1
done
echo '模式图标验证未在 20 秒内完成；不能视作通过。' >&2
exit 1
