#!/usr/bin/env python3
"""Read the HH515L API used by its GUI and check traffic before an automatic test."""

from __future__ import annotations

import base64
import hashlib
import hmac
import json
import math
import os
import secrets
import string
import sys
import tempfile
import time
from http.cookiejar import CookieJar
from pathlib import Path
from urllib.error import HTTPError, URLError
from urllib.parse import urlsplit
from urllib.request import HTTPCookieProcessor, HTTPRedirectHandler, ProxyHandler, Request, build_opener

from cryptography.hazmat.primitives import padding, serialization
from cryptography.hazmat.primitives.asymmetric import padding as rsa_padding
from cryptography.hazmat.primitives.asymmetric.rsa import RSAPublicKey
from cryptography.hazmat.primitives.ciphers import Cipher, algorithms, modes


class RouterUnavailable(Exception):
    """Only fixed, non-sensitive reasons may reach status sensors or logs."""


class NoRedirect(HTTPRedirectHandler):
    def redirect_request(self, req, fp, code, msg, headers, newurl):
        raise RouterUnavailable("router-redirect")


def compact(value: object) -> bytes:
    return json.dumps(value, separators=(",", ":"), ensure_ascii=False).encode()


def encrypt(plaintext: bytes, key: str) -> str:
    # OpenSSL-compatible format used by the installed HH515L TI v4.0 frontend.
    salt = secrets.token_bytes(8)
    material = hashlib.pbkdf2_hmac("sha256", key.encode(), salt, 50, 48)
    padder = padding.PKCS7(128).padder()
    padded = padder.update(plaintext) + padder.finalize()
    cipher = Cipher(algorithms.AES(material[:32]), modes.CBC(material[32:]))
    encryptor = cipher.encryptor()
    return base64.b64encode(b"Salted__" + salt + encryptor.update(padded) + encryptor.finalize()).decode()


def decrypt(ciphertext: str, key: str) -> object:
    try:
        data = base64.b64decode(ciphertext, validate=True)
        if len(data) < 32 or data[:8] != b"Salted__":
            raise ValueError("format")
        material = hashlib.pbkdf2_hmac("sha256", key.encode(), data[8:16], 50, 48)
        cipher = Cipher(algorithms.AES(material[:32]), modes.CBC(material[32:]))
        decryptor = cipher.decryptor()
        padded = decryptor.update(data[16:]) + decryptor.finalize()
        unpadder = padding.PKCS7(128).unpadder()
        return json.loads(unpadder.update(padded) + unpadder.finalize())
    except (ValueError, TypeError) as error:
        raise RouterUnavailable("router-response") from error


def object_result(value: object) -> dict[str, object]:
    if not isinstance(value, dict) or not all(isinstance(key, str) for key in value):
        raise RouterUnavailable("router-response")
    return value


def text_field(data: dict[str, object], key: str) -> str:
    value = data.get(key)
    if not isinstance(value, str) or not value:
        raise RouterUnavailable("router-response")
    return value


class TclRouter:
    def __init__(self, address: str, password: str):
        parsed = urlsplit(address)
        if (parsed.scheme not in {"http", "https"} or not parsed.hostname or parsed.username
                or parsed.password or parsed.path not in {"", "/"} or parsed.query or parsed.fragment):
            raise RouterUnavailable("router-address")
        if not password:
            raise RouterUnavailable("router-password-missing")
        self.address = address.rstrip("/")
        self.password = password
        self.session = "webui"
        self.token = ""
        alphabet = string.ascii_letters + string.digits
        self.key = "".join(secrets.choice(alphabet) for _ in range(128))
        self.hmac_key = "".join(secrets.choice(alphabet) for _ in range(32))
        self.opener = build_opener(ProxyHandler({}), NoRedirect(), HTTPCookieProcessor(CookieJar()))
        # The installed firmware rejects authenticated status calls without Referer.
        self.opener.addheaders = [("Referer", self.address + "/")]
        self.request_id = 0

    def call(self, method: str, params: object = None, *, encrypted: bool = True) -> dict[str, object]:
        self.request_id += 1
        timestamp = int(time.time() * 1000)
        payload = object_result({} if params is None else params) if encrypted else params
        signature = ""
        if encrypted:
            plaintext = compact({**object_result(payload), "_": timestamp})
            signature = hmac.new(self.hmac_key.encode(), plaintext, hashlib.sha256).hexdigest()
            payload = encrypt(plaintext, self.key)
        headers = {
            "Content-Type": "application/json",
            # Public constant from the router frontend, not a credential.
            "_TclRequestVerificationKey": "KSDHSDFOGQ5WERYTUIQWERTYUISDFG1HJZXCVCXBN2GDSMNDHKVKFsVBNf",
            "device_name": "HH515L", "custom_id": "TI", "sessionid": self.session,
        }
        if self.token:
            headers["_TclRequestVerificationToken"] = self.token
        body = compact({"_": timestamp, "id": str(self.request_id), "jsonrpc": "2.0",
                        "method": method, "params": payload, "hmac": signature})
        request = Request(self.address + "/jrd/webapi?name=" + method, data=body, headers=headers)
        try:
            with self.opener.open(request, timeout=5) as response:
                data = object_result(json.loads(response.read(1024 * 1024)))
        except (HTTPError, URLError, TimeoutError, OSError) as error:
            raise RouterUnavailable("router-unreachable") from error
        except (ValueError, TypeError) as error:
            raise RouterUnavailable("router-response") from error
        if "error" in data:
            error = data["error"]
            if isinstance(error, dict) and str(error.get("code")) == "-32699":
                raise RouterUnavailable("router-unauthorized")
            raise RouterUnavailable("router-api-error")
        result = data.get("result")
        if method != "GetPubKey":
            if not isinstance(result, str):
                raise RouterUnavailable("router-response")
            result = decrypt(result, self.key)
        return object_result(result)

    def login(self) -> None:
        public = self.call("GetPubKey", {}, encrypted=False)
        encoded_key = text_field(public, "publicKey").replace("\\n", "\n")
        try:
            if encoded_key.startswith("-----BEGIN"):
                key = serialization.load_pem_public_key(encoded_key.encode())
            else:
                key = serialization.load_der_public_key(base64.b64decode(encoded_key, validate=True))
            if not isinstance(key, RSAPublicKey):
                raise ValueError("key")
            exchange = key.encrypt(compact({"TmpKey": self.key, "HmacKey": self.hmac_key}), rsa_padding.PKCS1v15())
        except (ValueError, TypeError) as error:
            raise RouterUnavailable("router-public-key") from error
        session = self.call("SetConfidentKey", base64.b64encode(exchange).decode(), encrypted=False)
        self.session = text_field(session, "SessionId")
        device = self.call("GetDeviceSt")
        password = hashlib.pbkdf2_hmac("sha512", self.password.encode(), text_field(device, "Salt").encode(), 1024, 64).hex()
        # Encoded 'admin' from the installed frontend's username transformation.
        result = self.call("Login", {"UserName": "dc13ibej?7", "Password": password})
        self.token = text_field(result, "token")

    def traffic(self) -> tuple[float, float]:
        result = self.call("GetConnectionState")
        rates = []
        for key in ("Speed_Dl", "Speed_Ul"):
            value = result.get(key)
            if isinstance(value, bool) or not isinstance(value, (int, float)) or not math.isfinite(value) or value < 0:
                raise RouterUnavailable("router-traffic-invalid")
            rates.append(value / 1_000_000)
        return rates[0], rates[1]


def number(value: object) -> bool:
    return (not isinstance(value, bool) and isinstance(value, (int, float))
            and math.isfinite(value))


def threshold_value(value: object) -> float:
    if not number(value) or value <= 0:
        raise RouterUnavailable("router-options-invalid")
    return float(value)


def decision(samples: list[tuple[float, float]], threshold: float,
             window_seconds: float = 60) -> dict[str, object]:
    """Integrate three complete, adjacent windows, splitting samples at their boundaries."""
    if len(samples) < 2:
        raise RouterUnavailable("router-traffic-incomplete")
    end = samples[-1][0]
    start = end - 3 * window_seconds
    if samples[0][0] > start:
        raise RouterUnavailable("router-traffic-incomplete")
    totals = [0.0, 0.0, 0.0]
    for (left_at, left_rate), (right_at, right_rate) in zip(samples, samples[1:]):
        elapsed = right_at - left_at
        if elapsed <= 0 or elapsed > 10:
            raise RouterUnavailable("router-traffic-stale")
        for index in range(3):
            left = max(left_at, start + index * window_seconds)
            right = min(right_at, start + (index + 1) * window_seconds)
            if right <= left:
                continue
            # Linear interpolation preserves the trapezoidal mean when a sample spans a boundary.
            rate_at_left = left_rate + (right_rate - left_rate) * (left - left_at) / elapsed
            rate_at_right = left_rate + (right_rate - left_rate) * (right - left_at) / elapsed
            totals[index] += (rate_at_left + rate_at_right) / 2 * (right - left)
    averages = [total / window_seconds for total in totals]
    return {"state": "busy" if any(average >= threshold for average in averages) else "idle",
            "average_mbps": round(sum(averages) / 3, 3),
            "window_averages_mbps": [round(average, 3) for average in averages],
            "observed_seconds": 3 * window_seconds}


def observe(router: TclRouter, threshold: float, duration: float = 180,
            interval: float = 5, window_seconds: float = 60) -> dict[str, object]:
    """Startup checks wait for three minutes; every complete minute must be below the limit."""
    if duration != 3 * window_seconds or window_seconds <= 0 or not 0 < interval <= 5:
        raise RouterUnavailable("router-options-invalid")
    threshold = threshold_value(threshold)
    router.login()
    first_rate = sum(router.traffic())
    start = time.monotonic()
    samples = [(start, first_rate)]
    while samples[-1][0] - start < duration:
        time.sleep(min(interval, duration - (samples[-1][0] - start)))
        rate = sum(router.traffic())
        now = time.monotonic()
        elapsed = now - samples[-1][0]
        if elapsed <= 0 or elapsed > 10:
            raise RouterUnavailable("router-traffic-stale")
        samples.append((now, rate))
    return decision(samples, threshold, window_seconds)


def write_snapshot(path: Path, value: object) -> None:
    """Only traffic values and fixed status reasons leave the router process."""
    temporary = None
    try:
        with tempfile.NamedTemporaryFile(mode="wb", dir=path.parent, prefix=path.name + ".",
                                         delete=False) as stream:
            temporary = Path(stream.name)
            os.chmod(temporary, 0o600)
            stream.write(compact(value))
        os.replace(temporary, path)
    finally:
        if temporary is not None:
            temporary.unlink(missing_ok=True)


def monitor(router: TclRouter, path: Path) -> None:
    """The scheduler owns this short-lived monitor and stops it after the scheduled checks."""
    router.login()
    samples: list[tuple[float, float]] = []
    previous_monotonic = None
    previous_wall = None
    while True:
        rate = sum(router.traffic())
        monotonic = time.monotonic()
        wall = time.time()
        if previous_monotonic is not None:
            elapsed = monotonic - previous_monotonic
            if elapsed <= 0 or elapsed > 10:
                raise RouterUnavailable("router-traffic-stale")
            if abs((wall - previous_wall) - elapsed) > 1:
                raise RouterUnavailable("router-clock-changed")
        samples.append((wall, rate))
        # Keep one sample before the cutoff to interpolate the oldest window's boundary.
        while len(samples) > 2 and samples[1][0] < wall - 190:
            samples.pop(0)
        write_snapshot(path, {"state": "observing", "samples": samples})
        previous_monotonic, previous_wall = monotonic, wall
        time.sleep(5)


def check(path: Path, threshold: float) -> dict[str, object]:
    threshold = threshold_value(threshold)
    try:
        snapshot = object_result(json.loads(path.read_text()))
    except (OSError, ValueError, TypeError) as error:
        raise RouterUnavailable("router-traffic-unavailable") from error
    if snapshot.get("state") != "observing":
        reason = snapshot.get("reason")
        if reason in {"router-unauthorized", "router-password-missing", "router-unreachable",
                      "router-traffic-incomplete", "router-traffic-stale", "router-clock-changed"}:
            raise RouterUnavailable(reason)
        raise RouterUnavailable("router-traffic-unavailable")
    raw_samples = snapshot.get("samples")
    if not isinstance(raw_samples, list) or not 2 <= len(raw_samples) <= 128:
        raise RouterUnavailable("router-traffic-incomplete")
    samples = []
    for sample in raw_samples:
        if (not isinstance(sample, list) or len(sample) != 2 or not all(number(value) for value in sample)
                or sample[1] < 0):
            raise RouterUnavailable("router-traffic-invalid")
        samples.append((float(sample[0]), float(sample[1])))
    age = time.time() - samples[-1][0]
    if age < 0 or age > 10:
        raise RouterUnavailable("router-traffic-stale")
    return decision(samples, threshold)


def configured_router(path: Path) -> tuple[TclRouter, float]:
    options = object_result(json.loads(path.read_text()))
    protection = object_result(options.get("protection", {}))
    address = protection.get("router_url", "http://192.168.3.1")
    password = protection.get("password", "")
    threshold = threshold_value(protection.get("threshold_mbps", 2))
    if not isinstance(address, str) or not isinstance(password, str):
        raise RouterUnavailable("router-options-invalid")
    return TclRouter(address, password), threshold


def main() -> int:
    snapshot_path = None
    try:
        if sys.argv[1] == "check":
            result = check(Path(sys.argv[2]), float(sys.argv[3]))
        elif sys.argv[1] == "monitor":
            snapshot_path = Path(sys.argv[3])
            router, _ = configured_router(Path(sys.argv[2]))
            # Replace any history from an earlier monitor before authenticating.
            write_snapshot(snapshot_path, {"state": "unavailable", "reason": "router-traffic-incomplete"})
            monitor(router, snapshot_path)
            return 0
        else:
            router, threshold = configured_router(Path(sys.argv[1]))
            result = observe(router, threshold)
    except RouterUnavailable as error:
        result = {"state": "unavailable", "reason": str(error)}
    except (OSError, ValueError, IndexError, TypeError):
        result = {"state": "unavailable", "reason": "router-options-invalid"}
    if snapshot_path is not None:
        try:
            write_snapshot(snapshot_path, result)
        except OSError:
            result = {"state": "unavailable", "reason": "router-snapshot-unavailable"}
    print(json.dumps(result))
    return {"idle": 0, "busy": 2}.get(result["state"], 3)


if __name__ == "__main__":
    sys.exit(main())
