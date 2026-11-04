#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
RIME="$PWD/.cache/rime/dist"
mkdir -p .build
# Cache only compiled dictionaries, and invalidate on any schema/data change.
python3 - <<'PY'
from pathlib import Path
import hashlib, shutil
h = hashlib.sha256()
for p in sorted(Path('Resources').glob('*.yaml')):
    h.update(p.name.encode()); h.update(p.read_bytes())
marker = Path('.build/punctuation-rime-cache.sha256')
if not marker.exists() or marker.read_text() != h.hexdigest():
    shutil.rmtree('.build/punctuation-rime-cache', ignore_errors=True)
marker.write_text(h.hexdigest())
PY
clang -fobjc-arc -O2 -I "$RIME/include" -c Sources/RimeBridge.m -o .build/PunctuationRimeBridge.o
swiftc -swift-version 5 -Onone -import-objc-header Sources/RimeBridge.h \
  Sources/Agent*.swift Sources/Configuration.swift Sources/PinyinEngine.swift Sources/ContextRanking.swift Sources/CompositionSession.swift Sources/TranslationClient.swift \
  Tests/PunctuationTests.swift .build/PunctuationRimeBridge.o -L "$RIME/lib" -lrime -framework Foundation \
  -Xlinker -rpath -Xlinker "$RIME/lib" -o .build/punctuation-tests
.build/punctuation-tests
