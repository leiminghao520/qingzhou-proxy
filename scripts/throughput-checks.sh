#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
bash scripts/swift-local.sh build --product QingzhouChecks > .build/throughput-build.log 2>&1
stage="$PWD/.build/throughput-checks"
mkdir -p "$stage"
cat > "$stage/Bridge.swift" <<'SWIFT'
import QingzhouKit
typealias ConnectivityProbe = QingzhouKit.ConnectivityProbe
SWIFT
cat > "$stage/Main.swift" <<'SWIFT'
import Foundation
@main struct ThroughputChecks {
    static func main() async {
        await runThroughputChecks()
        exit(CheckHarness.failures == 0 ? 0:1)
    }
}
SWIFT
objects=(.build/debug/QingzhouKit.build/*.o .build/debug/CQingzhouRoute.build/*.o .build/debug/Yams.build/*.o .build/debug/CYaml.build/src/*.o)
swiftc -parse-as-library -swift-version 5 -profile-generate -profile-coverage-mapping -I .build/debug/Modules -I Vendor/Yams/Sources/CYaml/include -Xcc -fmodule-map-file=.build/debug/CQingzhouRoute.build/module.modulemap -module-cache-path .build/module-cache Sources/QingzhouKit/ThroughputProbe.swift Sources/QingzhouChecks/ThroughputTests.swift Sources/QingzhouChecks/Assertions.swift "$stage/Bridge.swift" "$stage/Main.swift" "${objects[@]}" -o "$stage/checks"
LLVM_PROFILE_FILE="$stage/checks.profraw" "$stage/checks"
xcrun llvm-profdata merge -sparse "$stage/checks.profraw" -o "$stage/checks.profdata"
xcrun llvm-cov report "$stage/checks" -instr-profile="$stage/checks.profdata" Sources/QingzhouKit/ThroughputProbe.swift > "$stage/coverage.txt"
xcrun llvm-cov export "$stage/checks" -instr-profile="$stage/checks.profdata" Sources/QingzhouKit/ThroughputProbe.swift > "$stage/coverage.json"
cat "$stage/coverage.txt"
