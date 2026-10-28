#!/usr/bin/env python3
"""串行对照原会话与临时默认核心，只导出计量，不改变应用配置。"""
import argparse
import copy
import datetime
import json
import re
import secrets
import socket
import subprocess
import tempfile
import time
import urllib.request
from pathlib import Path


def free_port():
    with socket.socket() as sock:
        sock.bind(('127.0.0.1', 0))
        return sock.getsockname()[1]


def api(context, path):
    request = urllib.request.Request('http://' + context['external_controller'] + path, headers={'Authorization': 'Bearer ' + context['secret']})
    with urllib.request.build_opener(urllib.request.ProxyHandler({})).open(request, timeout=2) as response:
        return json.load(response)


def actual(context):
    proxies = api(context, '/proxies')['proxies']
    tag = 'proxy'
    seen = set()
    while tag not in seen:
        seen.add(tag)
        next_tag = proxies.get(tag, {}).get('now')
        if not next_tag:
            return tag
        tag = next_tag
    raise RuntimeError('策略组存在循环')


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument('--directory', default=str(Path.home() / 'Library/Application Support/Qingzhou'))
    parser.add_argument('--core', default='/Applications/轻舟代理.app/Contents/Resources/sing-box')
    parser.add_argument('--app-asar', default='/Applications/ChatGPT.app/Contents/Resources/app.asar')
    parser.add_argument('--output', required=True)
    args = parser.parse_args()
    directory = Path(args.directory)
    state = json.loads((directory / 'state.json').read_text())
    profile = next(p['configuration'] for p in state['profiles'] if p['id'] == state['currentProfileID'])
    if profile['captureMode'] != 'systemProxy':
        raise SystemExit('仅在用户已连接的仅系统代理模式进行对照')
    paths = list(directory.glob('runtime-*.json'))
    if len(paths) != 1:
        raise SystemExit('当前运行配置不唯一')
    base = json.loads(paths[0].read_text())
    original = base['experimental']['clash_api']
    node = actual(original)
    if not node.startswith('node-'):
        raise SystemExit('实际策略没有选择单个代理节点')
    data = Path(args.app_asar).read_bytes()
    match = re.search(rb'n1l=`(client-[A-Za-z0-9]+)`', data)
    if not match:
        raise SystemExit('未找到本轮匿名请求所需的公开 SDK 标识')
    body = json.dumps({'user': {'userID': 'codex-network-diagnostic'}, 'statsigMetadata': {'sdkType': 'js-mono', 'sdkVersion': '3.0.0'}, 'hash': 'djb2'})
    rows = []
    generation = paths[0].name
    try:
        for cycle in range(1, 4):
            for label in ('original-before', 'independent-default', 'original-after'):
                if not paths[0].exists() or actual(original) != node:
                    raise RuntimeError('会话或实际节点变化，停止对照')
                process = None
                with tempfile.TemporaryDirectory(prefix='qingzhou-throughput-') as temp:
                    config = copy.deepcopy(base)
                    control = original
                    listen = profile['listenPort']
                    if label == 'independent-default':
                        listen = free_port()
                        control_port = free_port()
                        while control_port == listen:
                            control_port = free_port()
                        control = {'external_controller': '127.0.0.1:' + str(control_port), 'secret': secrets.token_hex(32)}
                        config['experimental']['clash_api'] = control
                        config['inbounds'] = [{'type': 'mixed', 'listen': '127.0.0.1', 'listen_port': listen}]
                        config['log'] = {'level': 'error'}
                        for outbound in config['outbounds']:
                            if outbound.get('tag') == 'proxy':
                                outbound['default'] = node
                        path = Path(temp) / 'runtime.json'
                        path.write_text(json.dumps(config)); path.chmod(0o600)
                        subprocess.run([args.core, 'check', '-c', str(path)], check=True, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
                        process = subprocess.Popen([args.core, 'run', '-c', str(path)], stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
                    try:
                        for _ in range(40):
                            try:
                                before = api(control, '/connections')['connections']
                                break
                            except Exception:
                                if process is None or process.poll() is not None:
                                    raise RuntimeError('核心控制通道不可用')
                                time.sleep(0.1)
                        else:
                            raise RuntimeError('临时核心启动超时')
                        old = {r['id'] for r in before}
                        curl_config = 'header = "statsig-api-key: ' + match.group(1).decode() + '"\n'
                        curl = subprocess.Popen(['curl', '--config', '-', '-sS', '--proxy', 'http://127.0.0.1:' + str(listen), '--noproxy', '', '--connect-timeout', '8', '--max-time', '25', '-H', 'Content-Type: application/json', '-H', 'Accept-Encoding: identity', '--data-binary', body, '-o', '/dev/null', '-w', '%{http_code} %{time_starttransfer} %{time_total} %{size_download}', 'https://ab.chatgpt.com/v1/initialize'], stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True)
                        curl.stdin.write(curl_config); curl.stdin.close(); curl.stdin = None
                        samples = []; new_ids = set(); started = time.monotonic()
                        while curl.poll() is None:
                            try:
                                connections = api(control, '/connections')['connections']
                                original_rows = connections if control is original else api(original, '/connections')['connections']
                                target = [r for r in connections if r['id'] not in old and r.get('metadata', {}).get('host') == 'ab.chatgpt.com']
                                new_ids.update(r['id'] for r in target)
                                samples.append({'seconds': round(time.monotonic() - started, 2), 'active': len(connections), 'new_target_connections': len(target), 'target_bytes': sum(r.get('download', 0) for r in target), 'background_bytes': sum(r.get('download', 0) for r in original_rows if r['id'] not in new_ids)})
                            except Exception:
                                samples.append({'seconds': round(time.monotonic() - started, 2), 'unavailable': True})
                            time.sleep(2)
                        output, _ = curl.communicate(timeout=3)
                        metrics = output.split()
                        time.sleep(2)
                        remaining = api(control, '/connections')['connections']
                        deltas = [max(0, b['background_bytes'] - a['background_bytes']) / max(0.001, b['seconds'] - a['seconds']) for a, b in zip(samples, samples[1:]) if 'background_bytes' in a and 'background_bytes' in b]
                        row = {'cycle': cycle, 'path': label, 'time': datetime.datetime.now(datetime.timezone(datetime.timedelta(hours=8))).isoformat(), 'exit': curl.returncode, 'http': int(metrics[0]), 'first_seconds': float(metrics[1]), 'seconds': float(metrics[2]), 'bytes': int(metrics[3]), 'complete': curl.returncode == 0 and int(metrics[0]) == 200, 'samples': samples, 'target_connections_remaining_after_2s': sum(r['id'] in new_ids for r in remaining), 'connection_attribution_ambiguous': any(s.get('new_target_connections', 0) > 1 for s in samples), 'background_peak_Bps': max(deltas, default=0)}
                        rows.append(row)
                        print(json.dumps({k: v for k, v in row.items() if k != 'samples'}), flush=True)
                    finally:
                        if curl is not None and curl.poll() is None:
                            curl.terminate(); curl.wait(timeout=3)
                        if process is not None:
                            process.terminate()
                            try:
                                process.wait(timeout=5)
                            except subprocess.TimeoutExpired:
                                process.kill(); process.wait()
                Path(args.output).write_text(json.dumps({'generation': generation, 'node': node, 'results': rows, 'scope': '匿名公网下载，目标正文可能变化；连接归因不唯一时单列'}, ensure_ascii=False, indent=2))
    finally:
        if rows:
            peaks = [r['background_peak_Bps'] for r in rows]
            median = sorted(peaks)[len(peaks) // 2]
            for row in rows:
                row['background_changed'] = row['background_peak_Bps'] > max(65536, median * 2)
            Path(args.output).write_text(json.dumps({'generation': generation, 'node': node, 'results': rows}, ensure_ascii=False, indent=2))


if __name__ == '__main__':
    main()
