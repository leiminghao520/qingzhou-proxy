#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
stage="$PWD/.build/claude-dedicated-checks"
mkdir -p "$stage"
bash scripts/swift-local.sh build --product Qingzhou > "$stage/build.log" 2>&1
objects=(.build/debug/QingzhouKit.build/*.o .build/debug/CQingzhouRoute.build/*.o .build/debug/Yams.build/*.o .build/debug/CYaml.build/src/*.o)
swiftc -parse-as-library -swift-version 5 -I .build/debug/Modules -I Vendor/Yams/Sources/CYaml/include -Xcc -fmodule-map-file=.build/debug/CQingzhouRoute.build/module.modulemap -module-cache-path .build/module-cache scripts/claude-dedicated-proxy-checks.swift "${objects[@]}" -o "$stage/checks"
"$stage/checks" "$stage"
for config in "$stage"/config-*.json; do Vendor/sing-box check -c "$config"; done
