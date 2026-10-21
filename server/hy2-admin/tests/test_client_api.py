"""联动接口的权限、统计及故障隔离回归。"""
import json
import re
import time
from contextlib import closing
from datetime import datetime,timedelta
from pathlib import Path
import pytest
from test_app import env,user,device,post,query,subscription
from db import connect,purge_old_data
from metrics import record_sample
from client_api import rollup,digest
from client_jobs import fetch_billing


def pair(env,d):
    result=post(env,f"/client-access/{d['id']}")
    assert result.status_code==200
    code=re.search(r'id="pairing-code"[^>]*value="([^"]+)"',result.text)[1]
    response=env[1].post('/api/client/v1/pair',json={'code':code})
    assert response.status_code==200
    return {'Authorization':'Bearer '+response.json['token']},code


def test_pairing_once_expiry_revocation_and_no_subscription_password(env):
    d=device(env,user(env)['id']);headers,code=pair(env,d)
    c=env[0].test_client()
    assert c.post('/api/client/v1/pair',json={'code':code}).status_code==401
    assert c.get('/api/client/v1/usage',headers=headers).status_code==200
    assert c.get('/api/client/v1/usage').status_code==401
    assert c.get('/api/client/v1/usage',headers={'Authorization':'Bearer '+env[0].fernet.decrypt(d['encrypted_token']).decode()}).status_code==401
    assert post(env,f"/client-access/{d['id']}/revoke").status_code==200
    assert c.get('/api/client/v1/usage',headers=headers).status_code==401
    result=post(env,f"/client-access/{d['id']}");code=re.search(r'id="pairing-code"[^>]*value="([^"]+)"',result.text)[1]
    with closing(connect(env[0].config['DATABASE'])) as conn,conn:conn.execute('UPDATE client_pairings SET expires=0')
    assert c.post('/api/client/v1/pair',json={'code':code}).status_code==401


def test_permissions_identity_isolation_and_user_disable(env):
    alice=user(env);a=device(env,alice['id']);b=device(env,user(env,'bob')['id'])
    headers,_=pair(env,a);c=env[0].test_client()
    assert [d['id'] for d in c.get('/api/client/v1/devices',headers=headers).json['devices']]==[a['id']]
    for path in ['status','billing','backup','backup/download']:
        assert c.get('/api/client/v1/'+path,headers=headers).status_code==403
    assert c.post('/api/client/v1/backup/recipient',json={},headers=headers).status_code==403
    assert c.post('/client-access/'+str(a['id'])).status_code==302
    assert env[1].post('/client-access/'+str(a['id'])).status_code==400
    assert post(env,f"/users/{alice['id']}",action='disable').status_code==302
    assert c.get('/api/client/v1/me',headers=headers).status_code==401


def test_pairing_copy_whitespace_replacement_and_internal_characters(env):
    d=device(env,user(env)['id']);path=f"/client-access/{d['id']}"
    def generate():
        response=post(env,path)
        assert 'readonly' in response.text and '此前的码失效' in response.text
        return re.search(r'id="pairing-code"[^>]*value="([^"]+)"',response.text)[1]
    previous=generate();latest=generate();c=env[0].test_client()
    for invalid in [previous,latest[:15]+' '+latest[15:],latest[:-1],latest.swapcase()]:
        response=c.post('/api/client/v1/pair',json={'code':invalid})
        assert response.status_code==401 and response.json['error']=='pairing_code_invalid'
    response=c.post('/api/client/v1/pair',json={'code':' \r\n'+latest+'\n\t'})
    assert response.status_code==200
    headers={'Authorization':'Bearer '+response.json['token']}
    assert c.get('/api/client/v1/me',headers=headers).status_code==200
    assert c.post('/api/client/v1/pair',json={'code':latest}).status_code==401
    with env[1].session_transaction() as session:csrf=session['csrf_token']
    revoked=env[1].post(path+'/revoke',data={'csrf_token':csrf},headers={'Accept':'text/html'})
    assert revoked.status_code==302 and revoked.location.endswith(f"/users/{d['user_id']}/devices/{d['id']}")
    assert c.get('/api/client/v1/me',headers=headers).status_code==401


def test_usage_rollup_survives_raw_purge_and_does_not_mix_devices(env):
    d=device(env,user(env)['id']);other=device(env,d['user_id']);headers,_=pair(env,d)
    with closing(connect(env[0].config['DATABASE'])) as conn:
        t=datetime(2025,1,1,10)
        record_sample(conn,{d['auth_id']:{'tx':10,'rx':20}}, {},'a',t)
        record_sample(conn,{d['auth_id']:{'tx':30,'rx':50},other['auth_id']:{'tx':999,'rx':999}}, {},'a',t+timedelta(minutes=1))
        rollup(conn);purge_old_data(conn,180);conn.commit();rollup(conn)
    result=env[1].get('/api/client/v1/usage',headers=headers).json
    assert result['retained']['upload']==20 and result['retained']['download']==30
    assert result['retained']['complete'] is False and result['fresh'] is False
    assert result['today']['upload'] is None


def test_owner_status_stale_and_backup_manifest_validation(env,tmp_path):
    d=device(env,user(env,role='owner')['id']);headers,_=pair(env,d)
    c=env[0].test_client()
    assert c.get('/api/client/v1/status',headers=headers).json['state']=='unconfigured'
    with closing(connect(env[0].config['DATABASE'])) as conn,conn:
        conn.execute('INSERT INTO client_cache VALUES(?,?,?)',('status','{"hysteria":"active"}',0))
    assert c.get('/api/client/v1/status',headers=headers).json['state']=='stale'
    env[0].config['CLIENT_BACKUP_DIR']=str(tmp_path)
    assert c.get('/api/client/v1/backup',headers=headers).json['latest'] is None
    assert c.get('/api/client/v1/backup/download',headers=headers).status_code==404
    (tmp_path/'latest.json').write_text('{"name":"../../etc/passwd"}')
    assert c.get('/api/client/v1/backup',headers=headers).status_code==503


def test_speed_limits_and_subscription_capability(env):
    d=device(env,user(env)['id']);headers,_=pair(env,d);c=env[0].test_client()
    assert subscription(env,d).headers['Qingzhou-Client-API']=='/api/client/v1'
    response=c.get('/api/client/v1/speed/download',headers=headers)
    assert len(response.data)==8*1024*1024
    assert c.get('/api/client/v1/speed/download',headers=headers).status_code==429
    assert c.post('/api/client/v1/speed/upload',data=b'a'*1024,headers=headers).json['bytes']==1024
    assert c.post('/api/client/v1/speed/upload',data=b'',headers=headers).status_code==429


def test_cloud_binding_paging_and_shared_package():
    calls=[]
    def api(action,payload):
        calls.append((action,payload))
        if action=='DescribeInstances':return {'InstanceSet':[{'InternetAccessible':{'InternetChargeType':'BANDWIDTH_PREPAID'}}]}
        if action=='DescribeAddresses':return {'AddressSet':[{'AddressId':'eip-bound'}]}
        if action=='DescribeTrafficPackages':return {'TrafficPackageSet':[{'TrafficPackageId':'tfp-1'}]}
        if action=='DescribeSpecificTrafficPackageUsedDetails':return {'UsedDetailSet':[{'ResourceId':'eip-bound'}]}
        if action=='DescribeBillDetail':
            if payload['Offset']==0:return {'Total':2,'DetailSet':[{'ResourceId':payload['ResourceId'],'ComponentSet':[]}]}
            return {'Total':2,'DetailSet':[{'ResourceId':'unrelated','ComponentSet':[]}]}
        raise AssertionError(action)
    result=fetch_billing({'instance_id':'ins-bound','package_ids':['tfp-1']},{k:api for k in ['cvm','vpc','billing']})
    assert len(result['bills'])==2
    assert result['packages'][0]['scope']=='shared_package'
    assert all(b['ResourceId'] in ['ins-bound','eip-bound'] for b in result['bills'])
    assert any(p.get('Offset')==1 for _,p in calls)


def test_backup_no_recipient_skips(env,tmp_path):
    from backup_job import create_backup
    assert create_backup(env[0].config['DATABASE'],tmp_path,tmp_path/'out') is None

@pytest.mark.parametrize('action',['disable','rotate'])
def test_device_action_revokes_client_token_and_pairing(env,action):
    u=user(env);d=device(env,u['id']);headers,_=pair(env,d)
    assert post(env,f"/users/{u['id']}/devices/{d['id']}",action=action).status_code==302
    assert env[0].test_client().get('/api/client/v1/me',headers=headers).status_code==401
    assert query(env,'SELECT * FROM client_access')==[]
    assert query(env,'SELECT * FROM client_pairings')==[]


def test_pair_input_disabled_device_and_per_ip_limit(env):
    c=env[0].test_client()
    for body in [[1],{'code':2},{'code':'a'*129}]:
        assert c.post('/api/client/v1/pair',json=body).status_code==400
    for _ in range(7):assert c.post('/api/client/v1/pair',json={'code':'missing'}).status_code==401
    assert c.post('/api/client/v1/pair',json={'code':'missing'}).status_code==429
    d=device(env,user(env)['id'])
    assert post(env,f"/users/{d['user_id']}/devices/{d['id']}",action='disable').status_code==302
    assert post(env,f"/client-access/{d['id']}").status_code==404


def test_pending_kick_and_invalid_authorization(env):
    d=device(env,user(env)['id']);headers,_=pair(env,d);c=env[0].test_client()
    assert c.get('/api/client/v1/me',headers=headers).json['owner'] is False
    for value in ['','Basic synthetic','Bearer x','Bearer '+'x'*129]:
        assert c.get('/api/client/v1/me',headers={'Authorization':value}).status_code==401
    from devices import queue_kick
    with closing(connect(env[0].config['DATABASE'])) as conn,conn:queue_kick(conn,d['auth_id'])
    assert c.get('/api/client/v1/me',headers=headers).status_code==401


def test_recipient_validation_owner_and_immutable_key(env,tmp_path,monkeypatch):
    import subprocess
    d=device(env,user(env,role='owner')['id']);headers,_=pair(env,d);c=env[0].test_client()
    for body in [[1],{'recipient':3},{'recipient':'bad'}]:
        assert c.post('/api/client/v1/backup/recipient',json=body,headers=headers).status_code==400
    payload={'recipient':'age1'+'a'*58}
    env[0].config['AGE_PATH']=None
    assert c.post('/api/client/v1/backup/recipient',json=payload,headers=headers).status_code==503
    env[0].config['AGE_PATH']='/fixture/age'
    def reject(*args,**kwargs):raise subprocess.TimeoutExpired('age',3)
    monkeypatch.setattr(subprocess,'run',reject)
    assert c.post('/api/client/v1/backup/recipient',json=payload,headers=headers).status_code==400
    monkeypatch.setattr(subprocess,'run',lambda *a,**kw:None)
    assert c.post('/api/client/v1/backup/recipient',json=payload,headers=headers).status_code==200
    assert c.post('/api/client/v1/backup/recipient',json=payload,headers=headers).status_code==200
    assert c.post('/api/client/v1/backup/recipient',json={'recipient':'age1'+'b'*58},headers=headers).status_code==409
    env[0].config['CLIENT_BACKUP_DIR']=str(tmp_path)
    name='backup-20261021T000000Z.tar.age';data=b'encrypted-fixture';(tmp_path/name).write_bytes(data)
    (tmp_path/'latest.json').write_text(json.dumps({'name':name,'size':len(data),'sha256':'a'*64}))
    assert c.get('/api/client/v1/backup',headers=headers).json['configured'] is True
    assert c.get('/api/client/v1/backup/download',headers=headers).data==data
    for broken in ['{','[]','{"name":3}']:
        (tmp_path/'latest.json').write_text(broken)
        assert c.get('/api/client/v1/backup',headers=headers).status_code==503


def test_usage_today_fresh_and_archive_update(env):
    d=device(env,user(env)['id']);headers,_=pair(env,d)
    with closing(connect(env[0].config['DATABASE'])) as conn:
        t=datetime.utcnow()
        record_sample(conn,{d['auth_id']:{'tx':10,'rx':20}}, {},'a',t-timedelta(minutes=1))
        record_sample(conn,{d['auth_id']:{'tx':30,'rx':50}}, {},'a',t)
        rollup(conn);rollup(conn)
    r=env[1].get('/api/client/v1/usage',headers=headers).json
    assert r['fresh'] is True and r['today']['upload']==20 and r['month']['download']==30


def test_upload_size_download_timeout_and_shared_rate_limit(env,monkeypatch):
    import client_api
    d=device(env,user(env)['id']);headers,_=pair(env,d);c=env[0].test_client()
    assert c.post('/api/client/v1/speed/upload',data=b'x'*(8*1024*1024+1),headers=headers).status_code==413
    with closing(connect(env[0].config['DATABASE'])) as conn,conn:conn.execute('DELETE FROM client_limits')
    stamps=iter([0,6]);monkeypatch.setattr(client_api.time,'monotonic',lambda:next(stamps))
    assert c.post('/api/client/v1/speed/upload',data=b'x',headers=headers).status_code==408
    stamps=iter([0,6]);assert c.get('/api/client/v1/speed/download',headers=headers).data==b''
    with closing(connect(env[0].config['DATABASE'])) as conn,conn:
        conn.execute('INSERT OR REPLACE INTO client_limits VALUES(?,?,120)',('client:'+str(d['id']),int(time.time())))
    assert c.get('/api/client/v1/me',headers=headers).status_code==429


def test_cloud_current_package_does_not_use_historical_remaining():
    def api(action,payload):
        if action=='DescribeInstances':return {'InstanceSet':[{}]}
        if action=='DescribeAddresses':return {'AddressSet':[{'AddressId':'eip-bound'}]}
        if action=='DescribeTrafficPackages':return {'TrafficPackageSet':[{'TotalAmount':100,'RemainingAmount':35,'CreatedTime':'2026-10-01','Deadline':'2026-11-01'}]}
        if action=='DescribeSpecificTrafficPackageUsedDetails':return {'TotalCount':2,'UsedDetailSet':[
            {'ResourceId':'eip-bound','Time':'2026-10-20','RemainingAmount':{'Value':999},'Deduction':{'Value':123}},
            {'ResourceId':'unrelated','Time':'2026-10-21','RemainingAmount':{'Value':888}}]}
        if action=='DescribeBillDetail':return {'DetailSet':[]}
    r=fetch_billing({'instance_id':'ins-bound','package_ids':['tfp-1']},{k:api for k in ['cvm','vpc','billing']})['packages'][0]
    assert r['total_gb']==100 and r['remaining_gb']==35
    assert r['last_bound_deduction_bytes']==123 and 'remaining_bytes' not in r
    with pytest.raises(ValueError,match='bound_instance_not_found'):
        fetch_billing({'instance_id':'ins-bound'},{'cvm':lambda *a:{'InstanceSet':[]}})


def test_lighthouse_bound_package_bytes_and_bill_filter():
    calls=[]
    def api(action,payload):
        calls.append((action,payload))
        assert payload.get('InstanceIds',[payload.get('ResourceId')])==['lhins-bound']
        if action=='DescribeInstances':return {'InstanceSet':[{'InstanceId':'lhins-bound','ExpiredTime':'2027-09-15T13:22:51Z'}]}
        if action=='DescribeInstancesTrafficPackages':return {'InstanceTrafficPackageSet':[
            {'InstanceId':'lhins-unrelated','TrafficPackageSet':[{'TrafficPackageTotal':1}]},
            {'InstanceId':'lhins-bound','TrafficPackageSet':[{'TrafficPackageId':'lhtfp-bound',
                'TrafficPackageTotal':1536*1024**3,'TrafficPackageRemaining':1496*1024**3,
                'TrafficUsed':40*1024**3,'TrafficOverflow':0,'StartTime':'start','EndTime':'end','Deadline':'deadline'},
                {'TrafficPackageId':'lhtfp-unknown','TrafficPackageTotal':None}]}]}
        if action=='DescribeBillDetail':return {'Total':2,'DetailSet':[
            {'ResourceId':'lhins-bound','ComponentSet':[{'RealCost':'1.00','InternalSecret':'excluded'}]},
            {'ResourceId':'lhins-unrelated','ComponentSet':[]}]}
        raise AssertionError('不应调用 CVM/VPC 接口')
    result=fetch_billing({'instance_id':'lhins-bound','package_ids':['ignored-cvm-package']},
                         {'lighthouse':api,'billing':api})
    assert result['resource_type']=='lighthouse'
    assert result['expires']=='2027-09-15T13:22:51Z'
    p=result['packages'][0]
    assert p['scope']=='instance_package' and p['unit']=='GiB'
    assert p['total_gb']==1536 and p['remaining_gb']==1496
    assert p['total_bytes']==1536*1024**3 and p['used_bytes']==40*1024**3
    assert p['cycle']=='start/end' and p['expires']=='deadline'
    assert result['packages'][1]['total_gb'] is None
    assert len(result['bills'])==1 and result['bills'][0]['ComponentSet']==[{
        'ComponentCodeName':None,'UsedAmount':None,'UsedAmountUnit':None,'RealCost':'1.00'}]
    assert len(calls)==3


@pytest.mark.parametrize('case',['unsupported','wrong-instance','missing-package','duplicate-package'])
def test_lighthouse_rejects_ambiguous_resource(case):
    def api(action,payload):
        if action=='DescribeInstances':return {'InstanceSet':[{'InstanceId':'lhins-wrong' if case=='wrong-instance' else 'lhins-bound'}]}
        if action=='DescribeInstancesTrafficPackages':return {'InstanceTrafficPackageSet':
            [] if case=='missing-package' else [{'InstanceId':'lhins-bound'},{'InstanceId':'lhins-bound'}]}
        raise AssertionError('绑定异常不能查询账单')
    config={'instance_id':'lhins-bound'}
    if case=='unsupported':config['resource_type']='unsupported'
    with pytest.raises(ValueError):fetch_billing(config,{'lighthouse':api})


def test_lighthouse_sdk_collection(env,monkeypatch):
    import client_jobs
    from tencentcloud.common import credential
    from tencentcloud.lighthouse.v20200324 import lighthouse_client
    from tencentcloud.billing.v20180709 import billing_client
    class Provider:
        def get_credential(self):return object()
    class Reply:
        def __init__(self,value):self.value=value
        def to_json_string(self):return json.dumps(self.value)
    class Client:
        def __init__(self,*args):pass
        def DescribeInstances(self,r):
            assert r.InstanceIds==['lhins-fixture']
            return Reply({'InstanceSet':[{'InstanceId':'lhins-fixture'}]})
        def DescribeInstancesTrafficPackages(self,r):
            assert r.InstanceIds==['lhins-fixture']
            return Reply({'InstanceTrafficPackageSet':[{'InstanceId':'lhins-fixture','TrafficPackageSet':[]}]})
        def DescribeBillDetail(self,r):
            assert r.ResourceId=='lhins-fixture'
            return Reply({'Total':0,'DetailSet':[]})
    monkeypatch.setattr(credential,'DefaultCredentialProvider',Provider)
    monkeypatch.setattr(lighthouse_client,'LighthouseClient',Client)
    monkeypatch.setattr(billing_client,'BillingClient',Client)
    monkeypatch.setenv('HY2_CLOUD_INSTANCE_ID','lhins-fixture')
    monkeypatch.setenv('HY2_CLOUD_REGION','ap-singapore')
    monkeypatch.setenv('HY2_CLOUD_RESOURCE_TYPE','lighthouse')
    with closing(connect(env[0].config['DATABASE'])) as conn:client_jobs.cloud_main(conn)
    data=json.loads(query(env,"SELECT value FROM client_cache WHERE key='billing'")[0]['value'])
    assert data['configured'] is True and data['resource_type']=='lighthouse' and data['bills']==[]


def test_cloud_unconfigured_and_sdk_contract(env,monkeypatch):
    from client_jobs import cloud_main
    monkeypatch.delenv('HY2_CLOUD_INSTANCE_ID',raising=False)
    with closing(connect(env[0].config['DATABASE'])) as conn:cloud_main(conn)
    assert json.loads(query(env,"SELECT value FROM client_cache WHERE key='billing'")[0]['value'])=={'configured':False}
    credential=pytest.importorskip('tencentcloud.common.credential')
    from tencentcloud.vpc.v20170312 import models
    assert callable(credential.DefaultCredentialProvider)
    response=models.DescribeSpecificTrafficPackageUsedDetailsResponse()
    response.from_json_string('{"TotalCount":1,"UsedDetailSet":[{"ResourceId":"eip-fixture","Deduction":{"Value":123}}]}')
    assert json.loads(response.to_json_string())['UsedDetailSet'][0]['Deduction']['Value']==123


def test_cloud_sdk_collection_and_local_fault_isolation(env,monkeypatch):
    import client_jobs,helper
    from tencentcloud.common import credential
    from tencentcloud.cvm.v20170312 import cvm_client
    from tencentcloud.vpc.v20170312 import vpc_client
    from tencentcloud.billing.v20180709 import billing_client
    class Provider:
        def get_credential(self):return object()
    class Reply:
        def __init__(self,value):self.value=value
        def to_json_string(self):return json.dumps(self.value)
    class Client:
        def __init__(self,*a):pass
        def DescribeInstances(self,r):return Reply({'InstanceSet':[{}]})
        def DescribeAddresses(self,r):return Reply({'AddressSet':[]})
        def DescribeBillDetail(self,r):return Reply({'Total':1,'DetailSet':[{'ResourceId':'ins-fixture','ComponentSet':[{'RealCost':'1.00','UsedAmount':'2','UsedAmountUnit':'GB'}]}]})
    monkeypatch.setattr(credential,'DefaultCredentialProvider',Provider)
    for module,name in [(cvm_client,'CvmClient'),(vpc_client,'VpcClient'),(billing_client,'BillingClient')]:monkeypatch.setattr(module,name,Client)
    monkeypatch.setenv('HY2_CLOUD_INSTANCE_ID','ins-fixture');monkeypatch.setenv('HY2_CLOUD_REGION','ap-singapore')
    monkeypatch.setenv('HY2_CLOUD_PACKAGE_IDS','')
    with closing(connect(env[0].config['DATABASE'])) as conn:
        client_jobs.cloud_main(conn)
        def failed(*a,**k):raise OSError('fixture')
        monkeypatch.setattr(helper.OperationsHelper,'call',failed)
        monkeypatch.setattr(client_jobs.socket,'create_connection',failed)
        client_jobs.refresh_local(conn)
    data={r['key']:json.loads(r['value']) for r in query(env,'SELECT * FROM client_cache')}
    assert data['billing']['configured'] is True
    assert data['billing']['bills'][0]['ComponentSet'][0]['RealCost']=='1.00'
    assert data['status']['hysteria']=='unknown' and data['status']['certificate_expires'] is None


def test_real_backup_roundtrip_retention_and_failure_atomicity(env,tmp_path,monkeypatch):
    import os,subprocess,sqlite3,tarfile
    import backup_job
    tools=Path(os.environ['AGE_TEST_TOOLS']);identity=tmp_path/'key'
    subprocess.run([str(tools/'age-keygen'),'-o',str(identity)],check=True,capture_output=True)
    public=subprocess.run([str(tools/'age-keygen'),'-y',str(identity)],check=True,capture_output=True,text=True).stdout.strip()
    with closing(connect(env[0].config['DATABASE'])) as conn,conn:
        conn.execute("INSERT INTO settings VALUES('backup_recipient',?)",(public,))
    source=tmp_path/'source';source.mkdir();(source/'app.py').write_text('fixture')
    (source/'.venv').mkdir();(source/'.venv'/'private').write_text('EXCLUDED')
    (source/'symlink').symlink_to(source/'app.py');(source/'nested').mkdir()
    config=tmp_path/'hy2-admin.env';config.write_text('APP_KEY=fixture\nTENCENTCLOUD_SECRET_ID=EXCLUDED\nHY2_CLOUD_REGION=EXCLUDED\n  TENCENTCLOUD_SECRET_KEY=EXCLUDED\nexport TENCENTCLOUD_TOKEN=EXCLUDED\n')
    unit=tmp_path/'fixture.service';unit.write_text('fixture service')
    absent=tmp_path/'missing';output=tmp_path/'backups';output.mkdir()
    for i in range(1,29):(output/f'backup-202609{i:02d}T000000Z.tar.age').write_bytes(b'old')
    manifest=backup_job.create_backup(env[0].config['DATABASE'],source,output,str(tools/'age'),(config,unit,absent),tmp_path)
    assert manifest['sha256']==__import__('hashlib').sha256((output/manifest['name']).read_bytes()).hexdigest()
    assert len(list(output.glob('*.age')))<=11
    raw=tmp_path/'restored.tar'
    subprocess.run([str(tools/'age'),'-d','-i',str(identity),'-o',str(raw),str(output/manifest['name'])],check=True,capture_output=True)
    with tarfile.open(raw) as tf:
        env_entry='config/'+str(config).lstrip('/');unit_entry='config/'+str(unit).lstrip('/')
        assert sorted(tf.getnames())==sorted([env_entry,unit_entry,'database.sqlite3','program/app.py','runtime.json'])
        assert 'EXCLUDED' not in tf.extractfile(env_entry).read().decode()
        restored=tmp_path/'restore.sqlite3';restored.write_bytes(tf.extractfile('database.sqlite3').read())
    with sqlite3.connect(restored) as conn:assert conn.execute('PRAGMA integrity_check').fetchone()[0]=='ok'
    before=(output/'latest.json').read_bytes()
    with pytest.raises(subprocess.CalledProcessError):
        backup_job.create_backup(env[0].config['DATABASE'],source,output,'/bin/false',work_dir=tmp_path)
    assert (output/'latest.json').read_bytes()==before and not list(output.glob('*.partial'))
    monkeypatch.setattr(backup_job.shutil,'disk_usage',lambda p:type('Disk',(),{'free':0})())
    with pytest.raises(RuntimeError,match='磁盘空间不足'):
        backup_job.create_backup(env[0].config['DATABASE'],source,output,str(tools/'age'),work_dir=tmp_path)


def test_backup_oversize_is_not_published(env,tmp_path,monkeypatch):
    import backup_job
    d=device(env,user(env,role='owner')['id']);headers,_=pair(env,d)
    with closing(connect(env[0].config['DATABASE'])) as conn,conn:
        conn.execute("INSERT INTO settings VALUES('backup_recipient','fixture')")
    def oversized(argv,**kw):
        with open(argv[4],'wb') as stream:stream.truncate(512*1024*1024+1)
    monkeypatch.setattr(backup_job.subprocess,'run',oversized)
    source=tmp_path/'source';source.mkdir();output=tmp_path/'output'
    with pytest.raises(RuntimeError,match='超过客户端同步上限'):
        backup_job.create_backup(env[0].config['DATABASE'],source,output,work_dir=tmp_path)
    assert not list(output.iterdir())
