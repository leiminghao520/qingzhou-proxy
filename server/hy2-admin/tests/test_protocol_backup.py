import hashlib
import os
from pathlib import Path
import sqlite3
import subprocess
import tarfile

from backup_job import create_backup, deployment_paths
from db import connect
from test_app import env


def test_protocol_deployment_manifest():
    paths = deployment_paths()
    assert len(paths) == len(set(paths))
    assert {Path(p) for p in ['/etc/nginx/nginx.conf', '/etc/haproxy/haproxy.cfg',
        '/etc/qz-vless/config.json', '/etc/hy2-admin-vless.json', '/etc/sudoers.d/hy2-admin',
        '/etc/systemd/system/qz-vless.service', '/etc/systemd/system/qz-vless-sync.service',
        '/etc/systemd/system/qz-vless-sync.timer']} <= set(paths)


def test_manifest_includes_dropins_and_skips_directories(monkeypatch, tmp_path):
    file = tmp_path/'vless.conf'; file.write_text('配置')
    folder = tmp_path/'directory'; folder.mkdir()
    monkeypatch.setattr(Path, 'glob', lambda self, pattern: iter([file, folder]))
    paths = deployment_paths()
    assert file in paths and folder not in paths and paths.count(file) == 1


def test_encrypted_protocol_backup_restores_bytes(env, tmp_path):
    tools = Path(os.environ.get('AGE_TEST_TOOLS', '/Applications/轻舟代理.app/Contents/Resources'))
    identity = tmp_path/'identity'
    subprocess.run([str(tools/'age-keygen'), '-o', str(identity)], check=True, capture_output=True)
    recipient = subprocess.check_output([str(tools/'age-keygen'), '-y', str(identity)], text=True).strip()
    with connect(env[0].config['DATABASE']) as conn:
        conn.execute("INSERT INTO settings VALUES('backup_recipient',?)", (recipient,))
    source = tmp_path/'program'; source.mkdir()
    (source/'vless_sync.py').write_text('恢复夹具')
    files = [tmp_path/'config.json', tmp_path/'haproxy.cfg', tmp_path/'vless.conf', tmp_path/'qz-vless-sync.timer']
    for i, path in enumerate(files): path.write_text('协议恢复内容-' + str(i))
    output = tmp_path/'backup'
    manifest = create_backup(env[0].config['DATABASE'], source, output, str(tools/'age'), files, tmp_path)
    archive = output/manifest['name']
    assert manifest['sha256'] == hashlib.sha256(archive.read_bytes()).hexdigest()
    restored = tmp_path/'restored.tar'
    subprocess.run([str(tools/'age'), '-d', '-i', str(identity), '-o', str(restored), str(archive)], check=True, capture_output=True)
    with tarfile.open(restored) as bundle:
        for path in files:
            assert bundle.extractfile('config/'+str(path).lstrip('/')).read() == path.read_bytes()
        assert bundle.extractfile('program/vless_sync.py').read() == (source/'vless_sync.py').read_bytes()
        database = tmp_path/'restored.db'
        database.write_bytes(bundle.extractfile('database.sqlite3').read())
    with sqlite3.connect(database) as conn:
        assert conn.execute('PRAGMA integrity_check').fetchone()[0] == 'ok'
