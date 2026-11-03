#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
scripts/swift-local.sh build --product QingzhouHelper
objects=(.build/debug/QingzhouKit.build/*.o .build/debug/CQingzhouRoute.build/*.o .build/debug/Yams.build/*.o .build/debug/CYaml.build/src/*.o)
# 只读取合成状态，不写系统代理，不启动已安装应用或辅助服务。
swiftc -parse-as-library -swift-version 5 -I .build/debug/Modules -I Vendor/Yams/Sources/CYaml/include -Xcc -fmodule-map-file=.build/debug/CQingzhouRoute.build/module.modulemap \
    -module-cache-path .build/module-cache Sources/QingzhouHelper/HelperProxyVerification.swift \
    scripts/proxy-activation-checks.swift "${objects[@]}" -o .build/proxy-activation-checks
.build/proxy-activation-checks
