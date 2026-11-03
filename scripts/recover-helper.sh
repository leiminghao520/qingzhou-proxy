#!/bin/bash
set -euo pipefail
# 管理员维护不依赖旧客户端身份；只清理仍由恢复记录证明属于汐航的接管。
if [ "$(id -u)" != 0 ]; then echo '请用 sudo 执行恢复。'; exit 1; fi
root=/Library/PrivilegedHelperTools/cn.qingzhou.proxy
plist=/Library/LaunchDaemons/cn.qingzhou.proxy.helper.plist
app="${1:-$(cd "$(dirname "$0")/../.." && pwd)}"
mode="${2:-}"
if [ -n "$mode" ] && [ "$mode" != --for-update ]; then echo '恢复参数无效。'; exit 1; fi
/usr/bin/codesign --verify --deep --strict "$app"
helper="$app/Contents/Resources/QingzhouHelper"
test -f "$helper"; test ! -L "$helper"; test -x "$helper"
# 保留根目录中的审计证据和原组件，失败时可追溯，不删除或改写原恢复记录。
backup=$(/usr/bin/mktemp -d /Library/PrivilegedHelperTools/qingzhou-recovery.XXXXXX)
/bin/chmod 700 "$backup"
for file in recovery.json manifest.json QingzhouHelper sing-box route-operations.jsonl route-operations.previous.jsonl; do
    if [ -f "$root/$file" ]; then /bin/cp -p "$root/$file" "$backup/$file"; fi
done
if [ -f "$plist" ]; then /bin/cp -p "$plist" "$backup/helper.plist"; fi
/usr/bin/install -o root -g wheel -m 755 "$helper" "$backup/recovery-helper"
/usr/bin/codesign --verify --strict "$backup/recovery-helper"
echo "管理员恢复备份：$backup"
stopped=0
cleanup() {
    code=$?
    trap - EXIT
    if [ "$stopped" = 1 ]; then
        # 尚有冲突时不重启旧版严格恢复流程，避免反复启动及覆盖外部网络。
        if [ -f "$root/recovery.json" ]; then
            echo '恢复未完成，旧服务保持停止，恢复记录和备份均已保留；可再次执行维护恢复。' >&2
        elif [ "$mode" != --for-update ] || [ "$code" != 0 ]; then
            /bin/launchctl bootstrap system "$plist" || { echo '辅助服务重启失败，请执行安装/更新。' >&2; exit 1; }
        fi
    fi
    exit "$code"
}
trap cleanup EXIT
if [ -f "$plist" ]; then
    if status=$(/bin/launchctl print system/cn.qingzhou.proxy.helper 2>&1); then
        /bin/launchctl bootout system "$plist"; stopped=1
    elif [[ "$status" != *'Could not find service "cn.qingzhou.proxy.helper"'* ]]; then
        echo "辅助服务状态无法确认：$status" >&2; exit 1
    fi
fi
# 旧服务退出可能更新恢复记录；另存停止后的最终意图，供故障复核。
if [ -f "$root/recovery.json" ]; then /bin/cp -p "$root/recovery.json" "$backup/recovery-after-stop.json"; fi
"$backup/recovery-helper" --recover-preserving-external
if [ -f "$root/recovery.json" ]; then echo '恢复核验仍有未完成记录，取消更新。' >&2; exit 1; fi
echo '汐航接管已清理，其他 VPN 与系统代理已保留。'
