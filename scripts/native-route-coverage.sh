#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
build_path=.build/native-coverage
bash scripts/swift-local.sh build --build-path "$build_path" -Xswiftc -profile-generate -Xswiftc -profile-coverage-mapping -Xcc -fprofile-instr-generate -Xcc -fcoverage-mapping --product QingzhouHelper
objects=("$build_path"/debug/QingzhouKit.build/*.o "$build_path"/debug/CQingzhouRoute.build/*.o "$build_path"/debug/Yams.build/*.o "$build_path"/debug/CYaml.build/src/*.o)
swiftc -parse-as-library -swift-version 5 -profile-generate -profile-coverage-mapping \
    -I "$build_path/debug/Modules" -I Vendor/Yams/Sources/CYaml/include -Xcc "-fmodule-map-file=$build_path/debug/CQingzhouRoute.build/module.modulemap" -module-cache-path .build/module-cache \
    Sources/QingzhouHelper/HelperRecoveryRecords.swift Sources/QingzhouHelper/HelperJournal.swift scripts/native-route-checks.swift scripts/native-route-scenarios.swift "${objects[@]}" -o "$build_path/checks"
profile_dir="$(mktemp -d "$PWD/$build_path/run.XXXXXX")"
LLVM_PROFILE_FILE="$profile_dir/checks-%p.profraw" "$build_path/checks"
xcrun llvm-profdata merge -sparse "$profile_dir"/*.profraw -o "$build_path/checks.profdata"
xcrun llvm-cov report "$build_path/checks" -instr-profile="$build_path/checks.profdata" \
    Sources/QingzhouKit/RouteBackend.swift Sources/QingzhouKit/CaptureRoutePlan.swift Sources/QingzhouKit/NetworkPreparationPool.swift Sources/QingzhouKit/BypassRoutePlan.swift Sources/QingzhouKit/CaptureOwnership.swift Sources/CQingzhouRoute/QingzhouRoute.c Sources/CQingzhouRoute/RouteRequestValidation.c Sources/CQingzhouRoute/RouteTransport.c > "$build_path/report.txt"
xcrun llvm-cov export "$build_path/checks" -instr-profile="$build_path/checks.profdata" \
    Sources/QingzhouKit/RouteBackend.swift Sources/QingzhouKit/CaptureRoutePlan.swift Sources/QingzhouKit/NetworkPreparationPool.swift Sources/QingzhouKit/BypassRoutePlan.swift Sources/QingzhouKit/CaptureOwnership.swift Sources/CQingzhouRoute/QingzhouRoute.c Sources/CQingzhouRoute/RouteRequestValidation.c Sources/CQingzhouRoute/RouteTransport.c > "$build_path/coverage.json"
cat "$build_path/report.txt"
