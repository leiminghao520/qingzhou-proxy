#!/usr/bin/env python3
# 在临时目录和模拟 launchctl 中验证管理员脚本，不接触真实服务或系统网络。
import json,os,pathlib,plistlib,subprocess,tempfile
R=pathlib.Path(__file__).resolve().parent.parent
scenarios=0
with tempfile.TemporaryDirectory(prefix='qz-helper-scripts-') as folder:
    stage=pathlib.Path(folder);root=stage/'root';plist=stage/'helper.plist';app=stage/'app.app';resources=app/'Contents/Resources';resources.mkdir(parents=True)
    (app/'Contents/Info.plist').write_bytes(plistlib.dumps({'CFBundleShortVersionString':'0.7.0'}))
    for file in ['sing-box','QingzhouHelper']:
        p=resources/file;p.write_text('#!/bin/bash\nexit 0\n');p.chmod(0o755)
    log=stage/'launch.log';mock=stage/'launchctl'
    mock.write_text("#!/usr/bin/env python3\nimport os,pathlib,sys\nroot=pathlib.Path(os.environ['TEST_ROOT']);log=pathlib.Path(os.environ['TEST_LOG'])\nwith log.open('a') as output:output.write(sys.argv[1]+'\\n')\nif sys.argv[1]=='bootstrap':\n    if os.environ.get('TEST_BOOTSTRAP_FAIL')=='1':sys.exit(1)\n    if os.environ.get('TEST_NO_SOCKET')=='1':sys.exit(0)\n    import socket\n    sock=socket.socket(socket.AF_UNIX,socket.SOCK_STREAM);sock.bind(str(root/'control.sock'));sock.close()\nif sys.argv[1]=='bootout':\n    p=root/'control.sock'\n    if p.exists():p.unlink()\n    if os.environ.get('TEST_RECOVERY_ON_STOP')=='1':(root/'recovery.json').write_text('{}')\n");mock.chmod(0o755)
    signer=stage/'codesign';signer.write_text('#!/bin/bash\nif [ "$1" = "-d" ]; then echo CDHash=abcdef >&2; fi\n');signer.chmod(0o755)
    installer=stage/'install';installer.write_text("#!/usr/bin/env python3\nimport os,pathlib,shutil,sys\nargs=sys.argv[1:];mode=0o755;directory=False;paths=[]\nwhile args:\n    item=args.pop(0)\n    if item in ['-o','-g']:args.pop(0)\n    elif item=='-m':mode=int(args.pop(0),8)\n    elif item=='-d':directory=True\n    else:paths.append(item)\nif directory:\n    for path in paths:pathlib.Path(path).mkdir(parents=True,exist_ok=True);os.chmod(path,mode)\nelse:shutil.copyfile(paths[0],paths[1]);os.chmod(paths[1],mode)\n");installer.chmod(0o755)
    def run(name,**options):
        source=(R/'scripts'/name).read_text().replace('$(id -u)','0').replace('/Library/PrivilegedHelperTools/cn.qingzhou.proxy',str(root)).replace('/Library/LaunchDaemons/cn.qingzhou.proxy.helper.plist',str(plist)).replace('/Library/PrivilegedHelperTools/qingzhou-install.',str(stage/'install.')).replace('/bin/launchctl',str(mock)).replace('/usr/bin/codesign',str(signer)).replace("'/usr/bin/codesign'",repr(str(signer))).replace('/usr/bin/install',str(installer)).replace('for attempt in {1..50}', 'for attempt in {1..2}')
        target=stage/name;target.write_text(source)
        env=dict(os.environ,SUDO_UID='501',TEST_ROOT=str(root),TEST_LOG=str(log),**options)
        result=subprocess.run(['/bin/bash',str(target),str(app)],env=env,capture_output=True,text=True)
        return result
    def reset():
        import shutil
        if root.exists():shutil.rmtree(root)
        root.mkdir()
        if plist.exists():plist.unlink()
        log.write_text('')
    def passed(name):
        global scenarios
        scenarios+=1;print('PASS HelperScripts.'+name)
    reset();(root/'recovery.json').write_text('{}');(root/'QingzhouHelper').write_text('old')
    result=run('install-helper.sh');assert result.returncode!=0 and log.read_text()=='' and (root/'QingzhouHelper').read_text()=='old';passed('pendingRecoveryKeepsService')
    reset();result=run('install-helper.sh',TEST_BOOTSTRAP_FAIL='1');assert result.returncode!=0 and not plist.exists() and not (root/'manifest.json').exists() and not (root/'QingzhouHelper').exists();passed('firstInstallFailureRemovesOwnedFiles')
    reset();plist.write_text('old-plist')
    for name in ['QingzhouHelper','sing-box','manifest.json']:(root/name).write_text('old-'+name)
    result=run('install-helper.sh',TEST_BOOTSTRAP_FAIL='1');assert result.returncode!=0 and plist.read_text()=='old-plist' and (root/'QingzhouHelper').read_text()=='old-QingzhouHelper';passed('upgradeFailureRestoresComponents')
    reset();result=run('install-helper.sh');assert result.returncode==0 and (root/'control.sock').exists() and json.loads((root/'manifest.json').read_text())['version']=='0.7.0';passed('successRequiresControlSocket')
    reset();plist.write_text('old-plist');(root/'QingzhouHelper').write_text('#!/bin/bash\nexit 1\n');(root/'QingzhouHelper').chmod(0o755)
    result=run('recover-helper.sh');assert result.returncode!=0 and log.read_text().splitlines()==['bootout','bootstrap'];passed('recoveryFailureRestartsService')
    reset();plist.write_text('old-plist');(root/'recovery.json').write_text('{}')
    result=run('uninstall-helper.sh');assert result.returncode!=0 and log.read_text()=='' and plist.exists();passed('uninstallPendingRecoveryKeepsService')
    reset();plist.write_text('old-plist');(root/'QingzhouHelper').write_text('old')
    result=run('uninstall-helper.sh',TEST_RECOVERY_ON_STOP='1');assert result.returncode!=0 and log.read_text().splitlines()==['bootout','bootstrap'] and (root/'QingzhouHelper').read_text()=='old';passed('uninstallConflictRestartsService')
    reset();plist.write_text('old-plist')
    for name in ['QingzhouHelper','sing-box','manifest.json']:(root/name).write_text('old-'+name)
    import socket
    stale=socket.socket(socket.AF_UNIX);stale.bind(str(root/'control.sock'));stale.close()
    result=run('install-helper.sh',TEST_NO_SOCKET='1')
    assert result.returncode!=0 and (root/'QingzhouHelper').read_text()=='old-QingzhouHelper' and not (root/'control.sock').exists()
    passed('staleSocketDoesNotProveNewServiceReady')
print('RESULT helper_script_scenarios='+str(scenarios)+' failures=0')
