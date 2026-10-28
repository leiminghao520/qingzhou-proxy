import json
import subprocess
import urllib.request


class OperationsHelper:
    ALLOWED = frozenset({"status", "reload", "sync-vless"})

    def __init__(self, helper_path, runner=None):
        self.helper_path = helper_path
        self.runner = runner or self._run

    def _run(self, operation, payload=None):
        proc = subprocess.run(
            ["sudo", self.helper_path, operation],
            input=json.dumps(payload or {}).encode(), stdout=subprocess.PIPE,
            stderr=subprocess.PIPE, timeout=20, check=False,
        )
        if proc.returncode:
            raise RuntimeError(proc.stderr.decode(errors="replace")[-500:] or "helper failed")
        return json.loads(proc.stdout.decode() or "{}")

    def call(self, operation, payload=None):
        if operation not in self.ALLOWED:
            raise ValueError("operation is not allowed")
        return self.runner(operation, payload)


def fetch_stats(url, secret, timeout=2):
    if not secret:
        raise RuntimeError('统计接口未配置')
    def get(path):
        req = urllib.request.Request(url.rstrip("/") + path, headers={"Authorization": secret})
        with urllib.request.urlopen(req, timeout=timeout) as response:
            return json.load(response)
    traffic, online = get('/traffic'), get('/online')
    if not isinstance(traffic, dict) or not isinstance(online, dict):
        raise ValueError('invalid statistics response')
    for value in traffic.values():
        if not isinstance(value, dict) or any(type(value.get(k)) is not int or value[k] < 0 for k in ('tx', 'rx')):
            raise ValueError('invalid traffic counters')
    if any(type(value) is not int or value < 0 for value in online.values()):
        raise ValueError('invalid online counters')
    return traffic, online


def kick_clients(url, secret, ids):
    if not secret:
        raise RuntimeError('统计接口未配置')
    req = urllib.request.Request(url.rstrip('/') + '/kick', data=json.dumps(ids).encode(),
                                 headers={'Authorization': secret, 'Content-Type': 'application/json'}, method='POST')
    with urllib.request.urlopen(req, timeout=2) as response:
        if response.status != 200:
            raise RuntimeError('kick rejected')
