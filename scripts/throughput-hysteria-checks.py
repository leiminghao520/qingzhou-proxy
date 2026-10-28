#!/usr/bin/env python3
"""在临时目录运行本地 Hysteria2，验证下载、并发、取消及确定性丢包。"""
import argparse
import concurrent.futures
import http.server
import json
import select
import socket
import ssl
import subprocess
import tempfile
import threading
import time
from pathlib import Path


def port(kind=socket.SOCK_STREAM):
    with socket.socket(socket.AF_INET, kind) as sock:
        sock.bind(('127.0.0.1', 0))
        return sock.getsockname()[1]


class Origin(http.server.BaseHTTPRequestHandler):
    def do_GET(self):
        size = 5 * 1024 * 1024
        self.send_response(200)
        self.send_header('Content-Length', str(size))
        self.end_headers()
        try:
            for _ in range(size // 16384):
                self.wfile.write(b'x' * 16384)
                if self.path == '/slow':
                    time.sleep(0.01)
        except (BrokenPipeError, ConnectionResetError, ssl.SSLError):
            pass

    def log_message(self, *_):
        pass


class LossRelay:
    def __init__(self, target, drop_every):
        self.front = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
        self.front.bind(('127.0.0.1', 0))
        self.target = target
        self.drop_every = drop_every
        self.packets = self.dropped = 0
        self.running = True
        self.clients = {}
        self.thread = threading.Thread(target=self.run, daemon=True)
        self.thread.start()

    def forward(self, sock, data, addr):
        self.packets += 1
        if self.drop_every and self.packets % self.drop_every == 0:
            self.dropped += 1
        else:
            sock.sendto(data, addr)

    def run(self):
        while self.running:
            ready, _, _ = select.select([self.front] + list(self.clients.values()), [], [], 0.1)
            for sock in ready:
                data, addr = sock.recvfrom(65535)
                if sock is self.front:
                    if addr not in self.clients:
                        upstream = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
                        upstream.bind(('127.0.0.1', 0))
                        self.clients[addr] = upstream
                    self.forward(self.clients[addr], data, self.target)
                else:
                    client = next(k for k, v in self.clients.items() if v is sock)
                    self.forward(self.front, data, client)

    def close(self):
        self.running = False
        self.thread.join(timeout=2)
        self.front.close()
        for sock in self.clients.values():
            sock.close()


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument('--core', default='/Applications/轻舟代理.app/Contents/Resources/sing-box')
    parser.add_argument('--output', required=True)
    args = parser.parse_args()
    rows = []
    with tempfile.TemporaryDirectory(prefix='qingzhou-local-hy2-') as directory:
        root = Path(directory)
        key, cert = root / 'key.pem', root / 'cert.pem'
        subprocess.run(['openssl', 'req', '-x509', '-newkey', 'rsa:2048', '-nodes', '-keyout', str(key), '-out', str(cert), '-days', '1', '-subj', '/CN=localhost', '-addext', 'subjectAltName=DNS:localhost,IP:127.0.0.1'], check=True, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
        origin = http.server.ThreadingHTTPServer(('127.0.0.1', 0), Origin)
        tls = ssl.SSLContext(ssl.PROTOCOL_TLS_SERVER)
        tls.load_cert_chain(cert, key)
        origin.socket = tls.wrap_socket(origin.socket, server_side=True)
        threading.Thread(target=origin.serve_forever, daemon=True).start()
        server_port = port(socket.SOCK_DGRAM)
        server = {'log': {'level': 'error'}, 'inbounds': [{'type': 'hysteria2', 'listen': '127.0.0.1', 'listen_port': server_port, 'users': [{'name': 'fixture', 'password': 'synthetic-only'}], 'tls': {'enabled': True, 'certificate_path': str(cert), 'key_path': str(key)}}], 'outbounds': [{'type': 'direct', 'tag': 'direct'}]}
        server_file = root / 'server.json'
        server_file.write_text(json.dumps(server))
        processes = []
        try:
            for drop_every in (0, 50):
                relay = LossRelay(('127.0.0.1', server_port), drop_every)
                listen = port()
                client = {'log': {'level': 'error'}, 'inbounds': [{'type': 'mixed', 'listen': '127.0.0.1', 'listen_port': listen}], 'outbounds': [{'type': 'hysteria2', 'tag': 'proxy', 'server': '127.0.0.1', 'server_port': relay.front.getsockname()[1], 'password': 'synthetic-only', 'tls': {'enabled': True, 'server_name': 'localhost', 'certificate_path': str(cert)}}], 'route': {'final': 'proxy'}}
                client_file = root / ('client-' + str(drop_every) + '.json')
                client_file.write_text(json.dumps(client))
                try:
                    for path in ([server_file] if not processes else []) + [client_file]:
                        subprocess.run([args.core, 'check', '-c', str(path)], check=True, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
                        processes.append(subprocess.Popen([args.core, 'run', '-c', str(path)], stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL))
                    for _ in range(50):
                        try:
                            with socket.create_connection(('127.0.0.1', listen), timeout=0.1):
                                break
                        except OSError:
                            time.sleep(0.05)
                    def download(path='/file', timeout=25):
                        p = subprocess.run(['curl', '-sS', '--proxy', 'socks5h://127.0.0.1:' + str(listen), '--noproxy', '', '--cacert', str(cert), '--max-time', str(timeout), '-o', '/dev/null', '-w', '%{http_code} %{size_download} %{time_total}', 'https://localhost:' + str(origin.server_port) + path], capture_output=True, text=True, timeout=timeout + 3)
                        parts = p.stdout.split()
                        return {'exit': p.returncode, 'http': int(parts[0]), 'bytes': int(parts[1]), 'seconds': float(parts[2])}
                    single = download()
                    with concurrent.futures.ThreadPoolExecutor(max_workers=3) as pool:
                        parallel = list(pool.map(lambda _: download(), range(3)))
                    with concurrent.futures.ThreadPoolExecutor(max_workers=2) as pool:
                        cancelled = pool.submit(download, '/slow', 0.2)
                        survivor = pool.submit(download, '/slow', 25)
                        cancellation, surviving = cancelled.result(), survivor.result()
                    after = download()
                    good = [single] + parallel + [surviving, after]
                    passed = all(r['exit'] == 0 and r['http'] == 200 and r['bytes'] == 5 * 1024 * 1024 for r in good) and cancellation['exit'] == 28
                    row = {'drop_every_packet': drop_every, 'relay_packets': relay.packets, 'relay_dropped': relay.dropped, 'single': single, 'concurrent': parallel, 'cancelled': cancellation, 'survivor': surviving, 'after_cancel': after, 'passed': passed}
                    rows.append(row)
                    print(json.dumps(row), flush=True)
                finally:
                    relay.close()
                    if len(processes) > 1:
                        p = processes.pop()
                        p.terminate()
                        p.wait(timeout=5)
        finally:
            for p in processes:
                p.terminate()
                p.wait(timeout=5)
            origin.shutdown()
            origin.server_close()
    Path(args.output).write_text(json.dumps({'scope': '本地隔离链路；不是公网性能验收', 'results': rows}, ensure_ascii=False, indent=2))
    if not all(r['passed'] for r in rows):
        raise SystemExit(1)


if __name__ == '__main__':
    main()
