#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
stage="$PWD/.build/diagnostic-feature-coverage"
bash scripts/swift-local.sh build --build-path "$stage" -Xswiftc -profile-generate -Xswiftc -profile-coverage-mapping --product QingzhouChecks > "$PWD/.build/features-coverage-build.log" 2>&1
objects=("$stage"/debug/QingzhouKit.build/*.o "$stage"/debug/CQingzhouRoute.build/*.o "$stage"/debug/Yams.build/*.o "$stage"/debug/CYaml.build/src/*.o)
swiftc -parse-as-library -swift-version 5 -profile-generate -profile-coverage-mapping -I "$stage/debug/Modules" -I Vendor/Yams/Sources/CYaml/include -Xcc -fmodule-map-file="$stage/debug/CQingzhouRoute.build/module.modulemap" -module-cache-path .build/module-cache scripts/diagnostics-history-events-checks.swift "${objects[@]}" -o "$stage/checks"
LLVM_PROFILE_FILE="$stage/checks.profraw" "$stage/checks" > "$stage/checks.log"
xcrun llvm-profdata merge -sparse "$stage/checks.profraw" -o "$stage/checks.profdata"
xcrun llvm-cov report "$stage/checks" -instr-profile="$stage/checks.profdata" Sources/QingzhouKit/DiagnosticSession.swift Sources/QingzhouKit/DiagnosticService.swift Sources/QingzhouKit/ProfileHistoryStore.swift Sources/QingzhouKit/ProfileHistoryDiff.swift Sources/QingzhouKit/NetworkEventStore.swift Sources/QingzhouKit/NodeStore.swift > "$stage/coverage.txt"
xcrun llvm-cov export "$stage/checks" -instr-profile="$stage/checks.profdata" Sources/QingzhouKit/DiagnosticSession.swift Sources/QingzhouKit/DiagnosticService.swift Sources/QingzhouKit/ProfileHistoryStore.swift Sources/QingzhouKit/ProfileHistoryDiff.swift Sources/QingzhouKit/NetworkEventStore.swift Sources/QingzhouKit/NodeStore.swift > "$stage/coverage.json"
cat "$stage/coverage.txt"
