"""在线加密备份，不停止代理、认证或采集服务。"""
import importlib.metadata
import hashlib
import json
import os
import shutil
import sqlite3
import subprocess
import tarfile
import tempfile
from datetime import datetime, timezone
from pathlib import Path


def file_hash(path):
    hasher=hashlib.sha256()
    with path.open('rb') as stream:
        for block in iter(lambda:stream.read(65536),b''):hasher.update(block)
    return hasher.hexdigest()


def deployment_paths():
    # 使用文件清单保存双协议入口与授权恢复所需的配置，私钥只进入加密归档。
    paths = ['/etc/hy2-admin.env','/etc/hysteria/config.yaml','/etc/nginx/nginx.conf',
        '/etc/haproxy/haproxy.cfg','/etc/qz-vless/config.json','/etc/hy2-admin-vless.json',
        '/usr/local/sbin/hy2-admin-helper','/etc/sudoers.d/hy2-admin']
    units = ['hy2-admin.service','hy2-auth.service','hy2-stats.service','hy2-stats.timer',
        'hy2-client-cloud.service','hy2-client-cloud.timer','hy2-client-backup.service','hy2-client-backup.timer',
        'qz-vless.service','qz-vless-sync.service','qz-vless-sync.timer']
    paths += ['/etc/systemd/system/' + unit for unit in units]
    for folder in ['/etc/nginx/sites-enabled','/etc/nginx/conf.d','/etc/nginx/snippets',
                   '/etc/systemd/system/hy2-admin.service.d','/etc/systemd/system/hy2-stats.service.d',
                   '/etc/systemd/system/qz-vless.service.d']:
        paths += [str(path) for path in sorted(Path(folder).glob('*')) if path.is_file()]
    return tuple(Path(path) for path in dict.fromkeys(paths))


def create_backup(database, source, output, age='/usr/bin/age', extra=(), work_dir="/run/qingzhou-backup"):
    with sqlite3.connect('file:'+str(database)+'?mode=ro',uri=True) as conn:
        row=conn.execute("SELECT value FROM settings WHERE key='backup_recipient'").fetchone()
    if not row: return None
    output.mkdir(parents=True,exist_ok=True,mode=0o700)
    if shutil.disk_usage(output).free < 512*1024*1024: raise RuntimeError('备份磁盘空间不足')
    stamp=datetime.now(timezone.utc).strftime('%Y%m%dT%H%M%SZ'); name='backup-'+stamp+'.tar.age'
    # 原文只进入权限受限的内存临时目录，加密成功才发布最新清单。
    with tempfile.TemporaryDirectory(prefix='hy2-backup-',dir=work_dir) as temp:
        folder=Path(temp); dbcopy=folder/'database.sqlite3'
        with sqlite3.connect('file:'+str(database)+'?mode=ro',uri=True) as src,sqlite3.connect(dbcopy) as dst:
            src.backup(dst)
            if dst.execute('PRAGMA integrity_check').fetchone()[0]!='ok': raise RuntimeError('数据库检查失败')
        bundle=folder/'snapshot.tar'
        with tarfile.open(bundle,'w') as tf:
            tf.add(dbcopy,arcname='database.sqlite3')
            runtime=folder/'runtime.json'
            runtime.write_text(json.dumps({'format':'age-tar-v1','packages':sorted(
                str(d.metadata['Name'])+'=='+d.version for d in importlib.metadata.distributions())}))
            tf.add(runtime,arcname='runtime.json')
            for p in sorted(source.rglob('*')):
                rel=p.relative_to(source)
                if p.is_symlink() or any(part.startswith('.') or part=='__pycache__' for part in rel.parts): continue
                if p.is_file(): tf.add(p,arcname='program/'+str(rel))
            for path in extra:
                if path.exists():
                    # 保留原路径层级，避免 Nginx 与 sudoers 同名文件互相覆盖。
                    relative=path.relative_to('/') if path.is_absolute() else path
                    target=folder/'config'/relative
                    target.parent.mkdir(parents=True,exist_ok=True)
                    if path.suffix=='.env':
                        target.write_text('\n'.join(l for l in path.read_text().splitlines() if not l.strip().removeprefix('export ').split('=',1)[0].strip().startswith(('HY2_CLOUD_','TENCENTCLOUD_')))+'\n')
                    else: shutil.copy2(path,target)
                    tf.add(target,arcname='config/'+str(relative))
        partial=output/(name+'.partial')
        try:
            subprocess.run([age,'-r',row[0],'-o',str(partial),str(bundle)],check=True,timeout=120,
                           stdout=subprocess.DEVNULL,stderr=subprocess.DEVNULL)
            if partial.stat().st_size>512*1024*1024:raise RuntimeError('备份超过客户端同步上限')
            os.chmod(partial,0o600); partial.replace(output/name)
        finally:
            if partial.exists(): partial.unlink()
    path=output/name
    manifest={'name':name,'size':path.stat().st_size,'sha256':file_hash(path),
              'created_at':stamp,'format':'age-tar-v1','includes_cloud_credentials':False}
    tmp=output/'latest.new'; tmp.write_text(json.dumps(manifest));os.chmod(tmp,0o600);tmp.replace(output/'latest.json')
    # 留存七份日备份与最近四个不同周的备份；先有完整新备份才清理。
    files=sorted(output.glob('backup-????????T??????Z.tar.age'),reverse=True)
    keep=set(files[:7]);weeks=set()
    for p in files:
        week=datetime.strptime(p.name[7:15],'%Y%m%d').strftime('%G-%V')
        if week not in weeks and len(weeks)<4: keep.add(p);weeks.add(week)
    for p in files:
        if p not in keep:p.unlink()
    return manifest


if __name__=='__main__':
    import fcntl
    from config import DATABASE
    # 定时与手动运行共用锁，避免相同输出和清理相互竞争。
    with open('/run/qingzhou-backup/job.lock','w') as lock:
        fcntl.flock(lock,fcntl.LOCK_EX|fcntl.LOCK_NB)
        result=create_backup(DATABASE,Path('/opt/hy2-admin'),Path('/var/backups/qingzhou-client'),
            extra=deployment_paths())
        if result:
            import pwd
            uid=pwd.getpwnam('hy2admin').pw_gid
            # 备份目录本身由 root 管理，后台只获得读取权限。
            folder=Path('/var/backups/qingzhou-client');os.chown(folder,0,uid);os.chmod(folder,0o750)
            for p in folder.iterdir():os.chown(p,0,uid);os.chmod(p,0o640)
        print('备份完成' if result else '未配置备份公钥，跳过')
