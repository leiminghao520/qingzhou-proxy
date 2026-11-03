#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
mkdir -p .build
bash scripts/swift-local.sh build --product QingzhouChecks > .build/automatic-selection-build.log 2>&1
objects=(.build/debug/QingzhouKit.build/*.o .build/debug/CQingzhouRoute.build/*.o .build/debug/Yams.build/*.o .build/debug/CYaml.build/src/*.o)
swiftc -parse-as-library -swift-version 5 -I .build/debug/Modules -I Vendor/Yams/Sources/CYaml/include -Xcc -fmodule-map-file=.build/debug/CQingzhouRoute.build/module.modulemap scripts/automatic-selection-checks.swift "${objects[@]}" -o .build/automatic-selection-checks
.build/automatic-selection-checks
