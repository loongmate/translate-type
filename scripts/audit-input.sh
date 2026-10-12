#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
mkdir -p .build
RIME="$PWD/.cache/rime/dist"
clang -fobjc-arc -O2 -I "$RIME/include" -c Sources/RimeBridge.m -o .build/AuditRimeBridge.o
swiftc -swift-version 5 -Onone -import-objc-header Sources/RimeBridge.h \
  Sources/Configuration.swift Sources/PinyinEngine.swift Sources/ContextRanking.swift Sources/CompositionSession.swift Sources/TranslationClient.swift \
  Tests/InputBehaviorAudit.swift .build/AuditRimeBridge.o \
  -L "$RIME/lib" -lrime -framework Foundation -framework Security \
  -Xlinker -rpath -Xlinker "$RIME/lib" -o .build/input-behavior-audit
.build/input-behavior-audit "${1:-.build/input-behavior-audit.json}"
