#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
scripts/swift-local.sh build --product Qingzhou
stage="$PWD/.build/page-optimization-checks"
mkdir -p "$stage"
# 独立入口不执行正式应用的恢复、辅助服务或连接流程。
/usr/bin/python3 - "$stage" <<'PY'
from pathlib import Path
import subprocess,sys
stage=Path(sys.argv[1])
source=Path('Sources/Qingzhou/QingzhouApp.swift').read_text().replace('@main struct QingzhouApp','struct QingzhouApp',1)
(stage/'QingzhouApp.swift').write_text(source)
legacy=subprocess.check_output(['git','show','HEAD:Sources/Qingzhou/NodeListViewModel.swift'],text=True)
(stage/'LegacyNodeListViewModel.swift').write_text(legacy.replace('NodeListViewModel','LegacyNodeListViewModel'))
PY
sources=()
for source in Sources/Qingzhou/*.swift; do
    if [[ "$source" != "Sources/Qingzhou/QingzhouApp.swift" ]]; then sources+=("$source"); fi
done
objects=(.build/debug/QingzhouKit.build/*.o .build/debug/CQingzhouRoute.build/*.o .build/debug/Yams.build/*.o .build/debug/CYaml.build/src/*.o)
swiftc -parse-as-library -swift-version 5 -profile-generate -profile-coverage-mapping -I .build/debug/Modules -I Vendor/Yams/Sources/CYaml/include -Xcc -fmodule-map-file=.build/debug/CQingzhouRoute.build/module.modulemap -module-cache-path .build/module-cache "${sources[@]}" "$stage/QingzhouApp.swift" "$stage/LegacyNodeListViewModel.swift" scripts/page-optimization-checks.swift "${objects[@]}" -o "$stage/checks"
fixture="$(mktemp -d "$stage/state.XXXXXX")"
LLVM_PROFILE_FILE="$stage/checks.profraw" "$stage/checks" --test-directory "$fixture" --output "$stage/evidence"
xcrun llvm-profdata merge -sparse "$stage/checks.profraw" -o "$stage/checks.profdata"
xcrun llvm-cov report "$stage/checks" -instr-profile="$stage/checks.profdata" Sources/Qingzhou/SessionDraftStore.swift Sources/Qingzhou/ListProjection.swift Sources/Qingzhou/NodeListViewModel.swift > "$stage/coverage.txt"
xcrun llvm-cov export "$stage/checks" -instr-profile="$stage/checks.profdata" Sources/Qingzhou/SessionDraftStore.swift Sources/Qingzhou/ListProjection.swift Sources/Qingzhou/NodeListViewModel.swift > "$stage/coverage.json"
