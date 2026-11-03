#!/usr/bin/env python3
import os
import shutil
import subprocess
import tempfile
from datetime import datetime, timezone
from pathlib import Path

import yaml

config = Path("/etc/hysteria/config.yaml")
backup_dir = Path("/var/backups/hy2-admin/configs")
backup_dir.mkdir(parents=True, exist_ok=True)
backup = backup_dir / ("pre-tls-" + datetime.now(timezone.utc).strftime("%Y%m%dT%H%M%SZ") + ".yaml")
shutil.copy2(config, backup)
data = yaml.safe_load(config.read_text()) or {}
data.pop("acme", None)
data["tls"] = {"cert": "/etc/hysteria/tls/fullchain.pem", "key": "/etc/hysteria/tls/privkey.pem", "sniGuard": "strict"}
data["trafficStats"] = {"listen": "127.0.0.1:9999", "secret": os.environ["HY2_STATS_SECRET"]}
fd, candidate = tempfile.mkstemp(prefix="config.", suffix=".yaml", dir=str(config.parent))
try:
    with os.fdopen(fd, "w") as out:
        yaml.safe_dump(data, out, sort_keys=False, allow_unicode=True)
        out.flush(); os.fsync(out.fileno())
    os.chmod(candidate, 0o640); shutil.chown(candidate, user="root", group="hysteria")
    os.replace(candidate, config)
    result = subprocess.run(["systemctl", "restart", "hysteria-server.service"], check=False)
    health = subprocess.run(["systemctl", "is-active", "hysteria-server.service"], capture_output=True, text=True)
    if result.returncode or health.stdout.strip() != "active":
        shutil.copy2(backup, config)
        subprocess.run(["systemctl", "restart", "hysteria-server.service"], check=False)
        raise SystemExit("migration failed; restored previous config")
    print(f"MIGRATION_OK backup={backup.name}")
finally:
    if os.path.exists(candidate): os.unlink(candidate)
