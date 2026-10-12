#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
mkdir -p .build
RIME="$PWD/.cache/rime/dist"
clang -fobjc-arc -O2 -I "$RIME/include" -c Sources/RimeBridge.m -o .build/PagingBridge.o
swiftc -swift-version 5 -Onone -import-objc-header Sources/RimeBridge.h \
    Sources/Configuration.swift Sources/PinyinEngine.swift Sources/ContextRanking.swift Sources/CompositionSession.swift Sources/TranslationClient.swift \
    Tests/PagingTests.swift .build/PagingBridge.o \
    -L "$RIME/lib" -lrime -framework Foundation -framework Security \
    -Xlinker -rpath -Xlinker "$RIME/lib" -o .build/paging-tests
.build/paging-tests
