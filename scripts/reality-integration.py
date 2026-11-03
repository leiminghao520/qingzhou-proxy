#!/usr/bin/env python3
"""只使用回环端口、临时凭据和受控 TLS 目标验证 Reality/Vision。"""
import http.server
import json
import pathlib
import socket
import ssl
import subprocess
import tempfile
import threading
import time
import uuid

ROOT = pathlib.Path(__file__).resolve().parent.parent
CORE = ROOT / 'Vendor/sing-box'
CHECKS = ROOT / '.build/debug/QingzhouChecks'
RESULTS = []


def reserve():
    with socket.socket() as sock:
        sock.bind(('127.0.0.1', 0))
        return sock.getsockname()[1]


def write(path, value):
    path.write_text(value if isinstance(value, str) else json.dumps(value))
    path.chmod(0o600)


def stop(process):
    if process.poll() is None:
        process.terminate()
        try:
            process.wait(timeout=3)
        except subprocess.TimeoutExpired:
            process.kill()
            process.wait()


def ready(port, process):
    for _ in range(100):
        if process.poll() is not None:
            raise RuntimeError('受控核心提前退出')
        try:
            with socket.create_connection(('127.0.0.1', port), timeout=.1):
                return
        except OSError:
            time.sleep(.05)
    raise RuntimeError('受控端口未就绪')


class Origin(http.server.BaseHTTPRequestHandler):
    def do_GET(self):
        payload = b'QINGZHOU_REALITY_OK'
        self.send_response(200)
        self.send_header('Content-Length', str(len(payload)))
        self.end_headers()
        self.wfile.write(payload)

    def log_message(self, *_):
        pass


with tempfile.TemporaryDirectory(prefix='qingzhou-reality-') as temporary:
    directory = pathlib.Path(temporary)
    directory.chmod(0o700)
    cert, key = directory / 'cert.pem', directory / 'key.pem'
    subprocess.run(['openssl', 'req', '-x509', '-newkey', 'rsa:2048', '-nodes', '-keyout', str(key), '-out', str(cert), '-days', '1', '-subj', '/CN=localhost', '-addext', 'subjectAltName=DNS:localhost,IP:127.0.0.1'], stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL, check=True)
    key.chmod(0o600)
    origin = http.server.ThreadingHTTPServer(('127.0.0.1', 0), Origin)
    target = http.server.ThreadingHTTPServer(('127.0.0.1', 0), Origin)
    context = ssl.SSLContext(ssl.PROTOCOL_TLS_SERVER)
    context.minimum_version = ssl.TLSVersion.TLSv1_3
    context.load_cert_chain(cert, key)
    context.set_servername_callback(lambda _, name, __: None if name == 'localhost' else ssl.ALERT_DESCRIPTION_UNRECOGNIZED_NAME)
    target.socket = context.wrap_socket(target.socket, server_side=True)
    for service in [origin, target]:
        threading.Thread(target=service.serve_forever, daemon=True).start()
    values = dict(line.split(': ', 1) for line in subprocess.check_output([str(CORE), 'generate', 'reality-keypair'], text=True).strip().splitlines())
    other = dict(line.split(': ', 1) for line in subprocess.check_output([str(CORE), 'generate', 'reality-keypair'], text=True).strip().splitlines())
    user = str(uuid.uuid4())
    kinds = ['reality', 'tls-vision', 'reality-vision']
    ports = {kind: reserve() for kind in kinds}
    inbounds = []
    for kind in kinds:
        tls = {'enabled': True, 'server_name': 'localhost'}
        if kind == 'tls-vision':
            tls.update(certificate_path=str(cert), key_path=str(key))
        else:
            tls['reality'] = {'enabled': True, 'handshake': {'server': '127.0.0.1', 'server_port': target.server_port}, 'private_key': values['PrivateKey'], 'short_id': ['abcd']}
        account = {'uuid': user}
        if 'vision' in kind:
            account['flow'] = 'xtls-rprx-vision'
        inbounds.append({'type': 'vless', 'tag': kind, 'listen': '127.0.0.1', 'listen_port': ports[kind], 'users': [account], 'tls': tls})
    server_config = {'inbounds': inbounds, 'outbounds': [{'type': 'direct', 'tag': 'direct'}]}
    processes, logs = [], []

    def start(config, name, port):
        path = directory / (name + '.json')
        write(path, config)
        check = subprocess.run([str(CORE), 'check', '-c', str(path)], capture_output=True)
        if check.returncode:
            raise RuntimeError('受控配置校验失败：' + check.stderr.decode()[:500])
        log = open(directory / (name + '.log'), 'wb')
        logs.append(log)
        process = subprocess.Popen([str(CORE), 'run', '-c', str(path)], stdout=log, stderr=log)
        processes.append(process)
        ready(port, process)
        return process

    def client(kind, variant='valid'):
        public = other['PublicKey'] if variant == 'public-key' else values['PublicKey']
        short = 'dcba' if variant == 'short-id' else 'abcd'
        name = 'wrong.invalid' if variant == 'sni' else 'localhost'
        identity = str(uuid.uuid4()) if variant == 'uuid' else user
        query = ('security=tls' if kind == 'tls-vision' else f'security=reality&pbk={public}&sid={short}') + f'&sni={name}'
        if 'vision' in kind:
            query += '&flow=xtls-rprx-vision'
        node = directory / 'node.txt'
        write(node, f'vless://{identity}@127.0.0.1:{ports[kind]}?{query}')
        config_file = directory / 'generated.json'
        port = reserve()
        subprocess.run([str(CHECKS), 'config', str(node), str(config_file), str(port)], stdout=subprocess.DEVNULL, check=True)
        config = json.loads(config_file.read_text())
        if kind == 'tls-vision':
            config['outbounds'][0]['tls']['certificate_path'] = str(cert)
        process = start(config, kind + '-' + variant, port)
        return process, port

    def request(port, https=False):
        url = f'https://localhost:{target.server_port}/' if https else f'http://127.0.0.1:{origin.server_port}/'
        return subprocess.run(['curl', '--silent', '--show-error', '--fail', '--max-time', '4', '--noproxy', '', '--proxy', f'http://127.0.0.1:{port}', '--cacert', str(cert), url], capture_output=True)

    def passed(name):
        RESULTS.append(name)
        print('PASS ' + name, flush=True)

    try:
        start(server_config, 'server', ports['reality'])
        for kind in kinds:
            process, port = client(kind)
            for https in [False, True]:
                response = request(port, https)
                if response.returncode or response.stdout != b'QINGZHOU_REALITY_OK':
                    raise RuntimeError(kind + ' 受控转发失败：' + response.stderr.decode()[:300])
                passed(kind + ('.https' if https else '.http'))
            stop(process)
        for variant in ['public-key', 'short-id', 'sni', 'uuid']:
            process, port = client('reality-vision', variant)
            if request(port).returncode == 0:
                raise RuntimeError('错误参数未被拒绝：' + variant)
            passed('reality-vision.reject-' + variant)
            stop(process)
    finally:
        for process in processes:
            stop(process)
        for log in logs:
            log.close()
        origin.shutdown()
        target.shutdown()
print('RESULT reality_scenarios=' + str(len(RESULTS)) + ' failures=0')
