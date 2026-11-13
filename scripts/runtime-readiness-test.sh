#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
mkdir -p .build
FIXTURE=$(mktemp -d "$PWD/.build/runtime-readiness.XXXXXX")
trap 'rm -rf "$FIXTURE"' EXIT
APP="$FIXTURE/RuntimeFixture.app"
mkdir -p "$APP/Contents/MacOS"
swiftc -swift-version 5 -parse-as-library Sources/InstallationRuntime.swift Tests/InstallationRuntimeTests.swift \
    -framework AppKit -o "$APP/Contents/MacOS/RuntimeFixture"
python3 - "$APP" <<'PY'
import plistlib,sys
from pathlib import Path
app=Path(sys.argv[1])
(app/'Contents/Info.plist').write_bytes(plistlib.dumps({'CFBundleIdentifier':'com.fangcun.RuntimeReadinessFixture','CFBundleVersion':'1','CFBundleExecutable':'RuntimeFixture','CFBundlePackageType':'APPL','LSUIElement':True}))
PY
codesign --force --sign - "$APP"
"$APP/Contents/MacOS/RuntimeFixture" "$APP"
