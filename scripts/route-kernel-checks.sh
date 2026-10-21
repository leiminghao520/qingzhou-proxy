#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
scripts/swift-local.sh build --product QingzhouHelper
objects=(.build/debug/QingzhouKit.build/*.o .build/debug/Yams.build/*.o .build/debug/CYaml.build/src/*.o)
# 构建本身不需要管理员权限；生成的验证程序只操作回环接口限定路由。
swiftc -parse-as-library -swift-version 5 -I .build/debug/Modules -I Vendor/Yams/Sources/CYaml/include \
    -module-cache-path .build/module-cache scripts/route-kernel-checks.swift "${objects[@]}" -o .build/route-kernel-checks
printf '%s\n' '构建完成；使用 sudo .build/route-kernel-checks 运行内核验证。'

# 残留修复工具默认只读，应用操作必须由操作者显式指定。
swiftc -parse-as-library -swift-version 5 -I .build/debug/Modules -I Vendor/Yams/Sources/CYaml/include \
    -module-cache-path .build/module-cache scripts/repair-legacy-host-route.swift "${objects[@]}" -o .build/repair-legacy-host-route
