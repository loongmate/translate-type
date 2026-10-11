#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
ROOT="$PWD"
RIME="$ROOT/.cache/rime/dist"
APP="$ROOT/build/FangCun.app"
mkdir -p .build "$APP/Contents/MacOS" "$APP/Contents/Resources" "$APP/Contents/Frameworks"
if [ ! -f "$RIME/include/rime_api.h" ] || [ ! -s Resources/pinyin_simp.dict.yaml ]; then
    echo '请先运行 scripts/bootstrap.sh 下载拼音引擎和词库。' >&2
    exit 1
fi
if [ ! -s Resources/AppIcon.icns ] || [ ! -s Resources/InputMenuIcon-v6.pdf ]; then swift scripts/MakeIcon.swift; fi
python3 scripts/prepare-double-pinyin.py
clang -fobjc-arc -O2 -I "$RIME/include" -c Sources/RimeBridge.m -o .build/RimeBridge.o
cp "$RIME/lib/librime.1.17.0.dylib" "$APP/Contents/Frameworks/librime.1.dylib"
cp Resources/*.yaml Resources/*LICENSE.txt Resources/*.pdf Resources/*.tiff Resources/*.icns "$APP/Contents/Resources/"
cp -R Resources/*.lproj "$APP/Contents/Resources/"
cp Resources/InfoPlist.strings "$APP/Contents/Resources/InfoPlist.strings"
python3 - "$APP/Contents/Resources" <<'PY'
from pathlib import Path
import sys
for path in Path(sys.argv[1]).rglob('InfoPlist.strings'):
    text = path.read_text(encoding='utf-8')
    path.write_bytes(text.encode('utf-16'))
PY
cp Resources/Info.plist "$APP/Contents/Info.plist"
swiftc -swift-version 5 -O -module-name TranslateType \
    -import-objc-header Sources/RimeBridge.h Sources/*.swift .build/RimeBridge.o \
    -L "$RIME/lib" -lrime -framework AppKit -framework InputMethodKit -framework Carbon -framework Security \
    -Xlinker -rpath -Xlinker @executable_path/../Frameworks -o "$APP/Contents/MacOS/TranslateType"
codesign --force --sign - "$APP/Contents/Frameworks/librime.1.dylib"
codesign --force --sign - "$APP"
echo "$APP"
