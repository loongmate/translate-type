#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
RIME="$PWD/.cache/rime/dist"
mkdir -p .build
# Reuse only compiled dictionaries, never user learning. Invalidate on any schema/dictionary change.
python3 - <<'PY_CACHE'
from pathlib import Path
import hashlib, shutil
h=hashlib.sha256()
for p in sorted(Path('Resources').glob('*.yaml')):
    h.update(p.name.encode()); h.update(p.read_bytes())
marker=Path('.build/editor-rime-cache.sha256')
if not marker.exists() or marker.read_text() != h.hexdigest():
    shutil.rmtree('.build/editor-rime-cache',ignore_errors=True)
marker.write_text(h.hexdigest())
PY_CACHE
python3 Tests/mock_server.py > .build/editor-mock.log 2>&1 &
MOCK_PID=$!
trap 'kill "$MOCK_PID" 2>/dev/null || true' EXIT
TEST_SUITE="${FANGCUN_EDITOR_TEST:-EditorTests}"
case "$TEST_SUITE" in EditorTests|AIActionTests) ;; *) exit 2 ;; esac
APP="$PWD/.build/$TEST_SUITE.app"
mkdir -p "$APP/Contents/MacOS"
clang -fobjc-arc -O2 -I "$RIME/include" -c Sources/RimeBridge.m -o .build/RimeBridge.o
cat > "$APP/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>CFBundleExecutable</key><string>EditorTests</string>
<key>CFBundleIdentifier</key><string>com.fangcun.EditorTests</string>
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
    "${SOURCES[@]}" Tests/TextClient.swift "Tests/$TEST_SUITE.swift" .build/RimeBridge.o \
    -L "$RIME/lib" -lrime -framework AppKit -framework InputMethodKit -framework Carbon -framework Security \
    -Xlinker -rpath -Xlinker "$RIME/lib" -o "$APP/Contents/MacOS/EditorTests"
"$APP/Contents/MacOS/EditorTests" "$@"
