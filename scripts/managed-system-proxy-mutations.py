from pathlib import Path
import subprocess

# 对真实事务边界做定向变异，所有执行只使用内存网络夹具。
root=Path(__file__).resolve().parents[1]
source=(root/'Sources/QingzhouHelper/ManagedSystemProxy.swift').read_text()
mutations=[
 ('port','(1024...65535).contains(port)','true'),
 ('exceptionLimit','(request.proxyExceptions ?? []).count<=4096','true'),
 ('domainLimit','(request.proxyProtectedDomains ?? []).count<=4096','true'),
 ('entryLimit','$0.utf8.count<=512','true'),
 ('newline','!$0.contains(where:{$0.isNewline})','true'),
 ('ownership','journal==nil || (owner==fd && journal?.proxies?.isEmpty != false)','true'),
 ('durability',';try save()',''),
 ('activation','try verifyProxyActivation();',''),
 ('conflict','guard issues.isEmpty else','guard true else'),
 ('settling','try verifyNoOwnedProxyEndpoint(records);',''),
 ('release','journal=nil;phase="restored"','phase="restored"'),
 ('ownerRelease','defer{owner=nil;activeRequest=nil}','defer{activeRequest=nil}'),
]
objects=list((root/'.build/debug/QingzhouKit.build').glob('*.o'))+list((root/'.build/debug/CQingzhouRoute.build').glob('*.o'))+list((root/'.build/debug/Yams.build').glob('*.o'))+list((root/'.build/debug/CYaml.build/src').glob('*.o'))
killed=0
for name,old,new in mutations:
    assert old in source,name
    target=root/'.build/managed-mutant.swift';target.write_text(source.replace(old,new,1))
    binary=root/'.build/managed-mutant'
    command=['swiftc','-parse-as-library','-swift-version','5','-I','.build/debug/Modules','-I','Vendor/Yams/Sources/CYaml/include','-Xcc','-fmodule-map-file=.build/debug/CQingzhouRoute.build/module.modulemap','-module-cache-path','.build/module-cache',str(target),'Sources/QingzhouHelper/HelperJournal.swift','Sources/QingzhouHelper/HelperRecoveryRecords.swift','scripts/managed-system-proxy-checks.swift',*[str(p) for p in objects],'-o',str(binary)]
    built=subprocess.run(command,cwd=root,capture_output=True,text=True)
    if built.returncode:raise RuntimeError(name+': '+built.stderr)
    result=subprocess.run([str(binary)],cwd=root,capture_output=True,timeout=15)
    if result.returncode:killed+=1;print('KILLED',name,flush=True)
    else:print('SURVIVED',name,flush=True)
print(f'MANAGED_PROXY_MUTATIONS killed={killed} total={len(mutations)} score={killed/len(mutations):.0%}')
assert killed==len(mutations)
