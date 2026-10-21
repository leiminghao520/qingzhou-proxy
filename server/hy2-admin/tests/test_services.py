import json
from contextlib import closing
from datetime import datetime, timedelta
from types import SimpleNamespace
from unittest.mock import Mock

import pytest
from cryptography.fernet import Fernet

import collect_stats
import helper
from app import create_app
from auth_service import create_auth_app
from db import connect, init_db
from devices import retry_kicks
from security import LoginLimiter, make_fernet
from test_app import env, user, device, post, query, auth, TOTP, PASSWORD
import pyotp


class Response:
    def __init__(self, data, status=200):
        self.data=json.dumps(data).encode();self.status=status
    def read(self):return self.data
    def __enter__(self):return self
    def __exit__(self,*args):pass


def test_stats_and_kick_transport(monkeypatch):
    requests=[]
    def open_request(request,timeout):
        requests.append(request)
        if request.full_url.endswith('/online'):return Response({'d':2})
        if request.full_url.endswith('/kick'):return Response({})
        return Response({'d':{'tx':10,'rx':20}})
    monkeypatch.setattr(helper.urllib.request,'urlopen',open_request)
    assert helper.fetch_stats('http://localhost','secret')==({'d':{'tx':10,'rx':20}},{'d':2})
    assert requests[0].headers['Authorization']=='secret'
    helper.kick_clients('http://localhost','secret',['d'])
    assert requests[-1].method=='POST' and json.loads(requests[-1].data)==['d']
    for fn in (helper.fetch_stats, lambda url,secret:helper.kick_clients(url,secret,['d'])):
        with pytest.raises(RuntimeError):fn('http://localhost','')
    monkeypatch.setattr(helper.urllib.request,'urlopen',lambda *a,**kw:Response({},503))
    with pytest.raises(RuntimeError):helper.kick_clients('http://localhost','s',['d'])


@pytest.mark.parametrize('traffic,online',[(None,{}),({},[]),({'d':1},{}),({'d':{'tx':-1,'rx':0}},{}),({}, {'d':-1})])
def test_invalid_stats_rejected(monkeypatch,traffic,online):
    replies=iter([traffic,online])
    monkeypatch.setattr(helper.urllib.request,'urlopen',lambda *a,**kw:Response(next(replies)))
    with pytest.raises(ValueError):helper.fetch_stats('http://localhost','s')


def test_operations_allowlist_and_errors(monkeypatch):
    runner=Mock(return_value=SimpleNamespace(returncode=0,stdout=b'{"ok":true}',stderr=b''))
    monkeypatch.setattr(helper.subprocess,'run',runner)
    ops=helper.OperationsHelper('/helper')
    assert ops.call('status')['ok']
    assert runner.call_args.args[0]==['sudo','/helper','status']
    with pytest.raises(ValueError):ops.call('rollback')
    for stderr in (b'failed',b''):
        runner.return_value=SimpleNamespace(returncode=1,stdout=b'',stderr=stderr)
        with pytest.raises(RuntimeError):ops.call('status')


def test_collector_success_failure_restart_and_purge(env,monkeypatch):
    u=user(env);d=device(env,u['id'])
    monkeypatch.setattr(collect_stats,'DATABASE',env[0].config['DATABASE'])
    monkeypatch.setattr(collect_stats,'fetch_stats',lambda *a,**kw:({d['auth_id']:{'tx':2,'rx':3}}, {d['auth_id']:1}))
    monkeypatch.setattr(collect_stats.OperationsHelper,'call',lambda *a:{'generation':'a'})
    collect_stats.main()
    assert query(env,'SELECT ok FROM metric_samples')[0]['ok']==1
    with closing(connect(env[0].config['DATABASE'])) as conn,conn:
        conn.execute('DELETE FROM metric_samples')
    sequence=iter([{'generation':'a'},{'generation':'b'}])
    monkeypatch.setattr(collect_stats.OperationsHelper,'call',lambda *a:next(sequence))
    collect_stats.main()
    assert query(env,'SELECT ok FROM metric_samples')[0]['ok']==0


def test_login_failures_rate_limit_force_change_and_security_errors(env):
    app,client=env[:2]
    anonymous=app.test_client();anonymous.get('/login')
    with anonymous.session_transaction() as session:csrf=session['csrf_token']
    for i in range(4):
        assert anonymous.post('/login',data={'csrf_token':csrf,'username':'absent','password':'bad'}).status_code==401
    assert anonymous.post('/login',data={'csrf_token':csrf}).status_code==429
    with client.session_transaction() as s:s['must_change']=True
    assert client.get('/users').location.endswith('/security')
    assert client.get('/security').status_code==200
    assert post(env,'/security',current_password=PASSWORD,totp=pyotp.TOTP(TOTP).now(),new_password='short').status_code==400
    with client.session_transaction() as s:s['must_change']=False
    limiter=LoginLimiter(1,2)
    assert limiter.allowed('x',1) and not limiter.allowed('x',2) and limiter.allowed('x',4)
    with pytest.raises(RuntimeError):make_fernet('bad-key')


def test_errors_service_failure_no_online_and_corrupted_credentials(env):
    def fail(*args):raise TimeoutError()
    env[0].operations.runner=fail
    assert env[1].get('/').status_code==200
    assert env[1].get('/api/overview').json['service']['ok'] is False
    assert post(env,'/operations',operation='reload').status_code==302
    u=user(env);d=device(env,u['id'])
    with closing(connect(env[0].config['DATABASE'])) as conn,conn:
        conn.execute("UPDATE devices SET encrypted_password=x'1234' WHERE id=?",(d['id'],))
    assert env[2].post('/auth',json={'auth':d['auth_id']+':whatever'}).status_code==503
    assert env[1].post('/users',data='x'*20000,content_type='application/x-www-form-urlencoded').status_code==413


def test_failed_database_transaction_is_not_committed(env):
    app=create_app(env[0].config)
    @app.route('/testing-error',methods=['POST'])
    def broken():
        from flask import g
        g.db.execute("INSERT INTO audit_log(actor,action) VALUES('uncommitted','test')")
        raise RuntimeError('failure')
    with pytest.raises(RuntimeError):app.test_client().post('/testing-error')
    assert not query(env,"SELECT 1 FROM audit_log WHERE actor='uncommitted'")


def test_cli_bootstrap_and_purge(tmp_path):
    app=create_app({'DATABASE':tmp_path/'cli.db','SECRET_KEY':'x','ENCRYPTION_KEY':Fernet.generate_key()})
    result=app.test_cli_runner().invoke(args=['bootstrap'])
    assert result.exit_code==0 and 'TOTP_URI=' in result.output
    assert app.test_cli_runner().invoke(args=['purge-old-data']).exit_code==0
    with pytest.raises(RuntimeError):create_app({'SECRET_KEY':None,'ENCRYPTION_KEY':Fernet.generate_key()})


def test_byte_units_login_wrong_existing_password_and_failed_reload(env):
    formatter=env[0].jinja_env.filters['bytes']
    assert formatter(None)=='—'
    for i,unit in enumerate(('B','KiB','MiB','GiB','TiB')):
        assert formatter(1024**i)=='1.0 '+unit
    assert formatter(1024**5)=='1024.0 TiB'
    env[0].operations.runner=lambda *args:{'ok':False}
    assert post(env,'/operations',operation='reload').status_code==302
    client=env[0].test_client();client.get('/login')
    with client.session_transaction() as s:csrf=s['csrf_token']
    assert client.post('/login',data={'csrf_token':csrf,'username':'admin','password':'bad'}).status_code==401


def test_concurrent_kick_retries_do_not_disconnect_fresh_session(env):
    from concurrent.futures import ThreadPoolExecutor
    from threading import Event
    from devices import queue_kick
    u=user(env);d=device(env,u['id'])
    with closing(connect(env[0].config['DATABASE'])) as conn,conn:queue_kick(conn,d['auth_id'])
    entered=Event();second_selected=Event();calls=[]
    def kick(*args):
        calls.append(args[2]);entered.set()
        assert second_selected.wait(3)
    def retry(observe=False):
        with closing(connect(env[0].config['DATABASE'])) as conn:
            if observe:
                conn.set_trace_callback(lambda sql:second_selected.set() if sql=='BEGIN IMMEDIATE' else None)
            return retry_kicks(conn,'http://test','secret',kick)
    with ThreadPoolExecutor(max_workers=2) as pool:
        first=pool.submit(retry)
        assert entered.wait(3)
        second=pool.submit(retry,True)
        assert first.result()==0 and second.result()==0
    assert calls==[[d['auth_id']]]


def test_offline_samples(env):
    from metrics import record_sample
    u=user(env);d=device(env,u['id'])
    with closing(connect(env[0].config['DATABASE'])) as conn:
        record_sample(conn,{}, {},'a',datetime(2026,9,20,2,0))
    assert query(env,'SELECT last_online_at FROM devices')[0]['last_online_at'] is None


def test_live_verifier_uses_device_subscriptions_without_printing_secrets(env,monkeypatch,capsys):
    from deploy import verify_subscriptions
    from email.message import Message
    from urllib.parse import urlsplit
    u=user(env);d=device(env,u['id'])
    monkeypatch.setattr(verify_subscriptions,'create_app',lambda:env[0])
    class Wrapped:
        def __init__(self,response):
            self.response=response;self.status=response.status_code;self.headers=Message()
            for key,value in response.headers:self.headers[key]=value
        def __enter__(self):return self
        def __exit__(self,*args):pass
        def read(self):return self.response.data
    monkeypatch.setattr(verify_subscriptions.urllib.request,'urlopen',lambda url,timeout:Wrapped(env[1].get(urlsplit(url).path)))
    verify_subscriptions.main()
    output=capsys.readouterr().out
    assert output.count('VERIFY_OK')==5
    assert env[0].fernet.decrypt(d['encrypted_token']).decode() not in output
