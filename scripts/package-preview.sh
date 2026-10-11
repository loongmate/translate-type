#!/bin/bash
# Local preview archive only. Does not install, notarize, or publish a release.
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
NAME="FangCun-$VERSION-build$BUILD-universal-preview"
mkdir -p dist .build
STAGING="$(mktemp -d "$PWD/.build/package-preview.XXXXXX")"
trap 'rm -rf "$STAGING"' EXIT
mkdir -p "$STAGING/$NAME"
ditto "$APP" "$STAGING/$NAME/FangCun.app"
cp docs/distribution-preview.txt "$STAGING/$NAME/INSTALL.txt"
ditto -c -k --keepParent "$STAGING/$NAME" "dist/$NAME.zip"
(cd dist && shasum -a 256 "$NAME.zip" > "$NAME.zip.sha256")
echo "本地预览包：$PWD/dist/$NAME.zip"
echo '仅有开发签名，未做 Apple 公证；不能作为正式安装包发布。'
