#!/bin/bash
set -euo pipefail
# 先停止 launchd 实例，避免两个恢复操作同时处理网络所有权记录。
if [ "$(id -u)" != 0 ]; then echo '请用 sudo 执行恢复。'; exit 1; fi
plist=/Library/LaunchDaemons/cn.qingzhou.proxy.helper.plist
if [ -f "$plist" ]; then /bin/launchctl bootout system "$plist" || true; fi
/Library/PrivilegedHelperTools/cn.qingzhou.proxy/QingzhouHelper --recover
if [ -f "$plist" ]; then /bin/launchctl bootstrap system "$plist"; fi
