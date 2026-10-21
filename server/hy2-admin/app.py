import hashlib
import io
import os
import re
import secrets
import sqlite3
from datetime import datetime, timedelta
from pathlib import Path
from urllib.parse import urlsplit

import pyotp
import qrcode
from flask import Flask, abort, flash, g, make_response, redirect, render_template, request, send_file, session, url_for

from config import DATABASE, ENCRYPTION_KEY, HELPER_PATH, LOGIN_LIMIT, LOGIN_WINDOW_SECONDS, PUBLIC_BASE_URL, SECRET_KEY, SERVER_NAME, SERVER_PORT, SESSION_COOKIE_SECURE, STATS_SECRET, STATS_URL
from db import audit, connect, init_db, purge_old_data
from devices import create_device, credentials, queue_kick, retry_kicks
from helper import OperationsHelper
from metrics import overview, device_usage
from security import LoginLimiter, PH, csrf_token, login_required, make_fernet, require_csrf, valid_totp
from subscriptions import render_subscription

FORMATS = {
    'qingzhou': ('轻舟完整配置（节点、规则及资产）', 'qingzhou.json'),
    'shadowrocket': ('Shadowrocket 节点订阅', 'shadowrocket.conf'),
    'shadowrocket-full': ('Shadowrocket 完整配置', 'shadowrocket-full.conf'),
    'mihomo': ('Mihomo / Clash 完整配置', 'mihomo.yaml'),
    'sing-box': ('sing-box 完整配置', 'sing-box.json'),
    'hy2': ('通用 HY2 节点', 'hy2.txt'),
}
PLATFORMS = ('iOS / iPadOS', 'Android', 'macOS', 'Windows', 'Linux', '其他')
CLIENTS = {'qingzhou':'轻舟代理','shadowrocket':'Shadowrocket', 'mihomo':'Clash Verge / Mihomo', 'sing-box':'sing-box',
           'hiddify':'Hiddify', 'nekobox':'NekoBox', 'v2rayn':'v2rayN', 'hy2':'其他 HY2 客户端'}
ACTIONS = {'login':'登录','login_failed':'登录失败','logout':'退出登录','create_user':'创建用户',
           'edit_user':'修改用户','disable_user':'停用用户','enable_user':'启用用户',
           'create_device':'添加设备','edit_device':'修改设备','disable_device':'停用设备',
           'enable_device':'启用设备','rotate_device':'轮换设备凭据','kick_complete':'断开连接完成',
           'change_admin_password':'修改后台密码','operation':'服务操作','create_owner':'创建 owner'}


def safe_next(value):
    value = value or '/'
    parts = urlsplit(value or '')
    return value if not parts.scheme and not parts.netloc and value.startswith('/') and not value.startswith('//') and '\\' not in value else '/'


def create_app(test_config=None):
    app = Flask(__name__)
    app.config.update(
        SECRET_KEY=SECRET_KEY, DATABASE=DATABASE, ENCRYPTION_KEY=ENCRYPTION_KEY,
        SESSION_COOKIE_HTTPONLY=True, SESSION_COOKIE_SAMESITE='Strict',
        SESSION_COOKIE_SECURE=SESSION_COOKIE_SECURE, PERMANENT_SESSION_LIFETIME=timedelta(minutes=30),
        SERVER_NAME_VALUE=SERVER_NAME, SERVER_PORT=SERVER_PORT, PUBLIC_BASE_URL=PUBLIC_BASE_URL.rstrip('/'),
        STATS_URL=STATS_URL, STATS_SECRET=STATS_SECRET, HELPER_PATH=HELPER_PATH, MAX_CONTENT_LENGTH=16384)
    app.config.update(test_config or {})
    if not app.config['SECRET_KEY']:
        raise RuntimeError('HY2_SECRET_KEY is required')
    app.fernet = make_fernet(app.config['ENCRYPTION_KEY'])
    init_db(Path(app.config['DATABASE']))
    from client_api import register
    register(app)
    app.login_limiter = LoginLimiter(LOGIN_LIMIT, LOGIN_WINDOW_SECONDS)
    app.operations = OperationsHelper(app.config['HELPER_PATH'], app.config.get('OPERATION_RUNNER'))

    @app.before_request
    def open_db():
        if request.path == "/api/client/v1/speed/upload": request.max_content_length = 8*1024*1024
        g.db = connect(app.config['DATABASE'])
        if session.get('admin') and session.get('must_change') and request.endpoint not in {'security', 'logout', 'static'}:
            return redirect(url_for('security'))

    @app.teardown_request
    def close_db(error=None):
        conn = g.pop('db', None)
        if conn is not None:
            if error is not None:
                conn.rollback()
            conn.close()

    @app.after_request
    def headers(response):
        response.headers['Cache-Control'] = 'no-store'
        response.headers['X-Content-Type-Options'] = 'nosniff'
        response.headers['Referrer-Policy'] = 'no-referrer'
        response.headers['Content-Security-Policy'] = "default-src 'self'; img-src 'self' data:; style-src 'self'; script-src 'self'; form-action 'self'; frame-ancestors 'none'; base-uri 'none'"
        return response

    @app.context_processor
    def inject():
        return dict(csrf_token=csrf_token(), formats=FORMATS, clients=CLIENTS, platforms=PLATFORMS, actions=ACTIONS)

    @app.template_filter('bytes')
    def pretty_bytes(value):
        if value is None:
            return '—'
        value = float(value)
        units = ('B', 'KiB', 'MiB', 'GiB', 'TiB')
        index = 0
        while abs(value) >= 1024 and index < len(units)-1:
            value /= 1024
            index += 1
        return f'{value:.1f} {units[index]}'

    @app.template_filter('bjtime')
    def bjtime(value):
        return (datetime.fromisoformat(value)+timedelta(hours=8)).strftime('%Y-%m-%d %H:%M') if value else '尚无记录'

    @app.errorhandler(400)
    @app.errorhandler(403)
    @app.errorhandler(404)
    @app.errorhandler(413)
    def friendly_error(error):
        return render_template('error.html', code=error.code, message={400:'输入不完整或表单已过期，请返回检查。',403:'验证失败或无权执行此操作。',404:'页面或订阅不存在，可能已失效。',413:'提交内容过大。'}[error.code]), error.code

    def save(action, target):
        audit(g.db, session['admin'], action, str(target))
        g.db.commit()

    def confirm_owner():
        admin = g.db.execute('SELECT * FROM admins WHERE username=?', (session['admin'],)).fetchone()
        try:
            valid = PH.verify(admin['password_hash'], request.form.get('admin_password', '')) and valid_totp(
                app.fernet.decrypt(admin['totp_secret']).decode(), request.form.get('admin_totp', ''))
        except Exception:
            valid = False
        if not valid:
            abort(403)

    def user_row(uid):
        row = g.db.execute('SELECT * FROM proxy_users WHERE id=?', (uid,)).fetchone()
        if not row:
            abort(404)
        return row

    def device_row(did, uid=None):
        row = g.db.execute('SELECT d.*,u.enabled user_enabled,u.role,u.display_name user_name FROM devices d '
                           'JOIN proxy_users u ON u.id=d.user_id WHERE d.id=?', (did,)).fetchone()
        if not row or (uid is not None and row['user_id'] != uid):
            abort(404)
        return row

    def form_text(key, limit, required=False):
        value = request.form.get(key, '').strip()
        if len(value) > limit or (required and not value):
            abort(400)
        return value

    def device_form():
        name = form_text('name', 80, True)
        platform, client = form_text('platform', 30, True), form_text('client', 30, True)
        if platform not in PLATFORMS or client not in CLIENTS:
            abort(400)
        return name, platform, client, form_text('note', 300)

    def kick_feedback():
        remaining = retry_kicks(g.db, app.config['STATS_URL'], app.config['STATS_SECRET'], app.config.get('KICK_RUNNER'))
        flash('凭据已失效，在线连接断开待重试。' if remaining else '凭据状态已更新，目标设备连接已断开。',
              'warning' if remaining else 'success')

    @app.route('/login', methods=['GET', 'POST'])
    def login():
        destination = safe_next(request.values.get('next', '/'))
        if request.method == 'POST':
            require_csrf()
            if not app.login_limiter.allowed(request.remote_addr or 'unknown'):
                return render_template('login.html', error='尝试过于频繁，请五分钟后重试', next=destination), 429
            username = request.form.get('username', '').strip()
            row = g.db.execute('SELECT * FROM admins WHERE username=?', (username,)).fetchone()
            try:
                valid = row and PH.verify(row['password_hash'], request.form.get('password', '')) and valid_totp(
                    app.fernet.decrypt(row['totp_secret']).decode(), request.form.get('totp', ''))
            except Exception:
                valid = False
            if not valid:
                audit(g.db, 'anonymous', 'login_failed'); g.db.commit()
                return render_template('login.html', error='用户名、密码或动态码错误', next=destination), 401
            session.clear(); session.permanent = True
            session.update(admin=row['username'], must_change=bool(row['must_change_password']))
            csrf_token(); save('login', row['username'])
            return redirect(url_for('security') if session['must_change'] else destination)
        return render_template('login.html', next=destination)

    @app.post('/logout')
    @login_required
    def logout():
        require_csrf(); save('logout', session['admin']); session.clear()
        return redirect(url_for('login'))

    @app.route('/security', methods=['GET', 'POST'])
    @login_required
    def security():
        if request.method == 'POST':
            require_csrf()
            admin = g.db.execute('SELECT * FROM admins WHERE username=?', (session['admin'],)).fetchone()
            try:
                verified = PH.verify(admin['password_hash'], request.form.get('current_password','')) and valid_totp(
                    app.fernet.decrypt(admin['totp_secret']).decode(), request.form.get('totp',''))
            except Exception:
                verified = False
            new = request.form.get('new_password', '')
            if not verified or len(new) < 14:
                return render_template('security.html', error='验证失败，或新密码不足 14 位', must_change=session.get('must_change')), 400
            g.db.execute('UPDATE admins SET password_hash=?,must_change_password=0,updated_at=CURRENT_TIMESTAMP WHERE id=?', (PH.hash(new),admin['id']))
            session['must_change'] = False; save('change_admin_password', session['admin'])
            flash('后台密码已更新', 'success'); return redirect(url_for('dashboard'))
        return render_template('security.html', must_change=session.get('must_change'))

    @app.get('/')
    @login_required
    def dashboard():
        metrics = overview(g.db, request.args.get('period', '24h'))
        counts = dict(g.db.execute('SELECT COUNT(*) total,COALESCE(SUM(enabled),0) enabled FROM proxy_users').fetchone())
        count_devices = g.db.execute('SELECT COUNT(*) FROM devices').fetchone()[0]
        users = g.db.execute('SELECT u.*,COUNT(d.id) device_count FROM proxy_users u LEFT JOIN devices d ON d.user_id=u.id GROUP BY u.id ORDER BY u.role,u.username LIMIT 8').fetchall()
        recent_audit = g.db.execute('SELECT action,target,created_at FROM audit_log ORDER BY id DESC LIMIT 5').fetchall()
        return render_template('dashboard.html', metrics=metrics, counts=counts, device_count=count_devices,
                               users=users, recent_audit=recent_audit, service=service_status())

    def service_status():
        try:
            return app.operations.call('status')
        except Exception:
            return {'ok': False, 'error': '暂时无法读取服务状态，请检查后台服务权限。'}

    @app.get('/api/overview')
    @login_required
    def api_overview():
        return dict(metrics=overview(g.db, request.args.get('period','24h')), service=service_status())

    @app.route('/users', methods=['GET', 'POST'])
    @login_required
    def users():
        if request.method == 'POST':
            require_csrf()
            username, name = form_text('username',48,True), form_text('display_name',80,True)
            if not re.fullmatch(r'[A-Za-z0-9_.-]{1,48}', username):
                abort(400)
            role = request.form.get('role','user')
            if role not in ('owner','user'):
                abort(400)
            password, token, _ = credentials(app.fernet)
            try:
                uid = g.db.execute('INSERT INTO proxy_users(username,display_name,role,note,encrypted_password,encrypted_token) VALUES(?,?,?,?,?,?)',
                                   (username,name,role,form_text('note',300),password,token)).lastrowid
                save('create_user',username)
            except sqlite3.IntegrityError:
                g.db.rollback(); flash('账号已存在，或 owner 已创建。','error'); return redirect(url_for('users'))
            flash('用户已创建，接下来添加实际使用的设备。','success')
            return redirect(url_for('user_detail',user_id=uid))
        q = request.args.get('q','')[:80]
        status = request.args.get('status','')
        where = ' WHERE (u.username LIKE ? OR u.display_name LIKE ?)'
        params = ['%'+q+'%']*2
        if status in ('0','1'):
            where += ' AND u.enabled=?'; params.append(int(status))
        total_users = g.db.execute('SELECT COUNT(*) FROM proxy_users u'+where, params).fetchone()[0]
        per_page = 20
        total_pages = max(1, (total_users + per_page - 1) // per_page)
        page = request.args.get('page', 1, type=int) or 1
        page = min(max(page, 1), total_pages)
        query = 'SELECT u.*,COUNT(d.id) device_count FROM proxy_users u LEFT JOIN devices d ON d.user_id=u.id'
        rows = g.db.execute(query+where+' GROUP BY u.id ORDER BY u.role,u.username LIMIT ? OFFSET ?',
                            params+[per_page, (page-1)*per_page]).fetchall()
        owner_exists = bool(g.db.execute("SELECT 1 FROM proxy_users WHERE role='owner'").fetchone())
        return render_template('users.html', users=rows, q=q, status=status, owner_exists=owner_exists,
                               page=page, total_pages=total_pages, total_users=total_users)

    @app.route('/users/<int:user_id>', methods=['GET','POST'])
    @login_required
    def user_detail(user_id):
        user = user_row(user_id)
        if request.method == 'POST':
            require_csrf(); action = request.form.get('action')
            if action == 'edit':
                g.db.execute('UPDATE proxy_users SET display_name=?,note=?,updated_at=CURRENT_TIMESTAMP WHERE id=?',
                             (form_text('display_name',80,True),form_text('note',300),user_id))
            elif action in ('disable','enable'):
                if user['role'] == 'owner' and action == 'disable':
                    confirm_owner()
                g.db.execute('UPDATE proxy_users SET enabled=?,updated_at=CURRENT_TIMESTAMP WHERE id=?',(action=='enable',user_id))
                if action == 'disable':
                    for row in g.db.execute('SELECT auth_id FROM devices WHERE user_id=?',(user_id,)):
                        queue_kick(g.db,row['auth_id'])
            else:
                abort(400)
            save(action+'_user',user['username'])
            if action == 'disable':
                kick_feedback()
            else:
                flash('用户信息已更新','success')
            return redirect(url_for('user_detail',user_id=user_id))
        rows = g.db.execute('SELECT d.*,EXISTS(SELECT 1 FROM pending_kicks k WHERE k.auth_id=d.auth_id) pending FROM devices d WHERE user_id=? ORDER BY id',(user_id,)).fetchall()
        usage = {row['id']:device_usage(g.db,row['id']) for row in rows}
        logs = g.db.execute('SELECT * FROM audit_log WHERE target=? OR target IN (SELECT auth_id FROM devices WHERE user_id=?) ORDER BY id DESC LIMIT 10',(user['username'],user_id)).fetchall()
        legacy = g.db.execute('SELECT COUNT(*) count, MAX(captured_at) last FROM traffic_snapshots WHERE username=?',(user['username'],)).fetchone()
        return render_template('user_detail.html',user=user,devices=rows,usage=usage,entries=logs,legacy=legacy,metrics=overview(g.db,user_id=user_id))

    @app.post('/users/<int:user_id>/devices')
    @login_required
    def add_device(user_id):
        require_csrf(); user_row(user_id)
        did = create_device(g.db,app.fernet,user_id,*device_form())
        row = device_row(did); save('create_device',row['auth_id'])
        flash('设备已创建，选择客户端后获取专属订阅。','success')
        return redirect(url_for('device_detail',user_id=user_id,device_id=did))

    @app.route('/users/<int:user_id>/devices/<int:device_id>', methods=['GET','POST'])
    @login_required
    def device_detail(user_id,device_id):
        device = device_row(device_id,user_id)
        if request.method == 'POST':
            require_csrf(); action = request.form.get('action')
            if device['role']=='owner' and action in ('disable','rotate'):
                confirm_owner()
            if action == 'edit':
                g.db.execute('UPDATE devices SET name=?,platform=?,client=?,note=?,updated_at=CURRENT_TIMESTAMP WHERE id=?',(*device_form(),device_id))
            elif action in ('enable','disable'):
                g.db.execute('UPDATE devices SET enabled=?,updated_at=CURRENT_TIMESTAMP WHERE id=?',(action=='enable',device_id))
                if action=='disable': queue_kick(g.db,device['auth_id'])
            elif action=='rotate':
                g.db.execute('UPDATE devices SET encrypted_password=?,encrypted_token=?,token_hash=?,updated_at=CURRENT_TIMESTAMP WHERE id=?',(*credentials(app.fernet),device_id))
                queue_kick(g.db,device['auth_id'])
            else: abort(400)
            save(action+'_device',device['auth_id'])
            if action in ('disable','rotate'):
                g.db.execute('DELETE FROM client_access WHERE device_id=?',(device_id,))
                g.db.execute('DELETE FROM client_pairings WHERE device_id=?',(device_id,))
                g.db.commit()
                kick_feedback()
            else: flash('设备信息已更新','success')
            return redirect(url_for('device_detail',user_id=user_id,device_id=device_id))
        kind = request.args.get('client',device['client'])
        if kind not in FORMATS: kind='hy2'
        token = app.fernet.decrypt(device['encrypted_token']).decode()
        link = app.config['PUBLIC_BASE_URL']+'/s/'+token+'/'+FORMATS[kind][1]
        pending = g.db.execute('SELECT 1 FROM pending_kicks WHERE auth_id=?',(device['auth_id'],)).fetchone()
        return render_template('device_detail.html',device=device,kind=kind,link=link,pending=pending,
                               metrics=overview(g.db,device_id=device_id),usage=device_usage(g.db,device_id))

    @app.get('/qr/<int:device_id>/<kind>')
    @login_required
    def qr(device_id,kind):
        device = device_row(device_id)
        if kind not in FORMATS or not device['enabled'] or not device['user_enabled']: abort(404)
        token = app.fernet.decrypt(device['encrypted_token']).decode()
        link = app.config['PUBLIC_BASE_URL']+'/s/'+token+'/'+FORMATS[kind][1]
        buf=io.BytesIO(); qrcode.make(link).save(buf,format='PNG'); buf.seek(0)
        return send_file(buf,mimetype='image/png',max_age=0)

    @app.get('/s/<token>/<path:fmt>')
    def public_subscription(token,fmt):
        kind = next((key for key,value in FORMATS.items() if value[1]==fmt),None)
        if kind is None or len(token)>128: abort(404)
        row = g.db.execute('SELECT d.* FROM devices d JOIN proxy_users u ON u.id=d.user_id '
                           'WHERE d.token_hash=? AND d.enabled=1 AND u.enabled=1',(hashlib.sha256(token.encode()).hexdigest(),)).fetchone()
        if not row: abort(404)
        body = render_subscription(kind,row['auth_id'],app.config['SERVER_NAME_VALUE'],app.config['SERVER_PORT'],
                                   app.fernet.decrypt(row['encrypted_password']).decode(),display_name=row['name'])
        response=make_response(body)
        response.headers['Content-Type']={'qingzhou':'application/json; charset=utf-8','sing-box':'application/json; charset=utf-8','mihomo':'application/yaml; charset=utf-8'}.get(kind,'text/plain; charset=utf-8')
        # 仅返回当前设备留存的已观测用量；缺失采样不补零，也不虚构配额或到期时间。
        usage = device_usage(g.db, row['id'])
        fields = [f'{name}={usage[key]}' for name, key in (('upload', 'tx'), ('download', 'rx'))
                  if usage[key] is not None]
        if fields:
            response.headers['Subscription-Userinfo'] = '; '.join(fields)
        response.headers['Qingzhou-Client-API'] = '/api/client/v1'
        response.headers['X-Robots-Tag']='noindex, nofollow'
        response.headers['Content-Disposition']='attachment; filename="'+fmt+'"'
        return response

    @app.route('/operations',methods=['GET','POST'])
    @login_required
    def operations():
        if request.method=='POST':
            require_csrf(); operation=request.form.get('operation')
            if operation=='retry-kicks':
                remaining=retry_kicks(g.db,app.config['STATS_URL'],app.config['STATS_SECRET'],app.config.get('KICK_RUNNER'))
                flash('连接断开任务已完成' if not remaining else '仍有连接待断开，将继续自动重试','success' if not remaining else 'warning')
            elif operation=='reload':
                try:
                    result=app.operations.call('reload')
                    if not result.get('ok'): raise RuntimeError()
                    flash('Nginx 校验与重载完成','success')
                except Exception: flash('重载未完成，请检查服务配置。','error')
                save('operation','nginx_reload')
            else: abort(400)
            return redirect(url_for('operations'))
        pending=g.db.execute('SELECT k.*,d.name FROM pending_kicks k JOIN devices d ON d.auth_id=k.auth_id ORDER BY k.created_at').fetchall()
        return render_template('operations.html',service=service_status(),pending=pending)

    @app.get('/audit')
    @login_required
    def audit_page():
        clauses,params=[],[]
        for key in ('action','target'):
            value=request.args.get(key,'')[:80]
            if value: clauses.append(key+'=?'); params.append(value)
        for key,operator in (('start','>='),('end','<')):
            value=request.args.get(key,'')
            if value:
                try: date=datetime.strptime(value,'%Y-%m-%d')-timedelta(hours=8)
                except ValueError: abort(400)
                if key=='end': date+=timedelta(days=1)
                clauses.append('created_at'+operator+'?'); params.append(date.strftime('%Y-%m-%d %H:%M:%S'))
        where=' WHERE '+' AND '.join(clauses) if clauses else ''
        total=g.db.execute('SELECT COUNT(*) FROM audit_log'+where,params).fetchone()[0]
        pages=max(1,(total+29)//30)
        page=max(1,min(request.args.get('page',1,type=int),pages))
        entries=g.db.execute('SELECT * FROM audit_log'+where+' ORDER BY id DESC LIMIT 30 OFFSET ?',params+[(page-1)*30]).fetchall()
        return render_template('audit.html',entries=entries,page=page,pages=pages,total=total)

    @app.cli.command('bootstrap')
    def bootstrap():
        password=os.environ.get('HY2_ADMIN_PASSWORD') or secrets.token_urlsafe(24)
        username=os.environ.get('HY2_ADMIN_USERNAME','admin'); secret=pyotp.random_base32()
        conn=connect(app.config['DATABASE'])
        try:
            with conn:
                conn.execute('INSERT INTO admins(username,password_hash,totp_secret) VALUES(?,?,?)',(username,PH.hash(password),app.fernet.encrypt(secret.encode())))
        finally: conn.close()
        print(f'USERNAME={username}\nPASSWORD={password}\nTOTP_URI={pyotp.TOTP(secret).provisioning_uri(username,issuer_name="HY2 Admin")}')

    @app.cli.command('purge-old-data')
    def purge():
        conn=connect(app.config['DATABASE'])
        try:
            with conn: purge_old_data(conn,180)
        finally: conn.close()

    return app
