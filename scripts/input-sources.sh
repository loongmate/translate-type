#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
mkdir -p .build
if [ ! -x .build/input-sources ] || [ Sources/InputSourceStatus.swift -nt .build/input-sources ] || [ scripts/InputSources/main.swift -nt .build/input-sources ]; then
    swiftc Sources/InputSourceStatus.swift scripts/InputSources/main.swift -framework AppKit -framework Carbon -o .build/input-sources
fi
exec .build/input-sources "$@"
