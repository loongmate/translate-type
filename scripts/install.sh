#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
SOURCE="$PWD/build/FangCun.app"
if [ "${1:-}" != --help ] && [ ! -x "$SOURCE/Contents/MacOS/TranslateType" ]; then
    echo '请先运行 scripts/build.sh' >&2
    exit 1
fi
mkdir -p .build
swiftc -swift-version 5 -parse-as-library -O \
    Installer/InstallTransaction.swift Installer/InstallerProcesses.swift Installer/InstallerService.swift \
    Sources/InputSourceStatus.swift Sources/InstallationRuntime.swift scripts/InstallerTool/main.swift \
    -framework AppKit -framework Carbon -o .build/install-tool
exec .build/install-tool "$SOURCE" "$@"
