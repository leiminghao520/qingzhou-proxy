"""Private Hysteria HTTP authentication application; never mount in the web app."""
import secrets
import sqlite3

from flask import Flask, request
from config import DATABASE, ENCRYPTION_KEY
from db import connect
from security import make_fernet


def create_auth_app(test_config=None):
    app = Flask(__name__)
    app.config.update(DATABASE=DATABASE, ENCRYPTION_KEY=ENCRYPTION_KEY, MAX_CONTENT_LENGTH=4096)
    app.config.update(test_config or {})
    fernet = make_fernet(app.config['ENCRYPTION_KEY'])

    @app.post('/auth')
    def authenticate():
        if request.remote_addr not in ('127.0.0.1', '::1'):
            return {'ok': False}, 403
        body = request.get_json(silent=True)
        auth = body.get('auth') if isinstance(body, dict) else None
        if not isinstance(auth, str) or ':' not in auth or len(auth) > 256:
            return {'ok': False}
        auth_id, password = auth.split(':', 1)
        try:
            conn = connect(app.config['DATABASE'])
            try:
                row = conn.execute(
                    'SELECT d.encrypted_password FROM devices d JOIN proxy_users u ON u.id=d.user_id '
                    'WHERE d.auth_id=? AND d.enabled=1 AND u.enabled=1 '
                    'AND NOT EXISTS (SELECT 1 FROM pending_kicks k WHERE k.auth_id=d.auth_id)', (auth_id,)).fetchone()
            finally:
                conn.close()
            if row and secrets.compare_digest(fernet.decrypt(row['encrypted_password']).decode(), password):
                return {'ok': True, 'id': auth_id}
        except (sqlite3.Error, OSError, ValueError):
            return {'ok': False}, 503
        except Exception:
            # Corrupt encrypted credentials must also fail closed, without logging secrets.
            return {'ok': False}, 503
        return {'ok': False}

    @app.errorhandler(413)
    def too_large(error):
        return {'ok': False}, 413

    return app
