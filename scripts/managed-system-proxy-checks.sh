#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
bash scripts/swift-local.sh build --product QingzhouHelper > .build/managed-helper-build.log 2>&1
objects=(.build/debug/QingzhouKit.build/*.o .build/debug/CQingzhouRoute.build/*.o .build/debug/Yams.build/*.o .build/debug/CYaml.build/src/*.o)
swiftc -parse-as-library -swift-version 5 -profile-generate -profile-coverage-mapping -I .build/debug/Modules -I Vendor/Yams/Sources/CYaml/include -Xcc -fmodule-map-file=.build/debug/CQingzhouRoute.build/module.modulemap -module-cache-path .build/module-cache Sources/QingzhouHelper/ManagedSystemProxy.swift Sources/QingzhouHelper/HelperJournal.swift Sources/QingzhouHelper/HelperRecoveryRecords.swift scripts/managed-system-proxy-checks.swift "${objects[@]}" -o .build/managed-system-proxy-checks
LLVM_PROFILE_FILE=.build/managed-proxy.profraw .build/managed-system-proxy-checks
xcrun llvm-profdata merge -sparse .build/managed-proxy.profraw -o .build/managed-proxy.profdata
xcrun llvm-cov report .build/managed-system-proxy-checks -instr-profile=.build/managed-proxy.profdata Sources/QingzhouHelper/ManagedSystemProxy.swift
