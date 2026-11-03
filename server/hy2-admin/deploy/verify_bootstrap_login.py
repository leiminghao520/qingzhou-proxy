#!/usr/bin/env python3
import http.cookiejar
import re
import secrets
import urllib.parse
import urllib.request
from pathlib import Path

import pyotp

path = Path("/root/hy2-admin-bootstrap.txt")
values = dict(line.split("=", 1) for line in path.read_text().splitlines() if "=" in line)
secret = urllib.parse.parse_qs(urllib.parse.urlparse(values["TOTP_URI"]).query)["secret"][0]
jar = http.cookiejar.CookieJar()
opener = urllib.request.build_opener(urllib.request.HTTPCookieProcessor(jar), urllib.request.HTTPRedirectHandler())

def csrf(url):
    html = opener.open(url, timeout=10).read().decode()
    return re.search(r'name="csrf_token" value="([^"]+)"', html).group(1)

login_url = "https://admin.lmh1103.icu/login"
token = csrf(login_url)
payload = urllib.parse.urlencode({"username": values["USERNAME"], "password": values["PASSWORD"],
                                  "totp": pyotp.TOTP(secret).now(), "csrf_token": token}).encode()
response = opener.open(urllib.request.Request(login_url, data=payload), timeout=10)
body = response.read().decode()
if response.geturl().rstrip("/") == "https://admin.lmh1103.icu" and "运行概览" in body:
    print("AUTH_FLOW_OK")
    raise SystemExit(0)
if not response.geturl().endswith("/security"): raise SystemExit("login did not reach security page")
token = re.search(r'name="csrf_token" value="([^"]+)"', body).group(1)
new_password = secrets.token_urlsafe(24)
payload = urllib.parse.urlencode({"current_password": values["PASSWORD"], "new_password": new_password,
                                  "totp": pyotp.TOTP(secret).now(), "csrf_token": token}).encode()
response = opener.open(urllib.request.Request("https://admin.lmh1103.icu/security", data=payload), timeout=10)
body = response.read().decode()
if response.geturl().rstrip("/") != "https://admin.lmh1103.icu" or "运行概览" not in body:
    raise SystemExit("password rotation did not reach dashboard")
values["PASSWORD"] = new_password
path.write_text("\n".join(f"{k}={v}" for k, v in values.items()) + "\n")
path.chmod(0o600)
print("AUTH_FLOW_OK")
