#!/bin/bash
# Build two read-only preview disk images; never install or launch the input method.
set -euo pipefail
cd "$(dirname "$0")/.."
APP="$PWD/build/FangCun.app"
PLIST="$APP/Contents/Info.plist"
codesign --verify --deep --strict "$APP"
for RELATIVE in Contents/MacOS/TranslateType Contents/Frameworks/librime.1.dylib; do
    lipo "$APP/$RELATIVE" -verify_arch x86_64 arm64
done
VERSION="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$PLIST")"
BUILD="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleVersion' "$PLIST")"
mkdir -p dist .build
STAGING="$(mktemp -d "$PWD/.build/package-dmg.XXXXXX")"
trap 'rm -rf "$STAGING"' EXIT
mkdir -p "$STAGING/images"
for CHIP in AppleSilicon Intel; do
    case "$CHIP" in
        AppleSilicon) ARCH=arm64; LABEL='Apple Silicon 版（M 系列芯片，arm64）' ;;
        Intel) ARCH=x86_64; LABEL='Intel 版（Intel 处理器，x86_64）' ;;
    esac
    NAME="FangCun-$VERSION-build$BUILD-$CHIP-preview"
    PACKAGE="$STAGING/$CHIP"
    DIST_APP="$PACKAGE/FangCun.app"
    mkdir -p "$PACKAGE"
    ditto "$APP" "$DIST_APP"
    for RELATIVE in Contents/MacOS/TranslateType Contents/Frameworks/librime.1.dylib; do
        BINARY="$DIST_APP/$RELATIVE"
        lipo "$BINARY" -thin "$ARCH" -output "$BINARY.thin"
        mv "$BINARY.thin" "$BINARY"
        [ "$(lipo -archs "$BINARY")" = "$ARCH" ]
    done
    codesign --force --sign - "$DIST_APP/Contents/Frameworks/librime.1.dylib"
    codesign --force --sign - "$DIST_APP"
    codesign --verify --deep --strict "$DIST_APP"
    printf '方寸输入法 %s · build %s\n下载版本：%s\n\n' "$VERSION" "$BUILD" "$LABEL" > "$PACKAGE/INSTALL.txt"
    cat docs/distribution-preview.txt >> "$PACKAGE/INSTALL.txt"
    # Input methods belong in Library/Input Methods, so there is no Applications alias.
    hdiutil create -volname "FangCun $VERSION $CHIP" -srcfolder "$PACKAGE" \
        -format UDZO -fs HFS+ "$STAGING/images/$NAME.dmg"
    hdiutil verify "$STAGING/images/$NAME.dmg"
    (cd "$STAGING/images" && LC_ALL=C shasum -a 256 "$NAME.dmg" > "$NAME.dmg.sha256")
done
# Expose artifacts only after both images have passed validation.
for CHIP in AppleSilicon Intel; do
    NAME="FangCun-$VERSION-build$BUILD-$CHIP-preview"
    mv "$STAGING/images/$NAME.dmg" "$STAGING/images/$NAME.dmg.sha256" dist/
    echo "DMG：$PWD/dist/$NAME.dmg"
done
echo '预览版采用 ad hoc 签名，未做 Apple 公证；请随包发布安装说明。'
