#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
stage="$PWD/.build/wake-recovery-coverage"
mkdir -p "$stage"
bash scripts/swift-local.sh build --build-path "$stage" -Xswiftc -profile-generate -Xswiftc -profile-coverage-mapping -Xcc -fprofile-instr-generate -Xcc -fcoverage-mapping --product Qingzhou > "$stage/build.log" 2>&1
objects=("$stage"/debug/QingzhouKit.build/*.o "$stage"/debug/CQingzhouRoute.build/*.o "$stage"/debug/Yams.build/*.o "$stage"/debug/CYaml.build/src/*.o)
flags=(-parse-as-library -swift-version 5 -profile-generate -profile-coverage-mapping -I "$stage/debug/Modules" -I Vendor/Yams/Sources/CYaml/include -Xcc "-fmodule-map-file=$stage/debug/CQingzhouRoute.build/module.modulemap" -module-cache-path .build/module-cache)
swiftc "${flags[@]}" scripts/wake-recovery-checks.swift "${objects[@]}" -o "$stage/checks"
LLVM_PROFILE_FILE="$stage/unit.profraw" "$stage/checks" > "$stage/unit.log"
python3 - "$stage" <<'PY'
from pathlib import Path
import sys
Path(sys.argv[1],'QingzhouApp.swift').write_text(Path('Sources/Qingzhou/QingzhouApp.swift').read_text().replace('@main struct QingzhouApp','struct QingzhouApp',1))
PY
sources=()
for source in Sources/Qingzhou/*.swift; do
    if [[ "$source" != "Sources/Qingzhou/QingzhouApp.swift" ]]; then sources+=("$source"); fi
done
swiftc "${flags[@]}" "${sources[@]}" "$stage/QingzhouApp.swift" scripts/network-resume-model-checks.swift "${objects[@]}" -o "$stage/model"
fixture="$(mktemp -d "$stage/state.XXXXXX")"
LLVM_PROFILE_FILE="$stage/model.profraw" "$stage/model" --test-directory "$fixture" > "$stage/model.log"
python3 - "$stage" <<'PYFIXTURE'
from pathlib import Path
import sys
Path(sys.argv[1],'HelperService.swift').write_text(Path('Sources/QingzhouHelper/main.swift').read_text().split('#if !QZ_HELPER_FIXTURE\n')[0])
PYFIXTURE
helper_sources=()
for source in Sources/QingzhouHelper/*.swift; do
    if [[ "$source" != "Sources/QingzhouHelper/main.swift" ]]; then helper_sources+=("$source"); fi
done
swiftc "${flags[@]}" -D QZ_HELPER_FIXTURE "${helper_sources[@]}" "$stage/HelperService.swift" scripts/helper-recovery-offline.swift "${objects[@]}" -o "$stage/helper"
LLVM_PROFILE_FILE="$stage/helper.profraw" "$stage/helper" > "$stage/helper.log"
xcrun llvm-profdata merge -sparse "$stage/unit.profraw" "$stage/model.profraw" "$stage/helper.profraw" -o "$stage/checks.profdata"
files=(Sources/QingzhouKit/WakeRecoveryCoordinator.swift Sources/QingzhouKit/RouteIdentityIndex.swift Sources/QingzhouKit/ConnectivityProbe.swift Sources/QingzhouKit/CaptureController.swift Sources/Qingzhou/AppModel+WakeRecovery.swift Sources/QingzhouKit/RouteBackend.swift Sources/QingzhouHelper/NativeRouteSupport.swift Sources/QingzhouHelper/QuitRelease.swift "$stage/HelperService.swift" Sources/CQingzhouRoute/QingzhouRoute.c)
xcrun llvm-cov report "$stage/model" -object "$stage/checks" -object "$stage/helper" -instr-profile="$stage/checks.profdata" "${files[@]}" > "$stage/report.txt"
xcrun llvm-cov export "$stage/model" -object "$stage/checks" -object "$stage/helper" -instr-profile="$stage/checks.profdata" "${files[@]}" > "$stage/report.json"
cat "$stage/report.txt"
