#!/usr/bin/env python3
"""Read the HH515L API used by its GUI and check traffic before an automatic test."""

from __future__ import annotations

import base64
import hashlib
import hmac
import json
import math
import secrets
import string
import sys
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


def observe(router: TclRouter, threshold: float, duration: float = 60, interval: float = 5) -> dict[str, object]:
    """Time-weighted samples over a full minute; incomplete observations never mean idle."""
    router.login()
    start = time.monotonic()
    previous_at = start
    previous_rate = sum(router.traffic())
    total = 0.0
    while previous_at - start < duration:
        time.sleep(min(interval, duration - (previous_at - start)))
        rate = sum(router.traffic())
        now = time.monotonic()
        elapsed = now - previous_at
        if elapsed > interval + 5:
            raise RouterUnavailable("router-traffic-stale")
        # Trapezoidal integration avoids favouring a single point at either end.
        total += (previous_rate + rate) / 2 * elapsed
        previous_rate, previous_at = rate, now
    average = total / (previous_at - start)
    return {"state": "busy" if average >= threshold else "idle", "average_mbps": round(average, 3),
            "observed_seconds": round(previous_at - start, 1)}


def main() -> int:
    try:
        options = object_result(json.loads(Path(sys.argv[1]).read_text()))
        protection = object_result(options.get("protection", {}))
        address = protection.get("router_url", "http://192.168.3.1")
        password = protection.get("password", "")
        threshold = protection.get("threshold_mbps", 2)
        if not isinstance(address, str) or not isinstance(password, str):
            raise RouterUnavailable("router-options-invalid")
        if isinstance(threshold, bool) or not isinstance(threshold, (int, float)) or not math.isfinite(threshold) or threshold <= 0:
            raise RouterUnavailable("router-options-invalid")
        result = observe(TclRouter(address, password), threshold)
    except RouterUnavailable as error:
        print(json.dumps({"state": "unavailable", "reason": str(error)}))
        return 3
    except (OSError, ValueError, IndexError, TypeError):
        print(json.dumps({"state": "unavailable", "reason": "router-options-invalid"}))
        return 3
    print(json.dumps(result))
    return 2 if result["state"] == "busy" else 0


if __name__ == "__main__":
    sys.exit(main())
