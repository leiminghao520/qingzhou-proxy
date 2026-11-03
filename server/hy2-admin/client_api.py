"""轻舟联动接口：独立授权、只读展示与受限测速。"""
import hashlib
import json
import secrets
import time
from datetime import datetime, timedelta, timezone
from functools import wraps
from pathlib import Path
from flask import Blueprint, abort, current_app, g, request, session, stream_with_context, Response, send_file, render_template, flash, redirect, url_for
from db import audit
from security import login_required, require_csrf

SCHEMA = """
CREATE TABLE IF NOT EXISTS client_pairings (digest TEXT PRIMARY KEY, device_id INTEGER NOT NULL REFERENCES devices(id), expires INTEGER NOT NULL);
CREATE TABLE IF NOT EXISTS client_access (digest TEXT PRIMARY KEY, device_id INTEGER NOT NULL REFERENCES devices(id), created INTEGER NOT NULL);
CREATE TABLE IF NOT EXISTS client_limits (bucket TEXT PRIMARY KEY, started INTEGER NOT NULL, count INTEGER NOT NULL);
CREATE TABLE IF NOT EXISTS client_cache (key TEXT PRIMARY KEY, value TEXT NOT NULL, captured_at INTEGER NOT NULL);
CREATE TABLE IF NOT EXISTS daily_usage (device_id INTEGER NOT NULL REFERENCES devices(id), day TEXT NOT NULL, upload INTEGER, download INTEGER, complete INTEGER NOT NULL, PRIMARY KEY(device_id,day));
"""
api = Blueprint('client_api', __name__)
def digest(value): return hashlib.sha256(value.encode()).hexdigest()
def now(): return int(time.time())
def utc_stamp(value):
    if not value:return None
    stamp=datetime.fromisoformat(value)
    return (stamp if stamp.tzinfo else stamp.replace(tzinfo=timezone.utc)).isoformat()

def limited(bucket, count, seconds):
    stamp = now()
    # 数据库限流在多个工作进程间保持一致。
    g.db.execute('BEGIN IMMEDIATE')
    g.db.execute('DELETE FROM client_limits WHERE started < ?', (stamp-86400,))
    row = g.db.execute('SELECT started,count FROM client_limits WHERE bucket=?', (bucket,)).fetchone()
    if row and row['started'] > stamp-seconds and row['count'] >= count:
        g.db.rollback(); abort(429)
    if row and row['started'] > stamp-seconds:
        g.db.execute('UPDATE client_limits SET count=count+1 WHERE bucket=?', (bucket,))
    else: g.db.execute('INSERT OR REPLACE INTO client_limits VALUES(?,?,1)', (bucket, stamp))
    g.db.commit()

def authorized(owner=False):
    def decorate(fn):
        @wraps(fn)
        def wrapped(*args, **kwargs):
            value = request.headers.get('Authorization', '')
            if not value.startswith('Bearer ') or not 20 <= len(value[7:]) <= 128: abort(401)
            row = g.db.execute('SELECT d.id,d.user_id,u.role FROM client_access a JOIN devices d ON d.id=a.device_id '
                               'JOIN proxy_users u ON u.id=d.user_id WHERE a.digest=? AND d.enabled=1 AND u.enabled=1 '
                               'AND NOT EXISTS(SELECT 1 FROM pending_kicks k WHERE k.auth_id=d.auth_id)', (digest(value[7:]),)).fetchone()
            if not row: abort(401)
            if owner and row['role'] != 'owner': abort(403)
            g.client = row; limited('client:'+str(row['id']), 120, 60)
            return fn(*args, **kwargs)
        return wrapped
    return decorate

def cached(key, max_age):
    row = g.db.execute('SELECT * FROM client_cache WHERE key=?', (key,)).fetchone()
    if not row: return {'state':'unconfigured', 'captured_at':None, 'data':None}
    return {'state':'fresh' if now()-row['captured_at'] <= max_age else 'stale',
            'captured_at':row['captured_at'], 'data':json.loads(row['value'])}

def rollup(conn):
    # 只刷新今日汇总，已经归档的日期不因原始采样清理而减少。
    today = (datetime.now(timezone.utc)+timedelta(hours=8)).strftime('%Y-%m-%d')
    rows = conn.execute("SELECT s.device_id,date(m.captured_at,'+8 hours') day,SUM(s.delta_tx) up,SUM(s.delta_rx) down,"
                        'MIN(CASE WHEN s.delta_tx IS NULL OR s.delta_rx IS NULL OR m.complete=0 THEN 0 ELSE 1 END) complete '
                        'FROM device_samples s JOIN metric_samples m ON m.id=s.sample_id GROUP BY s.device_id,day').fetchall()
    for r in rows:
        old = conn.execute('SELECT 1 FROM daily_usage WHERE device_id=? AND day=?', (r['device_id'],r['day'])).fetchone()
        if old and r['day'] != today: continue
        conn.execute('INSERT OR REPLACE INTO daily_usage VALUES(?,?,?,?,?)', (r['device_id'],r['day'],r['up'],r['down'],r['complete']))
    conn.commit()

def usage(conn, device_id, start=None):
    where, params = 'device_id=?', [device_id]
    if start: where += ' AND day>=?'; params.append(start)
    r = conn.execute('SELECT SUM(upload) upload,SUM(download) download,MIN(complete) complete,MIN(day) since FROM daily_usage WHERE '+where, params).fetchone()
    return {'upload':r['upload'],'download':r['download'],'complete':bool(r['complete']),'since':r['since']}

@api.post('/client-access/<int:device_id>')
@login_required
def pair_create(device_id):
    require_csrf()
    row = g.db.execute('SELECT d.id,d.name,d.platform,d.user_id,u.display_name user_name FROM devices d JOIN proxy_users u ON u.id=d.user_id WHERE d.id=? AND d.enabled=1 AND u.enabled=1',(device_id,)).fetchone()
    if not row: abort(404)
    limited('admin-pair',20,60); code = secrets.token_urlsafe(24)
    g.db.execute('DELETE FROM client_pairings WHERE expires<? OR device_id=?',(now(),device_id))
    expires=now()+600
    g.db.execute('INSERT INTO client_pairings VALUES(?,?,?)',(digest(code),device_id,expires))
    audit(g.db,session['admin'],'create_client_pairing',str(device_id)); g.db.commit()
    return render_template('client_pairing.html',code=code,device=row,expires=expires)

@api.post('/client-access/<int:device_id>/revoke')
@login_required
def pair_revoke(device_id):
    require_csrf()
    g.db.execute('DELETE FROM client_access WHERE device_id=?',(device_id,))
    g.db.execute('DELETE FROM client_pairings WHERE device_id=?',(device_id,))
    audit(g.db,session['admin'],'revoke_client_access',str(device_id)); g.db.commit()
    if request.accept_mimetypes.best=='text/html':
        row=g.db.execute('SELECT user_id FROM devices WHERE id=?',(device_id,)).fetchone()
        if row:
            flash('已撤销此设备的轻舟联动授权；节点订阅和代理连接不受影响。','success')
            return redirect(url_for('device_detail',user_id=row['user_id'],device_id=device_id))
    return {'ok':True}

@api.post('/api/client/v1/pair')
def pair_exchange():
    limited('pair-ip:'+digest(request.remote_addr or 'unknown'),10,60)
    body = request.get_json(silent=True) or {}
    if not isinstance(body,dict): abort(400)
    code = body.get('code','')
    if not isinstance(code,str) or len(code)>128: abort(400)
    # 复制页面文本时允许首尾换行；不修改码的内部字符，也不放宽有效期与单次兑换。
    code=code.strip()
    g.db.execute('BEGIN IMMEDIATE')
    r = g.db.execute('SELECT p.device_id FROM client_pairings p JOIN devices d ON d.id=p.device_id JOIN proxy_users u ON u.id=d.user_id '
                     'WHERE p.digest=? AND p.expires>? AND d.enabled=1 AND u.enabled=1',(digest(code),now())).fetchone()
    if not r:
        g.db.rollback()
        return {'error':'pairing_code_invalid','message':'配对码不匹配、已过期或已使用，请复制最新生成的完整配对码'},401
    token = secrets.token_urlsafe(32)
    g.db.execute('DELETE FROM client_pairings WHERE digest=?',(digest(code),))
    g.db.execute('INSERT INTO client_access VALUES(?,?,?)',(digest(token),r['device_id'],now())); g.db.commit()
    return {'token':token,'api_version':1}

@api.get('/api/client/v1/me')
@authorized()
def me(): return {'device_id':g.client['id'],'owner':g.client['role']=='owner','admin_url':current_app.config['CLIENT_ADMIN_URL']}

@api.get('/api/client/v1/status')
@authorized(owner=True)
def status(): return cached('status',150)

@api.get('/api/client/v1/usage')
@authorized()
def device_usage():
    day = (datetime.now(timezone.utc)+timedelta(hours=8)).strftime('%Y-%m-%d')
    r = g.db.execute('SELECT captured_at,ok FROM metric_samples ORDER BY captured_at DESC LIMIT 1').fetchone()
    fresh = bool(r and r['ok'] and now()-int(datetime.fromisoformat(r['captured_at']).replace(tzinfo=timezone.utc).timestamp())<=150)
    return {'source':'hysteria_observed','timezone':'Asia/Shanghai','captured_at':utc_stamp(r['captured_at']) if r else None,'fresh':fresh,
            'today':usage(g.db,g.client['id'],day),'month':usage(g.db,g.client['id'],day[:7]+'-01'),'retained':usage(g.db,g.client['id'])}

@api.get('/api/client/v1/devices')
@authorized()
def devices():
    rows = g.db.execute('SELECT id,name,platform,enabled,last_online_at FROM devices WHERE user_id=? ORDER BY id',(g.client['user_id'],)).fetchall()
    return {'devices':[{**dict(r),'last_online_at':utc_stamp(r['last_online_at']),'usage':usage(g.db,r['id'])} for r in rows]}

@api.get('/api/client/v1/billing')
@authorized(owner=True)
def billing(): return cached('billing',7200)

@api.get('/api/client/v1/speed/download')
@authorized()
def speed_download():
    limited('speed:'+str(g.client['id']),1,60)
    def chunks():
        start = time.monotonic(); block = secrets.token_bytes(65536)
        for _ in range(128):
            if time.monotonic()-start >= 5: break
            yield block
    return Response(stream_with_context(chunks()),content_type='application/octet-stream')

@api.post('/api/client/v1/speed/upload')
@authorized()
def speed_upload():
    limited('speed-upload:'+str(g.client['id']),1,60)
    if request.content_length is None or not 0 <= request.content_length <= 8*1024*1024: abort(413)
    total,start = 0,time.monotonic()
    while total < request.content_length:
        if time.monotonic()-start >= 5: abort(408)
        block = request.stream.read(min(65536,request.content_length-total))
        if not block: break
        total += len(block)
    if total != request.content_length: abort(400)
    return {'bytes':total}

@api.post('/api/client/v1/backup/recipient')
@authorized(owner=True)
def backup_recipient():
    import subprocess
    body=request.get_json(silent=True) or {}
    if not isinstance(body,dict): abort(400)
    value = body.get('recipient','')
    if not isinstance(value,str) or not value.startswith('age1') or len(value)!=62: abort(400)
    path = current_app.config.get('AGE_PATH')
    if not path: return {'error':'age_unavailable'},503
    try: subprocess.run([path,'-r',value],input=b'',stdout=subprocess.DEVNULL,stderr=subprocess.DEVNULL,check=True,timeout=3)
    except (OSError,subprocess.SubprocessError): abort(400)
    # 客户端不允许覆盖现有备份公钥，换钥由管理员单独执行。
    old = g.db.execute("SELECT value FROM settings WHERE key='backup_recipient'").fetchone()
    if old and old['value']!=value: return {'error':'recipient_already_set'},409
    g.db.execute("INSERT OR REPLACE INTO settings VALUES('backup_recipient',?)",(value,)); g.db.commit()
    return {'ok':True}

def backup_manifest():
    import re
    path = Path(current_app.config['CLIENT_BACKUP_DIR'])/'latest.json'
    if not path.exists(): return None
    try: v = json.loads(path.read_text())
    except (OSError,ValueError): abort(503)
    if not isinstance(v,dict): abort(503)
    if not isinstance(v.get('name'),str): abort(503)
    if not re.fullmatch(r'backup-[0-9]{8}T[0-9]{6}Z\.tar\.age',v.get('name','')): abort(503)
    return v

@api.get('/api/client/v1/backup')
@authorized(owner=True)
def backup_info():
    return {'configured':g.db.execute("SELECT 1 FROM settings WHERE key='backup_recipient'").fetchone() is not None,'latest':backup_manifest()}

@api.get('/api/client/v1/backup/download')
@authorized(owner=True)
def backup_download():
    v = backup_manifest()
    if not v: abort(404)
    return send_file(Path(current_app.config['CLIENT_BACKUP_DIR'])/v['name'],as_attachment=True)

def register(app):
    from db import connect
    with connect(app.config['DATABASE']) as conn: conn.executescript(SCHEMA)
    app.config.setdefault('CLIENT_ADMIN_URL','https://admin.lmh1103.icu')
    app.config.setdefault('CLIENT_BACKUP_DIR','/var/backups/qingzhou-client')
    app.config.setdefault('AGE_PATH','/usr/bin/age' if Path('/usr/bin/age').exists() else None)
    app.register_blueprint(api)
