#!/usr/bin/env python3
"""把公开源码暂存到隔离目录测试，绝不覆盖线上程序。"""
from pathlib import Path
import subprocess,tarfile,io
root=Path(__file__).resolve().parents[1]/'server/hy2-admin'
keys=list((Path.home()/'Desktop').glob('*/singapore_vps.pem'))
if len(keys)!=1:raise SystemExit('SSH_KEY_MATCH_NOT_UNIQUE')
known=Path('/Users/leiminghao/Documents/Codex/2026-10-12/new-chat/work/vps-known-hosts')
args=['ssh','-i',str(keys[0]),'-o','BatchMode=yes','-o','ConnectTimeout=10','-o','StrictHostKeyChecking=yes','-o','UserKnownHostsFile='+str(known),'ubuntu@43.163.70.144']
buf=io.BytesIO()
with tarfile.open(fileobj=buf,mode='w:gz') as tf:
    for p in root.rglob('*'):
        if p.is_file() and not any(x.startswith('.') or x=='__pycache__' for x in p.relative_to(root).parts):tf.add(p,arcname=str(p.relative_to(root)))
tools=Path(__file__).resolve().parents[1]/'.build/age-tools-linux'
if not (tools/'age').is_file() or not (tools/'age-keygen').is_file():raise SystemExit('请先交叉编译 Linux age 隔离检查工具')
stage='/var/tmp/qingzhou-client-v1-isolated'

if subprocess.run(args+['umask 077; mkdir -p '+stage+'; tar -xzf - -C '+stage],input=buf.getvalue(),timeout=40).returncode:raise SystemExit('隔离源码暂存失败')
tool_archive=io.BytesIO()
with tarfile.open(fileobj=tool_archive,mode='w:gz') as tf:
    for name in ['age','age-keygen']:tf.add(tools/name,arcname=name)
if subprocess.run(args+['mkdir -p '+stage+'/test-tools; tar -xzf - -C '+stage+'/test-tools; chmod 700 '+stage+'/test-tools/age*'],input=tool_archive.getvalue(),timeout=40).returncode:raise SystemExit('隔离工具暂存失败')
if subprocess.run(args+['cd '+stage+' && AGE_TEST_TOOLS='+stage+'/test-tools /var/tmp/qz-client-test-venv/bin/python -m coverage run --branch --source=client_api,client_jobs,backup_job -m pytest -q'],timeout=180).returncode:raise SystemExit('服务端隔离检查失败')

subprocess.run(args+['cd '+stage+' && /var/tmp/qz-client-test-venv/bin/python -m coverage report -m'],check=True,timeout=30)
