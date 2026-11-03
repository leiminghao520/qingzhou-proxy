#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
build_path=.build/protection-coverage
bash scripts/swift-local.sh build --build-path "$build_path" -Xswiftc -profile-generate -Xswiftc -profile-coverage-mapping --product QingzhouHelper
objects=("$build_path"/debug/QingzhouKit.build/*.o "$build_path"/debug/CQingzhouRoute.build/*.o "$build_path"/debug/Yams.build/*.o "$build_path"/debug/CYaml.build/src/*.o)
swiftc -parse-as-library -swift-version 5 -profile-generate -profile-coverage-mapping \
    -I "$build_path/debug/Modules" -I Vendor/Yams/Sources/CYaml/include -Xcc "-fmodule-map-file=$build_path/debug/CQingzhouRoute.build/module.modulemap" -module-cache-path .build/module-cache \
    Sources/QingzhouHelper/RouteWriter.swift Sources/QingzhouHelper/ProtectionMetrics.swift \
    scripts/protection-startup-checks.swift "${objects[@]}" -o "$build_path/checks"
profile_dir="$(mktemp -d "$PWD/$build_path/run.XXXXXX")"
LLVM_PROFILE_FILE="$profile_dir/checks-%p.profraw" "$build_path/checks"
xcrun llvm-profdata merge -sparse "$profile_dir"/*.profraw -o "$build_path/checks.profdata"
xcrun llvm-cov report "$build_path/checks" -instr-profile="$build_path/checks.profdata" \
    Sources/QingzhouKit/RouteIdentityIndex.swift Sources/QingzhouKit/HelperProgress.swift Sources/QingzhouKit/ConnectionTiming.swift \
    Sources/QingzhouHelper/RouteWriter.swift Sources/QingzhouHelper/ProtectionMetrics.swift > "$build_path/report.txt"
cat "$build_path/report.txt"
