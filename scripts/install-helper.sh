#!/bin/bash
set -euo pipefail
# 仅安装用户批准的固定组件；停止旧服务前完成新组件与恢复记录检查。
if [ "$(id -u)" != 0 ] || [ -z "${SUDO_UID:-}" ]; then echo '请由当前登录用户用 sudo 安装辅助服务。'; exit 1; fi
app="${1:?请指定本次构建的轻舟代理.app 路径}"
/usr/bin/codesign --verify --deep --strict "$app"
resources="$app/Contents/Resources"
for file in QingzhouHelper sing-box; do test -f "$resources/$file"; test ! -L "$resources/$file"; test -x "$resources/$file"; done
root=/Library/PrivilegedHelperTools/cn.qingzhou.proxy
plist=/Library/LaunchDaemons/cn.qingzhou.proxy.helper.plist
if [ -f "$root/recovery.json" ]; then echo '仍有恢复记录，保留旧恢复服务并拒绝覆盖。请先恢复网络。'; exit 1; fi
stage=$(/usr/bin/mktemp -d /Library/PrivilegedHelperTools/qingzhou-install.XXXXXX)
installed=0
stopped=0
completed=0
enabled_for_install=0
service=system/cn.qingzhou.proxy.helper
# 查询失败不能伪装成“未加载”，只接受 launchctl 明确返回服务不存在。
service_loaded() {
    local status
    if status=$(/bin/launchctl print "$service" 2>&1); then return 0; fi
    if [[ "$status" == *'Could not find service "cn.qingzhou.proxy.helper"'* ]]; then return 1; fi
    echo "辅助服务状态无法确认：$status" >&2
    return 2
}
was_disabled=0
cleanup() {
    code=$?
    trap - EXIT
    if [ "$completed" != 1 ]; then
        if [ "$installed" = 1 ]; then
            /bin/launchctl bootout system "$plist" 2>/dev/null || true
            for file in QingzhouHelper sing-box manifest.json; do
                if [ -f "$stage/old/$file" ]; then /bin/cp -p "$stage/old/$file" "$root/$file";
                elif [ ! -f "$root/recovery.json" ]; then /bin/rm -f "$root/$file"; fi
            done
            if [ -f "$stage/old/helper.plist" ]; then /bin/cp -p "$stage/old/helper.plist" "$plist";
            elif [ ! -f "$root/recovery.json" ]; then /bin/rm -f "$plist"; fi
        fi
        if [ "$stopped" = 1 ] && [ -f "$stage/old/helper.plist" ]; then
            # 停用标记与已加载状态相互独立，先恢复旧进程，再恢复原停用标记。
            if [ "$was_disabled" = 1 ]; then
                enabled_for_install=1
                /bin/launchctl enable "$service" || echo '旧服务临时启用失败，请手动检查。'
            fi
            /bin/launchctl bootstrap system "$plist" || echo '旧服务重启失败，保留组件与恢复记录，请手动检查。'
        fi
        if [ "$enabled_for_install" = 1 ]; then
            /bin/launchctl disable "$service" || echo '辅助服务停用状态恢复失败，请手动检查。'
        fi
    fi
    /bin/rm -rf "$stage"
    exit "$code"
}
trap cleanup EXIT
disabled_state=$(/bin/launchctl print-disabled system)
was_disabled=$(printf '%s' "$disabled_state" | /usr/bin/python3 -c 'import re,sys; text=sys.stdin.read(); match=re.search(r"\x22cn\.qingzhou\.proxy\.helper\x22\s*=>\s*(disabled|enabled|true|false)",text); print("1" if match and match[1] in ("disabled","true") else "0")')
/usr/bin/install -o root -g wheel -m 755 "$resources/QingzhouHelper" "$stage/QingzhouHelper"
/usr/bin/install -o root -g wheel -m 755 "$resources/sing-box" "$stage/sing-box"
/usr/bin/python3 - "$app" "$stage" "$root" "$SUDO_UID" <<'PYTHON'
import pathlib,subprocess,re,hashlib,json,sys,plistlib
app,stage,root,uid=sys.argv[1:];stage=pathlib.Path(stage)
text=subprocess.run(['/usr/bin/codesign','-d','--verbose=4',app],capture_output=True,text=True,check=True).stderr
match=re.search(r'^CDHash=([0-9a-f]+)$',text,re.M)
if not match: raise SystemExit('客户端代码身份无法读取')
version=plistlib.loads((pathlib.Path(app)/'Contents/Info.plist').read_bytes())['CFBundleShortVersionString']
manifest={'version':version,'uid':int(uid),'clientHash':match[1],'coreHash':hashlib.sha256((stage/'sing-box').read_bytes()).hexdigest(),'helperHash':hashlib.sha256((stage/'QingzhouHelper').read_bytes()).hexdigest()}
p=stage/'manifest.json';p.write_text(json.dumps(manifest));p.chmod(0o600)
value={'Label':'cn.qingzhou.proxy.helper','ProgramArguments':[root+'/QingzhouHelper'],'RunAtLoad':True,'KeepAlive':True,'ThrottleInterval':10,'UserName':'root','WorkingDirectory':root,'Umask':63,'StandardOutPath':'/dev/null','StandardErrorPath':'/dev/null'}
p=stage/'helper.plist';p.write_bytes(plistlib.dumps(value));p.chmod(0o644)
PYTHON
/bin/mkdir "$stage/old"
for file in QingzhouHelper sing-box manifest.json; do
    if [ -f "$root/$file" ]; then /bin/cp -p "$root/$file" "$stage/old/$file"; fi
done
if [ -f "$plist" ]; then
    /bin/cp -p "$plist" "$stage/old/helper.plist"
    if service_loaded; then
        if /bin/launchctl bootout system "$plist"; then
            stopped=1
        else
            # 服务可能在查询后自行退出；再次明确确认不存在才允许继续安装。
            if service_loaded; then echo '旧辅助服务未能停止，取消更新。' >&2; exit 1
            else status=$?; if [ "$status" != 1 ]; then exit "$status"; fi; fi
        fi
    else
        status=$?; if [ "$status" != 1 ]; then exit "$status"; fi
    fi
fi
# 退出旧服务时可能生成恢复记录，出现记录后继续保留旧服务。
if [ -f "$root/recovery.json" ]; then echo '旧服务退出后仍有恢复记录，已取消更新。'; exit 1; fi
# 旧服务退出后可能遗留套接字文件，不能把该文件当作新服务已经就绪。
if [ -S "$root/control.sock" ]; then /bin/rm -f "$root/control.sock"; fi
/usr/bin/install -d -o root -g wheel -m 755 "$root"
installed=1
for file in QingzhouHelper sing-box; do /usr/bin/install -o root -g wheel -m 755 "$stage/$file" "$root/$file"; done
/usr/bin/install -o root -g wheel -m 600 "$stage/manifest.json" "$root/manifest.json"
/usr/bin/install -o root -g wheel -m 644 "$stage/helper.plist" "$plist"
# 用户明确发起安装后才解除停用；失败回滚时恢复原标记。
if [ "$was_disabled" = 1 ]; then
    enabled_for_install=1
    /bin/launchctl enable "$service"
fi
/bin/launchctl bootstrap system "$plist"
for attempt in {1..50}; do
    if [ -S "$root/control.sock" ]; then completed=1; break; fi
    /bin/sleep 0.1
done
if [ "$completed" != 1 ]; then echo '辅助服务启动核验失败，回滚安装。'; exit 1; fi
echo '辅助服务安装完成。请在应用中检查版本后启用 TUN。'
