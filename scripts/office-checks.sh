#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
stage="$PWD/.build/office-checks"
mkdir -p "$stage"
build_path="${OFFICE_BUILD_PATH:-$PWD/.build}"
flags=(-c debug)
link_flags=(-g)
if [[ "${OFFICE_COVERAGE:-0}" == 1 ]]; then
    flags+=(-Xswiftc -profile-generate -Xswiftc -profile-coverage-mapping)
    link_flags+=(-profile-generate -profile-coverage-mapping)
fi
bash scripts/swift-local.sh build --build-path "$build_path" "${flags[@]}" --product QingzhouChecks
LLVM_PROFILE_FILE="$stage/kit.profraw" "$build_path/debug/QingzhouChecks" office-checks
bash scripts/swift-local.sh build --build-path "$build_path" "${flags[@]}" --product Qingzhou
python3 - "$stage" <<'PY'
from pathlib import Path
import sys
Path(sys.argv[1],'QingzhouApp.swift').write_text(Path('Sources/Qingzhou/QingzhouApp.swift').read_text().replace('@main struct QingzhouApp','struct QingzhouApp',1))
PY
sources=()
for source in Sources/Qingzhou/*.swift; do
    if [[ "$source" != "Sources/Qingzhou/QingzhouApp.swift" ]]; then sources+=("$source"); fi
done
objects=("$build_path"/debug/QingzhouKit.build/*.o "$build_path"/debug/CQingzhouRoute.build/*.o "$build_path"/debug/Yams.build/*.o "$build_path"/debug/CYaml.build/src/*.o)
swiftc -parse-as-library -swift-version 5 "${link_flags[@]}" -I "$build_path/debug/Modules" -I Vendor/Yams/Sources/CYaml/include -Xcc -fmodule-map-file="$build_path/debug/CQingzhouRoute.build/module.modulemap" -module-cache-path .build/module-cache "${sources[@]}" "$stage/QingzhouApp.swift" scripts/office-ui-checks.swift "${objects[@]}" -o "$stage/checks"
fixture="$(mktemp -d "$stage/state.XXXXXX")"
LLVM_PROFILE_FILE="$stage/ui.profraw" "$stage/checks" --test-directory "$fixture" --output "$stage/evidence"
if [[ "${OFFICE_COVERAGE:-0}" == 1 ]]; then
    xcrun llvm-profdata merge -sparse "$stage/kit.profraw" "$stage/ui.profraw" -o "$stage/checks.profdata"
    xcrun llvm-cov report "$stage/checks" -object "$build_path/debug/QingzhouChecks" -instr-profile="$stage/checks.profdata" Sources/QingzhouKit/OfficeModels.swift Sources/QingzhouKit/TargetDiagnosticService.swift Sources/QingzhouKit/DeveloperProxyAssistant.swift Sources/Qingzhou/OfficeDashboardModel.swift Sources/Qingzhou/OfficeTrafficDisplay.swift Sources/Qingzhou/OfficeViews.swift Sources/QingzhouKit/CoreAPIClient.swift Sources/Qingzhou/AppModel+Monitoring.swift Sources/Qingzhou/SessionDraftStore.swift > "$stage/coverage.txt"
fi
