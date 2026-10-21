#!/usr/bin/env python3
"""Verify live subscription endpoints without printing credentials or tokens."""

import json
import urllib.request
from contextlib import closing

import yaml

from app import create_app
from db import connect


def main():
    app = create_app()
    with closing(connect(app.config["DATABASE"])) as db:
        row = db.execute(
            "SELECT d.encrypted_token FROM devices d JOIN proxy_users u ON u.id=d.user_id "
            "WHERE d.enabled=1 AND u.enabled=1 "
            "ORDER BY CASE u.role WHEN 'owner' THEN 0 ELSE 1 END,d.id LIMIT 1"
        ).fetchone()
    if not row:
        raise SystemExit("VERIFY_FAILED no enabled device")

    token = app.fernet.decrypt(row["encrypted_token"]).decode()
    formats = {
        "hy2.txt": "text/plain",
        "shadowrocket.conf": "text/plain",
        "shadowrocket-full.conf": "text/plain",
        "mihomo.yaml": "application/yaml",
        "sing-box.json": "application/json",
    }
    for filename, expected_type in formats.items():
        url = f"{app.config['PUBLIC_BASE_URL']}/s/{token}/{filename}"
        try:
            with urllib.request.urlopen(url, timeout=15) as response:
                body = response.read().decode()
                content_type = response.headers.get_content_type()
                assert response.status == 200
                assert content_type == expected_type
                assert response.headers.get("Cache-Control") == "no-store"
                assert response.headers.get("X-Robots-Tag") == "noindex, nofollow"
            if filename == "hy2.txt":
                assert body.startswith("hysteria2://")
            elif filename == "shadowrocket.conf":
                assert body.startswith("hysteria2://")
            elif filename == "shadowrocket-full.conf":
                assert all(section in body for section in ("[General]", "[Proxy]", "[Proxy Group]", "[Rule]"))
            elif filename == "mihomo.yaml":
                config = yaml.safe_load(body)
                assert config["rules"][-1] == "MATCH,PROXY"
                assert config["proxy-groups"][0]["name"] == "PROXY"
            else:
                config = json.loads(body)
                assert config["route"]["final"] == "proxy"
                assert config["dns"]["final"] == "dns-global"
        except Exception:
            raise SystemExit(f"VERIFY_FAILED {filename}") from None
        print(f"VERIFY_OK {filename} status=200 type={content_type} bytes={len(body.encode())}")


if __name__ == "__main__":
    main()
