#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
SOURCE="$PWD/build/FangCun.app"
DESTINATION="$HOME/Library/Input Methods/FangCun.app"
LSREGISTER='/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister'
STAMP="$(date +%s)-$$"
BACKUP="$PWD/.build/FangCun-previous-$STAMP.snapshot"
STAGING="$HOME/Library/Input Methods/.FangCun-installing-$STAMP"
if [ ! -x "$SOURCE/Contents/MacOS/TranslateType" ]; then echo '请先运行 scripts/build.sh' >&2; exit 1; fi
mkdir -p .build "$HOME/Library/Input Methods"
ditto "$SOURCE" "$STAGING"
# Keep the identity and installed path that macOS already knows. Moving the
# brand to another bundle ID creates a second IME, not a renamed installation.
PREVIOUS_SOURCE=$(./scripts/input-sources.sh prepare-update)
PIDS=$(pgrep -f '^/Users/.*/Library/Input Methods/(方寸输入法|FangCun|TranslateType).app/Contents/MacOS/TranslateType' || true)
if [ -n "$PIDS" ]; then while read -r PID; do kill "$PID"; done <<< "$PIDS"; fi
"$LSREGISTER" -u "$SOURCE" || true
if [ -d "$DESTINATION" ]; then mv "$DESTINATION" "$BACKUP"; fi
mv "$STAGING" "$DESTINATION"
"$LSREGISTER" -f "$DESTINATION"
./scripts/input-sources.sh register "$DESTINATION"
if ! ./scripts/input-sources.sh enable "$DESTINATION" "$PREVIOUS_SOURCE"; then
    # A failed update must leave the previous working installation available.
    if [ -d "$BACKUP" ]; then
        mv "$DESTINATION" "$PWD/.build/FangCun-failed-$STAMP.snapshot"
        mv "$BACKUP" "$DESTINATION"
        "$LSREGISTER" -f "$DESTINATION"
        ./scripts/input-sources.sh register "$DESTINATION" || true
        ./scripts/input-sources.sh select "$PREVIOUS_SOURCE" || true
        echo '启用验证未通过，已恢复原安装。' >&2
    else
        open -a "$DESTINATION" --args --settings
        echo '应用已安装，尚未通过系统启用验证。' >&2
    fi
    exit 1
fi
# Retire only this project's superseded installations after the active identity
# has been verified. Keep snapshots outside the .app namespace.
for PREVIOUS in "$HOME/Library/Input Methods/方寸输入法.app" "$HOME/Library/Input Methods/TranslateType.app" "$PWD/build/TranslateType.app"; do
    if [ -d "$PREVIOUS" ]; then
        "$LSREGISTER" -u "$PREVIOUS" || true
        mv "$PREVIOUS" "$PWD/.build/$(basename "$PREVIOUS" .app)-retired-$STAMP.snapshot"
    fi
done
open -a "$DESTINATION" --args --settings
if [ "$PREVIOUS_SOURCE" = 'com.translatetype.inputmethod.TranslateType.Hans' ]; then
    ./scripts/input-sources.sh select "$PREVIOUS_SOURCE"
fi
echo "已更新并启用方寸输入法：$DESTINATION"
