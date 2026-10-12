#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
mkdir -p .build
swiftc Sources/SurroundingContext.swift Tests/TextClient.swift Tests/ContextTests.swift \
    -framework AppKit -framework InputMethodKit -framework Carbon -o .build/context-tests
.build/context-tests
