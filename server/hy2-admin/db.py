import sqlite3
from pathlib import Path

SCHEMA = """
CREATE TABLE IF NOT EXISTS admins (
 id INTEGER PRIMARY KEY, username TEXT UNIQUE NOT NULL, password_hash TEXT NOT NULL,
 totp_secret BLOB NOT NULL, must_change_password INTEGER NOT NULL DEFAULT 1,
 created_at TEXT NOT NULL DEFAULT CURRENT_TIMESTAMP, updated_at TEXT NOT NULL DEFAULT CURRENT_TIMESTAMP
);
CREATE TABLE IF NOT EXISTS proxy_users (
 id INTEGER PRIMARY KEY, username TEXT UNIQUE NOT NULL, display_name TEXT NOT NULL,
 role TEXT NOT NULL CHECK(role IN ('owner','user')), enabled INTEGER NOT NULL DEFAULT 1,
 note TEXT NOT NULL DEFAULT '', encrypted_password BLOB NOT NULL, encrypted_token BLOB NOT NULL,
 created_at TEXT NOT NULL DEFAULT CURRENT_TIMESTAMP, updated_at TEXT NOT NULL DEFAULT CURRENT_TIMESTAMP
);
CREATE UNIQUE INDEX IF NOT EXISTS one_owner ON proxy_users(role) WHERE role='owner';
CREATE TABLE IF NOT EXISTS audit_log (
 id INTEGER PRIMARY KEY, actor TEXT NOT NULL, action TEXT NOT NULL,
 target TEXT, metadata TEXT, created_at TEXT NOT NULL DEFAULT CURRENT_TIMESTAMP
);
CREATE TABLE IF NOT EXISTS traffic_snapshots (
 id INTEGER PRIMARY KEY, username TEXT NOT NULL, tx INTEGER NOT NULL DEFAULT 0,
 rx INTEGER NOT NULL DEFAULT 0, online INTEGER NOT NULL DEFAULT 0,
 captured_at TEXT NOT NULL DEFAULT CURRENT_TIMESTAMP
);
CREATE INDEX IF NOT EXISTS traffic_user_time ON traffic_snapshots(username,captured_at);
CREATE TABLE IF NOT EXISTS devices (
 id INTEGER PRIMARY KEY, user_id INTEGER NOT NULL REFERENCES proxy_users(id),
 auth_id TEXT UNIQUE NOT NULL, name TEXT NOT NULL, platform TEXT NOT NULL DEFAULT '',
 client TEXT NOT NULL DEFAULT 'hy2', note TEXT NOT NULL DEFAULT '',
 enabled INTEGER NOT NULL DEFAULT 1, encrypted_password BLOB NOT NULL,
 encrypted_token BLOB NOT NULL, token_hash TEXT UNIQUE NOT NULL,
 last_online_at TEXT, created_at TEXT NOT NULL DEFAULT CURRENT_TIMESTAMP,
 updated_at TEXT NOT NULL DEFAULT CURRENT_TIMESTAMP
);
CREATE INDEX IF NOT EXISTS devices_user ON devices(user_id);
CREATE TABLE IF NOT EXISTS pending_kicks (
 auth_id TEXT PRIMARY KEY REFERENCES devices(auth_id),
 attempts INTEGER NOT NULL DEFAULT 0, created_at TEXT NOT NULL DEFAULT CURRENT_TIMESTAMP
);
CREATE TABLE IF NOT EXISTS metric_samples (
 id INTEGER PRIMARY KEY, captured_at TEXT UNIQUE NOT NULL, generation TEXT,
 ok INTEGER NOT NULL, complete INTEGER NOT NULL DEFAULT 0
);
CREATE TABLE IF NOT EXISTS device_samples (
 sample_id INTEGER NOT NULL REFERENCES metric_samples(id) ON DELETE CASCADE,
 device_id INTEGER NOT NULL REFERENCES devices(id), tx INTEGER NOT NULL, rx INTEGER NOT NULL,
 online INTEGER NOT NULL, delta_tx INTEGER, delta_rx INTEGER,
 PRIMARY KEY(sample_id, device_id)
);
CREATE TABLE IF NOT EXISTS settings (key TEXT PRIMARY KEY, value TEXT NOT NULL);
INSERT OR IGNORE INTO settings(key,value) VALUES('schema_version','2');
"""

def connect(path):
    conn = sqlite3.connect(Path(path), timeout=10)
    conn.row_factory = sqlite3.Row
    conn.execute("PRAGMA foreign_keys=ON")
    conn.execute("PRAGMA journal_mode=WAL")
    return conn

def init_db(path):
    Path(path).parent.mkdir(parents=True, exist_ok=True)
    with connect(path) as conn:
        conn.executescript(SCHEMA)

def audit(conn, actor, action, target=None, metadata=None):
    if metadata and any(word in str(metadata).lower() for word in ("password", "token", "secret", "hysteria2://")):
        raise ValueError("sensitive metadata is forbidden")
    conn.execute("INSERT INTO audit_log(actor,action,target,metadata) VALUES(?,?,?,?)",
                 (actor, action, target, metadata))

def purge_old_data(conn, days=180):
    conn.execute("DELETE FROM audit_log WHERE created_at < datetime('now', ?)", (f"-{days} days",))
    conn.execute("DELETE FROM traffic_snapshots WHERE captured_at < datetime('now', ?)", (f"-{days} days",))
    conn.execute("DELETE FROM metric_samples WHERE captured_at < datetime('now', ?)", (f"-{days} days",))
