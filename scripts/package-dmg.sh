#!/bin/bash
# Build two read-only preview disk images; never install or launch the input method.
set -euo pipefail
cd "$(dirname "$0")/.."
APP="$PWD/build/FangCun.app"
PLIST="$APP/Contents/Info.plist"
SIGN_ID="${FANGCUN_SIGN_ID:--}"
NOTARY_PROFILE="${FANGCUN_NOTARY_PROFILE:-}"
if [ -n "$NOTARY_PROFILE" ] && [ "$SIGN_ID" = - ]; then
    echo 'Apple 公证需要通过 FANGCUN_SIGN_ID 指定 Developer ID Application 证书。' >&2
    exit 1
fi
SIGN_FLAGS=(--force --sign "$SIGN_ID")
if [ "$SIGN_ID" != - ]; then SIGN_FLAGS+=(--options runtime --timestamp); fi
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
notarize() {
    local FILE="$1" LOG="$2"
    xcrun notarytool submit "$FILE" --keychain-profile "$NOTARY_PROFILE" \
        --wait --output-format json > "$LOG"
    python3 - "$LOG" <<'PY'
import json, sys
result = json.load(open(sys.argv[1]))
print('Apple notarization:', result.get('id'), result.get('status'))
if result.get('status') != 'Accepted':
    raise SystemExit('公证未通过，停止打包；请使用 notarytool log 检查该提交。')
PY
}
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
    codesign "${SIGN_FLAGS[@]}" "$DIST_APP/Contents/Frameworks/librime.1.dylib"
    if [ "$SIGN_ID" = - ]; then
        codesign --force --sign - "$DIST_APP"
    else
        codesign "${SIGN_FLAGS[@]}" --entitlements Resources/Release.entitlements "$DIST_APP"
    fi
    codesign --verify --deep --strict "$DIST_APP"
    if [ -n "$NOTARY_PROFILE" ]; then
        ditto -c -k --keepParent "$DIST_APP" "$STAGING/$CHIP-notary.zip"
        notarize "$STAGING/$CHIP-notary.zip" "$PWD/.build/notary-build$BUILD-$CHIP-app.json"
        xcrun stapler staple "$DIST_APP"
        xcrun stapler validate "$DIST_APP"
        spctl --assess --type execute --verbose=4 "$DIST_APP"
    fi
    printf '方寸输入法 %s · build %s\n下载版本：%s\n\n' "$VERSION" "$BUILD" "$LABEL" > "$PACKAGE/INSTALL.txt"
    if [ -n "$NOTARY_PROFILE" ]; then
        echo '应用和 DMG 使用 Developer ID 正式签名，并通过 Apple 公证。' >> "$PACKAGE/INSTALL.txt"
    elif [ "$SIGN_ID" != - ]; then
        echo '应用和 DMG 使用 Developer ID 正式签名，尚未通过 Apple 公证。' >> "$PACKAGE/INSTALL.txt"
    else
        echo '本包采用 ad hoc 临时代码签名，没有 Developer ID 签名或 Apple 公证。' >> "$PACKAGE/INSTALL.txt"
    fi
    cat docs/distribution-preview.txt >> "$PACKAGE/INSTALL.txt"
    # Input methods belong in Library/Input Methods, so there is no Applications alias.
    hdiutil create -volname "FangCun $VERSION $CHIP" -srcfolder "$PACKAGE" \
        -format UDZO -fs HFS+ "$STAGING/images/$NAME.dmg"
    if [ "$SIGN_ID" != - ]; then
        codesign --force --timestamp --sign "$SIGN_ID" "$STAGING/images/$NAME.dmg"
        codesign --verify --strict "$STAGING/images/$NAME.dmg"
    fi
    if [ -n "$NOTARY_PROFILE" ]; then
        notarize "$STAGING/images/$NAME.dmg" "$PWD/.build/notary-build$BUILD-$CHIP-dmg.json"
        xcrun stapler staple "$STAGING/images/$NAME.dmg"
        xcrun stapler validate "$STAGING/images/$NAME.dmg"
        spctl --assess --type open --context context:primary-signature --verbose=4 "$STAGING/images/$NAME.dmg"
    fi
    hdiutil verify "$STAGING/images/$NAME.dmg"
    (cd "$STAGING/images" && LC_ALL=C shasum -a 256 "$NAME.dmg" > "$NAME.dmg.sha256")
done
# Expose artifacts only after both images have passed validation.
for CHIP in AppleSilicon Intel; do
    NAME="FangCun-$VERSION-build$BUILD-$CHIP-preview"
    mv "$STAGING/images/$NAME.dmg" "$STAGING/images/$NAME.dmg.sha256" dist/
    echo "DMG：$PWD/dist/$NAME.dmg"
done
echo 'DMG 打包完成；签名与公证状态见包内 INSTALL.txt。'
