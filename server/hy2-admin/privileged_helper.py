#!/usr/bin/env python3
"""Root-owned allow-listed bridge for Hysteria configuration and service state."""
import json
import os
import subprocess
import sys

def run(argv, timeout=15):
    return subprocess.run(argv, stdout=subprocess.PIPE, stderr=subprocess.PIPE,
                          text=True, timeout=timeout, check=False)

def status():
    h = run(["systemctl", "is-active", "hysteria-server.service"])
    n = run(["systemctl", "is-active", "nginx.service"])
    a = run(["systemctl", "is-active", "hy2-auth.service"])
    generation = run(["systemctl", "show", "hysteria-server.service", "--property=InvocationID", "--value"])
    return {"hysteria": h.stdout.strip(), "nginx": n.stdout.strip(), "auth": a.stdout.strip(),
            "generation": generation.stdout.strip() if h.returncode == 0 and generation.returncode == 0 else None,
            "ok": h.returncode == n.returncode == a.returncode == 0}

def main():
    if os.geteuid() != 0: raise SystemExit("must run as root")
    if len(sys.argv) != 2: raise SystemExit("one operation required")
    op = sys.argv[1]
    if op == "status": result = status()
    elif op == "reload":
        n = run(["nginx", "-t"])
        if n.returncode: raise RuntimeError("nginx validation failed")
        result = run(["systemctl", "reload", "nginx.service"])
        if result.returncode: raise RuntimeError("nginx reload failed")
        result = {"ok": True, **status()}
    # Version 2 rollback must restore code, database and configuration together.
    else: raise SystemExit("operation not allowed")
    print(json.dumps(result, ensure_ascii=False))

if __name__ == "__main__":
    try: main()
    except Exception as exc:
        print(str(exc), file=sys.stderr); raise SystemExit(1)
