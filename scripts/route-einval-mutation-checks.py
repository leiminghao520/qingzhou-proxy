#!/usr/bin/env python3
# 所有变异均在源码副本与禁止交换的模拟后端运行。
from pathlib import Path
import shutil,subprocess,json,re
root=Path(__file__).resolve().parent.parent
stage=root/'.build/route-einval-mutations';stage.mkdir(exist_ok=True)
for name in ['Sources','scripts']:shutil.copytree(root/name,stage/name,dirs_exist_ok=True)
shutil.copy2(root/'Package.swift',stage/'Package.swift')
for name in ['Vendor','Resources']:
    if not (stage/name).exists():(stage/name).symlink_to(root/name,target_is_directory=True)
plan=(stage/'Sources/QingzhouKit/CaptureRoutePlan.swift').read_text()
guard=next(line.strip() for line in plan.splitlines() if 'guard !prefixes.contains(where:' in line)
cases=[('恢复无作用域链路碎片','Sources/QingzhouKit/CaptureRoutePlan.swift','let protected=(plan.protectedRoutes','excluded += bypass.preservedRoutes.map(\\.destination)\n        let protected=(plan.protectedRoutes'),('整批预检未覆盖后续项','Sources/QingzhouKit/RouteBackend.swift','routes.enumerated()','routes.prefix(0).enumerated()'),('放行无法表达的全局前缀','Sources/QingzhouKit/CaptureRoutePlan.swift',guard,'guard true else {')]
def run():return subprocess.run(['bash','scripts/capture-codec-checks.sh'],cwd=stage,capture_output=True,text=True,timeout=180)
result=run();assert result.returncode==0,result.stderr[-1500:]
results=[]
for name,relative,old,new in cases:
    path=stage/relative;original=path.read_text();assert old in original;path.write_text(original.replace(old,new))
    try:
        result=run()
        compile_error=any(re.match(r'.+:\d+:\d+: error:',line) for line in result.stderr.splitlines())
        killed=result.returncode!=0 and not compile_error
        results.append({'mutation':name,'killed':killed,'exit':result.returncode});assert killed,result.stderr[-1500:]
    finally:path.write_text(original)
(root/'.build/route-einval-mutations.json').write_text(json.dumps({'scope':'3 项定向变异，非 PIT','results':results},ensure_ascii=False,indent=2))
print('ROUTE_EINVAL_MUTATIONS_OK 3/3')
