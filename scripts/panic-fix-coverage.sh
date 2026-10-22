#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
bp=.build/panic-fix-coverage
bash scripts/swift-local.sh build --build-path "$bp" -Xswiftc -profile-generate -Xswiftc -profile-coverage-mapping -Xcc -fprofile-instr-generate -Xcc -fcoverage-mapping --product QingzhouHelper
objects=("$bp"/debug/QingzhouKit.build/*.o "$bp"/debug/CQingzhouRoute.build/*.o "$bp"/debug/Yams.build/*.o "$bp"/debug/CYaml.build/src/*.o)
for entry in native channel precedence plan_codec; do
    sources=(scripts/helper-channel-offline.swift)
    if [[ "$entry" == native ]]; then sources=(Sources/QingzhouHelper/HelperRecoveryRecords.swift Sources/QingzhouHelper/HelperJournal.swift scripts/native-route-checks.swift scripts/native-route-scenarios.swift); fi
    if [[ "$entry" == precedence ]]; then sources=(scripts/capture-precedence-checks.swift); fi
    if [[ "$entry" == plan_codec ]]; then sources=(scripts/capture-codec-checks.swift); fi
    swiftc -parse-as-library -swift-version 5 -profile-generate -profile-coverage-mapping -I "$bp/debug/Modules" -I Vendor/Yams/Sources/CYaml/include \
        -Xcc "-fmodule-map-file=$bp/debug/CQingzhouRoute.build/module.modulemap" -module-cache-path .build/module-cache "${sources[@]}" "${objects[@]}" -o "$bp/$entry"
done
run="$(mktemp -d "$PWD/$bp/run.XXXXXX")"
LLVM_PROFILE_FILE="$run/native-%p.profraw" "$bp/native"
LLVM_PROFILE_FILE="$run/channel-%p.profraw" "$bp/channel"
LLVM_PROFILE_FILE="$run/precedence-%p.profraw" "$bp/precedence"
LLVM_PROFILE_FILE="$run/plan_codec-%p.profraw" "$bp/plan_codec"
xcrun llvm-profdata merge -sparse "$run"/*.profraw -o "$bp/swift.profdata"
sources=(Sources/QingzhouKit/RouteBackend.swift Sources/QingzhouKit/HelperRequestChannel.swift Sources/QingzhouKit/RouteAuditLog.swift Sources/QingzhouKit/SecureFile.swift Sources/QingzhouKit/CaptureRoutePlan.swift)
xcrun llvm-cov report "$bp/channel" -object "$bp/native" -object "$bp/precedence" -object "$bp/plan_codec" -instr-profile="$bp/swift.profdata" "${sources[@]}" > "$bp/swift-report.txt"
xcrun llvm-cov export "$bp/channel" -object "$bp/native" -object "$bp/precedence" -object "$bp/plan_codec" -instr-profile="$bp/swift.profdata" "${sources[@]}" > "$bp/swift-coverage.json"
clang -std=c11 -fprofile-instr-generate -fcoverage-mapping -g -I Sources/CQingzhouRoute/include scripts/route-transport-offline.c \
    Sources/CQingzhouRoute/RouteRequestValidation.c Sources/CQingzhouRoute/RouteTransport.c -o "$bp/transport"
clang -std=c11 -fprofile-instr-generate -fcoverage-mapping -g -I Sources/CQingzhouRoute/include scripts/route-codec-export.c \
    Sources/CQingzhouRoute/QingzhouRoute.c Sources/CQingzhouRoute/RouteRequestValidation.c -o "$bp/codec"
crun="$(mktemp -d "$PWD/$bp/c-run.XXXXXX")"
LLVM_PROFILE_FILE="$crun/transport-%p.profraw" "$bp/transport"
LLVM_PROFILE_FILE="$crun/codec-%p.profraw" "$bp/codec" > "$bp/corpus.jsonl"
xcrun llvm-profdata merge -sparse "$crun"/*.profraw -o "$bp/c.profdata"
sources=(Sources/CQingzhouRoute/QingzhouRoute.c Sources/CQingzhouRoute/RouteRequestValidation.c Sources/CQingzhouRoute/RouteTransport.c)
xcrun llvm-cov report "$bp/transport" -object "$bp/codec" -instr-profile="$bp/c.profdata" "${sources[@]}" > "$bp/c-report.txt"
xcrun llvm-cov export "$bp/transport" -object "$bp/codec" -instr-profile="$bp/c.profdata" "${sources[@]}" > "$bp/c-coverage.json"
cat "$bp/swift-report.txt" "$bp/c-report.txt"
