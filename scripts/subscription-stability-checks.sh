#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
bash scripts/swift-local.sh build --product QingzhouChecks > .build/subscription-build.log 2>&1
stage="$PWD/.build/subscription-stability"
mkdir -p "$stage"
objects=(.build/debug/QingzhouKit.build/*.o .build/debug/CQingzhouRoute.build/*.o .build/debug/Yams.build/*.o .build/debug/CYaml.build/src/*.o)
swiftc -parse-as-library -swift-version 5 -I .build/debug/Modules -I Vendor/Yams/Sources/CYaml/include -Xcc -fmodule-map-file=.build/debug/CQingzhouRoute.build/module.modulemap scripts/subscription-stability-checks.swift "${objects[@]}" -o "$stage/checks"
"$stage/checks"
