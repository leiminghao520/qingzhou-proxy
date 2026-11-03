#!/usr/bin/env python3
"""使用实施前源码快照对照速率发布；不替代实网启动、恢复或十五分钟资源验收。"""
from pathlib import Path
import glob
import json
import subprocess
import tarfile
import tempfile

root = Path(__file__).resolve().parent.parent
stage = root / '.build/office-performance'
stage.mkdir(parents=True, exist_ok=True)
archive_path = root / '.build/office-baseline/source.tar.gz'
if not archive_path.exists():
    raise SystemExit('缺少实施前源码快照，不能使用 Git HEAD 冒充当前工作区基线')
with tarfile.open(archive_path) as archive:
    for member in archive.getmembers():
        if member.isfile() and member.name.startswith('Sources/Qingzhou/') and '..' not in Path(member.name).parts:
            destination = stage / 'baseline' / member.name
            destination.parent.mkdir(parents=True, exist_ok=True)
            destination.write_bytes(archive.extractfile(member).read())
objects = [item for pattern in ['QingzhouKit.build/*.o', 'CQingzhouRoute.build/*.o', 'Yams.build/*.o', 'CYaml.build/src/*.o']
           for item in glob.glob(str(root / '.build/debug' / pattern))]
results = {}
for label, folder in [('baseline', stage / 'baseline/Sources/Qingzhou'), ('candidate', root / 'Sources/Qingzhou')]:
    app = stage / (label + '-App.swift')
    app.write_text((folder / 'QingzhouApp.swift').read_text().replace('@main struct QingzhouApp', 'struct QingzhouApp', 1))
    sources = [str(p) for p in sorted(folder.glob('*.swift')) if p.name != 'QingzhouApp.swift']
    executable = stage / (label + '-benchmark')
    command = ['swiftc', '-parse-as-library', '-swift-version', '5', '-Onone', '-I', str(root / '.build/debug/Modules'),
               '-I', str(root / 'Vendor/Yams/Sources/CYaml/include'), '-Xcc',
               '-fmodule-map-file=' + str(root / '.build/debug/CQingzhouRoute.build/module.modulemap'),
               '-module-cache-path', str(root / '.build/module-cache'), *sources, str(app),
               str(root / 'scripts/office-publication-benchmark.swift'), *objects, '-o', str(executable)]
    with (stage / (label + '-build.log')).open('w') as log:
        subprocess.run(command, cwd=root, stdout=log, stderr=log, check=True)
    fixture = tempfile.mkdtemp(prefix='state-', dir=stage)
    output = stage / (label + '.json')
    with (stage / (label + '-run.log')).open('w') as log:
        subprocess.run([str(executable), '--test-directory', fixture, '--output', str(output)],
                       cwd=root, stdout=log, stderr=log, check=True, timeout=60)
    results[label] = json.loads(output.read_text())
results['limits'] = ['应用模型发布次数是隔离测量，未挂载真实页面', '基线与候选复用相同核心库对象，仅比较客户端速率发布',
                     '未测量实网启动及唤醒 p95', '未进行应用、核心与辅助服务合计十五分钟 CPU、内存、唤醒次数对照']
(stage / 'comparison.json').write_text(json.dumps(results, ensure_ascii=False, indent=2))
print('OFFICE_PUBLICATION_COMPARISON', results['baseline']['appModelPublications'], '->', results['candidate']['appModelPublications'])
