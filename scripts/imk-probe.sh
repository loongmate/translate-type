#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
APP="$PWD/.build/IMKProbe.app"
mkdir -p "$APP/Contents/MacOS"
cat > "$APP/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>CFBundleExecutable</key><string>IMKProbe</string>
<key>CFBundleIdentifier</key><string>com.fangcun.IMKProbe</string>
<key>CFBundleName</key><string>FangCun IMK Probe</string>
<key>CFBundlePackageType</key><string>APPL</string>
<key>LSUIElement</key><true/>
</dict></plist>
PLIST
swiftc -swift-version 5 Tests/IMKProbe.swift -framework AppKit -o "$APP/Contents/MacOS/IMKProbe"
"$APP/Contents/MacOS/IMKProbe"
