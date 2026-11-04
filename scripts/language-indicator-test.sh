#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
mkdir -p .build
swiftc -swift-version 5 Sources/InputSourceStatus.swift Sources/InputLanguageIndicator.swift Tests/LanguageIndicatorTests.swift \
    -framework AppKit -framework Carbon -o .build/language-indicator-tests
.build/language-indicator-tests
