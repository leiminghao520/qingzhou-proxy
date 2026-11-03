#!/usr/bin/env python3
"""Root-only paired snapshots, HTTP-auth cutover and recoverable restoration.

Run snapshot BEFORE replacing the application. Never expose this CLI to sudoers
or the web application. A restore also restores secrets; snapshots are root-only.
"""
import argparse
import json
import os
from pathlib import Path
import shutil
import sqlite3
import subprocess
import tempfile
from datetime import datetime, timezone
import urllib.request

import yaml
from cryptography.fernet import Fernet

APP = Path('/opt/hy2-admin')
DB = Path('/var/lib/hy2-admin/hy2-admin.sqlite3')
CONFIG = Path('/etc/hysteria/config.yaml')
ENV = Path('/etc/hy2-admin.env')
ROOT = Path('/var/backups/hy2-admin/releases')
UNITS = ('hy2-admin.service','hy2-auth.service','hy2-stats.service','hy2-stats.timer')
SERVICES = ('hy2-stats.timer','hy2-stats.service','hy2-admin.service','hy2-auth.service')
HELPER = Path('/usr/local/sbin/hy2-admin-helper')
SUDOERS = Path('/etc/sudoers.d/hy2-admin')
NGINX_ROOT = Path('/etc/nginx')


def run(*argv, check=True):
    return subprocess.run(argv, check=check, capture_output=True, text=True, timeout=60)


def managed_files(nginx):
    return [CONFIG, ENV, HELPER, SUDOERS, nginx]+[Path('/etc/systemd/system')/unit for unit in UNITS]


def stop_writers():
    for name in SERVICES:
        run('systemctl','stop',name,check=False)
        if run('systemctl','is-active',name,check=False).returncode==0:
            raise RuntimeError('A database writer could not be stopped: '+name)


def copy_file(source, destination, uid=None, gid=None):
    destination.parent.mkdir(parents=True,exist_ok=True)
    shutil.copy2(source,destination)
    stat=source.stat()
    os.chown(destination,stat.st_uid if uid is None else uid,stat.st_gid if gid is None else gid)


def database_copy(source,destination):
    src=sqlite3.connect(f'file:{source}?mode=ro',uri=True)
    dest=sqlite3.connect(destination)
    try:
        src.backup(dest)
    finally:
        dest.close();src.close()


def snapshot(nginx):
    nginx=nginx.resolve(strict=True)
    if not nginx.is_relative_to(NGINX_ROOT) or not nginx.is_file():
        raise ValueError('Expected the exact HY2 nginx configuration file under /etc/nginx')
    if not APP.is_dir() or not DB.is_file():
        raise ValueError('Application and database must exist before snapshot')
    ROOT.mkdir(parents=True,exist_ok=True,mode=0o700)
    folder=Path(tempfile.mkdtemp(prefix=datetime.now(timezone.utc).strftime('%Y%m%dT%H%M%SZ-'),dir=ROOT))
    os.chmod(folder,0o700)
    active=[name for name in SERVICES if run('systemctl','is-active',name,check=False).returncode==0]
    enabled=[name for name in UNITS if run('systemctl','is-enabled',name,check=False).returncode==0]
    try:
        stop_writers()
        shutil.copytree(APP,folder/'app',symlinks=True,ignore=shutil.ignore_patterns('__pycache__','.pytest_cache'))
        database_copy(DB,folder/'database.sqlite3')
        files=[]
        for i,path in enumerate(managed_files(nginx)):
            entry={'path':str(path),'exists':path.exists(),'backup':f'file-{i}'}
            if path.exists():
                stat=path.stat();entry.update(uid=stat.st_uid,gid=stat.st_gid)
                shutil.copy2(path,folder/entry['backup'])
            files.append(entry)
        stat=DB.stat()
        manifest={'files':files,'active':active,'enabled':enabled,'db_uid':stat.st_uid,'db_gid':stat.st_gid,'db_mode':stat.st_mode&0o777,'complete':True}
        (folder/'manifest.json').write_text(json.dumps(manifest,indent=2))
    finally:
        for name in reversed(active): run('systemctl','start',name,check=False)
    print(folder)
    return folder


def read_snapshot(folder):
    folder=folder.resolve(strict=True)
    if folder.parent!=ROOT.resolve() or folder.stat().st_uid!=os.geteuid() or folder.stat().st_mode&0o077:
        raise ValueError('Expected a root-owned private release snapshot')
    manifest=json.loads((folder/'manifest.json').read_text())
    if not manifest.get('complete') or not (folder/'app').is_dir() or not (folder/'database.sqlite3').is_file():
        raise ValueError('Incomplete snapshot')
    for item in manifest['files']:
        if item['exists'] and not (folder/item['backup']).is_file():
            raise ValueError('Missing snapshot file')
    return folder,manifest


def restore(folder):
    folder,manifest=read_snapshot(folder)
    stop_writers()
    run('systemctl','stop','hysteria-server.service')
    for unit in UNITS:
        run('systemctl','disable',unit,check=False)
    recovery=Path(tempfile.mkdtemp(prefix='replaced-',dir=ROOT))
    os.chmod(recovery,0o700)
    # Keep the failed release recoverable; do not recursively delete either tree.
    APP.rename(recovery/'app')
    shutil.copytree(folder/'app',APP,symlinks=True)
    database_copy(DB,recovery/'database.sqlite3')
    database_copy(folder/'database.sqlite3',DB)
    os.chown(DB,manifest['db_uid'],manifest['db_gid']);os.chmod(DB,manifest['db_mode'])
    for item in manifest['files']:
        destination=Path(item['path'])
        if destination.exists():
            copy_file(destination,recovery/item['backup'])
        if item['exists']:
            copy_file(folder/item['backup'],destination,item['uid'],item['gid'])
        elif destination.exists():
            destination.rename(recovery/(item['backup']+'-removed'))
    run('systemctl','daemon-reload')
    for unit in manifest['enabled']:
        run('systemctl','enable',unit)
    run('nginx','-t');run('systemctl','reload','nginx')
    for name in reversed(manifest['active']):
        if name!='hy2-stats.service':run('systemctl','start',name)
    run('systemctl','start','hysteria-server.service')
    print('Restored paired snapshot. Replaced files retained at '+str(recovery))


def activate(folder,owner_device):
    read_snapshot(folder)
    # The new code/database and auth unit are installed before this command.
    run('systemctl','is-active','hy2-auth.service')
    conn=sqlite3.connect(f'file:{DB}?mode=ro',uri=True);conn.row_factory=sqlite3.Row
    try:
        row=conn.execute("SELECT d.* FROM devices d JOIN proxy_users u ON u.id=d.user_id WHERE d.id=? "
                         "AND u.role='owner' AND u.enabled=1 AND d.enabled=1 "
                         "AND NOT EXISTS(SELECT 1 FROM pending_kicks k WHERE k.auth_id=d.auth_id)",(owner_device,)).fetchone()
    finally:conn.close()
    if not row:raise ValueError('An enabled, ready owner device is required')
    key=os.environ.get('HY2_ENCRYPTION_KEY')
    if not key:raise ValueError('Load HY2_ENCRYPTION_KEY securely from the existing environment')
    password=Fernet(key).decrypt(row['encrypted_password']).decode()
    req=urllib.request.Request('http://127.0.0.1:8788/auth',data=json.dumps({'auth':row['auth_id']+':'+password}).encode(),
                               headers={'Content-Type':'application/json'})
    with urllib.request.urlopen(req,timeout=3) as response:result=json.load(response)
    if result!={'ok':True,'id':row['auth_id']}:raise ValueError('Owner authentication probe failed')
    current=yaml.safe_load(CONFIG.read_text())
    current['auth']={'type':'http','http':{'url':'http://127.0.0.1:8788/auth','insecure':False}}
    stat=CONFIG.stat()
    fd,name=tempfile.mkstemp(prefix='hy2-config-',dir=CONFIG.parent)
    try:
        with os.fdopen(fd,'w') as output:
            yaml.safe_dump(current,output,sort_keys=False);output.flush();os.fsync(output.fileno())
        os.chmod(name,stat.st_mode&0o777);os.chown(name,stat.st_uid,stat.st_gid)
        os.replace(name,CONFIG)
        run('systemctl','restart','hysteria-server.service')
        run('systemctl','is-active','hysteria-server.service')
    except Exception:
        restore(folder)
        raise RuntimeError('Cutover failed; paired release snapshot restored') from None
    finally:
        if os.path.exists(name):os.unlink(name)
    print('HTTP device authentication activated. Re-import every client device configuration.')


def main():
    parser=argparse.ArgumentParser(description=__doc__)
    commands=parser.add_subparsers(dest='command',required=True)
    backup=commands.add_parser('snapshot');backup.add_argument('--nginx-config',required=True,type=Path)
    switch=commands.add_parser('activate');switch.add_argument('--snapshot',required=True,type=Path);switch.add_argument('--owner-device',required=True,type=int)
    recovery=commands.add_parser('restore');recovery.add_argument('--snapshot',required=True,type=Path)
    args=parser.parse_args()
    if os.geteuid()!=0:parser.error('Must run as root during an authorized maintenance window')
    if args.command=='snapshot':snapshot(args.nginx_config)
    elif args.command=='activate':activate(args.snapshot,args.owner_device)
    else:restore(args.snapshot)


if __name__=='__main__':
    main()
