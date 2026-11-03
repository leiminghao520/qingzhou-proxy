#!/usr/bin/env python3
"""对实际事件过滤和接收逻辑做定向故障变异，编译失败不计入检出。"""
from pathlib import Path
import json
import subprocess

root = Path(__file__).resolve().parents[1]
stage = root / '.build/stability-event-mutations'
stage.mkdir(parents=True, exist_ok=True)
source = (root / 'Sources/QingzhouKit/RouteEventPump.swift').read_text()
checks = (root / 'scripts/stability-performance-checks.swift').read_text()
# 复用正式检查中的事件与套接字场景，只剥离本轮不变异的路由索引部分。
checks = checks[:checks.index('        let route=ProtectedRoute')]
checks = checks.replace('import QingzhouKit\n', '').replace('throw ProxyError("离线报文通道创建失败")', 'throw NSError(domain:"离线报文通道创建失败",code:1)') + '        print("EVENT_CHECKS_OK assertions=\\(assertions)")\n    }\n}\n'
(stage / 'Checks.swift').write_text(checks)
mutations = [
    ('纯查询继续触发检查', 'return packet[packet.startIndex + 3] != UInt8(RTM_GET) || packet.count < MemoryLayout<rt_msghdr>.size', 'return true'),
    ('真实变化被静默忽略', 'return packet[packet.startIndex + 3] != UInt8(RTM_GET) || packet.count < MemoryLayout<rt_msghdr>.size', 'return false'),
    ('接收风暴失去原有上限', 'for _ in 0..<64', 'for _ in 0..<6400'),
    ('取消前仍继续接收', 'guard !cancelled() else { return false }', 'guard true else { return false }'),
    ('取消后仍发布迟到检查', 'if changed && !cancelled()', 'if changed'),
    ('读取失败继续监听空转', 'observe(.receiveFailure); changed = true\n                return false', 'observe(.receiveFailure); changed = true\n                return true'),
    ('异常报文错误忽略', 'guard packet.count >= 4 else { return true }', 'guard packet.count >= 4 else { return false }'),
    ('每条报文都触发检查', 'if requiresCheck(packet) { changed = true }', 'if requiresCheck(packet) { changed = true; request() }'),
]
results = []
for ordinal, (name, before, after) in enumerate([('baseline', '', '')] + mutations):
    variant = stage / f'variant-{ordinal}.swift'
    executable = stage / f'variant-{ordinal}'
    if before and source.count(before) != 1:
        raise RuntimeError('变异锚点不唯一：' + name)
    variant.write_text(source.replace(before, after, 1) if before else source)
    compile_result = subprocess.run(['swiftc', '-parse-as-library', '-swift-version', '5', str(variant), str(stage / 'Checks.swift'), '-o', str(executable)], capture_output=True, text=True)
    (stage / f'compile-{ordinal}.log').write_text(compile_result.stdout + compile_result.stderr)
    if compile_result.returncode:
        raise RuntimeError('变异编译失败，不计为检出：' + name)
    try:
        run = subprocess.run([str(executable)], capture_output=True, text=True, timeout=10)
        passed = run.returncode == 0
        (stage / f'run-{ordinal}.log').write_text(run.stdout + run.stderr)
    except subprocess.TimeoutExpired:
        raise RuntimeError('变异运行超时，不计为断言检出：' + name)
    if ordinal == 0 and not passed:
        raise RuntimeError('基准事件检查失败')
    if ordinal:
        results.append({'name': name, 'detected': not passed, 'compilePassed': True})
summary = {'mutants': len(results), 'detected': sum(item['detected'] for item in results), 'results': results}
(stage / 'report.json').write_text(json.dumps(summary, ensure_ascii=False, indent=2))
print('STABILITY_EVENT_MUTATIONS', json.dumps(summary, ensure_ascii=False))
if summary['detected'] != summary['mutants']:
    raise SystemExit(1)
