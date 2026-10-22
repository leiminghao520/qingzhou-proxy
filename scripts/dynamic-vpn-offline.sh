#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
# 仅使用模拟网络快照与回环业务服务器，配置移除 TUN 入站，不操作宿主路由。
bash scripts/network-monitor-checks.sh
python3 scripts/dynamic-vpn-isolation.py
