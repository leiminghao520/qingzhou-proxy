#!/usr/bin/env python3
import json,pathlib,shutil,subprocess
root=pathlib.Path(__file__).resolve().parent.parent
stage=root/'.build/enterprise-dns/mutations'
stage.mkdir(parents=True,exist_ok=True)
for folder in ['Sources','scripts']:
    shutil.copytree(root/folder,stage/folder,dirs_exist_ok=True)
for folder in ['Vendor','Resources']:
    if not (stage/folder).exists(): (stage/folder).symlink_to(root/folder,target_is_directory=True)
shutil.copy2(root/'Package.swift',stage/'Package.swift')
mutations=[
    ('歧义解析器任意选择','CapturePlan.swift','guard corporate.allSatisfy({$0.interface==first.interface && $0.servers==first.servers})','guard true'),
    ('错误选择最短域名','CapturePlan.swift','let longest=matches.map{length($0)}.max()!','let longest=matches.map{length($0)}.min()!'),
    ('忽略 SupplementalMatchOrders','CaptureDNSPolicy.swift','return orders.indices.contains(index) ? orders[index]:((settings["SearchOrder"] as? Int) ?? 200000)','return (settings["SearchOrder"] as? Int) ?? 200000'),
    ('写前不保存事务','DNSServiceTransaction.swift','        try persist()',''),
    ('恢复误删外部改写','DNSServiceTransaction.swift','guard current == (try decode(record.expected)) else','guard true else'),
    ('恢复遇独立冲突提前退出','DNSServiceTransaction.swift','issues.append("DNS 服务已有外部修改，保留当前值："+record.key);continue','issues.append("DNS 服务已有外部修改，保留当前值："+record.key);return issues'),
    ('省略写后核验','DNSServiceTransaction.swift','guard try read(record.key)==expected else {throw ProxyError("DNS 服务写后核验失败："+record.key)}',''),
    ('放行旧代次响应','ScopedDNSForwarder.swift','planGeneration==generation || (!wasProtected && !plan.protects(name))','true || (!wasProtected && !plan.protects(name))'),
    ('保护失败仍返回答案','ScopedDNSForwarder.swift','catch {report(.answerProtectionFailed,"答案保护",server,resolver.interface);return DNSPacket.failure(query)}','catch {report(.answerProtectionFailed,"答案保护",server,resolver.interface);return response}'),
    ('无 AAAA 记录误报失败','ScopedDNSForwarder.swift','addresses.isEmpty ? .noRecords:.answered','addresses.isEmpty ? .servfail:.answered'),
]
results=[]
for index,(name,file,old,new) in enumerate(mutations):
    path=stage/'Sources/QingzhouKit'/file
    original=(root/'Sources/QingzhouKit'/file).read_text()
    if old not in original: raise SystemExit('变异位置不存在：'+name)
    path.write_text(original.replace(old,new,1))
    try:
        with (stage/f'{index}-build.log').open('wb') as log:
            build=subprocess.run(['bash',str(stage/'scripts/swift-local.sh'),'build','--product','QingzhouChecks'],stdout=log,stderr=log)
        if build.returncode: status='BUILD_ERROR'
        else:
            with (stage/f'{index}-checks.log').open('wb') as log:
                check=subprocess.run([str(stage/'.build/debug/QingzhouChecks'),'corporate-dns-checks'],cwd=stage,stdout=log,stderr=log,timeout=30)
            status='KILLED' if check.returncode else 'SURVIVED'
        results.append({'name':name,'file':file,'status':status});print(status,name,flush=True)
    finally: path.write_text(original)
report={'scope':'解析器选择、响应及多服务事务边界的定向变异；Swift 不适用 PIT，不代表穷尽变异覆盖','results':results,'killed':sum(x['status']=='KILLED' for x in results),'total':len(results),'buildErrors':sum(x['status']=='BUILD_ERROR' for x in results)}
(stage.parent/'mutation-results.json').write_text(json.dumps(report,ensure_ascii=False,indent=2))
raise SystemExit(0 if report['killed']==report['total'] else 1)
