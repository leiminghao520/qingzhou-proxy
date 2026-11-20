#!/usr/bin/python3
"""停用汐航并清理经所有权核对的过滤规则，保留企业网络。"""
import datetime
import json
import os
from pathlib import Path
import re
import shutil
import subprocess
import sys
import time

ROOT = Path('/Library/PrivilegedHelperTools/cn.qingzhou.proxy')
SERVICE = 'system/cn.qingzhou.proxy.helper'

def run(args, allowed=(0,)):
    result = subprocess.run(args, capture_output=True, text=True, timeout=25)
    if result.returncode not in allowed:
        raise RuntimeError('命令失败：' + ' '.join(args[:4]) + '\n' + result.stderr)
    return result

def pf(*args, missing=False):
    result = run(['/sbin/pfctl', *args])
    errors = [line for line in result.stderr.splitlines()
              if line and line not in ('No ALTQ support in kernel', 'ALTQ related functions disabled')]
    if errors and not (missing and errors == ['pfctl: DIOCGETRULES: Invalid argument'] and not result.stdout.strip()):
        raise RuntimeError('防火墙读取或操作异常：' + '\n'.join(errors))
    return result.stdout

def normalized(value):
    return '\n'.join(line.strip() for line in value.splitlines() if line.strip()) + '\n'

def main():
    if os.geteuid() != 0:
        raise RuntimeError('请用 sudo 执行此脚本')
    os.umask(0o077)
    processes = run(['/bin/ps', '-axo', 'comm=']).stdout.splitlines()
    if any(line.strip().endswith(('/Qingzhou', '/sing-box')) for line in processes):
        raise RuntimeError('汐航界面或代理核心仍在运行，未执行恢复')
    if (ROOT / 'recovery.json').exists():
        raise RuntimeError('发现尚未恢复的接管记录，不能跳过路由恢复直接清理')
    backup = ROOT.parent / ('qingzhou-network-rescue-' + datetime.datetime.now().strftime('%Y%m%d-%H%M%S-%f'))
    backup.mkdir(mode=0o700)
    names = ['disconnect-protection.json', 'disconnect-protection.conf',
             'disconnect-protection-root.conf', 'yunshu-control-context.json']
    for name in names:
        if (ROOT / name).exists():
            shutil.copy2(ROOT / name, backup / name)
    # 先禁止下次启动重新施加阻断，再停止当前辅助服务。
    run(['/bin/launchctl', 'disable', SERVICE])
    if subprocess.run(['/bin/launchctl', 'print', SERVICE], capture_output=True).returncode == 0:
        run(['/bin/launchctl', 'bootout', SERVICE])
    # 卸载返回后服务可能仍在退出，等待系统完成移除后再核验。
    for _ in range(40):
        if subprocess.run(['/bin/launchctl', 'print', SERVICE], capture_output=True).returncode != 0:
            break
        time.sleep(0.5)
    if subprocess.run(['/bin/launchctl', 'print', SERVICE], capture_output=True).returncode == 0:
        raise RuntimeError('辅助服务仍在运行，已停止后续操作')
    if (ROOT / 'recovery.json').exists():
        raise RuntimeError('停止服务后发现接管记录，保留证据并停止清理')
    record = ROOT / 'disconnect-protection.json'
    current_root = normalized(pf('-sr'))
    (backup / 'pf-root-before.txt').write_text(current_root)
    # 不释放旧的 PF 启用凭据，避免影响企业防火墙的启用状态。
    try:
        (backup / 'pf-references.txt').write_text(pf('-s', 'References'))
    except RuntimeError as error:
        (backup / 'pf-references-warning.txt').write_text(str(error))
        print('提示：PF 启用引用未能读取；本工具不释放该引用，继续核对自有过滤规则。')
    if record.exists():
        lease = json.loads(record.read_text())
        anchor = lease.get('anchor', '')
        if not re.fullmatch(r'qingzhou-lock-[0-9a-f]{8}(?:-[0-9a-f]{4}){3}-[0-9a-f]{12}', anchor):
            raise RuntimeError('保护锚点不符合本次已知格式，未清理')
        before = normalized(lease.get('rootBefore') or '')
        permitted = {'anchor "com.sangfor.' + name + '" all' for name in
                     ('atrust', 'atrust1', 'vpn', 'app01', 'app02', 'byod')}
        permitted.add('anchor "com.apple/*" all')
        lines = before.splitlines()
        if not lines or len(lines) != len(set(lines)) or not set(lines).issubset(permitted):
            raise RuntimeError('原企业根规则证据不匹配，未覆盖现有规则')
        expected_root = 'anchor "' + anchor + '" quick all\n' + before
        if lease.get('rootExpected') != expected_root or current_root not in (before, expected_root):
            raise RuntimeError('当前根规则存在其他变化，未覆盖现有规则')
        actual = pf('-a', anchor, '-sr', missing=True)
        inventory = pf('-s', 'Anchors').split()
        if anchor in inventory and pf('-a', anchor, '-s', 'Anchors').strip():
            raise RuntimeError('自有锚点存在子锚点，未清理')
        if actual.strip() and actual.strip() != (lease.get('expected') or '').strip():
            raise RuntimeError('自有锚点内容已变化，未清理')
        # 仅撤销已核对的自有根引用，不重载任何企业子锚点。
        if current_root != before:
            restore = backup / 'enterprise-root.conf'
            restore.write_text(before)
            run(['/sbin/pfctl', '-n', '-R', '-f', str(restore)])
            run(['/sbin/pfctl', '-R', '-f', str(restore)])
        if anchor in inventory:
            run(['/sbin/pfctl', '-a', anchor, '-F', 'rules'])
        if normalized(pf('-sr')) != before or pf('-a', anchor, '-sr', missing=True).strip():
            raise RuntimeError('清理后核验失败，恢复记录已保留')
        for name in names:
            if (ROOT / name).exists():
                shutil.move(str(ROOT / name), str(backup / ('archived-' + name)))
    elif 'qingzhou-lock-' in current_root:
        raise RuntimeError('缺少所有权记录但发现保护引用，未清理')
    print('完成：汐航后台已停用，自有公网阻断已清理；云枢、DNS、路由和系统 PF 启用状态未重置。')
    print('Claude 断线保护已关闭；请暂时不要重新打开汐航。')
    print('私有恢复备份：' + str(backup))

if __name__ == '__main__':
    try:
        main()
    except Exception as error:
        print('恢复未完成：' + str(error), file=sys.stderr)
        sys.exit(1)
