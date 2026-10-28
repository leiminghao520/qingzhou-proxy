import json
import subprocess
import sys
from unittest.mock import Mock
from urllib.parse import parse_qs, urlsplit, unquote

import pytest
import yaml
from cryptography.fernet import Fernet

import privileged_helper
import vless_sync
from db import connect
from subscriptions import render_subscription
from test_app import env, user, device, post, query, subscription
from vless import device_uuid, node, public_settings, uri


SETTINGS = {'server': '43.163.70.144', 'port': 443, 'server_name': 'www.microsoft.com',
            'public_key': 'a' * 43, 'short_id': '12345678'}


def configure(env, tmp_path):
    path = tmp_path / 'public.json'
    path.write_text(json.dumps(SETTINGS))
    env[0].config['VLESS_PUBLIC_CONFIG'] = str(path)
    return path


def test_device_identity_and_public_settings(tmp_path):
    assert device_uuid('a', 'b') == '88cc21f6-9077-484b-a235-75691a60ef67'
    assert device_uuid('a', 'b') != device_uuid('b', 'b')
    assert device_uuid('a', 'b') != device_uuid('a', 'c')
    assert node(None, 'a', 'b', 'n') is None
    assert public_settings(None) is None
    p = tmp_path / 'public.json'; p.write_text(json.dumps(SETTINGS))
    assert public_settings(p) == SETTINGS
    value = node(SETTINGS, 'a', 'b', '名称\n,=')
    parsed = urlsplit(uri(value))
    assert parsed.username == device_uuid('a', 'b')
    assert parsed.hostname == SETTINGS['server'] and parsed.port == 443
    assert unquote(parsed.fragment) == '名称\n,= · TCP 备用'
    assert parse_qs(parsed.query) == {'type':['tcp'], 'security':['reality'], 'encryption':['none'],
        'sni':['www.microsoft.com'], 'fp':['chrome'], 'pbk':['a'*43], 'sid':['12345678'], 'flow':['xtls-rprx-vision']}


@pytest.mark.parametrize('kind', ['hy2', 'shadowrocket', 'qingzhou', 'mihomo', 'sing-box', 'shadowrocket-full'])
def test_all_formats_keep_old_node_and_add_tcp(kind):
    tcp = node(SETTINGS, 'a', 'b', '设备')
    body = render_subscription(kind, 'a', 'proxy.example', 443, 'b', vless=tcp)
    if kind in ('hy2', 'shadowrocket'):
        assert body.splitlines()[0].startswith('hysteria2://')
        assert body.splitlines()[1] == uri(tcp)
    elif kind == 'qingzhou':
        config = json.loads(body)
        assert len(config['nodes']) == 2 and config['nodes'][1] == uri(tcp)
        original = json.loads(render_subscription(kind, 'a', 'proxy.example', 443, 'b'))
        assert config['configurationJSON'] == original['configurationJSON'] and config['revision'] == original['revision']
    elif kind == 'mihomo':
        config = yaml.safe_load(body)
        assert len(config['proxies']) == 2
        assert config['proxies'][0]['type'] == 'hysteria2'
        assert config['proxies'][1] == {'name': tcp['name'], 'type':'vless', 'server':SETTINGS['server'], 'port':443,
            'uuid':tcp['uuid'], 'network':'tcp', 'tls':True, 'flow':'xtls-rprx-vision', 'servername':'www.microsoft.com',
            'client-fingerprint':'chrome', 'reality-opts':{'public-key':'a'*43, 'short-id':'12345678'}, 'udp':True}
        assert config['proxy-groups'][0]['proxies'] == ['a', tcp['name'], 'DIRECT']
    elif kind == 'sing-box':
        config = json.loads(body)
        assert config['outbounds'][0] == {'type':'selector', 'tag':'proxy', 'outbounds':['hy2','vless-tcp'], 'default':'hy2'}
        assert config['outbounds'][1]['type'] == 'hysteria2' and config['outbounds'][1]['tag'] == 'hy2'
        value = config['outbounds'][-1]
        assert value == {'type':'vless', 'tag':'vless-tcp', 'server':SETTINGS['server'], 'server_port':443,
            'uuid':tcp['uuid'], 'flow':'xtls-rprx-vision', 'tls':{'enabled':True, 'server_name':'www.microsoft.com',
            'utls':{'enabled':True,'fingerprint':'chrome'}, 'reality':{'enabled':True,'public_key':'a'*43,'short_id':'12345678'}}}
    else:
        assert 'PROXY = select, a, 设备 · TCP 备用' in body
        assert '[Proxy]\n设备 · TCP 备用 = vless, 43.163.70.144, 443, username=' + tcp['uuid'] in body
        assert 'reality-pbk=' + 'a'*43 + ', reality-sid=12345678, flow=xtls-rprx-vision, udp=1' in body
        assert 'tls=true, peer=www.microsoft.com' in body
        assert 'FINAL,PROXY' in body


def test_shadowrocket_name_cannot_inject():
    tcp = node(SETTINGS, 'a', 'b', 'bad\n,=')
    body = render_subscription('shadowrocket-full', 'a', 'x', 443, 'b', vless=tcp)
    assert 'bad_ · TCP 备用 = vless' in body
    with pytest.raises(ValueError):
        render_subscription('unknown', 'a', 'x', 443, 'b', vless=tcp)


def test_subscription_device_lifecycle(env, tmp_path):
    configure(env, tmp_path)
    calls = []
    env[0].operations.runner = lambda op, payload: calls.append(op) or {'ok':True}
    u = user(env); a = device(env, u['id']); b = device(env, u['id'], 'Other')
    def tcp(d):
        return subscription(env, d).text.splitlines()[1]
    first = tcp(a)
    assert first != tcp(b) and tcp(a) == first
    assert calls == ['sync-vless'] * 2
    assert subscription(env, a).headers['Cache-Control'] == 'no-store'
    assert post(env, f"/users/{u['id']}/devices/{a['id']}", action='rotate').status_code == 302
    changed = query(env, 'SELECT * FROM devices WHERE id=?', (a['id'],))[0]
    assert subscription(env, a).status_code == 404
    assert tcp(changed) != first
    assert post(env, f"/users/{u['id']}/devices/{a['id']}", action='disable').status_code == 302
    assert subscription(env, changed).status_code == 404 and subscription(env, b).status_code == 200
    assert post(env, f"/users/{u['id']}/devices/{a['id']}", action='enable').status_code == 302
    assert subscription(env, changed).status_code == 200
    assert post(env, f"/users/{u['id']}", action='disable').status_code == 302
    assert subscription(env, b).status_code == 404


def test_sync_failure_reported_after_database_commit(env, tmp_path):
    configure(env, tmp_path)
    u = user(env); d = device(env, u['id'])
    def fail(*args): raise RuntimeError('failed')
    env[0].operations.runner = fail
    response = post(env, f"/users/{u['id']}/devices/{d['id']}", action='disable')
    assert response.status_code == 503 and '资料已保存，TCP 授权待同步' in response.text
    assert query(env, 'SELECT enabled FROM devices WHERE id=?', (d['id'],))[0][0] == 0


def test_edit_metadata_does_not_sync(env, tmp_path):
    configure(env, tmp_path)
    calls = []
    env[0].operations.runner = lambda op, payload: calls.append(op) or {'ok':True}
    u = user(env); d = device(env, u['id'])
    calls.clear()
    assert post(env, f"/users/{u['id']}", action='edit', display_name='新名称', note='备注').status_code == 302
    assert post(env, f"/users/{u['id']}/devices/{d['id']}", action='edit', name='新设备名', platform='macOS', client='qingzhou', note='备注').status_code == 302
    assert calls == []


def test_sync_reads_only_enabled_devices(env):
    u = user(env); a = device(env, u['id']); b = device(env, u['id'])
    fernet = env[0].fernet
    def active(): return vless_sync.users(env[0].config['DATABASE'], fernet)
    assert len(active()) == 2
    post(env, f"/users/{u['id']}/devices/{a['id']}", action='disable')
    assert active() == [{'name':b['auth_id'], 'uuid':device_uuid(b['auth_id'],fernet.decrypt(b['encrypted_password']).decode()), 'flow':'xtls-rprx-vision'}]
    post(env, f"/users/{u['id']}", action='disable')
    assert active() == []


@pytest.mark.parametrize('failure', [None, 'check', 'restart'])
def test_atomic_sync_and_fail_closed(tmp_path, failure):
    path = tmp_path / 'config.json'
    original = {'inbounds':[{'tag':'vless-reality', 'users':[]}], 'other':'unchanged'}
    path.write_text(json.dumps(original))
    calls = []
    def runner(argv, **kwargs):
        calls.append(argv)
        assert kwargs == {'check':True, 'capture_output':True, 'timeout':10}
        if failure and failure in argv: raise subprocess.CalledProcessError(1, argv)
    if failure:
        with pytest.raises(subprocess.CalledProcessError): vless_sync.synchronize(path, [{'uuid':'new'}], runner)
        if failure == 'check':
            assert json.loads(path.read_text()) == original
        else:
            assert calls[-1] == ['systemctl', 'stop', 'qz-vless.service']
            assert json.loads(path.read_text())['inbounds'][0]['users'] == [{'uuid':'new'}]
    else:
        assert vless_sync.synchronize(path, [{'uuid':'new'}], runner)
        assert calls[-1] == ['systemctl', 'restart', 'qz-vless.service']
        assert not vless_sync.synchronize(path, [{'uuid':'new'}], runner)
        assert json.loads(path.read_text())['other'] == 'unchanged'
        assert path.stat().st_mode & 0o777 == 0o600
    assert not list(tmp_path.glob('.sync-*'))


def test_privileged_bridge(monkeypatch, capsys):
    monkeypatch.setattr(privileged_helper.os, 'geteuid', lambda:0)
    monkeypatch.setattr(sys, 'argv', ['helper','sync-vless'])
    runner = Mock(return_value=Mock(returncode=0))
    monkeypatch.setattr(privileged_helper, 'run', runner)
    privileged_helper.main()
    assert runner.call_args.args[0] == ['systemd-run','--quiet','--wait','--collect',
        '--property=EnvironmentFile=/etc/hy2-admin.env', '/opt/hy2-admin/.venv/bin/python', '/opt/hy2-admin/vless_sync.py']
    assert json.loads(capsys.readouterr().out) == {'ok':True}
    runner.return_value.returncode = 1
    with pytest.raises(RuntimeError): privileged_helper.main()


@pytest.mark.parametrize('failure', [False, True])
def test_sync_main_locks_and_stops_on_failure(monkeypatch, tmp_path, failure):
    import builtins
    import fcntl
    key = Fernet.generate_key()
    monkeypatch.setenv('HY2_ENCRYPTION_KEY', key.decode())
    monkeypatch.setenv('HY2_DATABASE', '/database')
    opener = builtins.open
    monkeypatch.setattr(vless_sync, 'open', lambda path, mode: opener(tmp_path/'lock', mode), raising=False)
    lock = Mock()
    monkeypatch.setattr(vless_sync.fcntl, 'flock', lock)
    def read(path, fernet):
        assert path == '/database' and fernet.decrypt(Fernet(key).encrypt(b'x')) == b'x'
        if failure: raise ValueError('bad encrypted password')
        return [{'uuid':'device'}]
    monkeypatch.setattr(vless_sync, 'users', read)
    sync = Mock()
    monkeypatch.setattr(vless_sync, 'synchronize', sync)
    runner = Mock()
    monkeypatch.setattr(vless_sync.subprocess, 'run', runner)
    if failure:
        with pytest.raises(ValueError): vless_sync.main()
        assert runner.call_args.args[0] == ['systemctl','stop','qz-vless.service']
    else:
        vless_sync.main()
        sync.assert_called_once_with('/etc/qz-vless/config.json', [{'uuid':'device'}])
        assert runner.call_args.args[0] == ['systemctl','start','qz-vless.service']
    assert lock.call_args.args[1] == fcntl.LOCK_EX


def test_sync_cli_entrypoint(env, monkeypatch, tmp_path):
    import builtins
    import runpy
    from pathlib import Path
    monkeypatch.setenv('HY2_ENCRYPTION_KEY', env[0].config['ENCRYPTION_KEY'].decode())
    monkeypatch.setenv('HY2_DATABASE', str(env[0].config['DATABASE']))
    opener = builtins.open
    monkeypatch.setattr(builtins, 'open', lambda path, *args, **kwargs:
        opener(tmp_path/'lock' if path == '/run/qz-vless-sync.lock' else path, *args, **kwargs))
    original = Path.read_bytes
    monkeypatch.setattr(Path, 'read_bytes', lambda path:
        b'{"inbounds":[{"tag":"vless-reality","users":[]}]}' if str(path) == '/etc/qz-vless/config.json' else original(path))
    runner = Mock()
    monkeypatch.setattr(vless_sync.subprocess, 'run', runner)
    runpy.run_module('vless_sync', run_name='__main__')
    assert runner.call_args.args[0] == ['systemctl','start','qz-vless.service']


@pytest.mark.parametrize('content', [b'x'*(1024*1024+1), b'{"version":2,"rules":[1]}', b'{"version":1,"rules":[]}'])
def test_full_subscription_rejects_invalid_template(monkeypatch, content):
    import subscriptions
    monkeypatch.setattr(subscriptions, 'Path', lambda *args: Mock(resolve=lambda:Mock(with_name=lambda name:Mock(read_bytes=lambda:content))))
    with pytest.raises(ValueError): render_subscription('qingzhou', 'a', 'x', 443, 'b')
