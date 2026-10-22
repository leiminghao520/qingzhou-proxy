#!/usr/bin/env python3
"""在隔离副本执行定向变异；不运行只读诊断、真实辅助服务或内核写入夹具。"""
import json
import os
from pathlib import Path
import shutil
import signal
import subprocess

root = Path(__file__).resolve().parent.parent
stage = root / '.build/panic-fix-mutations'
stage.mkdir(parents=True, exist_ok=True)
for folder in ('Sources', 'scripts'):
    shutil.copytree(root / folder, stage / folder, dirs_exist_ok=True)
shutil.copy2(root / 'Package.swift', stage / 'Package.swift')
for name in ('Vendor', 'Resources'):
    if not (stage / name).exists():
        (stage / name).symlink_to(root / name, target_is_directory=True)


def run(script, name, timeout=180):
    with (stage / (name + '.log')).open('wb') as log:
        process = subprocess.Popen(['bash', 'scripts/' + script], cwd=stage,
                                   stdout=log, stderr=log, start_new_session=True)
        try:
            code = process.wait(timeout=timeout)
        except subprocess.TimeoutExpired:
            os.killpg(process.pid, signal.SIGKILL)
            process.wait()
            return 'TIMEOUT'
    content = (stage / (name + '.log')).read_text(errors='replace')
    if code == 0:
        return 'PASS'
    if 'error:' in content and 'Fatal error:' not in content and 'Assertion' not in content and 'AssertionError' not in content:
        return 'BUILD_ERROR'
    return 'FAILED'


mutations = [
    ('恢复 DNS 仍保留旧计划', 'QingzhouHelper/NetworkMonitor.swift', 'capturePlan=fresh;protectedQueriesSuspended=false;dnsForwarder?.updatePlan(fresh)', 'protectedQueriesSuspended=false;dnsForwarder?.updatePlan(fresh)', 'dynamic-vpn-offline.sh'),
    ('提交结果丢失', 'CQingzhouRoute/RouteTransport.c', '*submitted=1;if((size_t)n!=length)', '*submitted=0;if((size_t)n!=length)', 'route-transport-offline.sh'),
    ('短写继续确认', 'CQingzhouRoute/RouteTransport.c', 'if((size_t)n!=length)', 'if(0 && (size_t)n!=length)', 'route-transport-offline.sh'),
    ('取消后仍发送', 'CQingzhouRoute/RouteTransport.c', 'if(cancelled && cancelled(context))', 'if(0 && cancelled && cancelled(context))', 'route-transport-offline.sh'),
    ('错误序列当作确认', 'CQingzhouRoute/RouteTransport.c', 'h.rtm_pid!=pid || h.rtm_seq!=sequence', 'h.rtm_pid!=pid || (0 && h.rtm_seq!=sequence)', 'route-transport-offline.sh'),
    ('提交前绕过验证', 'CQingzhouRoute/RouteTransport.c', 'if(result)return result;', 'if(0 && result)return result;', 'route-transport-offline.sh'),
    ('迟到响应仍接收', 'CQingzhouRoute/RouteTransport.c', 'if(io->now(io->context)>=deadline)', 'if(0 && io->now(io->context)>=deadline)', 'route-transport-offline.sh'),
    ('重引入空 IFP 强制出口', 'CQingzhouRoute/QingzhouRoute.c', 'header.rtm_addrs|=RTA_GATEWAY;', 'header.rtm_addrs|=RTA_GATEWAY|RTA_IFP;', 'route-protocol-offline.sh'),
    ('全局路由误带接口作用域', 'CQingzhouRoute/QingzhouRoute.c', 'header.rtm_index=scoped ? index:0', 'header.rtm_index=index', 'route-protocol-offline.sh'),
    ('无作用域目标注入接口编号', 'CQingzhouRoute/QingzhouRoute.c', 'family,scoped ? index:0,operation==RTM_GET', 'family,index,operation==RTM_GET', 'route-protocol-offline.sh'),
    ('取消不能唤醒阻塞接收', 'QingzhouKit/HelperRequestChannel.swift', '_=shutdown(descriptor,SHUT_RDWR)', '_=descriptor', 'helper-channel-offline.sh'),
    ('写前审计失败仍操作', 'QingzhouKit/RouteAuditLog.swift', 'try record("begin")', 'try? record("begin")', 'helper-channel-offline.sh'),
    ('把未知写入记成失败', 'QingzhouKit/RouteAuditLog.swift', '? "unknown":', '? "failed":', 'helper-channel-offline.sh'),
]
for script in sorted({item[-1] for item in mutations}):
    result = run(script, 'baseline-' + script)
    if result != 'PASS':
        raise SystemExit('变异基线未通过：' + script + ':' + result)
results = []
for i, (name, relative, old, new, script) in enumerate(mutations):
    path = stage / 'Sources' / relative
    original = path.read_text()
    assert old in original, '变异点不存在：' + name
    path.write_text(original.replace(old, new))
    try:
        result = run(script, str(i), timeout=30)
        status = 'KILLED' if result in ('FAILED', 'TIMEOUT') else ('SURVIVED' if result == 'PASS' else result)
        results.append({'name': name, 'status': status, 'evidence': result})
        print(status, name, flush=True)
    finally:
        path.write_text(original)
(root / '.build/panic-fix-mutation-results.json').write_text(json.dumps({'scope': '13 个定向变异；非 PIT 或全量指标', 'results': results}, ensure_ascii=False, indent=2))
raise SystemExit(0 if all(item['status'] == 'KILLED' for item in results) else 1)
