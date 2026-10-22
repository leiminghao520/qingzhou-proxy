#!/usr/bin/env python3
import json,pathlib,shutil,subprocess,tempfile
root=pathlib.Path(__file__).resolve().parent.parent
stage=pathlib.Path(tempfile.mkdtemp(prefix='bypass-mutations-',dir=root/'.build'))
# 所有变异仅写入独立副本，避免覆盖用户的工作区或已有修改。
for name in ('Sources','Resources'):shutil.copytree(root/name,stage/name)
(stage/'scripts').mkdir()
shutil.copy2(root/'scripts/swift-local.sh',stage/'scripts/swift-local.sh')
shutil.copy2(root/'Package.swift',stage/'Package.swift')
(stage/'Vendor').symlink_to(root/'Vendor',target_is_directory=True)
mutations=[
 ('主机前缀被扩大','NetworkBypass.swift','(ipv6 ? 128:32)','(ipv6 ? 64:24)'),
 ('系统代理主机例外错误使用 CIDR','NetworkBypass.swift','parts.last==Substring(value.contains(":") ? "128":"32")','false'),
 ('精确域名错误覆盖子域','NetworkBypass.swift','kind == .domain ? .domain:.suffix','kind == .domain ? .suffix:.suffix'),
 ('重复项未拒绝','NetworkBypass.swift','guard seen.insert(item.kind.rawValue+":"+item.value).inserted else','guard true else'),
 ('迁移标识不稳定','NetworkBypass.swift','item.id=UUID(uuidString:uuid)!','item.id=UUID()'),
 ('绕过晚于普通规则','NetworkPolicy.swift','leading+bypassRules+prefix+ordered','leading+prefix+ordered+bypassRules')]
with (stage/'baseline-build.log').open('wb') as stream:
    baseline=subprocess.run([str(stage/'scripts/swift-local.sh'),'build','--product','QingzhouChecks'],cwd=stage,stdout=stream,stderr=stream)
if baseline.returncode:raise SystemExit('基线编译失败：'+str(stage/'baseline-build.log'))
results=[]
for name,file,old,new in mutations:
    path=stage/'Sources/QingzhouKit'/file
    original=(root/'Sources/QingzhouKit'/file).read_text()
    assert old in original,name
    path.write_text(original.replace(old,new))
    with (stage/'build.log').open('wb') as stream:
        build=subprocess.run([str(stage/'scripts/swift-local.sh'),'build','--product','QingzhouChecks'],cwd=stage,stdout=stream,stderr=stream)
    if build.returncode:status='BUILD_ERROR'
    else:
        with (stage/'test.log').open('wb') as stream:
            test=subprocess.run([str(stage/'.build/debug/QingzhouChecks'),'bypass-checks'],cwd=stage,stdout=stream,stderr=stream,timeout=60)
        status='KILLED' if test.returncode else 'SURVIVED'
    results.append({'name':name,'file':file,'status':status})
    print(status,name,flush=True)
    path.write_text(original)
summary={'scope':'六项定向变异；不等同于 PIT 或完整变异覆盖','killed':sum(item['status']=='KILLED' for item in results),'results':results,'stage':str(stage)}
print(json.dumps(summary,ensure_ascii=False,indent=2))
raise SystemExit(0 if summary['killed']==len(mutations) else 1)
