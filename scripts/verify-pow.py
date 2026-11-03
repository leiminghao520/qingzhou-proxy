#!/usr/bin/env python3
"""核对随源码交付的 Pow 固定版本与文件完整性。"""
import hashlib,json,pathlib
root=pathlib.Path(__file__).resolve().parent.parent
lock=json.loads((root/'Vendor/pow-lock.json').read_text())
base=root/'Vendor/Pow'
actual={str(p.relative_to(base)):hashlib.sha256(p.read_bytes()).hexdigest() for p in sorted(base.rglob('*')) if p.is_file()}
if actual != lock['files']:
    raise SystemExit('Pow 文件与锁定清单不一致')
print('POW_VERIFIED '+lock['version']+' '+lock['revision'])
