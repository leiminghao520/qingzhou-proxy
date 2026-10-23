#!/usr/bin/env python3
"""在隔离副本执行办公功能定向变异；不代表 PIT 或全项目变异覆盖率。"""
import json
from pathlib import Path
import shutil
import subprocess

root = Path(__file__).resolve().parent.parent
stage = root / '.build/office-mutations'
workspace = stage / 'workspace'
workspace.mkdir(parents=True, exist_ok=True)
shutil.copytree(root / 'Sources', workspace / 'Sources', dirs_exist_ok=True)
shutil.copy2(root / 'Package.swift', workspace / 'Package.swift')
for name in ['Vendor', 'Resources']:
    if not (workspace / name).exists():
        (workspace / name).symlink_to(root / name, target_is_directory=True)


def check(name):
    with (stage / (name + '-build.log')).open('w') as log:
        result = subprocess.run(['bash', str(root / 'scripts/swift-local.sh'), 'build',
                                 '--package-path', str(workspace), '--build-path', str(stage / 'build'),
                                 '--product', 'QingzhouChecks'], cwd=root, stdout=log, stderr=log,
                                timeout=180)
    if result.returncode:
        return 'build_failed'
    try:
        result = subprocess.run([str(stage / 'build/debug/QingzhouChecks'), 'office-checks'],
                                cwd=root, text=True, capture_output=True, timeout=45)
        (stage / (name + '-run.log')).write_text(result.stdout + result.stderr)
        if result.returncode == 0:
            return 'survived'
        return 'detected' if 'FAIL ' in result.stdout else 'crashed'
    except subprocess.TimeoutExpired:
        return 'timeout'


if check('baseline') != 'survived':
    raise SystemExit('OFFICE_MUTATION_BASELINE_FAILED')
mutations = [
    ('drop-saved-targets', 'Models.swift',
     'savedDiagnosticTargets=try c.decodeIfPresent([SavedDiagnosticTarget].self,forKey:.savedDiagnosticTargets)',
     'savedDiagnosticTargets=nil'),
    ('enable-template-autoconnect', 'OfficeModels.swift', 'state.autoConnect=false', 'state.autoConnect=true'),
    ('ignore-health-network-generation', 'OfficeModels.swift', 'context==value && !stale', '!stale'),
    ('allow-command-injection', 'DeveloperProxyAssistant.swift',
     'let normalized=try ProtectedDomainPolicy.normalize(domains)', 'let normalized=domains'),
    ('allow-duplicate-targets', 'OfficeModels.swift',
     r'Set(values.map(\.id)).count==values.count', 'true'),
    ('unbounded-probes', 'TargetDiagnosticService.swift', 'guard active<2 else', 'guard active<20 else'),
    ('ignore-probe-cancel', 'TargetDiagnosticService.swift',
     'onCancel:{self.finish(.failure(CancellationError()))}', 'onCancel:{}'),
    ('wrong-hidden-cadence', 'OfficeModels.swift', 'hidden ? 10:pageVisible ? 1:5', 'hidden ? 1:pageVisible ? 1:5'),
]
results = []
for name, filename, old, new in mutations:
    path = workspace / 'Sources/QingzhouKit' / filename
    original = path.read_text()
    if old not in original:
        raise SystemExit('MUTATION_TARGET_MISSING ' + name)
    try:
        path.write_text(original.replace(old, new, 1))
        result = check(name)
        results.append(dict(name=name, result=result))
        print(name, result, flush=True)
    finally:
        path.write_text(original)
(stage / 'results.json').write_text(json.dumps(results, indent=2))
print('OFFICE_TARGETED_MUTATIONS', sum(r['result'] == 'detected' for r in results), '/', len(results))
raise SystemExit(0 if all(r['result'] == 'detected' for r in results) else 1)
