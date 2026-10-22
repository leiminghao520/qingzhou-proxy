#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
scripts/swift-local.sh build --product QingzhouHelper
objects=(.build/debug/QingzhouKit.build/*.o .build/debug/CQingzhouRoute.build/*.o .build/debug/Yams.build/*.o .build/debug/CYaml.build/src/*.o)
# 链接正式监控实现，夹具禁止管理员写操作，不安装或启动真实辅助服务。
swiftc -parse-as-library -swift-version 5 -I .build/debug/Modules -I Vendor/Yams/Sources/CYaml/include -Xcc -fmodule-map-file=.build/debug/CQingzhouRoute.build/module.modulemap \
    -module-cache-path .build/module-cache Sources/QingzhouHelper/NetworkMonitor.swift Sources/QingzhouHelper/NetworkResume.swift Sources/QingzhouHelper/RouteWriter.swift Sources/QingzhouHelper/DynamicNetwork.swift Sources/QingzhouHelper/HelperProxyVerification.swift \
    scripts/network-monitor-checks.swift scripts/dynamic-vpn-fixture.swift "${objects[@]}" -o .build/network-monitor-checks
.build/network-monitor-checks
