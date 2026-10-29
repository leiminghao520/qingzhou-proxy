#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
scripts/swift-local.sh build --product Qingzhou
stage="$PWD/.build/bypass-interface-checks"
mkdir -p "$stage"
# 只链接界面和隔离模型，不运行正式应用的启动恢复入口。
/usr/bin/python3 - "$stage" <<'PY'
from pathlib import Path
import sys
source=Path('Sources/Qingzhou/QingzhouApp.swift').read_text().replace('@main struct QingzhouApp','struct QingzhouApp',1)
Path(sys.argv[1],'QingzhouApp.swift').write_text(source)
PY
sources=()
for source in Sources/Qingzhou/*.swift; do
    if [[ "$source" != "Sources/Qingzhou/QingzhouApp.swift" ]]; then sources+=("$source"); fi
done
objects=(.build/debug/Pow.build/*.o .build/debug/QingzhouKit.build/*.o .build/debug/CQingzhouRoute.build/*.o .build/debug/Yams.build/*.o .build/debug/CYaml.build/src/*.o)
swiftc -parse-as-library -swift-version 5 -I .build/debug/Modules -I Vendor/Yams/Sources/CYaml/include -Xcc -fmodule-map-file=.build/debug/CQingzhouRoute.build/module.modulemap -module-cache-path .build/module-cache "${sources[@]}" "$stage/QingzhouApp.swift" scripts/bypass-interface-checks.swift "${objects[@]}" -o "$stage/checks"
fixture="$(mktemp -d "$stage/state.XXXXXX")"
"$stage/checks" --test-directory "$fixture" --output "${1:-$stage/evidence}" "${@:2}"
