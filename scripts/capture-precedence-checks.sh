#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
bash scripts/swift-local.sh build --product QingzhouHelper
objects=(.build/debug/QingzhouKit.build/*.o .build/debug/CQingzhouRoute.build/*.o .build/debug/Yams.build/*.o .build/debug/CYaml.build/src/*.o)
swiftc -parse-as-library -swift-version 5 -I .build/debug/Modules -I Vendor/Yams/Sources/CYaml/include -Xcc -fmodule-map-file=.build/debug/CQingzhouRoute.build/module.modulemap scripts/capture-precedence-checks.swift "${objects[@]}" -o .build/capture-precedence-checks
.build/capture-precedence-checks
