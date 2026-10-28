#!/usr/bin/env python3
"""只在构建目录变异吞吐探针；不覆盖工作区源码。"""
import argparse
import json
import subprocess
from pathlib import Path

root = Path(__file__).resolve().parents[1]
parser = argparse.ArgumentParser()
parser.add_argument('--output', default=str(root / '.build/throughput-mutations.json'))
args = parser.parse_args()
stage = root / '.build/throughput-mutations'
stage.mkdir(parents=True, exist_ok=True)
source = (root / 'Sources/QingzhouKit/ThroughputProbe.swift').read_text()
mutations = [
    ('把超时标为完成', 'self?.finish(.timedOut)', 'self?.finish(.completed)'),
    ('取消变成成功', 'public func cancel() { finish(.cancelled) }', 'public func cancel() { finish(.completed) }'),
    ('忽略 HTTP 错误状态', '!(200...299).contains(http.statusCode)', 'false'),
    ('移除声明大小上限', 'expected>byteLimit ? .sizeLimit : nil', 'false ? .sizeLimit : nil'),
    ('移除流式大小上限', 'exceeded=count>byteLimit', 'exceeded=false'),
    ('漏记下载字节', 'received+=Int64(data.count)', 'received+=0'),
    ('把截断标为成功', 'outcome = expected>=0 && received != expected ? .truncated : .completed', 'outcome = .completed'),
    ('失败也满足目标预算', 'outcome == .completed && receivedBytes > 0 && totalSeconds <= targetSeconds', 'totalSeconds <= targetSeconds'),
    ('转发重定向凭据', 'completionHandler(nil); finish(.httpError)', 'completionHandler(request); finish(.httpError)'),
    ('信任所有认证挑战', 'challenge.protectionSpace.authenticationMethod == NSURLAuthenticationMethodServerTrust ? .performDefaultHandling : .cancelAuthenticationChallenge', '.performDefaultHandling'),
]
objects = []
for pattern in ['QingzhouKit.build/*.o', 'CQingzhouRoute.build/*.o', 'Yams.build/*.o', 'CYaml.build/src/*.o']:
    objects += list((root / '.build/debug').glob(pattern))
base = ['swiftc', '-parse-as-library', '-swift-version', '5', '-I', '.build/debug/Modules', '-I', 'Vendor/Yams/Sources/CYaml/include', '-Xcc', '-fmodule-map-file=.build/debug/CQingzhouRoute.build/module.modulemap', '-module-cache-path', '.build/module-cache']
rows = []
for index, (name, old, new) in enumerate(mutations):
    if old not in source:
        raise SystemExit('找不到变异位置：' + name)
    path = stage / 'ThroughputProbe.swift'
    path.write_text(source.replace(old, new, 1))
    binary = stage / 'checks'
    command = base + [str(path), 'Sources/QingzhouChecks/ThroughputTests.swift', 'Sources/QingzhouChecks/Assertions.swift', '.build/throughput-checks/Bridge.swift', '.build/throughput-checks/Main.swift'] + [str(p) for p in objects] + ['-o', str(binary)]
    with (stage / ('build-' + str(index) + '.log')).open('w') as log:
        compiled = subprocess.run(command, cwd=root, stdout=log, stderr=log, timeout=90)
    if compiled.returncode:
        status = 'BUILD_ERROR'
    else:
        with (stage / ('run-' + str(index) + '.log')).open('w') as log:
            try:
                test = subprocess.run([str(binary)], cwd=root, stdout=log, stderr=log, timeout=8)
                status = 'KILLED' if test.returncode else 'SURVIVED'
            except subprocess.TimeoutExpired:
                status = 'TIMEOUT'
    rows.append({'mutation': name, 'status': status})
    print(status, name, flush=True)
summary = {'scope': '吞吐探针的 10 个定向变异；不代表全项目变异覆盖', 'results': rows, 'killed': sum(r['status'] == 'KILLED' for r in rows), 'total': len(rows)}
Path(args.output).write_text(json.dumps(summary, ensure_ascii=False, indent=2))
if summary['killed'] / summary['total'] < 0.8 or any(r['status'] != 'KILLED' for r in rows):
    raise SystemExit(1)
