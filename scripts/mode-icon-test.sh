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
PREVIOUS_SOURCE=$(./scripts/input-sources.sh current)
# Run the bundled test executable from this test runner, as controller-test.sh
# does. macOS still checks this process's own accessibility permission; the
# probe records SKIP rather than requesting or bypassing unavailable access.
"$PROBE/Contents/MacOS/ModeIconProbe" "$REPORT" &
PROBE_PID=$!
cleanup() {
    kill "$PROBE_PID" 2>/dev/null || true
    wait "$PROBE_PID" 2>/dev/null || true
    ./scripts/input-sources.sh select "$PREVIOUS_SOURCE" || true
}
trap cleanup EXIT
for ((attempt=0; attempt<20; attempt++)); do
    if [ -f "$REPORT" ]; then
        cat "$REPORT"
        if rg -q '^MODE ICON METADATA PASSED:' "$REPORT"; then exit 0; fi
        if rg -q '^SKIP:' "$REPORT"; then exit 77; fi
        exit 1
    fi
    sleep 1
done
echo '模式图标验证未在 20 秒内完成；不能视作通过。' >&2
exit 1
