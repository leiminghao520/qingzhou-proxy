import time, secrets
from collections import defaultdict, deque
from functools import wraps
import pyotp
from argon2 import PasswordHasher
from cryptography.fernet import Fernet
from flask import abort, request, session, redirect, url_for, flash
PH = PasswordHasher()
class LoginLimiter:
    def __init__(self, limit=5, window=300): self.limit, self.window, self.events = limit, window, defaultdict(deque)
    def allowed(self, key, now=None):
        now = time.time() if now is None else now; q = self.events[key]
        while q and q[0] <= now-self.window: q.popleft()
        if len(q) >= self.limit: return False
        q.append(now); return True
def make_fernet(key):
    if not key: raise RuntimeError('HY2_ENCRYPTION_KEY is required')
    try: return Fernet(key)
    except Exception as exc: raise RuntimeError('HY2_ENCRYPTION_KEY is invalid') from exc
def csrf_token():
    if 'csrf_token' not in session: session['csrf_token'] = secrets.token_urlsafe(32)
    return session['csrf_token']
def require_csrf():
    supplied = request.form.get('csrf_token', '')
    expected = session.get('csrf_token', '')
    if not expected or not supplied or not secrets.compare_digest(supplied, expected):
        abort(400, description='表单已过期，请刷新页面后重试')
def login_required(view):
    @wraps(view)
    def wrapped(*a, **kw):
        if not session.get('admin'):
            if request.path.startswith('/api/'):
                return {'error': '登录已过期，请重新登录'}, 401
            flash('请登录后继续操作', 'info')
            return redirect(url_for('login', next=request.full_path.rstrip('?')))
        return view(*a, **kw)
    return wrapped
def valid_totp(secret, code): return bool(code) and pyotp.TOTP(secret).verify(code, valid_window=1)
