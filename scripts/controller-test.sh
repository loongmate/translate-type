#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
RIME="$PWD/.cache/rime/dist"
APP="$PWD/.build/ControllerTests.app"
mkdir -p "$APP/Contents/MacOS"
clang -fobjc-arc -O2 -I "$RIME/include" -c Sources/RimeBridge.m -o .build/RimeBridge.o
cat > "$APP/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>CFBundleExecutable</key><string>ControllerTests</string>
<key>CFBundleIdentifier</key><string>com.fangcun.ControllerTests</string>
<key>CFBundleName</key><string>FangCun Controller Tests</string>
<key>CFBundlePackageType</key><string>APPL</string>
<key>InputMethodServerControllerClass</key><string>TTInputController</string>
<key>LSUIElement</key><true/>
</dict></plist>
PLIST
SOURCES=()
for SOURCE in Sources/*.swift; do
    if [ "$SOURCE" != 'Sources/main.swift' ]; then SOURCES+=("$SOURCE"); fi
done
swiftc -swift-version 5 -Onone -import-objc-header Sources/RimeBridge.h \
    "${SOURCES[@]}" Tests/TextClient.swift Tests/ControllerTests.swift .build/RimeBridge.o \
    -L "$RIME/lib" -lrime -framework AppKit -framework InputMethodKit -framework Carbon -framework Security \
    -Xlinker -rpath -Xlinker "$RIME/lib" -o "$APP/Contents/MacOS/ControllerTests"
"$APP/Contents/MacOS/ControllerTests" "$@"
