from __future__ import annotations

import base64
import hashlib
import hmac
import json
import os
from typing import Any

from cryptography.hazmat.primitives.ciphers.aead import AESGCM


def base64url(value: bytes) -> str:
    return base64.urlsafe_b64encode(value).decode("ascii").rstrip("=")


def sha256(value: bytes) -> bytes:
    return hashlib.sha256(value).digest()


def token_hash(token: str) -> bytes:
    return sha256(token.encode("ascii"))


class DataCipher:
    def __init__(self, key: bytes) -> None:
        self._cipher = AESGCM(key)

    def encrypt_json(self, value: Any, *, associated_data: bytes) -> bytes:
        nonce = os.urandom(12)
        plaintext = json.dumps(
            value,
            separators=(",", ":"),
            ensure_ascii=False,
            allow_nan=False,
        ).encode("utf-8")
        return nonce + self._cipher.encrypt(nonce, plaintext, associated_data)

    def decrypt_json(self, value: bytes, *, associated_data: bytes) -> Any:
        if len(value) < 29:
            raise ValueError("encrypted value is truncated")
        plaintext = self._cipher.decrypt(value[:12], value[12:], associated_data)
        return json.loads(plaintext)


class CursorCodec:
    prefix = "rrc1"

    def __init__(self, key: bytes) -> None:
        self._key = key

    def encode(self, ride_id: str, sequence: int) -> str:
        message = f"{ride_id}\n{sequence}".encode()
        signature = base64url(hmac.new(self._key, message, hashlib.sha256).digest())
        return f"{self.prefix}.{sequence}.{signature}"

    def decode(self, ride_id: str, cursor: str | None) -> int:
        if cursor is None:
            return 0
        parts = cursor.split(".")
        if len(parts) != 3 or parts[0] != self.prefix or not parts[1].isdigit():
            raise ValueError("invalid cursor")
        sequence = int(parts[1])
        if sequence < 0:
            raise ValueError("invalid cursor")
        expected = self.encode(ride_id, sequence)
        if not hmac.compare_digest(cursor, expected):
            raise ValueError("invalid cursor")
        return sequence
