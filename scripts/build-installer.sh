#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
PAYLOAD="$1"
INSTALLER="$2"
ARCH="$3"
case "$ARCH" in x86_64|arm64) ;; *) exit 2 ;; esac
SDK="$(xcrun --sdk macosx --show-sdk-path)"
mkdir -p "$INSTALLER/Contents/MacOS" "$INSTALLER/Contents/Resources"
swiftc -swift-version 5 -parse-as-library -O -target "$ARCH-apple-macosx13.0" -sdk "$SDK" \
    Installer/*.swift Sources/InputSourceStatus.swift Sources/InstallationRuntime.swift -framework AppKit -framework Carbon \
    -o "$INSTALLER/Contents/MacOS/FangCunInstaller"
cp Installer/Info.plist "$INSTALLER/Contents/Info.plist"
python3 - "$PAYLOAD/Contents/Info.plist" "$INSTALLER/Contents/Info.plist" <<'PY'
import plistlib, sys
with open(sys.argv[1], 'rb') as f: payload = plistlib.load(f)
with open(sys.argv[2], 'rb') as f: info = plistlib.load(f)
for key in ['CFBundleShortVersionString', 'CFBundleVersion', 'LSMinimumSystemVersion']:
    info[key] = payload[key]
with open(sys.argv[2], 'wb') as f: plistlib.dump(info, f)
PY
cp Resources/AppIcon.icns "$INSTALLER/Contents/Resources/AppIcon.icns"
ditto "$PAYLOAD" "$INSTALLER/Contents/Resources/FangCun.app"
codesign --force --sign - "$INSTALLER"
codesign --verify --deep --strict "$INSTALLER"
