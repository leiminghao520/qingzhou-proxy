#!/usr/bin/env python3
import hashlib,json,pathlib

root=pathlib.Path(__file__).resolve().parents[3]
snapshot=root/'source-snapshot.json'
if snapshot.exists():
 record=json.loads(snapshot.read_text(encoding='utf-8'))
 for item in record['files']:
  path=(root/item['path']).resolve()
  if not path.is_relative_to(root) or not path.is_file() or hashlib.sha256(path.read_bytes()).hexdigest()!=item['sha256']:
   raise SystemExit('源码文件缺失或摘要不符：'+item['path'])
 print('SOURCE_SNAPSHOT_HASHES_PASS')
else:
 print('当前为源码目录，没有独立源码包清单')
