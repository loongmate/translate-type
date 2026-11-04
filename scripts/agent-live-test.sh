#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
if [ "${FANGCUN_AGENT_LIVE:-0}" != 1 ]; then echo '使用 FANGCUN_AGENT_LIVE=1 显式启用已配置模型的联网验证。'; exit 0; fi
mkdir -p .build
RIME="$PWD/.cache/rime/dist"
clang -fobjc-arc -O2 -I "$RIME/include" -c Sources/RimeBridge.m -o .build/AgentLiveBridge.o
swiftc -swift-version 5 -Onone -import-objc-header Sources/RimeBridge.h \
  Sources/Agent*.swift Sources/Configuration.swift Sources/PinyinEngine.swift Sources/ContextRanking.swift \
  Tests/AgentLiveProbe.swift .build/AgentLiveBridge.o -L "$RIME/lib" -lrime -framework Foundation \
  -Xlinker -rpath -Xlinker "$RIME/lib" -o .build/agent-live-probe
.build/agent-live-probe
