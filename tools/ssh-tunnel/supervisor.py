#!/usr/bin/env python3
"""监护外部 SSH 转发：持续验证 TLS 数据通道，卡死后有退避地重建。"""

import argparse
import datetime
import signal
import socket
import ssl
import subprocess
import threading


def tls_probe(port, server_name, timeout=5):
    # 验证证书和主机名，不能把本地端口仍在监听当成通道可用。
    context = ssl.create_default_context()
    with socket.create_connection(("127.0.0.1", port), timeout=timeout) as connection:
        with context.wrap_socket(connection, server_hostname=server_name):
            pass


def stop_child(child):
    if child.poll() is None:
        child.terminate()
        try:
            child.wait(timeout=5)
        except subprocess.TimeoutExpired:
            child.kill()
            child.wait()


def supervise(command, probe, stopped, wait=None, launch=subprocess.Popen, log=print):
    wait = wait or stopped.wait
    backoff = 5
    while not stopped.is_set():
        child = launch(command)
        failures = 0
        recovered = False
        try:
            # 给 SSH 建连和远端转发预留时间；停止信号随时打断等待。
            if wait(10):
                return
            while not stopped.is_set() and child.poll() is None:
                try:
                    probe()
                    if failures:
                        log("SSH 转发数据通道已恢复")
                    failures = 0
                    recovered = True
                except (OSError, ssl.SSLError):
                    failures += 1
                    log("SSH 转发 TLS 检查失败，连续次数=" + str(failures))
                    if failures >= 3:
                        log("SSH 转发数据通道持续不可用，重建连接")
                        break
                if wait(15):
                    return
        finally:
            # 只处理本监护器创建的子进程，不扫描或终止其他 SSH 连接。
            stop_child(child)
        if stopped.is_set():
            return
        if recovered:
            backoff = 5
        log("SSH 转发等待重连，秒数=" + str(backoff))
        if wait(backoff):
            return
        backoff = min(backoff * 2, 120)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--probe-port", type=int, required=True)
    parser.add_argument("--server-name", required=True)
    parser.add_argument("command", nargs=argparse.REMAINDER)
    args = parser.parse_args()
    command = args.command[1:] if args.command[:1] == ["--"] else args.command
    if not command or command[0] != "/usr/bin/ssh" or not 1 <= args.probe_port <= 65535:
        parser.error("需要有效探测端口和 /usr/bin/ssh 命令")
    stopped = threading.Event()
    for event in [signal.SIGTERM, signal.SIGINT]:
        signal.signal(event, lambda *_: stopped.set())

    def log(message):
        print(datetime.datetime.now().astimezone().isoformat(timespec="seconds"), message, flush=True)

    supervise(command, lambda: tls_probe(args.probe_port, args.server_name), stopped, log=log)


if __name__ == "__main__":
    main()
