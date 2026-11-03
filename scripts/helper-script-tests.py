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
    mock.write_text('#!/usr/bin/env python3\nimport os,pathlib,sys\nroot=pathlib.Path(os.environ[\'TEST_ROOT\']);log=pathlib.Path(os.environ[\'TEST_LOG\'])\nstate=root/\'test-launch-state\'\nloaded=state.exists() if os.environ.get(\'TEST_LOADED\')==\'0\' else not (root/\'test-unloaded\').exists()\noperation=sys.argv[1]\nif operation==\'print-disabled\':\n    if os.environ.get(\'TEST_DISABLED_QUERY_FAIL\')==\'1\':sys.exit(5)\n    disabled=os.environ.get(\'TEST_DISABLED\')==\'1\' and not (root/\'test-enabled\').exists()\n    print(\'"cn.qingzhou.proxy.helper" => \'+(\'disabled\' if disabled else \'enabled\'))\n    sys.exit(0)\nif operation==\'print\':\n    if os.environ.get(\'TEST_PRINT_FAIL\')==\'1\':print(\'Operation not permitted\',file=sys.stderr);sys.exit(1)\n    if loaded:print(\'system/cn.qingzhou.proxy.helper = {}\');sys.exit(0)\n    print(\'Could not find service "cn.qingzhou.proxy.helper" in domain for system\',file=sys.stderr);sys.exit(113)\nwith log.open(\'a\') as output:output.write(operation+\'\\n\')\nif operation==\'enable\':\n    if os.environ.get(\'TEST_ENABLE_FAIL\')==\'1\':sys.exit(5)\n    (root/\'test-enabled\').touch()\nif operation==\'disable\':\n    (root/\'test-enabled\').unlink(missing_ok=True)\nif operation==\'bootstrap\':\n    if os.environ.get(\'TEST_BOOTSTRAP_FAIL_ONCE\')==\'1\' and not (root/\'test-first-bootstrap-failed\').exists():\n        (root/\'test-first-bootstrap-failed\').touch();sys.exit(5)\n    if os.environ.get(\'TEST_BOOTSTRAP_FAIL\')==\'1\':sys.exit(1)\n    if os.environ.get(\'TEST_DISABLED\')==\'1\' and not (root/\'test-enabled\').exists():sys.exit(5)\n    state.touch();(root/\'test-unloaded\').unlink(missing_ok=True)\n    if os.environ.get(\'TEST_NO_SOCKET\')==\'1\':sys.exit(0)\n    import socket\n    sock=socket.socket(socket.AF_UNIX,socket.SOCK_STREAM);sock.bind(str(root/\'control.sock\'));sock.close()\nif operation==\'bootout\':\n    if os.environ.get(\'TEST_BOOTOUT_FAIL\')==\'1\':\n        if os.environ.get(\'TEST_STOP_RACE\')==\'1\':(root/\'test-unloaded\').touch();state.unlink(missing_ok=True)\n        sys.exit(5)\n    if not loaded:sys.exit(5)\n    (root/\'test-unloaded\').touch();state.unlink(missing_ok=True)\n    p=root/\'control.sock\'\n    if p.exists():p.unlink()\n    if os.environ.get(\'TEST_RECOVERY_ON_STOP\')==\'1\':(root/\'recovery.json\').write_text(\'{}\')\n');mock.chmod(0o755)
    signer=stage/'codesign';signer.write_text("#!/usr/bin/env python3\nimport os,sys\nif '-d' in sys.argv:\n    if '-r-' in sys.argv:print('designated => '+os.environ.get('TEST_REQUIREMENT',''),file=sys.stderr)\n    else:\n        print('CDHash=abcdef',file=sys.stderr)\n        if os.environ.get('TEST_SIGNED')=='1':print('TeamIdentifier=TESTTEAM01',file=sys.stderr)\n");signer.chmod(0o755)
    installer=stage/'install';installer.write_text("#!/usr/bin/env python3\nimport os,pathlib,shutil,sys\nargs=sys.argv[1:];mode=0o755;directory=False;paths=[]\nwhile args:\n    item=args.pop(0)\n    if item in ['-o','-g']:args.pop(0)\n    elif item=='-m':mode=int(args.pop(0),8)\n    elif item=='-d':directory=True\n    else:paths.append(item)\nif directory:\n    for path in paths:pathlib.Path(path).mkdir(parents=True,exist_ok=True);os.chmod(path,mode)\nelse:shutil.copyfile(paths[0],paths[1]);os.chmod(paths[1],mode)\n");installer.chmod(0o755)
    def transform(name):
        return (R/'scripts'/name).read_text().replace('$(id -u)','0').replace('/Library/PrivilegedHelperTools/cn.qingzhou.proxy',str(root)).replace('/Library/LaunchDaemons/cn.qingzhou.proxy.helper.plist',str(plist)).replace('/Library/PrivilegedHelperTools/qingzhou-install.',str(stage/'install.')).replace('/Library/PrivilegedHelperTools/qingzhou-recovery.',str(stage/'recovery.')).replace('/bin/launchctl',str(mock)).replace('/usr/bin/codesign',str(signer)).replace("'/usr/bin/codesign'",repr(str(signer))).replace('/usr/bin/install',str(installer)).replace('for attempt in {1..50}', 'for attempt in {1..2}')
    def run(name,**options):
        target=stage/name;target.write_text(transform(name))
        recovery=resources/'recover-helper.sh';recovery.write_text(transform('recover-helper.sh'));recovery.chmod(0o755)
        env=dict(os.environ,SUDO_UID='501',TEST_ROOT=str(root),TEST_LOG=str(log),**options)
        return subprocess.run(['/bin/bash',str(target),str(app)],env=env,capture_output=True,text=True)
    def reset():
        import shutil
        if root.exists():shutil.rmtree(root)
        root.mkdir()
        if plist.exists():plist.unlink()
        log.write_text('')
    def passed(name):
        global scenarios
        scenarios+=1;print('PASS HelperScripts.'+name)
    valid_requirement='identifier "cn.qingzhou.proxy" and anchor apple generic and certificate leaf[subject.OU] = "TESTTEAM01"'
    for requirement in [valid_requirement,valid_requirement.replace('"TESTTEAM01"','TESTTEAM01')]:
        reset();result=run('install-helper.sh',TEST_SIGNED='1',TEST_REQUIREMENT=requirement)
        assert result.returncode==0,(result.stdout,result.stderr)
        assert json.loads((root/'manifest.json').read_text())['clientRequirement']==requirement
        passed('signedIdentityPinsFullRequirement')
    for requirement in ['identifier "cn.qingzhou.proxy"',valid_requirement.replace('TESTTEAM01','OTHERTEAM'),valid_requirement.replace('cn.qingzhou.proxy','foreign.app')]:
        reset();result=run('install-helper.sh',TEST_SIGNED='1',TEST_REQUIREMENT=requirement)
        assert result.returncode!=0 and not (root/'manifest.json').exists()
        passed('rejectsIncompleteSigningIdentity')
    reset();(root/'recovery.json').write_text('{}');(root/'QingzhouHelper').write_text('old')
    result=run('install-helper.sh');assert result.returncode!=0 and log.read_text()=='' and (root/'QingzhouHelper').read_text()=='old';passed('pendingRecoveryKeepsService')
    reset();result=run('install-helper.sh',TEST_BOOTSTRAP_FAIL='1');assert result.returncode!=0 and not plist.exists() and not (root/'manifest.json').exists() and not (root/'QingzhouHelper').exists();passed('firstInstallFailureRemovesOwnedFiles')
    reset();plist.write_text('old-plist')
    for name in ['QingzhouHelper','sing-box','manifest.json']:(root/name).write_text('old-'+name)
    result=run('install-helper.sh',TEST_BOOTSTRAP_FAIL='1');assert result.returncode!=0 and plist.read_text()=='old-plist' and (root/'QingzhouHelper').read_text()=='old-QingzhouHelper';passed('upgradeFailureRestoresComponents')
    reset();result=run('install-helper.sh');assert result.returncode==0 and (root/'control.sock').exists() and json.loads((root/'manifest.json').read_text())['version']=='0.7.0';passed('successRequiresControlSocket')
    reset();plist.write_text('old-plist');(root/'recovery.json').write_text('{}')
    result=run('recover-helper.sh');assert result.returncode!=0 and log.read_text().splitlines()==['bootout'] and (root/'recovery.json').exists();passed('unresolvedRecoveryDoesNotRestartStrictOldService')
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
    for disabled in ['0','1']:
        reset();plist.write_text('old-plist');(root/'QingzhouHelper').write_text('old')
        result=run('install-helper.sh',TEST_LOADED='0',TEST_DISABLED=disabled)
        assert result.returncode==0,(result.stdout,result.stderr)
        assert log.read_text().splitlines()==(['enable','bootstrap'] if disabled=='1' else ['bootstrap'])
        passed('unloadedServiceInstallDisabled'+disabled)
    reset();plist.write_text('old-plist');(root/'QingzhouHelper').write_text('old')
    result=run('install-helper.sh',TEST_LOADED='0',TEST_DISABLED='1',TEST_BOOTSTRAP_FAIL='1')
    assert result.returncode!=0 and (root/'QingzhouHelper').read_text()=='old' and plist.read_text()=='old-plist'
    assert log.read_text().splitlines()==['enable','bootstrap','bootout','disable'] and not (root/'test-enabled').exists()
    passed('failedDisabledInstallRestoresDisabledState')
    reset();plist.write_text('old-plist');(root/'QingzhouHelper').write_text('old')
    result=run('install-helper.sh',TEST_LOADED='0',TEST_DISABLED='1',TEST_ENABLE_FAIL='1')
    assert result.returncode!=0 and (root/'QingzhouHelper').read_text()=='old' and not (root/'test-enabled').exists()
    assert log.read_text().splitlines()==['enable','bootout','disable']
    passed('enableFailureRestoresComponents')
    for flag in ['TEST_PRINT_FAIL','TEST_DISABLED_QUERY_FAIL']:
        reset();plist.write_text('old-plist');(root/'QingzhouHelper').write_text('old')
        result=run('install-helper.sh',**{flag:'1'})
        assert result.returncode!=0 and log.read_text()=='' and (root/'QingzhouHelper').read_text()=='old'
        assert not list(stage.glob('install.*'))
        passed('statusFailureAborts'+flag)
    reset();plist.write_text('old-plist');(root/'QingzhouHelper').write_text('old')
    result=run('install-helper.sh',TEST_BOOTOUT_FAIL='1')
    assert result.returncode!=0 and log.read_text().splitlines()==['bootout'] and (root/'QingzhouHelper').read_text()=='old'
    passed('loadedBootoutFailureDoesNotOverwrite')
    reset();plist.write_text('old-plist')
    result=run('install-helper.sh',TEST_BOOTOUT_FAIL='1',TEST_STOP_RACE='1')
    assert result.returncode==0 and log.read_text().splitlines()==['bootout','bootstrap']
    passed('confirmedConcurrentExitAllowsInstall')
    reset();plist.write_text('old-plist');(root/'QingzhouHelper').write_text('old')
    result=run('install-helper.sh',TEST_DISABLED='1',TEST_BOOTSTRAP_FAIL_ONCE='1')
    assert result.returncode!=0 and (root/'QingzhouHelper').read_text()=='old'
    assert log.read_text().splitlines()==['bootout','enable','bootstrap','bootout','enable','bootstrap','disable']
    assert (root/'test-launch-state').exists() and not (root/'test-enabled').exists()
    passed('loadedDisabledRollbackRestoresBothStates')
    # 新版恢复器独立于旧客户端身份，失败保留记录，成功后再安装新组件。
    helper=resources/'QingzhouHelper'
    helper.write_text('#!/bin/bash\nset -e\nprintf "%s\\n" "$*" >> "$TEST_ROOT/recovery.calls"\nif [ "${TEST_RECOVER_FAIL:-0}" = 1 ]; then exit 9; fi\nif [ "${TEST_RECOVER_CLEAR:-0}" = 1 ]; then /bin/rm -f "$TEST_ROOT/recovery.json"; fi\n')
    helper.chmod(0o755)
    reset();plist.write_text('old-plist');(root/'recovery.json').write_text('{"intent":"old"}');(root/'QingzhouHelper').write_text('old-helper')
    result=run('install-helper.sh',TEST_RECOVER_CLEAR='1')
    assert result.returncode==0,(result.stdout,result.stderr)
    assert not (root/'recovery.json').exists() and log.read_text().splitlines()==['bootout','bootstrap']
    assert (root/'recovery.calls').read_text().strip()=='--recover-preserving-external'
    assert any((p/'recovery.json').read_text()=='{"intent":"old"}' for p in stage.glob('recovery.*') if (p/'recovery.json').exists())
    passed('pendingRecoveryUsesNewHelperThenInstalls')
    reset();plist.write_text('old-plist');(root/'recovery.json').write_text('{"intent":"retained"}');(root/'QingzhouHelper').write_text('old-helper')
    result=run('install-helper.sh',TEST_RECOVER_FAIL='1')
    assert result.returncode!=0 and (root/'QingzhouHelper').read_text()=='old-helper'
    assert (root/'recovery.json').read_text()=='{"intent":"retained"}' and log.read_text().splitlines()==['bootout']
    passed('failedNewRecoveryRetainsOldComponentsAndIntent')
    result=run('install-helper.sh',TEST_RECOVER_CLEAR='1')
    assert result.returncode==0,(result.stdout,result.stderr)
    assert log.read_text().splitlines()==['bootout','bootstrap']
    passed('retryAfterStoppedRecoveryCanComplete')
    reset();plist.write_text('old-plist');(root/'recovery.json').write_text('{}')
    result=run('recover-helper.sh',TEST_RECOVER_CLEAR='1')
    assert result.returncode==0 and log.read_text().splitlines()==['bootout','bootstrap']
    passed('standaloneSafeRecoveryRestartsAfterRelease')
print('RESULT helper_script_scenarios='+str(scenarios)+' failures=0')
