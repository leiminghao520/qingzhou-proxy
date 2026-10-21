#!/usr/bin/env python3
"""在源码副本中运行定向变异，不修改正在使用的应用或服务。"""
from pathlib import Path
import json,subprocess,shutil,sys
root=Path(__file__).resolve().parents[1]
python_mutants=[
 ('所有者权限失效','client_api.py',"if owner and row['role'] != 'owner': abort(403)","if False: abort(403)",'test_permissions_identity'),
 ('过期配对码放行','client_api.py','p.expires>?','?>=0','test_pairing_once'),
 ('配对码允许重用','client_api.py','DELETE FROM client_pairings WHERE digest=?','DELETE FROM client_pairings WHERE digest=? AND 0','test_pairing_once'),
 ('设备范围越界','client_api.py','WHERE user_id=? ORDER BY id','WHERE ? IS NOT NULL ORDER BY id','test_permissions_identity'),
 ('历史余量冒充当前余量','client_jobs.py',"'remaining_gb':p.get('RemainingAmount')","'remaining_gb':exact.get('RemainingAmount',{}).get('Value')",'test_cloud_current'),
 ('轻量套餐字节单位错误','client_jobs.py','value / 1073741824','value / 1000000000','test_lighthouse_bound_package'),
 ('轻量套餐误标共享','client_jobs.py',"'scope':'instance_package'","'scope':'shared_package'",'test_lighthouse_bound_package'),
 ('不清理过期备份','backup_job.py','keep=set(files[:7])','keep=set(files)','test_real_backup_roundtrip'),
 ('云密钥进入备份','backup_job.py',"if not l.strip().removeprefix('export ').split('=',1)[0].strip().startswith(('HY2_CLOUD_','TENCENTCLOUD_'))","if True",'test_real_backup_roundtrip'),
]
results=[]
if '--server' in sys.argv:
    keys=list((Path.home()/'Desktop').glob('*/singapore_vps.pem'))
    if len(keys)!=1:raise SystemExit('SSH_KEY_MATCH_NOT_UNIQUE')
    args=['ssh','-i',str(keys[0]),'-o','BatchMode=yes','-o','ConnectTimeout=10','-o','StrictHostKeyChecking=yes',
          '-o','UserKnownHostsFile=/Users/leiminghao/Documents/Codex/2026-10-12/new-chat/work/vps-known-hosts','ubuntu@43.163.70.144','/var/tmp/qz-client-test-venv/bin/python -']
    remote='''import json,pathlib,subprocess,py_compile,os
stage=pathlib.Path('/var/tmp/qingzhou-client-v1-isolated');os.chdir(stage)
os.environ['AGE_TEST_TOOLS']=str(stage/'test-tools')
results=[]
for name,file,old,new,test in MUTANTS:
    p=stage/file;original=p.read_text()
    if old not in original:raise SystemExit('变异位置不存在')
    try:
        p.write_text(original.replace(old,new,1));py_compile.compile(str(p),doraise=True)
        result=subprocess.run(['/var/tmp/qz-client-test-venv/bin/python','-m','pytest','-q','tests/test_client_api.py','-k',test],stdout=subprocess.PIPE,stderr=subprocess.STDOUT,timeout=90)
        state='KILLED' if result.returncode==1 else 'SURVIVED' if result.returncode==0 else 'ERROR'
        results.append({'mutation':name,'status':state})
    finally:p.write_text(original)
print(json.dumps(results,ensure_ascii=False))
'''.replace('MUTANTS',repr(python_mutants))
    run=subprocess.run(args,input=remote,text=True,capture_output=True,timeout=180)
    if run.returncode:raise SystemExit('服务端变异检查执行失败')
    results=json.loads(run.stdout)
else:
    stage=root/'.build/vps-mutation-stage';stage.mkdir(parents=True,exist_ok=True)
    shutil.copytree(root/'Sources',stage/'Sources',dirs_exist_ok=True)
    shutil.copytree(root/'scripts',stage/'scripts',dirs_exist_ok=True)
    shutil.copy2(root/'Package.swift',stage/'Package.swift')
    if not (stage/'Vendor').exists():(stage/'Vendor').symlink_to(root/'Vendor',target_is_directory=True)
    mutants=[
        ('跳过备份校验','VPSClient.swift','count==size,hasher.finalize().map({String(format:"%02x",$0)}).joined()==sha256','count==size'),
        ('未知服务端判为故障','VPSDiagnostics.swift','DiagnosticResult("服务端证据","未验证"','DiagnosticResult("服务端证据","失败"'),
        ('移除测速节点校验','VPSDiagnostics.swift','row.chains.contains(nodeTag)','true'),
        ('放行重定向','VPSClient.swift','completionHandler(nil)','completionHandler(request)'),
    ]
    for name,file,old,new in mutants:
        path=stage/'Sources/QingzhouKit'/file;original=(root/'Sources/QingzhouKit'/file).read_text()
        if old not in original:raise SystemExit('变异位置不存在')
        try:
            path.write_text(original.replace(old,new,1))
            with (stage/'build.log').open('wb') as log:
                build=subprocess.run([str(stage/'scripts/swift-local.sh'),'build','--product','QingzhouChecks'],stdout=log,stderr=log,timeout=180)
            if build.returncode:state='ERROR'
            else:
                with (stage/'test.log').open('wb') as log:
                    check=subprocess.run([str(stage/'.build/debug/QingzhouChecks'),'vps-checks'],cwd=stage,stdout=log,stderr=log,timeout=60)
                state='KILLED' if check.returncode==1 else 'SURVIVED' if check.returncode==0 else 'ERROR'
            results.append({'mutation':name,'status':state});print(state,name,flush=True)
        finally:path.write_text(original)
report={'scope':'联动关键边界的定向变异，不代表全部代码的变异覆盖','results':results,'killed':sum(r['status']=='KILLED' for r in results),'total':len(results)}
output=root/'.build'/('vps-server-mutations.json' if '--server' in sys.argv else 'vps-client-mutations.json')
output.write_text(json.dumps(report,ensure_ascii=False,indent=2));print(json.dumps(report,ensure_ascii=False))
if report['killed']!=report['total']:raise SystemExit(1)
