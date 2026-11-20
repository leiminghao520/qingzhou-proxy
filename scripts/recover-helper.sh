#!/bin/bash
set -euo pipefail
# 管理员维护不依赖旧客户端身份；只清理仍由恢复记录证明属于汐航的接管。
if [ "$(id -u)" != 0 ]; then echo '请用 sudo 执行恢复。'; exit 1; fi
root=/Library/PrivilegedHelperTools/cn.qingzhou.proxy
plist=/Library/LaunchDaemons/cn.qingzhou.proxy.helper.plist
app="${1:-$(cd "$(dirname "$0")/../.." && pwd)}"
mode="${2:-}"
if [ -n "$mode" ] && [ "$mode" != --for-update ] && [ "$mode" != --acknowledge ]; then echo '恢复参数无效。'; exit 1; fi
/usr/bin/codesign --verify --deep --strict "$app"
helper="$app/Contents/Resources/QingzhouHelper"
test -f "$helper"; test ! -L "$helper"; test -x "$helper"
# 保留根目录中的审计证据和原组件，失败时可追溯，不删除或改写原恢复记录。
backup=$(/usr/bin/mktemp -d /Library/PrivilegedHelperTools/qingzhou-recovery.XXXXXX)
/bin/chmod 700 "$backup"
for file in disconnect-protection.json disconnect-protection.conf disconnect-protection-root.conf recovery.json normal-network-recovery.json manifest.json QingzhouHelper sing-box route-operations.jsonl route-operations.previous.jsonl; do
    if [ -f "$root/$file" ]; then /bin/cp -p "$root/$file" "$backup/$file"; fi
done
if [ -f "$plist" ]; then /bin/cp -p "$plist" "$backup/helper.plist"; fi
/usr/bin/install -o root -g wheel -m 755 "$helper" "$backup/recovery-helper"
/usr/bin/codesign --verify --strict "$backup/recovery-helper"
echo "管理员恢复备份：$backup"
service=system/cn.qingzhou.proxy.helper
service_loaded() {
    local status
    if status=$(/bin/launchctl print "$service" 2>&1); then return 0; fi
    if [[ "$status" == *'Could not find service "cn.qingzhou.proxy.helper"'* ]]; then return 1; fi
    echo "辅助服务状态无法确认：$status" >&2
    return 2
}
if [ "$mode" = --acknowledge ]; then
    if service_loaded; then echo '辅助服务仍运行，不能确认独立恢复。' >&2; exit 1
    else result=$?; if [ "$result" != 1 ]; then exit 1; fi; fi
    "$backup/recovery-helper" --acknowledge-normal-recovery
    exit 0
fi
# 明确恢复网络后保持旧服务停用，避免它再次施加阻断；安装新服务由用户重新发起。
if [ "$mode" != --for-update ]; then /bin/launchctl disable "$service"; fi
old_pid=""
if service_loaded; then
    old_pid=$(/bin/launchctl print "$service" | /usr/bin/awk '/^[[:space:]]*pid = [0-9]+/ {print $3; exit}')
    /bin/launchctl bootout "$service"
else
    result=$?; if [ "$result" != 1 ]; then exit 1; fi
fi
# 等待服务卸载和原进程实际退出，不能在旧进程仍可能写网络时运行一次性恢复器。
confirmed=0
for attempt in {1..50}; do
    if service_loaded; then :
    else
        result=$?; if [ "$result" != 1 ]; then exit 1; fi
        command=""
        if [ -n "$old_pid" ]; then command=$(/bin/ps -p "$old_pid" -o comm= 2>/dev/null || true); fi
        if [ "$command" != "$root/QingzhouHelper" ]; then confirmed=1; break; fi
    fi
    /bin/sleep 0.1
done
if [ "$confirmed" != 1 ]; then echo '旧辅助服务尚未退出，恢复未完成；未启动第二个恢复器。' >&2; exit 1; fi
# 旧服务退出可能更新恢复记录；另存停止后的最终意图，供故障复核。
if [ -f "$root/recovery.json" ]; then /bin/cp -p "$root/recovery.json" "$backup/recovery-after-stop.json"; fi
if [ "$mode" = --for-update ]; then
    # 升级只清理接管，不得借维护流程隐式解除用户持有的断网屏障。
    "$backup/recovery-helper" --recover-preserving-protection
else
    echo '正在明确解除汐航断网保护，之后 Claude 可能直连。'
    "$backup/recovery-helper" --recover-preserving-external
fi
if [ -f "$root/recovery.json" ]; then echo '恢复核验仍有未完成记录，取消更新。' >&2; exit 1; fi
if [ "$mode" = --for-update ]; then
    echo '汐航接管已清理，断网保护保留，可继续更新。'
else
    echo '汐航接管与阻断已清理，旧服务保持停用；其他 VPN 与系统代理已保留。'
fi
