"""用隔离子进程和时钟验证转发卡死、恢复和取消，不触碰真实网络。"""

import threading
import unittest
from unittest.mock import patch

import supervisor


class Child:
    def __init__(self, exited=False):
        self.exited = exited
        self.terminations = 0

    def poll(self):
        return 1 if self.exited else None

    def terminate(self):
        self.terminations += 1
        self.exited = True

    def wait(self, timeout=None):
        return 0


class SupervisorTests(unittest.TestCase):
    def run_scenario(self, results, stop_after):
        stopped = threading.Event()
        children, waits = [], []
        probes = iter(results)
        calls = 0

        def launch(_):
            child = Child()
            children.append(child)
            return child

        def probe():
            nonlocal calls
            calls += 1
            result = next(probes)
            if calls == stop_after:
                stopped.set()
            if not result:
                raise OSError("注入通道超时")

        def wait(delay):
            waits.append(delay)
            return stopped.is_set()

        supervisor.supervise(["隔离 SSH"], probe, stopped, wait, launch, lambda _: None)
        return children, waits

    def test_stalled_live_process_is_rebuilt(self):
        children, waits = self.run_scenario([False, False, False, True], 4)
        self.assertEqual(len(children), 2)
        self.assertEqual([child.terminations for child in children], [1, 1])
        self.assertEqual(waits, [10, 15, 15, 5, 10, 15])

    def test_transient_failure_keeps_session(self):
        children, _ = self.run_scenario([False, False, True, True], 4)
        self.assertEqual(len(children), 1)

    def test_exited_process_retries_with_bounded_backoff_until_cancelled(self):
        stopped = threading.Event()
        delays = []

        def wait(delay):
            delays.append(delay)
            if len(delays) == 20:
                stopped.set()
            return stopped.is_set()

        supervisor.supervise([], lambda: self.fail("已退出进程不能探测"), stopped,
                             wait, lambda _: Child(exited=True), lambda _: None)
        self.assertEqual(delays[1::2], [5, 10, 20, 40, 80, 120, 120, 120, 120, 120])

    def test_cancel_during_startup_cleans_up_owned_child(self):
        stopped = threading.Event()
        child = Child()

        def wait(_):
            stopped.set()
            return True

        supervisor.supervise([], lambda: self.fail("已取消不能探测"), stopped,
                             wait, lambda _: child, lambda _: None)
        self.assertEqual(child.terminations, 1)

    def test_tls_probe_requires_server_certificate_and_closes_sockets(self):
        with patch.object(supervisor.socket, "create_connection") as connect, \
                patch.object(supervisor.ssl, "create_default_context") as context:
            supervisor.tls_probe(28443, "fixture.example")
            connect.assert_called_once_with(("127.0.0.1", 28443), timeout=5)
            context.return_value.wrap_socket.assert_called_once_with(
                connect.return_value.__enter__.return_value, server_hostname="fixture.example")
            connect.return_value.__exit__.assert_called_once()
            context.return_value.wrap_socket.return_value.__exit__.assert_called_once()


if __name__ == "__main__":
    unittest.main()
