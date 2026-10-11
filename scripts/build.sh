#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
ROOT="$PWD"
RIME="$ROOT/.cache/rime/dist"
mkdir -p .build build
STAGING="$(mktemp -d "$ROOT/.build/app-stage.XXXXXX")"
trap 'rm -rf "$STAGING"' EXIT
APP="$STAGING/FangCun.app"
SDK="$(xcrun --sdk macosx --show-sdk-path)"
MIN_MACOS="$(/usr/libexec/PlistBuddy -c 'Print :LSMinimumSystemVersion' Resources/Info.plist)"
# Local builds keep their host architecture. Distribution builds opt in to both.
read -r -a ARCHS <<< "${FANGCUN_ARCHS:-$(uname -m)}"
BINARIES=()
mkdir -p .build "$APP/Contents/MacOS" "$APP/Contents/Resources" "$APP/Contents/Frameworks"
if [ ! -f "$RIME/include/rime_api.h" ] || [ ! -s Resources/pinyin_simp.dict.yaml ]; then
    echo '请先运行 scripts/bootstrap.sh 下载拼音引擎和词库。' >&2
    exit 1
fi
if [ ! -s Resources/AppIcon.icns ] || [ ! -s Resources/InputMenuIcon-v6.pdf ]; then swift scripts/MakeIcon.swift; fi
if [ ! -s Resources/InputMenuEnglish-v1.pdf ]; then swift scripts/MakeIcon.swift --english-menu-only; fi
python3 scripts/prepare-double-pinyin.py
for ARCH in "${ARCHS[@]}"; do
    case "$ARCH" in x86_64|arm64) ;; *) echo "不支持的架构：$ARCH" >&2; exit 1 ;; esac
    lipo "$RIME/lib/librime.1.17.0.dylib" -verify_arch "$ARCH"
    OUTPUT="$ROOT/.build/release-$ARCH"
    mkdir -p "$OUTPUT"
    clang -target "$ARCH-apple-macos$MIN_MACOS" -isysroot "$SDK" -fobjc-arc -O2 \
        -I "$RIME/include" -c Sources/RimeBridge.m -o "$OUTPUT/RimeBridge.o"
    swiftc -target "$ARCH-apple-macosx$MIN_MACOS" -sdk "$SDK" -swift-version 5 -O -module-name TranslateType \
        -import-objc-header Sources/RimeBridge.h Sources/*.swift "$OUTPUT/RimeBridge.o" \
        -L "$RIME/lib" -lrime -framework AppKit -framework InputMethodKit -framework Carbon -framework Security \
        -Xlinker -rpath -Xlinker @executable_path/../Frameworks -o "$OUTPUT/TranslateType"
    BINARIES+=("$OUTPUT/TranslateType")
done
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
lipo -create "${BINARIES[@]}" -output "$APP/Contents/MacOS/TranslateType"
codesign --force --sign - "$APP/Contents/Frameworks/librime.1.dylib"
codesign --force --sign - "$APP"
codesign --verify --deep --strict "$APP"
lipo -archs "$APP/Contents/MacOS/TranslateType"
# Assemble a fresh bundle so removed resources cannot leak into a release.
# Preserve the previous build until both architectures and signatures pass.
rm -rf "$ROOT/build/FangCun.app"
mv "$APP" "$ROOT/build/FangCun.app"
echo "$ROOT/build/FangCun.app"
