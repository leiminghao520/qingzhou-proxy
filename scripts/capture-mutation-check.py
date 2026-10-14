#!/usr/bin/env python3
import json,pathlib,shutil,subprocess
root=pathlib.Path(__file__).resolve().parent.parent
stage=root/'.build/capture-mutations';stage.mkdir(parents=True,exist_ok=True)
for name in ['Sources','scripts']:shutil.copytree(root/name,stage/name,dirs_exist_ok=True)
shutil.copy2(root/'Package.swift',stage/'Package.swift')
if not (stage/'Vendor').exists():(stage/'Vendor').symlink_to(root/'Vendor',target_is_directory=True)
mutations=[
 ('不保留企业公网路由','CapturePlan.swift','Self.isVPN(route.interface) || Self.localCIDRs.contains','false || Self.localCIDRs.contains'),
 ('企业匹配域错误走物理解析器','CapturePlan.swift','if !matches.isEmpty {','if false {'),
 ('内网 NXDOMAIN 错误继续重试','ScopedDNSForwarder.swift','return code != 2 && code != 5','return code == 0'),
 ('接受不匹配的 DNS 事务','ScopedDNSForwarder.swift','response[0]==query[0],response[1]==query[1],',''),
 ('保护路由晚于普通分流','CaptureConfiguration.swift','leading+protected+rules','leading+rules+protected'),
 ('忽略代理绕过列表恢复冲突','ProxyRecovery.swift','keys+["ExceptionsList","ExcludeSimpleHostnames"]','keys')]
results=[]
for name,file,old,new in mutations:
 path=stage/'Sources/QingzhouKit'/file;original=(root/'Sources/QingzhouKit'/file).read_text()
 if old not in original:raise SystemExit('变异位置未找到: '+name)
 path.write_text(original.replace(old,new))
 with (stage/'build.log').open('wb') as log:build=subprocess.run([str(stage/'scripts/swift-local.sh'),'build','--product','QingzhouChecks'],stdout=log,stderr=log)
 if build.returncode:status='BUILD_ERROR'
 else:
  with (stage/'test.log').open('wb') as log:test=subprocess.run([str(stage/'.build/debug/QingzhouChecks')],cwd=stage,stdout=log,stderr=log,timeout=60)
  status='KILLED' if test.returncode else 'SURVIVED'
 results.append({'name':name,'file':file,'status':status});print(status,name,flush=True);path.write_text(original)
summary={'scope':'新增接管逻辑的六项定向变异；不是 PIT 或完整变异覆盖','results':results,'killed':sum(x['status']=='KILLED' for x in results),'build_errors':sum(x['status']=='BUILD_ERROR' for x in results)}
(root.parent/'capture-mutation-results.json').write_text(json.dumps(summary,ensure_ascii=False,indent=2));print(json.dumps(summary,ensure_ascii=False));raise SystemExit(0 if summary['killed']==len(mutations) else 1)
