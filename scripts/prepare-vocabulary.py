"""Reproduce the offline mixed vocabulary from pinned upstream Git blobs."""
from pathlib import Path
import base64
import hashlib
import json
import subprocess

ROOT = Path(__file__).resolve().parent.parent
CACHE = ROOT / '.cache/rime'
RESOURCES = ROOT / 'Resources'
CACHE.mkdir(parents=True, exist_ok=True)
RESOURCES.mkdir(exist_ok=True)

def blob(sha, cache_name):
    cached = CACHE / cache_name
    if cached.exists():
        data = cached.read_bytes()
    else:
        url = f'https://api.github.com/repos/iDvel/rime-ice/git/blobs/{sha}'
        response = subprocess.check_output(['curl','--fail','--silent','--show-error','--connect-timeout','15','--max-time','60',url])
        data = base64.b64decode(json.loads(response)['content'])
    actual = hashlib.sha1(b'blob ' + str(len(data)).encode() + b'\0' + data).hexdigest()
    if actual != sha:
        raise RuntimeError('Vocabulary integrity check failed: ' + cache_name)
    cached.write_bytes(data)
    return data

english = blob('54b596853133044a02216f7131f628c55797b604', 'english-source.yaml')
chinese = blob('f1e253ea14ad035198f66b449c83217131184775', 'chinese-source.yaml')
license_text = blob('f288702d2fa16d3cdf0035b15a9fcbc552cd88e7', 'rime-ice-license.txt')
words = {}
for line in english.decode().split('...\n', 1)[1].splitlines():
    if not line or line.startswith('#'):
        continue
    parts = line.split('\t')
    if len(parts) < 2:
        continue
    word, code = parts[:2]
    if code.isascii() and code.isalpha() and len(code) >= 2:
        key = code.lower()
        if key not in words or word == key:
            words[key] = word
header = '''# English vocabulary adapted from iDvel/rime-ice en_dicts/en.dict.yaml.
# Pinned Git blob: 54b596853133044a02216f7131f628c55797b604
# Codes normalized to lowercase for use inside pinyin sentences.
# See RIMEICE-LICENSE.txt for the upstream license.
---
name: mixed_english
version: "0.2.0"
sort: by_weight
...
'''
(RESOURCES / 'mixed_english.dict.yaml').write_text(header + ''.join(
    f'{word}\t{code}\t1\n' for code, word in sorted(words.items())))
(RESOURCES / 'base.dict.yaml').write_bytes(chinese)
(RESOURCES / 'RIMEICE-LICENSE.txt').write_bytes(license_text)
print(f'离线中文词库与 {len(words)} 条英文词汇已准备好。')
