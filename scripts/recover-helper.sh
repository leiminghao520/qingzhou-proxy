#!/bin/bash
set -euo pipefail
# 串行恢复期间停止服务；即使恢复遇到冲突，也重新提供旧控制通道。
if [ "$(id -u)" != 0 ]; then echo '请用 sudo 执行恢复。'; exit 1; fi
plist=/Library/LaunchDaemons/cn.qingzhou.proxy.helper.plist
stopped=0
cleanup() {
    code=$?
    trap - EXIT
    if [ "$stopped" = 1 ] && [ -f "$plist" ]; then
        /bin/launchctl bootstrap system "$plist" || { echo '辅助服务重启失败，恢复记录已保留。'; exit 1; }
    fi
    exit "$code"
}
trap cleanup EXIT
if [ -f "$plist" ]; then /bin/launchctl bootout system "$plist"; stopped=1; fi
/Library/PrivilegedHelperTools/cn.qingzhou.proxy/QingzhouHelper --recover
