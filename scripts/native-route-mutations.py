#!/usr/bin/env python3
"""原生路由与捕获差集的定向变异，不能当作 PIT 或全量变异覆盖率。"""
import json
import pathlib
import shutil
import subprocess

root = pathlib.Path(__file__).resolve().parent.parent
stage = root / '.build/native-mutations'
stage.mkdir(parents=True, exist_ok=True)
for folder in ('Sources', 'scripts'):
    shutil.copytree(root / folder, stage / folder, dirs_exist_ok=True)
shutil.copy2(root / 'Package.swift', stage / 'Package.swift')
for name in ('Vendor', 'Resources'):
    if not (stage / name).exists():
        (stage / name).symlink_to(root / name, target_is_directory=True)


def run(name):
    path = stage / (name + '.log')
    with path.open('wb') as log:
        code = subprocess.run(['bash', 'scripts/native-route-checks.sh'], cwd=stage,
                              stdout=log, stderr=log, timeout=240).returncode
    return code, path.read_text(errors='replace')


if run('baseline')[0]:
    raise SystemExit('原生路由变异基线未通过')
mutations = [
    ('错误拒绝无作用域链路查询', 'CQingzhouRoute/QingzhouRoute.c', 'index,operation==RTM_GET,address,&n)', 'index,0,address,&n)'),
    ('链路本地纳入全局出口', 'QingzhouKit/BypassRoutePlan.swift', 'route.scope==route.interface,let prefix=IPPrefix(route.destination)', 'let prefix=IPPrefix(route.destination)'),
    ('保留冗余链路缓存', 'QingzhouKit/BypassRoutePlan.swift', 'if !covered && !preserved.contains(route)', 'if !preserved.contains(route)'),
    ('扩大链路排除至整个范围', 'QingzhouKit/CaptureRoutePlan.swift', 'excluded += bypass.preservedRoutes.map(\\.destination)', 'excluded += bypass.preservedRoutes.map{_ in "fe80::/10"}'),
    ('忽略 PID', 'CQingzhouRoute/QingzhouRoute.c', 'if(h.rtm_pid!=pid || h.rtm_seq!=sequence)', 'if(h.rtm_seq!=sequence)'),
    ('忽略序列', 'CQingzhouRoute/QingzhouRoute.c', 'if(h.rtm_pid!=pid || h.rtm_seq!=sequence)', 'if(h.rtm_pid!=pid)'),
    ('接受非连续掩码', 'CQingzhouRoute/QingzhouRoute.c', 'if (zero) return EPROTO;', ''),
    ('忽略内核拒绝', 'QingzhouKit/RouteBackend.swift', 'return result.kernelError==0 ? .applied:.rejected(result.kernelError)', 'return .applied'),
    ('未知响应冒充确定失败', 'QingzhouKit/RouteBackend.swift', 'outcomeUnknown:operation != RTM_GET', 'outcomeUnknown:false'),
    ('遗漏排除终点', 'QingzhouKit/CaptureRoutePlan.swift', 'if terminal{return}', 'if false{return}'),
    ('颠倒前缀包含', 'QingzhouKit/CaptureRoutePlan.swift', 'bits<=other.bits', 'bits>=other.bits'),
    ('预算回退仍声称排除', 'QingzhouKit/CaptureRoutePlan.swift', 'prefixes=Self.legacyPrefixes;self.exclusions=[];', 'prefixes=Self.legacyPrefixes;self.exclusions=normalized.map(\\.text);'),
    ('歧义出口取首项', 'QingzhouKit/CaptureRoutePlan.swift', 'guard longest.count==1,let route=longest.first', 'guard let route=longest.first'),
    ('作用域路径伪装全局', 'QingzhouKit/CaptureRoutePlan.swift', '$0.scope==nil && IPPrefix($0.destination)?.contains(prefix)==true', 'IPPrefix($0.destination)?.contains(prefix)==true'),
]
results = []
for index, (name, relative, old, new) in enumerate(mutations):
    path = stage / 'Sources' / relative
    original = path.read_text()
    if old not in original:
        raise SystemExit('缺少变异点：' + name)
    path.write_text(original.replace(old, new))
    try:
        code, log = run(str(index))
        status = 'BUILD_ERROR' if 'error:' in log and 'fatal error:' not in log.lower() else ('KILLED' if code else 'SURVIVED')
        results.append({'name': name, 'status': status})
        print(status, name, flush=True)
    finally:
        path.write_text(original)
report = {'scope': str(len(mutations)) + ' 个定向变异；非 PIT，非全项目指标', 'results': results}
(root / '.build/native-mutation-results.json').write_text(json.dumps(report, ensure_ascii=False, indent=2))
raise SystemExit(0 if all(item['status'] == 'KILLED' for item in results) else 1)
