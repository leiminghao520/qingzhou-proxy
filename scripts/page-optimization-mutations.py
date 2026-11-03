#!/usr/bin/env python3
# 定向故障变异只编译展示和草稿逻辑，不启动正式应用或连接辅助服务。
from pathlib import Path
import json, subprocess, time
root=Path(__file__).resolve().parent.parent
stage=root/'.build/page-optimization-mutations'
stage.mkdir(parents=True,exist_ok=True)
names=['ListProjection.swift','NodeListViewModel.swift','SessionDraftStore.swift']
sources={name:(root/'Sources/Qingzhou'/name).read_text() for name in names}
driver=(root/'scripts/page-optimization-checks.swift').read_text().split('        let parent=NSWindow(')[0]+'        print("LOGIC_CHECKS_OK")\n    }\n}\n'
(stage/'checks.swift').write_text(driver)
legacy=subprocess.check_output(['git','show','HEAD:Sources/Qingzhou/NodeListViewModel.swift'],cwd=root,text=True)
(stage/'legacy.swift').write_text(legacy.replace('NodeListViewModel','LegacyNodeListViewModel'))
mutations=[
 ('cache-miss','ListProjection.swift','if self.key==key,let value','if false,let value'),
 ('connection-prefix','ListProjection.swift','connections.filter {row in','Array(connections.prefix(1000)).filter {row in'),
 ('connection-protocol','ListProjection.swift','network=="全部" || row.metadata.network?.uppercased()==network','true'),
 ('page-limit-reset','ListProjection.swift','if oldValue != query {limit=1000}','if false {limit=1000}'),
 ('favorite-order','NodeListViewModel.swift','if fa != fb {return fa}','if fa != fb {return fb}'),
 ('profile-identity','NodeListViewModel.swift','Key(profile:profile,','Key(profile:nil,'),
 ('ignore-notes','NodeListViewModel.swift','notes:state.notes,','notes:[:],'),
 ('same-name-order','NodeListViewModel.swift','return a.id.uuidString<b.id.uuidString','return a.id.uuidString>b.id.uuidString'),
 ('port-dirty','SessionDraftStore.swift',' || port != basePort',''),
 ('leave-cancel','SessionDraftStore.swift','guard confirm(action) else{return false}','guard true else{return false}'),
 ('text-revision','SessionDraftStore.swift','self.revision=self.revision ?? revision','self.revision=revision'),
 ('bypass-conflict','SessionDraftStore.swift','if !dirty {discard()}','if true {discard()}'),
]
objects=[]
for pattern in ['QingzhouKit.build/*.o','CQingzhouRoute.build/*.o','Yams.build/*.o','CYaml.build/src/*.o']:
 objects+=list((root/'.build/debug').glob(pattern))
def run_case(label,changed=None):
 folder=stage/label;folder.mkdir(exist_ok=True)
 for name,text in sources.items():
  if changed and name==changed[0]:
   assert changed[1] in text,(label,changed[1]);text=text.replace(changed[1],changed[2],1)
  (folder/name).write_text(text)
 command=['swiftc','-parse-as-library','-swift-version','5','-I',str(root/'.build/debug/Modules'),'-I',str(root/'Vendor/Yams/Sources/CYaml/include'),'-Xcc','-fmodule-map-file='+str(root/'.build/debug/CQingzhouRoute.build/module.modulemap'),'-module-cache-path',str(root/'.build/module-cache')]+[str(folder/name) for name in names]+[str(stage/'legacy.swift'),str(stage/'checks.swift')]+list(map(str,objects))+['-o',str(folder/'checks')]
 build=subprocess.run(command,cwd=root,capture_output=True,text=True,timeout=90)
 (folder/'build.log').write_text(build.stdout+build.stderr)
 if build.returncode:return 'compile-error'
 result=subprocess.run([str(folder/'checks'),'--quick','--output',str(folder)],cwd=root,capture_output=True,text=True,timeout=60)
 (folder/'run.log').write_text(result.stdout+result.stderr)
 return 'passed' if result.returncode==0 else 'killed'
assert run_case('baseline')=='passed','逻辑基线未通过'
results=[]
for label,name,old,new in mutations:
 status=run_case(label,(name,old,new));results.append({'mutation':label,'status':status});print(label,status,flush=True)
killed=sum(x['status']=='killed' for x in results)
report={'mutations':results,'killed':killed,'total':len(results),'score':100*killed/len(results),'PIT':'not applicable to Swift; targeted checks only','changedSystemNetwork':False}
(stage/'report.json').write_text(json.dumps(report,ensure_ascii=False,indent=2))
print(json.dumps(report,ensure_ascii=False),flush=True)
if any(x['status']=='compile-error' for x in results) or report['score']<80:raise SystemExit(1)
