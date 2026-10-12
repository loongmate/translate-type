#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
APP="$PWD/.build/ContextHostProbe.app"
mkdir -p "$APP/Contents/MacOS"
swiftc Tests/ContextHostProbe.swift -framework AppKit -framework WebKit -framework Carbon -o "$APP/Contents/MacOS/ContextHostProbe"
cat > "$APP/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict><key>CFBundleExecutable</key><string>ContextHostProbe</string><key>CFBundleIdentifier</key><string>com.fangcun.ContextHostProbe</string><key>CFBundleName</key><string>方寸上下文验证</string><key>CFBundlePackageType</key><string>APPL</string></dict></plist>
PLIST
codesign --force --sign - "$APP"
PREVIOUS=$(./scripts/input-sources.sh current)
trap './scripts/input-sources.sh select "$PREVIOUS" || true' EXIT
"$APP/Contents/MacOS/ContextHostProbe" "$PWD/.build/context-samples.jsonl" "$PWD/.build/context-host-results.json"
