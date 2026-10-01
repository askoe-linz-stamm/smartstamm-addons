"""Protocol and traffic decisions without credentials or an internet speed test."""

import base64
import hashlib
import hmac
import json
import sys
import threading
import unittest
from http.server import BaseHTTPRequestHandler, HTTPServer
from pathlib import Path
from unittest.mock import patch

from cryptography.hazmat.primitives import serialization
from cryptography.hazmat.primitives.asymmetric import padding, rsa

sys.path.insert(0, str(Path(__file__).resolve().parents[1] / "netzmessung"))
from router import RouterUnavailable, TclRouter, compact, decrypt, encrypt, observe


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
            return observe(Source(), threshold, duration=10, interval=5)

    def test_full_window_uses_mean_instead_of_last_sample(self):
        result = self.observation([4, 4, 0], 2)
        self.assertEqual(result, {"state": "busy", "average_mbps": 3, "observed_seconds": 10})

    def test_idle_and_threshold_boundary(self):
        self.assertEqual(self.observation([1, 1, 1], 2)["state"], "idle")
        self.assertEqual(self.observation([2, 2, 2], 2)["state"], "busy")

    def test_missing_window_and_stale_samples_do_not_pass(self):
        with self.assertRaises(StopIteration):
            self.observation([0], 2)
        with self.assertRaisesRegex(RouterUnavailable, "traffic-stale"):
            self.observation([0, 0], 2, extra_delay=6)


if __name__ == "__main__":
    unittest.main()
