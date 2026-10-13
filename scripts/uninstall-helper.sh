#!/bin/bash
set -euo pipefail
# 卸载先触发辅助服务恢复，不删除仍需手动处理的所有权记录。
if [ "$(id -u)" != 0 ]; then echo '请用 sudo 卸载辅助服务。'; exit 1; fi
root=/Library/PrivilegedHelperTools/cn.qingzhou.proxy
plist=/Library/LaunchDaemons/cn.qingzhou.proxy.helper.plist
if [ -f "$plist" ]; then /bin/launchctl bootout system "$plist" || true; fi
if [ -f "$root/recovery.json" ]; then echo '恢复记录仍存在，未删除组件。请先按手动恢复说明处理，再卸载。'; exit 1; fi
for file in control.sock runtime.json manifest.json QingzhouHelper sing-box; do /bin/rm -f "$root/$file"; done
/bin/rmdir "$root" 2>/dev/null || true
/bin/rm -f "$plist"
echo '辅助服务已卸载。'
