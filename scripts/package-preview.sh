#!/bin/bash
# Prepare unsigned preview archives. Does not install, notarize, or upload them.
set -euo pipefail
cd "$(dirname "$0")/.."
APP="$PWD/build/FangCun.app"
PLIST="$APP/Contents/Info.plist"
if [ ! -x "$APP/Contents/MacOS/TranslateType" ]; then
    echo '请先运行 FANGCUN_ARCHS="x86_64 arm64" ./scripts/build.sh' >&2
    exit 1
fi
codesign --verify --deep --strict "$APP"
for BINARY in "$APP/Contents/MacOS/TranslateType" "$APP/Contents/Frameworks/librime.1.dylib"; do
    lipo "$BINARY" -verify_arch x86_64 arm64
done
VERSION="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$PLIST")"
BUILD="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleVersion' "$PLIST")"
mkdir -p dist .build
STAGING="$(mktemp -d "$PWD/.build/package-preview.XXXXXX")"
trap 'rm -rf "$STAGING"' EXIT
mkdir -p "$STAGING/archives"
for CHIP in AppleSilicon Intel; do
    case "$CHIP" in
        AppleSilicon) ARCH=arm64; LABEL='Apple Silicon 版（M 系列芯片，arm64）' ;;
        Intel) ARCH=x86_64; LABEL='Intel 版（Intel 处理器，x86_64）' ;;
    esac
    NAME="FangCun-$VERSION-build$BUILD-$CHIP-preview"
    PACKAGE="$STAGING/$NAME"
    DIST_APP="$PACKAGE/FangCun.app"
    mkdir -p "$PACKAGE"
    ditto "$APP" "$DIST_APP"
    # Strip both the executable and Rime, then sign the changed bundle inside out.
    for RELATIVE in Contents/MacOS/TranslateType Contents/Frameworks/librime.1.dylib; do
        BINARY="$DIST_APP/$RELATIVE"
        lipo "$BINARY" -thin "$ARCH" -output "$BINARY.thin"
        mv "$BINARY.thin" "$BINARY"
        [ "$(lipo -archs "$BINARY")" = "$ARCH" ]
    done
    codesign --force --sign - "$DIST_APP/Contents/Frameworks/librime.1.dylib"
    codesign --force --sign - "$DIST_APP"
    codesign --verify --deep --strict "$DIST_APP"
    printf '下载版本：%s\n\n' "$LABEL" > "$PACKAGE/INSTALL.txt"
    cat docs/distribution-preview.txt >> "$PACKAGE/INSTALL.txt"
    ditto -c -k --keepParent "$PACKAGE" "$STAGING/archives/$NAME.zip"
    (cd "$STAGING/archives" && LC_ALL=C shasum -a 256 "$NAME.zip" > "$NAME.zip.sha256")
done
# Publish the pair locally only after both bundles have passed validation.
for CHIP in AppleSilicon Intel; do
    NAME="FangCun-$VERSION-build$BUILD-$CHIP-preview"
    mkdir -p "build/releases/$CHIP"
    rm -rf "build/releases/$CHIP/FangCun.app"
    mv "$STAGING/$NAME/FangCun.app" "build/releases/$CHIP/FangCun.app"
    mv "$STAGING/archives/$NAME.zip" "$STAGING/archives/$NAME.zip.sha256" dist/
    echo "本地预览包：$PWD/dist/$NAME.zip"
done
# Keep superseded local universal artifacts out of the two-download directory.
mkdir -p .build/retired-distributions
for EXT in zip zip.sha256; do
    OLD="dist/FangCun-$VERSION-build$BUILD-universal-preview.$EXT"
    if [ -f "$OLD" ]; then mv "$OLD" .build/retired-distributions/; fi
done
echo '预览包仅有开发签名，未做 Apple 公证；发布时需明确此状态及手动安装步骤。'
