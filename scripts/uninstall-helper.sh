#!/bin/bash
set -euo pipefail
# 卸载先触发辅助服务恢复，不删除仍需手动处理的所有权记录。
if [ "$(id -u)" != 0 ]; then echo '请用 sudo 卸载辅助服务。'; exit 1; fi
root=/Library/PrivilegedHelperTools/cn.qingzhou.proxy
plist=/Library/LaunchDaemons/cn.qingzhou.proxy.helper.plist
if [ -f "$root/recovery.json" ]; then echo '恢复记录尚未处理，保留恢复服务并拒绝卸载。'; exit 1; fi
if [ -f "$plist" ]; then /bin/launchctl bootout system "$plist"; fi
if [ -f "$root/recovery.json" ]; then
    /bin/launchctl bootstrap system "$plist" || true
    echo '服务退出后仍有恢复记录，保留组件并恢复控制通道。'; exit 1
fi
for file in control.sock runtime.json manifest.json QingzhouHelper sing-box; do /bin/rm -f "$root/$file"; done
/bin/rmdir "$root" 2>/dev/null || true
/bin/rm -f "$plist"
echo '辅助服务已卸载。'
