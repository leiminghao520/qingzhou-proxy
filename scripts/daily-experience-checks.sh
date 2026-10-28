#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
mkdir -p .build
bash scripts/swift-local.sh build --product Qingzhou > .build/daily-experience-build.log 2>&1
stage="$PWD/.build/daily-experience-checks"
mkdir -p "$stage"
python3 - "$stage" <<'PY'
from pathlib import Path
import sys
Path(sys.argv[1]+'/QingzhouApp.swift').write_text(Path('Sources/Qingzhou/QingzhouApp.swift').read_text().replace('@main struct QingzhouApp','struct QingzhouApp',1))
PY
sources=()
for source in Sources/Qingzhou/*.swift; do
    if [[ "$source" != "Sources/Qingzhou/QingzhouApp.swift" ]]; then sources+=("$source"); fi
done
objects=(.build/debug/QingzhouKit.build/*.o .build/debug/CQingzhouRoute.build/*.o .build/debug/Yams.build/*.o .build/debug/CYaml.build/src/*.o)
swiftc -parse-as-library -swift-version 5 -profile-generate -profile-coverage-mapping -I .build/debug/Modules -I Vendor/Yams/Sources/CYaml/include -Xcc -fmodule-map-file=.build/debug/CQingzhouRoute.build/module.modulemap -module-cache-path .build/module-cache "${sources[@]}" "$stage/QingzhouApp.swift" scripts/daily-experience-checks.swift "${objects[@]}" -o "$stage/checks"
fixture="$(mktemp -d "$stage/state.XXXXXX")"
LLVM_PROFILE_FILE="$stage/checks.profraw" "$stage/checks" --test-directory "$fixture"
xcrun llvm-profdata merge -sparse "$stage/checks.profraw" -o "$stage/checks.profdata"
xcrun llvm-cov report "$stage/checks" -instr-profile="$stage/checks.profdata" Sources/Qingzhou/SelectionStatus.swift Sources/Qingzhou/NodeListViewModel.swift Sources/Qingzhou/DailyLinesView.swift > "$stage/coverage.txt"
cat "$stage/coverage.txt"
