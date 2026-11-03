#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
scripts/swift-local.sh build --product QingzhouHelper
objects=(.build/debug/QingzhouKit.build/*.o .build/debug/CQingzhouRoute.build/*.o .build/debug/Yams.build/*.o .build/debug/CYaml.build/src/*.o)
# 正式辅助服务扩展链接到纯内存夹具，不安装服务，不执行真实管理员命令。
swiftc -parse-as-library -swift-version 5 -I .build/debug/Modules -I Vendor/Yams/Sources/CYaml/include -Xcc -fmodule-map-file=.build/debug/CQingzhouRoute.build/module.modulemap \
    -module-cache-path .build/module-cache Sources/QingzhouHelper/HelperRecoveryRecords.swift Sources/QingzhouHelper/BypassFirewall.swift Sources/QingzhouHelper/RouteWriter.swift \
    scripts/bypass-helper-checks.swift "${objects[@]}" -o .build/bypass-helper-checks
.build/bypass-helper-checks
