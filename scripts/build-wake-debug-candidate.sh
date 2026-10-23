#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
release_app="${1:?需要已签名的 Release 候选路径}"
test -d "$release_app/Contents/Resources"
bash scripts/swift-local.sh build --product Qingzhou
bash scripts/swift-local.sh build --product QingzhouRunner
bash scripts/swift-local.sh build --product QingzhouHelper
stage="$(mktemp -d "$PWD/.build/wake-recovery/candidates/debug-0.13.4.XXXXXX")"
app="$stage/轻舟代理.app"
# 复用经过校验的资源，只替换正式 Debug 构建；不启动应用或安装组件。
ditto "$release_app" "$app"
cp .build/debug/Qingzhou "$app/Contents/MacOS/Qingzhou"
cp .build/debug/QingzhouHelper "$app/Contents/Resources/QingzhouHelper"
cp .build/debug/QingzhouRunner "$app/Contents/Resources/QingzhouRunner"
codesign --force --sign - "$app/Contents/Resources/QingzhouHelper"
codesign --force --sign - "$app/Contents/Resources/QingzhouRunner"
codesign --force --sign - "$app"
codesign --verify --deep --strict "$app"
python3 - "$release_app" "$app" <<'PY'
from pathlib import Path
import hashlib,json,sys
release,app=map(Path,sys.argv[1:])
manifest=json.loads((release.parent/'artifact-manifest.json').read_text())
manifest['buildConfiguration']='Debug'
for name,entry in manifest['components'].items():
    data=(app/name).read_bytes();entry['size']=len(data);entry['sha256']=hashlib.sha256(data).hexdigest()
(app.parent/'artifact-manifest.json').write_text(json.dumps(manifest,indent=2))
PY
echo "DEBUG_APP_BUILD_OK $app"
