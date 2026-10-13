#!/bin/bash
set -euo pipefail
# 用户以 sudo 执行此脚本，批准固定组件和当前应用身份；不接受外部核心或任意执行命令。
if [ "$(id -u)" != 0 ] || [ -z "${SUDO_UID:-}" ]; then echo '请由当前登录用户用 sudo 安装辅助服务。'; exit 1; fi
app="${1:?请指定本次构建的轻舟代理.app 路径}"
/usr/bin/codesign --verify --deep --strict "$app"
resources="$app/Contents/Resources"
for file in QingzhouHelper sing-box; do test -f "$resources/$file"; test ! -L "$resources/$file"; done
root=/Library/PrivilegedHelperTools/cn.qingzhou.proxy
plist=/Library/LaunchDaemons/cn.qingzhou.proxy.helper.plist
if [ -f "$plist" ]; then /bin/launchctl bootout system "$plist" || true; fi
if [ -f "$root/recovery.json" ]; then echo '仍有恢复记录，拒绝覆盖安装。请先在应用中恢复，或按手动恢复说明处理。'; exit 1; fi
/usr/bin/install -d -o root -g wheel -m 755 "$root"
/usr/bin/install -o root -g wheel -m 755 "$resources/QingzhouHelper" "$root/QingzhouHelper"
/usr/bin/install -o root -g wheel -m 755 "$resources/sing-box" "$root/sing-box"
/usr/bin/python3 - "$app" "$root" "$SUDO_UID" <<'PY'
import pathlib,subprocess,re,hashlib,json,sys,os
app,root,uid=sys.argv[1:];root=pathlib.Path(root)
text=subprocess.run(['/usr/bin/codesign','-d','--verbose=4',app],capture_output=True,text=True,check=True).stderr
match=re.search(r'^CDHash=([0-9a-f]+)$',text,re.M)
if not match: raise SystemExit('客户端代码身份无法读取')
manifest={'version':'0.3.0','uid':int(uid),'clientHash':match[1],'coreHash':hashlib.sha256((root/'sing-box').read_bytes()).hexdigest(),'helperHash':hashlib.sha256((root/'QingzhouHelper').read_bytes()).hexdigest()}
p=root/'manifest.json';p.write_text(json.dumps(manifest));p.chmod(0o600)
import plistlib
value={'Label':'cn.qingzhou.proxy.helper','ProgramArguments':[str(root/'QingzhouHelper')],'RunAtLoad':True,'KeepAlive':True,'ThrottleInterval':10,'UserName':'root','WorkingDirectory':str(root),'Umask':63,'StandardOutPath':'/dev/null','StandardErrorPath':'/dev/null'}
p=pathlib.Path('/Library/LaunchDaemons/cn.qingzhou.proxy.helper.plist');p.write_bytes(plistlib.dumps(value));p.chmod(0o644)
PY
/bin/launchctl bootstrap system "$plist"
echo '辅助服务安装完成。请在应用中检查版本后启用 TUN。'
