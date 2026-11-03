#!/usr/bin/env python3
"""使用真实 age 工具在隔离目录验证备份和恢复，不接触线上网络。"""
import importlib.util,sqlite3,tempfile,subprocess,tarfile,hashlib,json
from pathlib import Path
root=Path(__file__).resolve().parents[1]
spec=importlib.util.spec_from_file_location('backup_job',root/'server/hy2-admin/backup_job.py')
module=importlib.util.module_from_spec(spec);spec.loader.exec_module(module)
age=root/'.build/age-tools/age';keygen=root/'.build/age-tools/age-keygen'
with tempfile.TemporaryDirectory(prefix='qingzhou-backup-check-') as tmp:
    folder=Path(tmp);identity=folder/'identity'
    subprocess.run([str(keygen),'-o',str(identity)],check=True,capture_output=True)
    recipient=subprocess.run([str(keygen),'-y',str(identity)],check=True,capture_output=True,text=True).stdout.strip()
    db=folder/'live.db'
    with sqlite3.connect(db) as conn:
        conn.execute('CREATE TABLE settings(key TEXT PRIMARY KEY,value TEXT)')
        conn.execute('INSERT INTO settings VALUES(?,?)',('backup_recipient',recipient));conn.commit()
    source=folder/'source';source.mkdir();(source/'app.py').write_text('print("fixture")')
    (source/'.venv').mkdir();(source/'.venv/secret').write_text('EXCLUDE')
    env=folder/'hy2-admin.env';env.write_text('HY2_ENCRYPTION_KEY=fixture\nTENCENTCLOUD_SECRET_KEY=DO_NOT_BACK_UP\nHY2_CLOUD_INSTANCE_ID=ins-fixture\n')
    other=folder/'other';other.mkdir();duplicate=other/env.name;duplicate.write_text('DISTINCT_CONFIG=fixture\n')
    output=folder/'output'
    manifest=module.create_backup(db,source,output,age=str(age),extra=(env,duplicate),work_dir=folder)
    data=(output/manifest['name']).read_bytes()
    assert hashlib.sha256(data).hexdigest()==manifest['sha256']
    assert b'DO_NOT_BACK_UP' not in data and b'fixture' not in data
    archive=folder/'restored.tar'
    subprocess.run([str(age),'-d','-i',str(identity),'-o',str(archive),str(output/manifest['name'])],check=True,capture_output=True)
    env_entry='config/'+str(env).lstrip('/');duplicate_entry='config/'+str(duplicate).lstrip('/')
    with tarfile.open(archive) as tf:
        assert tf.getnames()==['database.sqlite3','runtime.json','program/app.py',env_entry,duplicate_entry]
        assert tf.extractfile(duplicate_entry).read()==b'DISTINCT_CONFIG=fixture\n'
        text=tf.extractfile(env_entry).read().decode()
        assert 'HY2_ENCRYPTION_KEY=fixture' in text and 'TENCENTCLOUD' not in text and 'HY2_CLOUD_' not in text
        restored=folder/'restored.db';restored.write_bytes(tf.extractfile('database.sqlite3').read())
    with sqlite3.connect(restored) as conn:assert conn.execute('PRAGMA integrity_check').fetchone()[0]=='ok'
    corrupt=folder/'corrupt.age';corrupt.write_bytes(data[:-20]+b'corrupt')
    assert subprocess.run([str(age),'-d','-i',str(identity),str(corrupt)],stdout=subprocess.DEVNULL,stderr=subprocess.DEVNULL).returncode!=0
    print('BACKUP_CHECKS_OK: encrypted snapshot, isolated restore, database integrity, credential exclusion, corruption rejection')
