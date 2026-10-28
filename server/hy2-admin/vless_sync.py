"""由 root 服务同步数据库中的有效设备，配置改变后重新加载 TCP 服务。"""
import fcntl
import json
import os
from pathlib import Path
import sqlite3
import subprocess
import tempfile

from cryptography.fernet import Fernet
from vless import device_uuid


def users(database, fernet):
    # 只读连接避免同步进程迁移或更改业务数据库。
    conn = sqlite3.connect(Path(database).resolve().as_uri() + '?mode=ro', uri=True)
    try:
        rows = conn.execute('SELECT d.auth_id,d.encrypted_password FROM devices d '
                            'JOIN proxy_users u ON u.id=d.user_id WHERE d.enabled=1 AND u.enabled=1 ORDER BY d.auth_id')
        return [{'name': auth_id, 'uuid': device_uuid(auth_id, fernet.decrypt(password).decode()),
                 'flow': 'xtls-rprx-vision'} for auth_id, password in rows]
    finally:
        conn.close()


def synchronize(config_path, active_users, runner=subprocess.run):
    path = Path(config_path)
    original = path.read_bytes()
    config = json.loads(original)
    inbound = next(value for value in config['inbounds'] if value['tag'] == 'vless-reality')
    if inbound['users'] == active_users:
        return False
    inbound['users'] = active_users
    fd, temporary = tempfile.mkstemp(dir=path.parent, prefix='.sync-')
    try:
        with os.fdopen(fd, 'w') as stream:
            json.dump(config, stream, indent=2)
        runner(['/opt/qz-vless/sing-box', 'check', '-c', temporary], check=True, capture_output=True, timeout=10)
        os.replace(temporary, path)
        try:
            runner(['systemctl', 'restart', 'qz-vless.service'], check=True, capture_output=True, timeout=10)
        except Exception:
            # 不恢复旧授权列表，避免停用或轮换后的旧凭据再次获得访问。
            runner(['systemctl', 'stop', 'qz-vless.service'], check=True, capture_output=True, timeout=10)
            raise
    finally:
        if os.path.exists(temporary):
            os.unlink(temporary)
    return True


def main():
    with open('/run/qz-vless-sync.lock', 'w') as lock:
        fcntl.flock(lock, fcntl.LOCK_EX)
        try:
            active = users(os.environ.get('HY2_DATABASE', '/var/lib/hy2-admin/hy2-admin.sqlite3'),
                           Fernet(os.environ['HY2_ENCRYPTION_KEY']))
            synchronize('/etc/qz-vless/config.json', active)
            subprocess.run(['systemctl', 'start', 'qz-vless.service'], check=True, capture_output=True, timeout=10)
        except Exception:
            # 读取或解密失败也关闭服务，避免继续使用过期授权。
            subprocess.run(['systemctl', 'stop', 'qz-vless.service'], check=True, capture_output=True, timeout=10)
            raise


if __name__ == '__main__':
    main()
