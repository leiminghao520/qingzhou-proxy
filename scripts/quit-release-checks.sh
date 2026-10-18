#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
scripts/swift-local.sh build --product QingzhouHelper
objects=(.build/debug/QingzhouKit.build/*.o .build/debug/Yams.build/*.o .build/debug/CYaml.build/src/*.o)
# 正式退出核验与隔离夹具链接，不安装辅助服务或改写当前网络。
swiftc -parse-as-library -swift-version 5 -I .build/debug/Modules -I Vendor/Yams/Sources/CYaml/include \
    -module-cache-path .build/module-cache Sources/QingzhouHelper/QuitRelease.swift \
    scripts/quit-release-checks.swift "${objects[@]}" -o .build/quit-release-checks
.build/quit-release-checks
