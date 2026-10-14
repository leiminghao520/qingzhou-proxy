#!/usr/bin/env python3
import json,pathlib,shutil,subprocess
root=pathlib.Path(__file__).resolve().parent.parent
stage=root/'.build/mutation-stage';stage.mkdir(parents=True,exist_ok=True)
shutil.copytree(root/'Sources',stage/'Sources',dirs_exist_ok=True)
shutil.copytree(root/'scripts',stage/'scripts',dirs_exist_ok=True)
shutil.copytree(root/'Resources',stage/'Resources',dirs_exist_ok=True)
shutil.copy2(root/'Package.swift',stage/'Package.swift')
if not (stage/'Vendor').exists():(stage/'Vendor').symlink_to(root/'Vendor',target_is_directory=True)
mutations=[
 ('未知参数放行','NodeParser.swift','guard allowed.contains(item.name) else','guard true else'),
 ('限制端口上界为65534','NodeParser.swift','(1...65535).contains(port)','(1...65534).contains(port)'),
 ('禁用订阅响应大小限制','ImportService.swift','if self.data.count + data.count > limit','if false'),
 ('失效默认策略改为直连','PolicyValidator.swift','state.ruleFinal = .reject','state.ruleFinal = .direct'),
 ('自动策略容差改为500','MultiConfigBuilder.swift','"tolerance":50','"tolerance":500'),
 ('自动策略间隔改为10分钟','MultiConfigBuilder.swift','"interval":"5m"','"interval":"10m"')]
results=[]
for name,file,old,new in mutations:
    path=stage/'Sources/QingzhouKit'/file;original=(root/'Sources/QingzhouKit'/file).read_text()
    if old not in original:raise SystemExit('变异位置未找到')
    path.write_text(original.replace(old,new))
    with (stage/'build.log').open('wb') as log:build=subprocess.run([str(stage/'scripts/swift-local.sh'),'build','--product','QingzhouChecks'],stdout=log,stderr=log)
    if build.returncode:status='BUILD_ERROR'
    else:
        with (stage/'test.log').open('wb') as log:test=subprocess.run([str(stage/'.build/debug/QingzhouChecks')],stdout=log,stderr=log,timeout=40)
        status='KILLED' if test.returncode else 'SURVIVED'
    results.append({'mutation':name,'file':file,'status':status});print(status,name,flush=True)
    path.write_text(original)
summary={'scope':'6 个定向变异，仅运行单元/下载检查；不代表全项目变异覆盖','results':results,'killed':sum(x['status']=='KILLED' for x in results),'survived':sum(x['status']=='SURVIVED' for x in results),'buildErrors':sum(x['status']=='BUILD_ERROR' for x in results)}
(root/'.build/mutation-results.json').write_text(json.dumps(summary,ensure_ascii=False,indent=2))
print('RESULT '+json.dumps({k:v for k,v in summary.items() if k!='results'},ensure_ascii=False))
