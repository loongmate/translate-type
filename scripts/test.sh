#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
mkdir -p .build
RIME="$PWD/.cache/rime/dist"
clang -fobjc-arc -O2 -I "$RIME/include" -c Sources/RimeBridge.m -o .build/RimeBridge.o
python3 Tests/mock_server.py > .build/mock-server.log 2>&1 &
MOCK_PID=$!
trap 'kill "$MOCK_PID" 2>/dev/null || true' EXIT
swiftc -swift-version 5 -Onone -import-objc-header Sources/RimeBridge.h \
  Sources/Configuration.swift Sources/PinyinEngine.swift Sources/ContextRanking.swift Sources/CompositionSession.swift Sources/TranslationClient.swift Sources/ShiftTap.swift \
  Tests/CoreTests.swift .build/RimeBridge.o -L "$RIME/lib" -lrime -framework Foundation -framework Security \
  -Xlinker -rpath -Xlinker "$RIME/lib" -o .build/core-tests
.build/core-tests
