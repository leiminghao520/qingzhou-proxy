#!/usr/bin/env python3
import os
import sqlite3
from cryptography.fernet import Fernet

db = os.environ["HY2_DATABASE"]
fernet = Fernet(os.environ["HY2_ENCRYPTION_KEY"])
conn = sqlite3.connect(db)
rows = conn.execute("SELECT id,totp_secret FROM admins").fetchall()
updated = 0
for admin_id, value in rows:
    raw = value if isinstance(value, bytes) else value.encode()
    try:
        fernet.decrypt(raw)
    except Exception:
        conn.execute("UPDATE admins SET totp_secret=? WHERE id=?", (fernet.encrypt(raw), admin_id)); updated += 1
conn.commit(); conn.close()
print(f"TOTP_MIGRATION_OK updated={updated}")
