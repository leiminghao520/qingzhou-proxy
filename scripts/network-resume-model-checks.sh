#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
scripts/swift-local.sh build --product Qingzhou
stage="$PWD/.build/network-resume-model"
mkdir -p "$stage"
# 单独链接正式模型，使用独立目录，不启动真实核心或执行系统网络恢复。
/usr/bin/python3 - "$stage" <<'PY'
from pathlib import Path
import sys
source = Path('Sources/Qingzhou/QingzhouApp.swift').read_text()
Path(sys.argv[1], 'QingzhouApp.swift').write_text(source.replace('@main struct QingzhouApp', 'struct QingzhouApp', 1))
PY
sources=()
for source in Sources/Qingzhou/*.swift; do
    if [[ "$source" != "Sources/Qingzhou/QingzhouApp.swift" ]]; then sources+=("$source"); fi
done
objects=(.build/debug/QingzhouKit.build/*.o .build/debug/CQingzhouRoute.build/*.o .build/debug/Yams.build/*.o .build/debug/CYaml.build/src/*.o)
swiftc -parse-as-library -swift-version 5 -I .build/debug/Modules -I Vendor/Yams/Sources/CYaml/include -Xcc -fmodule-map-file=.build/debug/CQingzhouRoute.build/module.modulemap \
    -module-cache-path .build/module-cache "${sources[@]}" "$stage/QingzhouApp.swift" \
    scripts/network-resume-model-checks.swift "${objects[@]}" -o "$stage/checks"
fixture="$(mktemp -d "$stage/state.XXXXXX")"
"$stage/checks" --test-directory "$fixture"
