from pathlib import Path
import json,shutil,subprocess
ROOT=Path(__file__).resolve().parent.parent
stage=ROOT/'.build/dynamic-vpn-mutations'
stage.mkdir(parents=True,exist_ok=True)
for name in ['Sources','scripts','Resources']:
    shutil.copytree(ROOT/name,stage/name,dirs_exist_ok=True)
shutil.copy2(ROOT/'Package.swift',stage/'Package.swift')
if not (stage/'Vendor').exists():(stage/'Vendor').symlink_to(ROOT/'Vendor',target_is_directory=True)
cases=[
 ('旧代次响应被接受','ScopedDNSForwarder.swift','return !stopped && (planGeneration==generation || (!wasProtected && !plan.protects(name)))','return !stopped'),
 ('暂停期间继续企业解析','ScopedDNSForwarder.swift','if suspended && plan.protects(name)','if false && plan.protects(name)'),
 ('取消一致采样等待','DynamicCaptureRules.swift','return now-since>=1','return now-since>=0'),
 ('忽略最长前缀分区','DynamicCaptureRules.swift','guard excluded.count>original.count,excluded.starts(with:original)','guard false,excluded.starts(with:original)'),
 ('保护域名落入公共解析','CapturePlan.swift','if domains.contains(where:{name==$0 || name.hasSuffix("."+$0)}) {return []}','if false {return []}')]
results=[]
for name,file,old,new in cases:
    target=stage/'Sources/QingzhouKit'/file
    original=(ROOT/'Sources/QingzhouKit'/file).read_text()
    assert old in original,(file,old)
    target.write_text(original.replace(old,new,1))
    log=stage/(str(len(results))+'.log')
    with log.open('w') as stream:
        build=subprocess.run([str(stage/'scripts/swift-local.sh'),'build','--product','QingzhouChecks'],cwd=stage,stdout=stream,stderr=subprocess.STDOUT)
        if build.returncode:status='BUILD_ERROR'
        else:
            check=subprocess.run([str(stage/'.build/debug/QingzhouChecks')],cwd=stage,stdout=stream,stderr=subprocess.STDOUT,timeout=90)
            status='KILLED' if check.returncode else 'SURVIVED'
    target.write_text(original)
    results.append({'name':name,'status':status});print(status,name,flush=True)
report={'scope':'五项定向变异，不等同于完整变异覆盖','results':results,'killed':sum(x['status']=='KILLED' for x in results)}
(stage/'results.json').write_text(json.dumps(report,ensure_ascii=False,indent=2))
raise SystemExit(0 if report['killed']==len(cases) else 1)
