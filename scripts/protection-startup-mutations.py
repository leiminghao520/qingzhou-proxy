#!/usr/bin/env python3
"""对路由保护、取消和进度协议执行定向变异；结果不代表全项目指标。"""
import json
import pathlib
import shutil
import subprocess

root = pathlib.Path(__file__).resolve().parent.parent
stage = root / '.build/protection-mutations'
stage.mkdir(parents=True, exist_ok=True)
for folder in ('Sources', 'scripts'):
    shutil.copytree(root / folder, stage / folder, dirs_exist_ok=True)
shutil.copy2(root / 'Package.swift', stage / 'Package.swift')
for name in ('Vendor', 'Resources'):
    if not (stage / name).exists():
        (stage / name).symlink_to(root / name, target_is_directory=True)


def run(name):
    with (stage / (name + '.log')).open('wb') as log:
        return subprocess.run(['bash', 'scripts/protection-startup-checks.sh'], cwd=stage,
                              stdout=log, stderr=log, timeout=180).returncode


if run('baseline'):
    raise SystemExit('变异基线未通过')
mutations = [
    ('忽略网关', 'QingzhouKit/RouteIdentityIndex.swift', '$0.gateway==expected.gateway && $0.interface==expected.interface', '$0.interface==expected.interface'),
    ('忽略作用域', 'QingzhouKit/RouteIdentityIndex.swift', '.filter{$0.scope==expected.scope}', '.filter{_ in true}'),
    ('最终核验使用过期基线', 'QingzhouKit/RouteIdentityIndex.swift', 'let final=RouteIdentityIndex(try read().ownershipRoutes)', 'let final=RouteIdentityIndex(baseline.ownershipRoutes)'),
    ('遗漏全局保护核验', 'QingzhouKit/RouteIdentityIndex.swift', 'if route.scope != nil {', 'if false {'),
    ('忽略取消', 'QingzhouKit/RouteIdentityIndex.swift', 'try check()', '()'),
    ('路由写前不保存意图', 'QingzhouHelper/RouteWriter.swift', 'journal!.routes.append(route);try save()', 'journal!.routes.append(route)'),
    ('忽略内核拒绝', 'QingzhouHelper/RouteWriter.swift', 'guard !CaptureOwnership.routeWriteFailed(output)', 'guard true'),
    ('忽略写后核验', 'QingzhouHelper/RouteWriter.swift', 'guard try verifiedRoute(expected,info:current)', 'guard true'),
    ('把进度当作成功', 'QingzhouKit/HelperProgress.swift', 'while reply.isProgress==true {', 'while false {'),
    ('把失败指标标为成功', 'QingzhouKit/ConnectionTiming.swift', 'old.succeeded && succeeded', 'true'),
]
results = []
for index, (name, relative, old, new) in enumerate(mutations):
    path = stage / 'Sources' / relative
    original = path.read_text()
    if old not in original:
        raise SystemExit('缺少变异点：' + name)
    path.write_text(original.replace(old, new))
    try:
        code = run(str(index))
        log = (stage / (str(index) + '.log')).read_text(errors='replace')
        status = 'BUILD_ERROR' if 'error:' in log and 'fatal error:' not in log.lower() else ('KILLED' if code else 'SURVIVED')
        results.append({'name': name, 'status': status})
        print(status, name, flush=True)
    finally:
        path.write_text(original)
report = {'scope': '10 个定向变异，不代表全项目覆盖率或 PIT 指标', 'results': results}
(root / '.build/protection-mutation-results.json').write_text(json.dumps(report, ensure_ascii=False, indent=2))
raise SystemExit(0 if all(item['status'] == 'KILLED' for item in results) else 1)
