#!/usr/bin/env python3
"""隔离编译协调器和所有权索引的定向变异；编译失败及超时不计检出。"""
from pathlib import Path
import json
import subprocess

root=Path(__file__).resolve().parents[1]
stage=root/'.build/wake-recovery-mutations'
stage.mkdir(parents=True,exist_ok=True)
coordinator=(root/'Sources/QingzhouKit/WakeRecoveryCoordinator.swift').read_text()
identity=(root/'Sources/QingzhouKit/RouteIdentityIndex.swift').read_text()
native=(root/'Sources/CQingzhouRoute/QingzhouRoute.c').read_text()
checks=root/'scripts/wake-recovery-checks.swift'
mutations=[
    ('删除父项误用 HOST','native','host_override!=0','1'),
    ('丢失原生链路缓存证据','native','link->sdl_alen==6 && offset+6<=gateway->sa_len','0'),
    ('单次失败即重建','coordinator','if failures>=2 {','if failures>=1 {'),
    ('超出三次重建上限','coordinator','guard attempt<3 else','guard attempt<4 else'),
    ('取消稳定等待','coordinator','try await self.sleep(stableDelay)','try await self.sleep(0)'),
    ('错误重建退避','coordinator','[1.0,3,10][attempt]','[0.0,0,0][attempt]'),
    ('未知节点误报恢复','coordinator','if unknown>=2 {publish(WakeRecoveryStatus(.manual,attempt:attempt,reason:reason));return}','if unknown>=2 {publish(WakeRecoveryStatus(.recovered,attempt:attempt,reason:reason));return}'),
    ('忽略连接代次','coordinator',' && isCurrent()',''),
    ('超时误判节点失效','coordinator','return .inconclusive(.unverified)}','return .failed(.nodeUnavailable)}'),
    ('忽略其他接口竞争','identity','$0.route.interface==expected.interface && $0.flags & UInt32(RTF_HOST|RTF_LLINFO|RTF_MULTICAST)','$0.flags & UInt32(RTF_HOST|RTF_LLINFO|RTF_MULTICAST)'),
    ('缓存例外扩展普通单播','identity','expected.destination=="239.255.255.250/32",let records','true,let records'),
    ('忽略父项克隆证据','identity','$0.flags & UInt32(RTF_MULTICAST|RTF_CLONING)==UInt32(RTF_MULTICAST|RTF_CLONING)','true'),
    ('丢失缓存链路地址约束','identity','cache.linkLayerAddress?.lowercased()=="1:0:5e:7f:ff:fa"','true'),
    ('忽略父网段竞争','identity','parents.count==1,let parent=parents.first','let parent=parents.first'),
    ('缺失父网段克隆标志','identity','parent.flags & parentFlags==parentFlags','true'),
]
objects=[]
for pattern in ['.build/debug/QingzhouKit.build/*.o','.build/debug/CQingzhouRoute.build/*.o','.build/debug/Yams.build/*.o','.build/debug/CYaml.build/src/*.o']:
    objects.extend(str(path) for path in root.glob(pattern))
results=[]
for index,item in enumerate([('baseline',None,None,None)]+mutations):
    name,target,before,after=item
    sources={'coordinator':coordinator,'identity':identity,'native':native}
    if target:
        if before not in sources[target]:raise RuntimeError('变异锚点失效：'+name)
        sources[target]=sources[target].replace(before,after,1)
    paths=[]
    for key,source in sources.items():
        if key=='native':continue
        path=stage/f'{index}-{key}.swift';path.write_text('import QingzhouKit\n'+source);paths.append(str(path))
    linked_objects=objects
    if target=='native':
        c_source=stage/f'{index}-native.c';c_source.write_text(sources['native'])
        c_object=stage/f'{index}-native.o'
        native_compile=subprocess.run(['xcrun','clang','-c','-I',str(root/'Sources/CQingzhouRoute/include'),str(c_source),'-o',str(c_object)],capture_output=True,text=True)
        (stage/f'compile-native-{index}.log').write_text(native_compile.stdout+native_compile.stderr)
        if native_compile.returncode:raise RuntimeError('原生变异编译失败，不计检出：'+name)
        linked_objects=[item for item in objects if not item.endswith('/QingzhouRoute.c.o')]+[str(c_object)]
    executable=stage/f'variant-{index}'
    command=['swiftc','-parse-as-library','-swift-version','5','-I',str(root/'.build/debug/Modules'),'-I',str(root/'Vendor/Yams/Sources/CYaml/include'),'-Xcc','-fmodule-map-file='+str(root/'.build/debug/CQingzhouRoute.build/module.modulemap'),'-module-cache-path',str(root/'.build/module-cache'),*paths,str(checks),*linked_objects,'-o',str(executable)]
    compiled=subprocess.run(command,cwd=root,capture_output=True,text=True)
    (stage/f'compile-{index}.log').write_text(compiled.stdout+compiled.stderr)
    if compiled.returncode:raise RuntimeError('变异编译失败，不计检出：'+name)
    try:run=subprocess.run([str(executable)],cwd=root,capture_output=True,text=True,timeout=20)
    except subprocess.TimeoutExpired:raise RuntimeError('变异超时，不计断言检出：'+name)
    (stage/f'run-{index}.log').write_text(run.stdout+run.stderr)
    if index==0 and run.returncode:raise RuntimeError('基准检查失败')
    if index:results.append({'name':name,'compiled':True,'detected':run.returncode!=0})
report={'mutants':len(results),'detected':sum(x['detected'] for x in results),'results':results,'scope':'定向协调器和路由分类变异，不等于全项目 PIT'}
(stage/'report.json').write_text(json.dumps(report,ensure_ascii=False,indent=2))
print(json.dumps(report,ensure_ascii=False))
if report['mutants']!=report['detected']:raise SystemExit(1)
