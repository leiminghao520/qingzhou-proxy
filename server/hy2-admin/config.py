import os
from pathlib import Path

BASE_DIR = Path(__file__).resolve().parent
DATA_DIR = Path(os.environ.get("HY2_DATA_DIR", "/var/lib/hy2-admin"))
DATABASE = Path(os.environ.get("HY2_DATABASE", DATA_DIR / "hy2-admin.sqlite3"))
SECRET_KEY = os.environ.get("HY2_SECRET_KEY")
ENCRYPTION_KEY = os.environ.get("HY2_ENCRYPTION_KEY")
SESSION_COOKIE_SECURE = os.environ.get("HY2_COOKIE_SECURE", "1") == "1"
LOGIN_LIMIT = int(os.environ.get("HY2_LOGIN_LIMIT", "5"))
LOGIN_WINDOW_SECONDS = int(os.environ.get("HY2_LOGIN_WINDOW", "300"))
SERVER_NAME = os.environ.get("HY2_SERVER_NAME", "proxy.lmh1103.icu")
SERVER_PORT = int(os.environ.get("HY2_SERVER_PORT", "443"))
PUBLIC_BASE_URL = os.environ.get("HY2_PUBLIC_BASE_URL", "https://sub.lmh1103.icu")
STATS_URL = os.environ.get("HY2_STATS_URL", "http://127.0.0.1:9999")
STATS_SECRET = os.environ.get("HY2_STATS_SECRET")
HELPER_PATH = os.environ.get("HY2_HELPER_PATH", "/usr/local/sbin/hy2-admin-helper")
