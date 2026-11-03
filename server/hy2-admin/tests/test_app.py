import hashlib
import json
from datetime import datetime, timedelta
from contextlib import closing

import pyotp
import pytest
import yaml
from cryptography.fernet import Fernet

from app import create_app, safe_next
from auth_service import create_auth_app
from db import connect, init_db, audit, purge_old_data
from devices import retry_kicks
from metrics import record_sample, overview
from security import PH

TOTP='JBSWY3DPEHPK3PXP'
PASSWORD='test-admin-password'


@pytest.fixture
def env(tmp_path):
    kicked=[]
    cfg={'TESTING':True,'DATABASE':tmp_path/'test.db','SECRET_KEY':'testing-secret','ENCRYPTION_KEY':Fernet.generate_key(),
         'SESSION_COOKIE_SECURE':False,'STATS_URL':'http://stats.test','STATS_SECRET':'test-stats-secret',
         'PUBLIC_BASE_URL':'http://localhost','KICK_RUNNER':lambda url,secret,ids:kicked.extend(ids),
         'OPERATION_RUNNER':lambda op,payload=None:{'ok':True,'hysteria':'active','nginx':'active','auth':'active','generation':'a'}}
    app=create_app(cfg)
    with closing(connect(cfg['DATABASE'])) as conn,conn:
        conn.execute('INSERT INTO admins(username,password_hash,totp_secret,must_change_password) VALUES(?,?,?,0)',
                     ('admin',PH.hash(PASSWORD),app.fernet.encrypt(TOTP.encode())))
    client=app.test_client()
    client.get('/login')
    with client.session_transaction() as session: token=session['csrf_token']
    assert client.post('/login',data={'username':'admin','password':PASSWORD,'totp':pyotp.TOTP(TOTP).now(),'csrf_token':token}).status_code==302
    return app,client,create_auth_app(cfg).test_client(),kicked


def post(env,path,**data):
    client=env[1]
    with client.session_transaction() as session: data['csrf_token']=session['csrf_token']
    return client.post(path,data=data)


def query(env,sql,params=()):
    with closing(connect(env[0].config['DATABASE'])) as conn:
        return conn.execute(sql,params).fetchall()


def user(env,name='alice',role='user'):
    result=post(env,'/users',username=name,display_name=name,role=role,note='test')
    assert result.status_code==302
    return query(env,'SELECT * FROM proxy_users WHERE username=?',(name,))[0]


def device(env,uid,name='Phone',client='hy2'):
    result=post(env,f'/users/{uid}/devices',name=name,platform='iOS / iPadOS',client=client,note='test')
    assert result.status_code==302
    return query(env,'SELECT * FROM devices ORDER BY id DESC LIMIT 1')[0]


def auth(env,d,password=None):
    if password is None: password=env[0].fernet.decrypt(d['encrypted_password']).decode()
    return env[2].post('/auth',json={'auth':d['auth_id']+':'+password}).json['ok']


def subscription(env,d,fmt='hy2.txt'):
    token=env[0].fernet.decrypt(d['encrypted_token']).decode()
    return env[1].get(f'/s/{token}/{fmt}')


def test_login_redirect_csrf_and_expiry(env):
    anonymous=env[0].test_client()
    assert anonymous.get('/users?q=hello').location.endswith('/login?next=/users?q%3Dhello')
    assert anonymous.get('/api/overview').status_code==401
    assert anonymous.post('/login',data={}).status_code==400
    assert env[1].post('/users',data={'username':'x'}).status_code==400
    assert post(env,'/logout').status_code==302
    assert env[1].get('/users').status_code==302


@pytest.mark.parametrize('value', ['https://evil.test','//evil.test','/\\evil.test','javascript:alert(1)','foo'])
def test_safe_next(value):
    assert safe_next(value)=='/'


def test_login_next_and_password_change(env):
    client=env[0].test_client();client.get('/login')
    with client.session_transaction() as s: csrf=s['csrf_token']
    assert client.post('/login?next=/users',data={'csrf_token':csrf,'username':'admin','password':PASSWORD,'totp':pyotp.TOTP(TOTP).now()}).location=='/users'
    assert post(env,'/security',current_password='wrong',totp=pyotp.TOTP(TOTP).now(),new_password='new-password-long').status_code==400
    assert post(env,'/security',current_password=PASSWORD,totp=pyotp.TOTP(TOTP).now(),new_password='new-password-long').status_code==302
    assert query(env,"SELECT action FROM audit_log WHERE action='change_admin_password'")


def test_user_validation_edit_filters_and_duplicates(env):
    u=user(env)
    assert post(env,'/users',username='bad:user',display_name='X').status_code==400
    assert post(env,'/users',username='bob',display_name='X',role='admin').status_code==400
    assert post(env,'/users',username='alice',display_name='Dup').status_code==302
    assert len(query(env,'SELECT * FROM proxy_users'))==1
    assert post(env,f"/users/{u['id']}",action='edit',display_name='New name',note='updated').status_code==302
    assert query(env,'SELECT username,display_name FROM proxy_users')[0]['username']=='alice'
    assert b'New name' in env[1].get('/users?q=New').data
    assert b'New name' not in env[1].get('/users?q=missing').data
    assert post(env,f"/users/{u['id']}",action='nonsense').status_code==400


def test_user_pagination_and_dashboard_preview(env):
    with closing(connect(env[0].config['DATABASE'])) as conn, conn:
        for index in range(25):
            name = f'person{index:02d}'
            conn.execute('INSERT INTO proxy_users(username,display_name,role,encrypted_password,encrypted_token) VALUES(?,?,?,?,?)',
                         (name, name, 'user', b'x', b'y'))
        audit(conn, 'admin', 'first_action', 'person00')
        audit(conn, 'admin', 'latest_action', 'person24')
    first = env[1].get('/users').data
    second = env[1].get('/users?page=2').data
    assert b'person00' in first and b'person19' in first and b'person20' not in first
    assert b'person20' in second and b'person00' not in second
    assert b'person24' in env[1].get('/users?page=999').data
    assert b'person24' in env[1].get('/users?q=person2').data
    assert b'person19' not in env[1].get('/users?q=person2').data
    dashboard = env[1].get('/').data
    assert b'person00' in dashboard and b'person08' not in dashboard
    assert b'latest_action' in dashboard


def test_device_authentication_formats_and_legacy_invalidation(env):
    u=user(env);d=device(env,u['id'])
    assert auth(env,d)
    assert not auth(env,d,'wrong')
    old_token=env[0].fernet.decrypt(u['encrypted_token']).decode()
    assert env[1].get('/s/'+old_token+'/hy2.txt').status_code==404
    assert not env[2].post('/auth',json={'auth':u['username']+':'+env[0].fernet.decrypt(u['encrypted_password']).decode()}).json['ok']
    for fmt,ctype in [('hy2.txt','text/plain'),('shadowrocket.conf','text/plain'),('shadowrocket-full.conf','text/plain'),('mihomo.yaml','application/yaml'),('sing-box.json','application/json')]:
        response=subscription(env,d,fmt)
        assert response.status_code==200 and response.content_type.startswith(ctype)
        assert response.headers['Cache-Control']=='no-store'
        assert response.headers['X-Robots-Tag']=='noindex, nofollow'
    assert subscription(env,d,'unknown').status_code==404
    assert env[1].get(f"/qr/{d['id']}/hy2").content_type=='image/png'
    assert env[1].get(f"/qr/{d['id']}/invalid").status_code==404
    assert len(env[3])==0


def test_device_isolation_disable_and_rotation(env):
    u=user(env);a=device(env,u['id'],'Phone');b=device(env,u['id'],'Laptop')
    path=f"/users/{u['id']}/devices/{a['id']}"
    assert post(env,path,action='disable').status_code==302
    assert not auth(env,a) and auth(env,b)
    assert subscription(env,a).status_code==404 and subscription(env,b).status_code==200
    assert env[3]==[a['auth_id']]
    assert post(env,path,action='enable').status_code==302
    assert auth(env,a)
    assert post(env,path,action='rotate').status_code==302
    new=query(env,'SELECT * FROM devices WHERE id=?',(a['id'],))[0]
    assert new['auth_id']==a['auth_id']
    assert not auth(env,a) and auth(env,new) and auth(env,b)
    assert subscription(env,a).status_code==404 and subscription(env,new).status_code==200
    other=user(env,'bob')
    assert env[1].get(f"/users/{other['id']}/devices/{a['id']}").status_code==404
    assert post(env,f"/users/{other['id']}/devices/{a['id']}",action='disable').status_code==404


def test_parent_enable_preserves_device_disabled_state(env):
    u=user(env);a=device(env,u['id']);b=device(env,u['id'],'Laptop')
    post(env,f"/users/{u['id']}/devices/{a['id']}",action='disable')
    post(env,f"/users/{u['id']}",action='disable')
    assert not auth(env,a) and not auth(env,b)
    post(env,f"/users/{u['id']}",action='enable')
    assert not auth(env,a) and auth(env,b)


def test_owner_requires_second_factor(env):
    u=user(env,'owner','owner');d=device(env,u['id'])
    path=f"/users/{u['id']}/devices/{d['id']}"
    for action in ('rotate','disable'):
        assert post(env,path,action=action).status_code==403
    assert post(env,f"/users/{u['id']}",action='disable').status_code==403
    assert auth(env,d)
    assert post(env,path,action='disable',admin_password=PASSWORD,admin_totp=pyotp.TOTP(TOTP).now()).status_code==302
    assert not auth(env,d)
    assert post(env,f"/users/{u['id']}",action='disable',admin_password=PASSWORD,admin_totp=pyotp.TOTP(TOTP).now()).status_code==302


def test_failed_kick_is_durable_and_fail_closed_until_retry(env):
    u=user(env);d=device(env,u['id']);other=device(env,u['id'],'Other')
    def fail(*args): raise TimeoutError()
    env[0].config['KICK_RUNNER']=fail
    post(env,f"/users/{u['id']}/devices/{d['id']}",action='rotate')
    updated=query(env,'SELECT * FROM devices WHERE id=?',(d['id'],))[0]
    assert not auth(env,d) and not auth(env,updated) and auth(env,other)
    assert query(env,'SELECT attempts FROM pending_kicks')[0]['attempts']==1
    # A new independent auth app sees the committed revocation, even if web restarts.
    auth2=create_auth_app(env[0].config).test_client()
    assert not auth2.post('/auth',json={'auth':updated['auth_id']+':'+env[0].fernet.decrypt(updated['encrypted_password']).decode()}).json['ok']
    env[0].config['KICK_RUNNER']=lambda *args:None
    post(env,'/operations',operation='retry-kicks')
    assert not query(env,'SELECT * FROM pending_kicks')
    assert auth(env,updated)


@pytest.mark.parametrize('payload', [None, [], {}, {'auth':123}, {'auth':'x'}, {'auth':'x'*300}])
def test_auth_malformed_requests(env,payload):
    assert env[2].post('/auth',json=payload).json=={'ok':False}


def test_auth_not_public_and_database_failure(env):
    assert env[2].post('/auth',json={'auth':'a:b'},environ_base={'REMOTE_ADDR':'8.8.8.8'}).status_code==403
    assert env[1].post('/auth',json={'auth':'a:b'}).status_code==404
    assert env[2].post('/auth',data='x'*5000,content_type='application/json').status_code==413
    app=create_auth_app({'DATABASE':'/nonexistent-parent/no.db','ENCRYPTION_KEY':env[0].config['ENCRYPTION_KEY']})
    assert app.test_client().post('/auth',json={'auth':'a:b'}).status_code==503


def test_device_edit_and_bad_inputs(env):
    u=user(env);d=device(env,u['id']);path=f"/users/{u['id']}/devices/{d['id']}"
    assert post(env,path,action='edit',name='Changed',platform='macOS',client='mihomo',note='updated').status_code==302
    assert query(env,'SELECT name FROM devices')[0]['name']=='Changed'
    assert post(env,path,action='unknown').status_code==400
    assert post(env,f"/users/{u['id']}/devices",name='',platform='macOS',client='hy2').status_code==400
    assert post(env,f"/users/{u['id']}/devices",name='x',platform='bad',client='hy2').status_code==400
    assert env[1].get('/users/9999').status_code==404
    other=device(env,u['id'],'Hiddify device',client='hiddify')
    assert env[1].get(f"/users/{u['id']}/devices/{other['id']}").status_code==200


def test_all_pages_and_filters_render(env):
    u=user(env);d=device(env,u['id'])
    for path in ('/','/?period=7d','/?period=30d','/users','/users?status=1',f"/users/{u['id']}",f"/users/{u['id']}/devices/{d['id']}",'/operations','/audit','/security'):
        assert env[1].get(path).status_code==200,path
    for kind in ('hy2','shadowrocket','shadowrocket-full','mihomo','sing-box','unknown'):
        assert env[1].get(f"/users/{u['id']}/devices/{d['id']}?client={kind}").status_code==200
    assert env[1].get('/api/overview').json['metrics']['online'] is None
    assert env[1].get('/audit?start=invalid').status_code==400
    assert env[1].get('/audit?start=2026-01-01&end=2026-12-31&action=create_device&page=2').status_code==200
    assert post(env,'/operations',operation='rollback').status_code==400
    assert post(env,'/operations',operation='reload').status_code==302


def test_audit_filters_pagination_and_sensitive_data(env):
    u=user(env);d=device(env,u['id'])
    with closing(connect(env[0].config['DATABASE'])) as conn,conn:
        for i in range(65): audit(conn,'admin','edit_user','alice')
        with pytest.raises(ValueError): audit(conn,'admin','x','alice','password=secret')
        conn.execute("INSERT INTO audit_log(actor,action,created_at) VALUES('old','old','2000-01-01')")
        purge_old_data(conn,180)
    assert not query(env,"SELECT 1 FROM audit_log WHERE actor='old'")
    assert env[1].get('/audit?action=edit_user&target=alice&page=2').status_code==200
    records=str([dict(r) for r in query(env,'SELECT * FROM audit_log')])
    assert env[0].fernet.decrypt(d['encrypted_password']).decode() not in records
    assert env[0].fernet.decrypt(d['encrypted_token']).decode() not in records


def test_statistics_deltas_duplicates_restarts_gaps_and_no_traffic_online(env):
    u=user(env);d=device(env,u['id'])
    start=datetime(2026,9,20,2,0)
    with closing(connect(env[0].config['DATABASE'])) as conn:
        def sample(minute,tx,rx,gen='a',online=1):
            record_sample(conn,{d['auth_id']:{'tx':tx,'rx':rx}},{d['auth_id']:online},gen,start+timedelta(minutes=minute))
        sample(0,100,200);sample(1,150,300);sample(1,999,999)
        assert conn.execute('SELECT COUNT(*) FROM metric_samples').fetchone()[0]==2
        latest=conn.execute('SELECT * FROM device_samples ORDER BY sample_id DESC LIMIT 1').fetchone()
        assert (latest['delta_tx'],latest['delta_rx'])==(50,100)
        sample(2,10,20,'b') # new generation, do not bridge reset
        sample(3,20,40,'b')
        sample(4,1,2,'b') # counter reset even without generation change
        sample(7,11,22,'b') # missed collection gap
        record_sample(conn,None,None,None,start+timedelta(minutes=8))
        sample(9,31,42,'b')
        sample(10,31,42,'b') # online, but no additional traffic
        assert conn.execute('SELECT SUM(delta_tx),SUM(delta_rx) FROM device_samples').fetchone()[:]==(60,120)
        latest=conn.execute('SELECT * FROM device_samples ORDER BY sample_id DESC LIMIT 1').fetchone()
        assert latest['online']==1 and latest['delta_tx']==0
        result=overview(conn,now=start+timedelta(minutes=10))
        assert result['tx']==60 and result['rx']==120 and result['online']==1 and not result['complete']
        assert overview(conn,user_id=u['id'],now=start+timedelta(minutes=10))['rx']==120
        assert overview(conn,device_id=d['id'],now=start+timedelta(minutes=10))['rx']==120
        assert overview(conn,now=start+timedelta(minutes=14))['online'] is None
    assert query(env,'SELECT last_online_at FROM devices')[0]['last_online_at']=='2026-09-20 02:10:00'


def test_online_without_traffic_and_retention(env):
    u=user(env);d=device(env,u['id'])
    with closing(connect(env[0].config['DATABASE'])) as conn:
        record_sample(conn,{}, {d['auth_id']:2},'a',datetime(2000,1,1))
        assert conn.execute('SELECT online,tx FROM device_samples').fetchone()[:]==(2,0)
        purge_old_data(conn,180);conn.commit()
        assert conn.execute('SELECT COUNT(*) FROM device_samples').fetchone()[0]==0
    init_db(env[0].config['DATABASE']) # idempotent migration preserves existing records
    assert len(query(env,'SELECT * FROM devices'))==1

def test_fail_closed_and_uri_encoding(tmp_path):
    import pytest
    with pytest.raises(RuntimeError): create_app({'DATABASE':tmp_path/'z.db','SECRET_KEY':'x','ENCRYPTION_KEY':None})
    from subscriptions import render_subscription
    assert 'alice%3Apa%2Fss' in render_subscription('hy2','alice','x',443,'pa/ss')
    mihomo = yaml.safe_load(render_subscription('mihomo','alice','x',443,'pa/ss'))
    assert mihomo['proxies'][0]['password'] == 'alice:pa/ss'
    assert mihomo['proxy-groups'][0]['proxies'][0] == 'alice'
    assert mihomo['rules'][-1] == 'MATCH,PROXY'
    assert mihomo['dns']['fallback'][0].endswith('#PROXY')
    singbox = json.loads(render_subscription('sing-box','alice','x',443,'pa/ss'))
    assert singbox['outbounds'][0]['password'] == 'alice:pa/ss'
    assert singbox['route']['final'] == 'proxy'
    assert singbox['dns']['final'] == 'dns-global'

def test_complete_client_configs_and_safe_shadowrocket_label():
    from subscriptions import render_subscription
    shadowrocket = render_subscription('shadowrocket-full','alice','x',443,'secret',display_name='A,=\nB')
    assert '[General]' in shadowrocket
    assert '[Proxy]' in shadowrocket
    assert '[Proxy Group]' in shadowrocket
    assert '[Rule]' in shadowrocket
    assert 'FINAL,PROXY' in shadowrocket
    assert 'A_B = hysteria2' in shadowrocket

    import pytest
    with pytest.raises(ValueError):
        render_subscription('unknown','alice','x',443,'secret')

def test_subscription_output_snapshots():
    from subscriptions import render_subscription
    expected = {
        'hy2': 'c547f3ea07cf643ffc897681f70c63a84b8d1ae0b9f14ed2554ecb8f3d9e8177',
        'shadowrocket': 'c547f3ea07cf643ffc897681f70c63a84b8d1ae0b9f14ed2554ecb8f3d9e8177',
        'shadowrocket-full': '2d7103cc2c1db431e098cc79b45b070ff35dce7471f0c935e3c84987e6f05367',
        'mihomo': 'ddbc4cadf7f2c5fc63ea89d987757f9acb38f556d61ccd0ed8d57f817fa5c020',
        'sing-box': 'e6891c18a78cb47edc144671a58520ab4691d3455da9f7e81a0903210b7729bc',
    }
    for kind, digest in expected.items():
        body = render_subscription(
            kind, 'alice', 'proxy.example.com', 443, 'secret',
            tls_sni='sni.example.com', display_name='测试节点',
        )
        assert hashlib.sha256(body.encode()).hexdigest() == digest


@pytest.mark.parametrize('fmt', ['qingzhou.json', 'hy2.txt', 'shadowrocket.conf',
                                  'shadowrocket-full.conf', 'mihomo.yaml', 'sing-box.json'])
def test_subscription_reports_only_own_observed_usage(env, fmt):
    owner = user(env)
    first = device(env, owner['id'], name='First')
    second = device(env, owner['id'], name='Second')
    start = datetime(2026, 10, 21, 10, 0)
    with closing(connect(env[0].config['DATABASE'])) as conn:
        record_sample(conn, {first['auth_id']: {'tx': 100, 'rx': 200},
                             second['auth_id']: {'tx': 9000, 'rx': 8000}}, {}, 'a', start)
        record_sample(conn, {first['auth_id']: {'tx': 140, 'rx': 270},
                             second['auth_id']: {'tx': 9900, 'rx': 8800}}, {}, 'a', start+timedelta(minutes=1))
        # 重启及缺失采样后的未知增量不纳入用量，后续有效增量继续累加。
        record_sample(conn, {first['auth_id']: {'tx': 5, 'rx': 10}}, {}, 'b', start+timedelta(minutes=2))
        record_sample(conn, {first['auth_id']: {'tx': 8, 'rx': 15}}, {}, 'b', start+timedelta(minutes=3))
    result = subscription(env, first, fmt)
    assert result.status_code == 200
    assert result.headers['Subscription-Userinfo'] == 'upload=43; download=75'
    assert result.headers['Cache-Control'] == 'no-store'
    assert subscription(env, second, fmt).headers['Subscription-Userinfo'] == 'upload=900; download=800'
    assert env[0].test_client().get('/s/invalid/'+fmt).status_code == 404
    assert post(env, f"/users/{owner['id']}/devices/{first['id']}", action="disable").status_code == 302
    assert subscription(env, first, fmt).status_code == 404


def test_subscription_unknown_usage_and_observed_zero_are_distinct(env):
    d = device(env, user(env)['id'])
    assert 'Subscription-Userinfo' not in subscription(env, d).headers
    start = datetime(2026, 10, 21, 10, 0)
    with closing(connect(env[0].config['DATABASE'])) as conn:
        record_sample(conn, {d['auth_id']: {'tx': 10, 'rx': 20}}, {}, 'a', start)
        assert 'Subscription-Userinfo' not in subscription(env, d).headers
        record_sample(conn, {d['auth_id']: {'tx': 10, 'rx': 20}}, {}, 'a', start+timedelta(minutes=1))
    assert subscription(env, d).headers['Subscription-Userinfo'] == 'upload=0; download=0'
