#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
mkdir -p .build
RIME="$PWD/.cache/rime/dist"
python3 scripts/prepare-double-pinyin.py
clang -fobjc-arc -O2 -I "$RIME/include" -c Sources/RimeBridge.m -o .build/EmojiBridge.o
swiftc -swift-version 5 -Onone -import-objc-header Sources/RimeBridge.h \
    Sources/Agent*.swift Sources/Configuration.swift Sources/PinyinEngine.swift Sources/ContextRanking.swift Sources/CompositionSession.swift Sources/TranslationClient.swift \
    Tests/EmojiTests.swift .build/EmojiBridge.o \
    -L "$RIME/lib" -lrime -framework Foundation \
    -Xlinker -rpath -Xlinker "$RIME/lib" -o .build/emoji-tests
.build/emoji-tests "${1:-Resources}"
