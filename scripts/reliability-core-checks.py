#!/usr/bin/env python3
"""使用仓库固定核心验证自动组故障切换；只监听回环端口，不接管系统网络。"""
import http.client
import http.server
import json
import pathlib
import socket
import subprocess
import tempfile
import threading
import time
import urllib.request

ROOT = pathlib.Path(__file__).resolve().parent.parent
CORE = ROOT / "Vendor/sing-box"
opener = urllib.request.build_opener(urllib.request.ProxyHandler({}))


def port():
    with socket.socket() as sock:
        sock.bind(("127.0.0.1", 0))
        return sock.getsockname()[1]


class Origin(http.server.BaseHTTPRequestHandler):
    def do_GET(self):
        self.send_response(204)
        self.end_headers()

    def log_message(self, *_):
        pass


def stop(process):
    if process.poll() is None:
        process.terminate()
        try:
            process.wait(timeout=3)
        except subprocess.TimeoutExpired:
            process.kill()
            process.wait()


def main():
    processes = []
    origin = http.server.ThreadingHTTPServer(("127.0.0.1", 0), Origin)
    threading.Thread(target=origin.serve_forever, daemon=True).start()
    try:
        with tempfile.TemporaryDirectory(prefix="qingzhou-reliability-") as folder:
            directory = pathlib.Path(folder)
            with (directory / "core.log").open("w") as log:
                def start(name, config, listen):
                    path = directory / (name + ".json")
                    path.write_text(json.dumps(config))
                    process = subprocess.Popen([str(CORE), "run", "-c", str(path)], stdout=log, stderr=log)
                    processes.append(process)
                    for _ in range(100):
                        if process.poll() is not None:
                            raise RuntimeError("隔离核心提前退出：" + (directory / "core.log").read_text()[-1500:])
                        try:
                            with socket.create_connection(("127.0.0.1", listen), timeout=.1):
                                return process
                        except OSError:
                            time.sleep(.05)
                    raise RuntimeError("隔离核心启动超时")

                a, b, entry, control = port(), port(), port(), port()
                def gateway(listen):
                    return {"log": {"level": "error"}, "inbounds": [{"type": "mixed", "listen": "127.0.0.1", "listen_port": listen}], "outbounds": [{"type": "direct", "tag": "direct"}]}

                first = start("A", gateway(a), a)
                url = f"http://127.0.0.1:{origin.server_port}/generate_204"
                start("client", {
                    "log": {"level": "error"},
                    "inbounds": [{"type": "mixed", "listen": "127.0.0.1", "listen_port": entry}],
                    "outbounds": [
                        {"type": "socks", "tag": "A", "server": "127.0.0.1", "server_port": a},
                        {"type": "socks", "tag": "B", "server": "127.0.0.1", "server_port": b},
                        {"type": "urltest", "tag": "auto", "outbounds": ["A", "B"], "url": url, "interval": "5m", "tolerance": 50},
                        {"type": "selector", "tag": "proxy", "outbounds": ["auto", "A", "B"], "default": "auto"}],
                    "route": {"final": "proxy"},
                    "experimental": {"clash_api": {"external_controller": f"127.0.0.1:{control}", "secret": "isolated-fixture"}}
                }, control)

                def api(path, value=None):
                    body = None if value is None else json.dumps(value).encode()
                    request = urllib.request.Request(f"http://127.0.0.1:{control}" + path, data=body, method="GET" if body is None else "PUT", headers={"Authorization": "Bearer isolated-fixture", "Content-Type": "application/json"})
                    with opener.open(request, timeout=12) as response:
                        data = response.read()
                        return json.loads(data) if data else None

                api("/group/auto/delay?timeout=8000")
                assert api("/proxies")["proxies"]["auto"]["now"] == "A", "初始自动组没有选择优先节点 A"
                start("B", gateway(b), b)
                stop(first)
                api("/group/auto/delay?timeout=8000")
                info = api("/proxies")["proxies"]
                assert info["auto"]["now"] == "B" and info["proxy"]["now"] == "auto", "A 故障后应转 B 且保留自动策略"
                print("PASS real core: A 故障转 B，用户选择仍为 auto")
                # 显式请求代理端口，避免环境 NO_PROXY 对回环地址的绕过。
                conn = http.client.HTTPConnection("127.0.0.1", entry, timeout=4)
                conn.request("GET", url)
                assert conn.getresponse().status == 204, "B 出口没有恢复实际请求"
                conn.close()
                print("PASS real core: B 出口实际 HTTP 转发恢复")
                api("/proxies/proxy", {"name": "A"})
                assert api("/proxies")["proxies"]["proxy"]["now"] == "A", "手动选择被改写"
                print("PASS real core: 手动 A 保持固定，不被自动组覆盖")
                print("RESULT reliability_real_core_assertions=4 failures=0")
    finally:
        for process in reversed(processes):
            stop(process)
        origin.shutdown()
        origin.server_close()


if __name__ == "__main__":
    main()
