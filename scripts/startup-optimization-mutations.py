#!/usr/bin/env python3
"""在隔离副本验证启动优化的关键约束，不代表全项目变异覆盖率。"""
import json
import pathlib
import shutil
import subprocess

root = pathlib.Path(__file__).resolve().parent.parent
stage = root / '.build/startup-mutations'
stage.mkdir(parents=True, exist_ok=True)
shutil.copytree(root / 'Sources', stage / 'Sources', dirs_exist_ok=True)
shutil.copytree(root / 'scripts', stage / 'scripts', dirs_exist_ok=True)
shutil.copy2(root / 'Package.swift', stage / 'Package.swift')
for name in ('Vendor', 'Resources'):
    if not (stage / name).exists():
        (stage / name).symlink_to(root / name, target_is_directory=True)


def run(command, log, timeout=180):
    with log.open('wb') as stream:
        return subprocess.run(command, cwd=stage, stdout=stream, stderr=stream,
                              timeout=timeout).returncode


build = ['bash', 'scripts/swift-local.sh', 'build', '--product', 'QingzhouChecks']
checks = [str(stage / '.build/debug/QingzhouChecks'), 'startup-checks']
if run(build, stage / 'baseline-build.log') or run(checks, stage / 'baseline-checks.log', 20):
    raise SystemExit('隔离基线未通过，不能计入变异结果')

mutations = [
    ('成功后仍等待另一目标', 'CoreAPIClient.swift', 'tasks.cancelAll(); return .success(delay)', 'return .success(delay)'),
    ('允许超过四个底层任务', 'NetworkPreparationPool.swift', 'min(4, concurrency)', 'min(8, concurrency + 1)'),
    ('节点域名不去重', 'NetworkPreparationPool.swift', 'Array(Set(hosts)).sorted()', 'hosts.sorted()'),
    ('忽略批次截止时间', 'NetworkPreparationPool.swift', 'if let deadline, now >= deadline', 'if let deadline, now < 0 && now >= deadline'),
    ('忽略单项截止时间', 'NetworkPreparationPool.swift', 'now - $0.value >= itemTimeout', 'now < 0 && now - $0.value >= itemTimeout'),
    ('失败计时被标为成功', 'ConnectionTiming.swift', 'succeeded: succeeded)', 'succeeded: true)'),
]
results = []
for index, (name, filename, old, new) in enumerate(mutations):
    path = stage / 'Sources/QingzhouKit' / filename
    original = (root / 'Sources/QingzhouKit' / filename).read_text()
    if old not in original:
        raise SystemExit('变异位置不存在：' + name)
    path.write_text(original.replace(old, new, 1))
    try:
        if run(build, stage / f'{index}-build.log'):
            status = 'BUILD_ERROR'
        else:
            try:
                status = 'KILLED' if run(checks, stage / f'{index}-checks.log', 20) else 'SURVIVED'
            except subprocess.TimeoutExpired:
                status = 'KILLED_TIMEOUT'
        results.append({'name': name, 'status': status})
        print(status, name, flush=True)
    finally:
        path.write_text(original)

report = {'scope': '6 个启动优化定向变异，不代表全项目指标', 'results': results,
          'killed': sum(item['status'].startswith('KILLED') for item in results),
          'survived': sum(item['status'] == 'SURVIVED' for item in results),
          'buildErrors': sum(item['status'] == 'BUILD_ERROR' for item in results)}
(root / '.build/startup-mutation-results.json').write_text(json.dumps(report, ensure_ascii=False, indent=2))
print('RESULT', json.dumps(report, ensure_ascii=False))
raise SystemExit(0 if report['killed'] == len(mutations) else 1)
