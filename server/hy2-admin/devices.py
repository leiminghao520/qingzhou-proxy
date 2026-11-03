"""Device credentials and durable, fail-closed connection revocation."""
import hashlib
import secrets

from db import audit
from helper import kick_clients


def credentials(fernet):
    password, token = secrets.token_urlsafe(24), secrets.token_urlsafe(32)
    return (fernet.encrypt(password.encode()), fernet.encrypt(token.encode()),
            hashlib.sha256(token.encode()).hexdigest())


def create_device(conn, fernet, user_id, name, platform, client, note):
    password, token, digest = credentials(fernet)
    cursor = conn.execute(
        'INSERT INTO devices(user_id,auth_id,name,platform,client,note,encrypted_password,encrypted_token,token_hash) '
        'VALUES(?,?,?,?,?,?,?,?,?)',
        (user_id, 'd_' + secrets.token_hex(12), name, platform, client, note, password, token, digest))
    return cursor.lastrowid


def queue_kick(conn, auth_id):
    conn.execute('INSERT OR IGNORE INTO pending_kicks(auth_id) VALUES(?)', (auth_id,))


def retry_kicks(conn, url, secret, runner=None):
    """A pending identity cannot authenticate, including after rotation/re-enable.

    Hold the SQLite write lock through each bounded kick so concurrent retries
    cannot kick a new connection after another worker has cleared the queue.
    """
    runner = runner or kick_clients
    for item in conn.execute('SELECT auth_id FROM pending_kicks').fetchall():
        conn.execute('BEGIN IMMEDIATE')
        auth_id = item['auth_id']
        if not conn.execute('SELECT 1 FROM pending_kicks WHERE auth_id=?', (auth_id,)).fetchone():
            conn.rollback()
            continue
        try:
            runner(url, secret, [auth_id])
        except Exception:
            conn.execute('UPDATE pending_kicks SET attempts=attempts+1 WHERE auth_id=?', (auth_id,))
        else:
            conn.execute('DELETE FROM pending_kicks WHERE auth_id=?', (auth_id,))
            audit(conn, 'system', 'kick_complete', auth_id)
        conn.commit()
    return conn.execute('SELECT COUNT(*) FROM pending_kicks').fetchone()[0]
