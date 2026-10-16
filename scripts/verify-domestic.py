#!/usr/bin/python3
# 固定资源与编译内嵌副本必须一致，防止构建时误用半下载文件或未审核更新。
import base64, hashlib, json, pathlib, re
root = pathlib.Path(__file__).resolve().parent.parent
payload = (root / 'Resources/domestic-rules.json').read_bytes()
lock = json.loads((root / 'Resources/domestic-rules-lock.json').read_text())
source = (root / 'Sources/QingzhouKit/DomesticRuleData.swift').read_text()
assert hashlib.sha256(payload).hexdigest() == lock['payloadSHA256']
assert base64.b64decode(re.search(r'payload="([^"]+)"', source)[1]) == payload
assert re.search(r'sha256="([^"]+)"', source)[1] == lock['payloadSHA256']
print('DOMESTIC_RULES_VERIFIED', lock['commit'], lock['payloadSHA256'])
