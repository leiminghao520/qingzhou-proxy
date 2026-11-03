"""Release orchestration runs against temporary files and mocked system services."""
import json
import os
from pathlib import Path
import sqlite3
from types import SimpleNamespace
from contextlib import closing
from unittest.mock import Mock

import pytest
import yaml
from cryptography.fernet import Fernet

from deploy import release
from test_app import env, user, device


@pytest.fixture
def release_env(tmp_path,monkeypatch):
    app=tmp_path/'app';app.mkdir();(app/'version').write_text('old')
    database=tmp_path/'data.db'
    with sqlite3.connect(database) as conn:
        conn.execute('CREATE TABLE version(value TEXT)');conn.execute("INSERT INTO version VALUES('old')")
    nginx_root=tmp_path/'nginx';nginx_root.mkdir();nginx=nginx_root/'hy2.conf';nginx.write_text('old-nginx')
    config=tmp_path/'config.yaml';config.write_text('auth:\n  type: userpass\n')
    keyfile=tmp_path/'env';keyfile.write_text('fake-test-secret')
    unit=tmp_path/'unit';unit.write_text('old-unit')
    root=tmp_path/'backups';root.mkdir()
    monkeypatch.setattr(release,'APP',app);monkeypatch.setattr(release,'DB',database)
    monkeypatch.setattr(release,'CONFIG',config);monkeypatch.setattr(release,'ENV',keyfile)
    monkeypatch.setattr(release,'ROOT',root);monkeypatch.setattr(release,'NGINX_ROOT',nginx_root)
    monkeypatch.setattr(release,'managed_files',lambda n:[config,keyfile,unit,n,tmp_path/'new-unit'])
    active={'hy2-admin.service','hy2-stats.timer'}
    enabled=set(active)
    calls=[]
    def run(*args,check=True):
        calls.append(args)
        rc=0
        if args[:2]==('systemctl','is-active'):rc=0 if args[2] in active else 3
        elif args[:2]==('systemctl','is-enabled'):rc=0 if args[2] in enabled else 1
        elif args[:2]==('systemctl','stop'):active.discard(args[2])
        elif args[:2] in (('systemctl','start'),('systemctl','restart')):active.add(args[2])
        return SimpleNamespace(returncode=rc,stdout='',stderr='')
    monkeypatch.setattr(release,'run',run)
    # No ownership changes outside fixtures, even when tests run as an ordinary user.
    monkeypatch.setattr(release.os,'chown',lambda *args:None)
    return SimpleNamespace(app=app,db=database,config=config,nginx=nginx,root=root,unit=unit,active=active,calls=calls)


def test_snapshot_and_paired_restore_preserve_failed_release(release_env,monkeypatch):
    r=release_env
    folder=release.snapshot(r.nginx)
    manifest=json.loads((folder/'manifest.json').read_text())
    assert manifest['complete'] and r.active=={'hy2-admin.service','hy2-stats.timer'}
    assert (folder/'app/version').read_text()=='old'
    (r.app/'version').write_text('new');r.config.write_text('new-config');r.unit.write_text('new-unit')
    (r.root.parent/'new-unit').write_text('added-auth-unit')
    with sqlite3.connect(r.db) as conn:conn.execute("UPDATE version SET value='new'")
    monkeypatch.setattr(release,'read_snapshot',lambda p:(folder,manifest))
    release.restore(folder)
    assert (r.app/'version').read_text()=='old'
    assert 'userpass' in r.config.read_text()
    with sqlite3.connect(r.db) as conn:assert conn.execute('SELECT value FROM version').fetchone()[0]=='old'
    recovery=next(r.root.glob('replaced-*'))
    assert (recovery/'app/version').read_text()=='new'
    assert not (r.root.parent/'new-unit').exists()
    assert ('systemctl','start','hysteria-server.service') in r.calls


def test_snapshot_invalid_path_and_failed_copy_restart_writers(release_env,monkeypatch):
    r=release_env
    with pytest.raises(ValueError):release.snapshot(r.unit)
    monkeypatch.setattr(release.shutil,'copytree',Mock(side_effect=OSError('full disk')))
    with pytest.raises(OSError):release.snapshot(r.nginx)
    assert r.active=={'hy2-admin.service','hy2-stats.timer'}
    assert not list(r.root.glob('*/manifest.json'))


def test_stop_writers_refuses_active_service(monkeypatch):
    monkeypatch.setattr(release,'run',lambda *args,**kw:SimpleNamespace(returncode=0))
    with pytest.raises(RuntimeError):release.stop_writers()


def test_cutover_requires_owner_and_uses_http_auth(env,release_env,monkeypatch):
    r=release_env
    monkeypatch.setattr(release,'DB',env[0].config['DATABASE'])
    monkeypatch.setattr(release,'read_snapshot',lambda p:(p,{}))
    monkeypatch.setenv('HY2_ENCRYPTION_KEY',env[0].config['ENCRYPTION_KEY'].decode())
    u=user(env,'owner','owner');d=device(env,u['id'])
    class Response:
        def __enter__(self):return self
        def __exit__(self,*args):pass
        def read(self):return json.dumps({'ok':True,'id':d['auth_id']}).encode()
    captured=[]
    def urlopen(req,timeout):captured.append(req);return Response()
    monkeypatch.setattr(release.urllib.request,'urlopen',urlopen)
    release.activate(r.root,d['id'])
    assert yaml.safe_load(r.config.read_text())['auth']['type']=='http'
    assert json.loads(captured[0].data)['auth'].startswith(d['auth_id']+':')
    assert ('systemctl','restart','hysteria-server.service') in r.calls
    with pytest.raises(ValueError):release.activate(r.root,999)


def test_cutover_failure_restores_paired_snapshot(env,release_env,monkeypatch):
    r=release_env
    monkeypatch.setattr(release,'DB',env[0].config['DATABASE'])
    monkeypatch.setattr(release,'read_snapshot',lambda p:(p,{}))
    u=user(env,'owner','owner');d=device(env,u['id'])
    monkeypatch.delenv('HY2_ENCRYPTION_KEY',raising=False)
    with pytest.raises(ValueError):release.activate(r.root,d['id'])
    monkeypatch.setenv('HY2_ENCRYPTION_KEY',env[0].config['ENCRYPTION_KEY'].decode())
    class Response:
        def __enter__(self):return self
        def __exit__(self,*args):pass
        def read(self):return json.dumps({'ok':True,'id':d['auth_id']}).encode()
    monkeypatch.setattr(release.urllib.request,'urlopen',lambda *args,**kw:Response())
    def run(*args,**kw):
        if args[:2]==('systemctl','restart'):raise RuntimeError('startup failure')
        return SimpleNamespace(returncode=0)
    monkeypatch.setattr(release,'run',run)
    restore=Mock();monkeypatch.setattr(release,'restore',restore)
    with pytest.raises(RuntimeError):release.activate(r.root,d['id'])
    restore.assert_called_once_with(r.root)


def test_snapshot_validation_and_missing_files(release_env):
    r=release_env;folder=release.snapshot(r.nginx)
    assert release.read_snapshot(folder)[1]['complete']
    os.chmod(folder,0o755)
    with pytest.raises(ValueError):release.read_snapshot(folder)
    os.chmod(folder,0o700)
    manifest=json.loads((folder/'manifest.json').read_text())
    manifest['complete']=False;(folder/'manifest.json').write_text(json.dumps(manifest))
    with pytest.raises(ValueError):release.read_snapshot(folder)
    manifest['complete']=True;(folder/'manifest.json').write_text(json.dumps(manifest))
    (folder/'file-0').unlink()
    with pytest.raises(ValueError):release.read_snapshot(folder)


def test_missing_app_and_direct_managed_paths(release_env,monkeypatch):
    r=release_env
    monkeypatch.setattr(release,'APP',r.root/'missing')
    with pytest.raises(ValueError):release.snapshot(r.nginx)


def test_root_only_cli_dispatch(monkeypatch,tmp_path):
    import sys
    import runpy
    monkeypatch.setattr(sys,'argv',['release','snapshot','--nginx-config',str(tmp_path/'nginx')])
    monkeypatch.setattr(release.os,'geteuid',lambda:1000)
    with pytest.raises(SystemExit):release.main()
    with pytest.raises(SystemExit):runpy.run_path(release.__file__,run_name='__main__')
    monkeypatch.setattr(release.os,'geteuid',lambda:0)
    snapshot=Mock();activate=Mock();restore=Mock()
    monkeypatch.setattr(release,'snapshot',snapshot);monkeypatch.setattr(release,'activate',activate);monkeypatch.setattr(release,'restore',restore)
    release.main();snapshot.assert_called_once()
    monkeypatch.setattr(sys,'argv',['release','activate','--snapshot',str(tmp_path),'--owner-device','1'])
    release.main();activate.assert_called_once_with(tmp_path,1)
    monkeypatch.setattr(sys,'argv',['release','restore','--snapshot',str(tmp_path)])
    release.main();restore.assert_called_once_with(tmp_path)


def test_command_runner_and_managed_path_inventory(monkeypatch,tmp_path):
    process=Mock(return_value=SimpleNamespace(returncode=0))
    monkeypatch.setattr(release.subprocess,'run',process)
    assert release.run('nginx','-t').returncode==0
    assert process.call_args.kwargs['timeout']==60
    paths=release.managed_files(tmp_path/'nginx')
    assert release.CONFIG in paths and release.ENV in paths and release.HELPER in paths


def test_restore_missing_current_files_and_oneshot_service(release_env):
    r=release_env;folder=release.snapshot(r.nginx)
    manifest=json.loads((folder/'manifest.json').read_text())
    manifest['active'].append('hy2-stats.service')
    (folder/'manifest.json').write_text(json.dumps(manifest))
    r.unit.unlink()
    release.restore(folder)
    assert r.unit.read_text()=='old-unit'
    assert ('systemctl','start','hy2-stats.service') not in r.calls


def test_cutover_rejected_probe_does_not_touch_proxy_config(env,release_env,monkeypatch):
    r=release_env
    monkeypatch.setattr(release,'DB',env[0].config['DATABASE'])
    monkeypatch.setattr(release,'read_snapshot',lambda p:(p,{}))
    monkeypatch.setenv('HY2_ENCRYPTION_KEY',env[0].config['ENCRYPTION_KEY'].decode())
    u=user(env,'owner','owner');d=device(env,u['id'])
    class Response:
        def __enter__(self):return self
        def __exit__(self,*args):pass
        def read(self):return b'{"ok":false}'
    monkeypatch.setattr(release.urllib.request,'urlopen',lambda *a,**kw:Response())
    with pytest.raises(ValueError):release.activate(r.root,d['id'])
    assert yaml.safe_load(r.config.read_text())['auth']['type']=='userpass'
    assert ('systemctl','restart','hysteria-server.service') not in r.calls
