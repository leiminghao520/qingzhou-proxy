"""生成设备独立的 TCP 节点，不共享设备访问凭据。"""
import hashlib
import hmac
import json
import uuid
from pathlib import Path
from urllib.parse import quote, urlencode


def device_uuid(auth_id, password):
    digest = hmac.new(password.encode(), ('qingzhou-vless-v1:' + auth_id).encode(), hashlib.sha256).digest()
    return str(uuid.UUID(bytes=digest[:16], version=4))


def public_settings(path):
    return json.loads(Path(path).read_text()) if path else None


def node(settings, auth_id, password, label):
    if settings is None:
        return None
    return {**settings, 'uuid': device_uuid(auth_id, password), 'name': label + ' · TCP 备用'}


def uri(value):
    params = {'type': 'tcp', 'security': 'reality', 'encryption': 'none',
              'sni': value['server_name'], 'fp': 'chrome', 'pbk': value['public_key'],
              'sid': value['short_id'], 'flow': 'xtls-rprx-vision'}
    return f"vless://{value['uuid']}@{value['server']}:{value['port']}?{urlencode(params)}#{quote(value['name'], safe='')}"
