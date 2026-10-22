#!/usr/bin/env python3
# 仅在隔离源码副本运行三项定向变异，不启动管理员服务或真实 TUN。
from pathlib import Path
import shutil,subprocess,json,re
root=Path(__file__).resolve().parent.parent
stage=root/'.build/activation-mutations';stage.mkdir(exist_ok=True)
for name in ['Sources','scripts']:shutil.copytree(root/name,stage/name,dirs_exist_ok=True)
shutil.copy2(root/'Package.swift',stage/'Package.swift')
for name in ['Vendor','Resources']:
    if not (stage/name).exists():(stage/name).symlink_to(root/name,target_is_directory=True)
cases=[('遗漏捕获优先级保护','Sources/QingzhouKit/CaptureRoutePlan.swift','route.contains($0) && $0.bits>=route.bits','false','capture-precedence-checks.sh'),('重新放大企业公网主机','Sources/QingzhouKit/CaptureRoutePlan.swift','let protected=plan.protectedRoutes','excluded += plan.protectedRoutes.filter{$0.scope==nil && index.state($0) == .owned}.map(\\.destination)\n        let protected=plan.protectedRoutes','capture-precedence-checks.sh'),('忽略竞争接管','Sources/QingzhouHelper/RouteWriter.swift','if let tunnel=journal?.interface','if let tunnel=Optional<String>.none','protection-startup-checks.sh')]
results=[]
def run(script):
    return subprocess.run(['bash','scripts/'+script],cwd=stage,capture_output=True,text=True,timeout=180)
for script in set(item[-1] for item in cases):
    result=run(script)
    assert result.returncode==0,result.stderr[-2000:]
for name,relative,old,new,script in cases:
    path=stage/relative;original=path.read_text();assert old in original
    path.write_text(original.replace(old,new))
    try:
        result=run(script)
        compile_error=any(re.match(r'.+:\d+:\d+: error:',line) for line in result.stderr.splitlines())
        killed=result.returncode!=0 and not compile_error
        results.append({'name':name,'killed':killed,'exit':result.returncode})
        assert killed,result.stderr[-2000:]
    finally:path.write_text(original)
(root/'.build/activation-mutations.json').write_text(json.dumps({'scope':'三个定向变异，非 PIT','results':results},ensure_ascii=False,indent=2))
print('ACTIVATION_MUTATIONS_OK 3/3')
