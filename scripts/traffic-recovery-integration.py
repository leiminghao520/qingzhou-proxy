#!/usr/bin/env python3
import base64
import hashlib
import http.server
import json
import pathlib
import socket
import subprocess
import threading

ROOT = pathlib.Path(__file__).resolve().parent.parent
observations = []
closed = threading.Event()


class Traffic(http.server.BaseHTTPRequestHandler):
    protocol_version = "HTTP/1.1"

    def do_GET(self):
        # 仅使用合成密钥，校验每次重连都携带鉴权并访问固定回环接口。
        observations.append((self.path, self.headers.get("Authorization")))
        key = self.headers["Sec-WebSocket-Key"]
        digest = hashlib.sha1((key + "258EAFA5-E914-47DA-95CA-C5AB0DC85B11").encode()).digest()
        self.send_response(101)
        self.send_header("Upgrade", "websocket")
        self.send_header("Connection", "Upgrade")
        self.send_header("Sec-WebSocket-Accept", base64.b64encode(digest).decode())
        self.end_headers()
        payload = json.dumps({"up": 1, "down": 11 if len(observations) == 1 else 22}).encode()
        self.wfile.write(bytes([0x81, len(payload)]) + payload)
        self.wfile.flush()
        if len(observations) == 1:
            # 第一条连接在有效样本后非正常断开，第二条保持到客户端主动取消。
            self.connection.shutdown(socket.SHUT_RDWR)
        else:
            self.connection.settimeout(5)
            try:
                self.connection.recv(1024)
                closed.set()
            except ConnectionResetError:
                closed.set()
            except OSError:
                pass
        self.close_connection = True

    def log_message(self, *_):
        pass


server = http.server.ThreadingHTTPServer(("127.0.0.1", 0), Traffic)
threading.Thread(target=server.serve_forever, daemon=True).start()
try:
    subprocess.run([str(ROOT / ".build/debug/QingzhouChecks"), "traffic-transport-checks", str(server.server_port)], check=True, timeout=15)
    assert observations == [("/traffic", "Bearer synthetic-traffic-secret")] * 2, observations
    assert closed.wait(2), "客户端取消后应关闭 WebSocket"
    print("RESULT traffic_websocket_scenarios=2 failures=0")
finally:
    server.shutdown()
    server.server_close()
