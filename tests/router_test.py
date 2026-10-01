"""Protocol and traffic decisions without credentials or an internet speed test."""

import base64
import hashlib
import hmac
import json
import io
from contextlib import redirect_stdout
import sys
import tempfile
import threading
import unittest
from http.server import BaseHTTPRequestHandler, HTTPServer
from pathlib import Path
from unittest.mock import patch

from cryptography.hazmat.primitives import serialization
from cryptography.hazmat.primitives.asymmetric import padding, rsa

sys.path.insert(0, str(Path(__file__).resolve().parents[1] / "netzmessung"))
from router import RouterUnavailable, TclRouter, check, compact, decrypt, encrypt, main, monitor, observe, write_snapshot


class ProtocolTest(unittest.TestCase):
    def test_encrypted_login_and_protected_status(self):
        key = rsa.generate_private_key(public_exponent=65537, key_size=2048)
        failures = []
        calls = []

        class Handler(BaseHTTPRequestHandler):
            def log_message(self, *args):
                pass

            def do_POST(self):
                try:
                    request = json.loads(self.rfile.read(int(self.headers["Content-Length"])))
                    method = request["method"]
                    calls.append(method)
                    if method == "GetPubKey":
                        result = {"publicKey": key.public_key().public_bytes(
                            serialization.Encoding.PEM, serialization.PublicFormat.SubjectPublicKeyInfo
                        ).decode().replace("\n", "\\n")}
                    elif method == "SetConfidentKey":
                        exchange = json.loads(key.decrypt(base64.b64decode(request["params"]), padding.PKCS1v15()))
                        self.server.exchange = exchange
                        result = {"SessionId": "test-session"}
                    else:
                        exchange = self.server.exchange
                        payload = decrypt(request["params"], exchange["TmpKey"])
                        signature = hmac.new(exchange["HmacKey"].encode(), compact(payload), hashlib.sha256).hexdigest()
                        assert hmac.compare_digest(signature, request["hmac"])
                        assert isinstance(payload["_"], int)
                        assert self.headers["sessionid"] == "test-session"
                        if method == "GetDeviceSt":
                            result = {"Salt": "test-salt"}
                        elif method == "Login":
                            assert payload["UserName"] == "dc13ibej?7"
                            assert payload["Password"] == hashlib.pbkdf2_hmac(
                                "sha512", b"test-password", b"test-salt", 1024, 64).hex()
                            result = {"token": "test-token"}
                        else:
                            assert method == "GetConnectionState"
                            assert self.headers["_TclRequestVerificationToken"] == "test-token"
                            assert self.headers["Referer"] == address + "/"
                            result = {"Speed_Dl": 2_000_000, "Speed_Ul": 500_000}
                    if method != "GetPubKey":
                        result = encrypt(compact(result), self.server.exchange["TmpKey"])
                    body = compact({"result": result})
                except Exception as error:
                    failures.append(error)
                    body = compact({"error": {"code": -32699}})
                self.send_response(200)
                self.send_header("Content-Type", "application/json")
                self.end_headers()
                self.wfile.write(body)

        server = HTTPServer(("127.0.0.1", 0), Handler)
        address = "http://127.0.0.1:" + str(server.server_port)
        worker = threading.Thread(target=server.serve_forever)
        worker.start()
        try:
            router = TclRouter(address, "test-password")
            router.login()
            self.assertEqual(router.traffic(), (2, 0.5))
            self.assertEqual(calls, ["GetPubKey", "SetConfidentKey", "GetDeviceSt", "Login", "GetConnectionState"])
            self.assertEqual(failures, [])
        finally:
            server.shutdown()
            worker.join()
            server.server_close()

    def test_invalid_traffic_never_means_idle(self):
        router = TclRouter("http://127.0.0.1", "test-password")
        for value in [None, "0", -1, True, float("nan"), float("inf")]:
            with self.subTest(value=value), patch.object(router, "call", return_value={"Speed_Dl": value, "Speed_Ul": 0}):
                with self.assertRaisesRegex(RouterUnavailable, "traffic-invalid"):
                    router.traffic()

    def test_credentials_cannot_be_redirected(self):
        class Redirect(BaseHTTPRequestHandler):
            def log_message(self, *args):
                pass

            def do_POST(self):
                self.send_response(302)
                self.send_header("Location", "http://example.invalid/")
                self.end_headers()

        server = HTTPServer(("127.0.0.1", 0), Redirect)
        worker = threading.Thread(target=server.serve_forever)
        worker.start()
        try:
            with self.assertRaisesRegex(RouterUnavailable, "router-redirect"):
                TclRouter("http://127.0.0.1:" + str(server.server_port), "test-password").login()
        finally:
            server.shutdown()
            worker.join()
            server.server_close()


class ObservationTest(unittest.TestCase):
    def observation(self, rates, threshold, extra_delay=0):
        clock = [0]
        samples = iter(rates)

        class Source:
            def login(self):
                pass

            def traffic(self):
                return next(samples), 0

        def sleep(seconds):
            clock[0] += seconds + extra_delay

        with patch("router.time.monotonic", side_effect=lambda: clock[0]), patch("router.time.sleep", side_effect=sleep):
            return observe(Source(), threshold, duration=30, interval=5, window_seconds=10)

    def test_busy_minute_cannot_be_diluted_by_two_idle_minutes(self):
        result = self.observation([0, 0, 0, 4, 4, 0, 0], 2)
        self.assertEqual(result, {"state": "busy", "average_mbps": 1.333,
                                  "window_averages_mbps": [0, 3, 1], "observed_seconds": 30})

    def test_idle_and_threshold_boundary(self):
        self.assertEqual(self.observation([1] * 7, 2)["state"], "idle")
        self.assertEqual(self.observation([2] * 7, 2)["state"], "busy")

    def test_missing_window_and_stale_samples_do_not_pass(self):
        with self.assertRaises(StopIteration):
            self.observation([0], 2)
        with self.assertRaisesRegex(RouterUnavailable, "traffic-stale"):
            self.observation([0, 0], 2, extra_delay=6)

    def test_default_observation_waits_full_three_minutes(self):
        clock = [0]

        class Source:
            def login(self):
                pass

            def traffic(self):
                return 0.2, 0.3

        def sleep(seconds):
            clock[0] += seconds

        with patch("router.time.monotonic", side_effect=lambda: clock[0]), patch("router.time.sleep", side_effect=sleep):
            result = observe(Source(), 2)
        self.assertEqual(clock[0], 180)
        self.assertEqual(result["window_averages_mbps"], [0.5] * 3)


class SnapshotTest(unittest.TestCase):
    def setUp(self):
        self.directory = tempfile.TemporaryDirectory()
        self.addCleanup(self.directory.cleanup)
        self.path = Path(self.directory.name) / "traffic.json"

    def check_samples(self, samples, now=1000, threshold=2):
        write_snapshot(self.path, {"state": "observing", "samples": samples})
        with patch("router.time.time", return_value=now):
            return check(self.path, threshold)

    def test_recent_full_history_passes_without_router_login(self):
        result = self.check_samples([[at, 0.5] for at in range(820, 1001, 5)], now=1009)
        self.assertEqual(result, {"state": "idle", "average_mbps": 0.5,
                                  "window_averages_mbps": [0.5] * 3, "observed_seconds": 180})
        self.assertEqual(self.path.stat().st_mode & 0o777, 0o600)
        self.assertEqual(list(self.path.parent.iterdir()), [self.path])

    def test_busy_latest_minute_cannot_be_hidden_by_quiet_history(self):
        samples = [[at, 0 if at <= 940 else 4] for at in range(820, 1001, 5)]
        result = self.check_samples(samples)
        self.assertEqual(result["state"], "busy")
        self.assertLess(result["average_mbps"], 2)
        self.assertEqual(result["window_averages_mbps"], [0, 0, 3.833])

    def test_samples_across_window_boundaries_are_interpolated(self):
        # Each ten-second segment crosses a minute boundary five seconds from either end.
        samples = [[at, (at - 815) / 100] for at in range(815, 1006, 10)]
        result = self.check_samples(samples, now=1005, threshold=1.6)
        self.assertEqual(result["window_averages_mbps"], [0.4, 1, 1.6])
        self.assertEqual(result["state"], "busy")

    def test_exact_threshold_is_busy(self):
        result = self.check_samples([[at, 2] for at in range(820, 1001, 5)])
        self.assertEqual(result["state"], "busy")

    def test_stale_incomplete_missing_and_failed_history_fail_closed(self):
        samples = [[at, 0] for at in range(820, 1001, 5)]
        with self.assertRaisesRegex(RouterUnavailable, "traffic-stale"):
            self.check_samples(samples, now=1011)
        with self.assertRaisesRegex(RouterUnavailable, "traffic-stale"):
            self.check_samples(samples, now=999)
        with self.assertRaisesRegex(RouterUnavailable, "traffic-incomplete"):
            self.check_samples(samples[1:])
        self.path.unlink()
        with self.assertRaisesRegex(RouterUnavailable, "traffic-unavailable"):
            check(self.path, 2)
        write_snapshot(self.path, {"state": "unavailable", "reason": "router-unreachable"})
        with self.assertRaisesRegex(RouterUnavailable, "router-unreachable"):
            check(self.path, 2)

    def test_invalid_rates_times_and_gaps_fail_closed(self):
        for value in [None, True, "0", -1, float("nan"), float("inf")]:
            samples = [[at, 0] for at in range(820, 1001, 5)]
            samples[10][1] = value
            with self.subTest(value=value), self.assertRaisesRegex(RouterUnavailable, "traffic-invalid"):
                self.check_samples(samples)
        for mutation in (lambda values: values.__delitem__(slice(10, 12)),
                         lambda values: values.__setitem__(10, values[9]),
                         lambda values: values.__setitem__(10, [0, 0])):
            samples = [[at, 0] for at in range(820, 1001, 5)]
            mutation(samples)
            with self.assertRaisesRegex(RouterUnavailable, "traffic-stale"):
                self.check_samples(samples)

    def test_failed_monitor_replaces_previous_history_with_fixed_reason(self):
        write_snapshot(self.path, {"state": "observing", "samples": [[820, 0], [1000, 0]]})
        output = io.StringIO()
        with patch("router.sys.argv", ["router.py", "monitor", "options.json", str(self.path)]), \
                patch("router.configured_router", side_effect=RouterUnavailable("router-unauthorized")), \
                redirect_stdout(output):
            self.assertEqual(main(), 3)
        expected = {"state": "unavailable", "reason": "router-unauthorized"}
        self.assertEqual(json.loads(self.path.read_text()), expected)
        self.assertEqual(json.loads(output.getvalue()), expected)

    def test_monitor_bounds_history_and_detects_wall_clock_jump(self):
        clock = [1000]
        samples_seen = []

        class Source:
            def login(self):
                pass

            def traffic(self):
                return 0.5, 0.5

        def sleep(seconds):
            snapshot = json.loads(self.path.read_text())
            samples_seen.append(snapshot["samples"])
            clock[0] += seconds

        def wall_time():
            return clock[0] if clock[0] <= 1250 else clock[0] + 30

        with patch("router.time.monotonic", side_effect=lambda: clock[0]), patch("router.time.time", side_effect=wall_time), \
                patch("router.time.sleep", side_effect=sleep):
            with self.assertRaisesRegex(RouterUnavailable, "router-clock-changed"):
                monitor(Source(), self.path)
        self.assertLessEqual(len(samples_seen[-1]), 40)
        self.assertGreaterEqual(samples_seen[-1][-1][0] - samples_seen[-1][0][0], 190)
        self.assertNotIn("password", self.path.read_text())


if __name__ == "__main__":
    unittest.main()
