#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
mkdir -p .cache/rime Resources
if [ ! -f .cache/rime/dist/include/rime_api.h ]; then
    curl -L --fail --silent --show-error --connect-timeout 15 --max-time 120 \
      -H 'Accept: application/octet-stream' https://api.github.com/repos/rime/librime/releases/assets/439256111 \
      -o .cache/rime/library.tar.bz2
    echo '11d8dc663c6ec06d5ccb6111ba664a9e7b631b703ac6acd07cffbac664021850  .cache/rime/library.tar.bz2' | shasum -a 256 -c -
    tar -xjf .cache/rime/library.tar.bz2 -C .cache/rime
fi
if [ ! -s Resources/pinyin_simp.dict.yaml ]; then
    curl -L --fail --silent --show-error --connect-timeout 15 --max-time 60 \
      https://api.github.com/repos/rime/rime-pinyin-simp/git/blobs/6f2e996d2792416cb7f41bb49967a1dec7060c92 \
      -o .cache/rime/dictionary.json
    python3 - <<'PY'
import base64,hashlib,json
from pathlib import Path
obj=json.loads(Path('.cache/rime/dictionary.json').read_text())
data=base64.b64decode(obj['content'])
assert hashlib.sha1(b'blob '+str(len(data)).encode()+b'\0'+data).hexdigest()=='6f2e996d2792416cb7f41bb49967a1dec7060c92'
Path('Resources/pinyin_simp.dict.yaml').write_bytes(data)
PY
fi
if [ ! -s Resources/base.dict.yaml ] || [ ! -s Resources/mixed_english.dict.yaml ] || [ ! -s Resources/RIMEICE-LICENSE.txt ]; then
    python3 scripts/prepare-vocabulary.py
fi
python3 scripts/prepare-double-pinyin.py
echo 'Rime 1.17.0、全拼与双拼词库已准备好。'
