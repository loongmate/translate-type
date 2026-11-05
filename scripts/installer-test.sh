#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
mkdir -p .build
swiftc -swift-version 5 -parse-as-library -Onone \
    Installer/InstallTransaction.swift Installer/InstallerProcesses.swift Installer/InstallerService.swift Installer/InstallerWindow.swift Sources/InputSourceStatus.swift Tests/InstallerTests.swift \
    -framework AppKit -framework Carbon -o .build/installer-tests
.build/installer-tests
