#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
# 本入口仅运行内存、文件和进程内 Unix 通道夹具，禁止管理员身份及宿主网络诊断分支。
if [[ "$(id -u)" == 0 ]]; then printf '%s\n' '离线检查禁止管理员运行。' >&2;exit 1;fi
mkdir -p .build/panic-fix-evidence
bash scripts/route-transport-offline.sh
bash scripts/route-protocol-offline.sh
bash scripts/native-route-checks.sh
bash scripts/capture-precedence-checks.sh
bash scripts/capture-codec-checks.sh
.build/native-route-checks --export-plans > .build/panic-fix-evidence/capture-plans.json
/usr/bin/python3 scripts/capture-plan-oracle.py .build/panic-fix-evidence/capture-plans.json
bash scripts/helper-channel-offline.sh
bash scripts/helper-recovery-offline.sh
bash scripts/protection-startup-checks.sh
bash scripts/network-monitor-checks.sh
/usr/bin/python3 scripts/dynamic-vpn-isolation.py
bash scripts/bypass-helper-checks.sh
bash scripts/quit-release-checks.sh
bash scripts/proxy-activation-checks.sh
bash scripts/network-resume-model-checks.sh
bash scripts/swift-local.sh run QingzhouChecks
printf '%s\n' 'PANIC_FIX_OFFLINE_SUITE_OK（不表示真实内核写入或实网验收通过）'
