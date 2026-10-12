#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
RIME="$PWD/.cache/rime/dist"
APP="$PWD/.build/PanelTests.app"
mkdir -p "$APP/Contents/MacOS"
cat > "$APP/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>CFBundleExecutable</key><string>PanelTests</string>
<key>CFBundleIdentifier</key><string>com.fangcun.PanelTests</string>
<key>CFBundlePackageType</key><string>APPL</string>
<key>LSUIElement</key><true/>
</dict></plist>
PLIST
python3 Tests/mock_server.py > .build/panel-mock-server.log 2>&1 &
MOCK_PID=$!
trap 'kill "$MOCK_PID" 2>/dev/null || true' EXIT
clang -fobjc-arc -O2 -I "$RIME/include" -c Sources/RimeBridge.m -o .build/PanelBridge.o
swiftc -swift-version 5 -Onone -import-objc-header Sources/RimeBridge.h \
    Sources/Configuration.swift Sources/PinyinEngine.swift Sources/ContextRanking.swift Sources/CompositionSession.swift Sources/TranslationClient.swift Sources/CandidatePanel.swift \
    Tests/PanelTests.swift .build/PanelBridge.o \
    -L "$RIME/lib" -lrime -framework AppKit -framework Security \
    -Xlinker -rpath -Xlinker "$RIME/lib" -o "$APP/Contents/MacOS/PanelTests"
"$APP/Contents/MacOS/PanelTests"
