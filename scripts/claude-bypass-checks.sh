#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
# 检查串行构建，不安装服务、不加载 PF、不修改当前网络。
bash scripts/swift-local.sh build --product QingzhouChecks
QZ_BYPASS_RULE_FIXTURE="$PWD/.build/claude-bypass-rules.conf" \
QZ_BYPASS_CORE_FIXTURE="$PWD/.build/claude-bypass-core.json" \
    .build/debug/QingzhouChecks claude-bypass-checks
Vendor/sing-box check -c .build/claude-bypass-core.json
/sbin/pfctl -nf .build/claude-bypass-rules.conf
/sbin/pfctl -nf .build/claude-bypass-rules.conf.link
/sbin/pfctl -nf .build/claude-bypass-rules.conf.yunshu
.build/debug/QingzhouChecks disconnect-protection-checks
.build/debug/QingzhouChecks corporate-dns-checks
bash scripts/claude-bypass-helper-checks.sh
bash scripts/network-monitor-checks.sh
bash scripts/quit-release-checks.sh
bash scripts/claude-safety-checks.sh
