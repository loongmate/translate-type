#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
mkdir -p .build
RIME="$PWD/.cache/rime/dist"
clang -fobjc-arc -O2 -I "$RIME/include" -c Sources/RimeBridge.m -o .build/CredentialBridge.o
swiftc -swift-version 5 -Onone -import-objc-header Sources/RimeBridge.h \
    Sources/Agent*.swift Sources/Configuration.swift Sources/PinyinEngine.swift Sources/ContextRanking.swift \
    Tests/CredentialTests.swift .build/CredentialBridge.o \
    -L "$RIME/lib" -lrime -framework Foundation \
    -Xlinker -rpath -Xlinker "$RIME/lib" -o .build/credential-tests
.build/credential-tests
