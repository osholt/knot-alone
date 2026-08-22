#!/usr/bin/env python3
"""Ask App Store Connect for the next unused Tide and Seek build number.

Reads APPSTORE_CONNECT_API_KEY_ID and APPSTORE_CONNECT_API_ISSUER_ID from the
environment and the matching private key from
~/.appstoreconnect/private_keys/AuthKey_<KEY_ID>.p8. Prints the highest build
number Apple already holds for the requested bundle ID, plus one.
"""

from __future__ import annotations

import base64
import json
import os
import pathlib
import sys
import time
import urllib.error
import urllib.request

from cryptography.hazmat.primitives import hashes, serialization
from cryptography.hazmat.primitives.asymmetric import ec
from cryptography.hazmat.primitives.asymmetric.utils import decode_dss_signature

API_ROOT = "https://api.appstoreconnect.apple.com/v1"


def _b64(payload: bytes) -> str:
    return base64.urlsafe_b64encode(payload).rstrip(b"=").decode()


def token(key_id: str, issuer_id: str, key_path: pathlib.Path) -> str:
    private_key = serialization.load_pem_private_key(key_path.read_bytes(), password=None)
    if not isinstance(private_key, ec.EllipticCurvePrivateKey):
        raise SystemExit("the App Store Connect key is not an EC private key")

    now = int(time.time())
    header = {"alg": "ES256", "kid": key_id, "typ": "JWT"}
    claims = {
        "iss": issuer_id,
        "iat": now,
        "exp": now + 600,
        "aud": "appstoreconnect-v1",
    }
    signing_input = f"{_b64(json.dumps(header).encode())}.{_b64(json.dumps(claims).encode())}"
    der = private_key.sign(signing_input.encode(), ec.ECDSA(hashes.SHA256()))
    r, s = decode_dss_signature(der)
    signature = r.to_bytes(32, "big") + s.to_bytes(32, "big")
    return f"{signing_input}.{_b64(signature)}"


def get(path: str, bearer: str) -> dict:
    url = f"{API_ROOT}{path}"
    if not url.startswith("https://api.appstoreconnect.apple.com/"):
        raise SystemExit(f"refusing to send a token to {url}")
    request = urllib.request.Request(  # noqa: S310 - URL is pinned above
        url,
        headers={"Authorization": f"Bearer {bearer}"},
    )
    with urllib.request.urlopen(request, timeout=30) as response:  # noqa: S310
        return json.load(response)


def main(argv: list[str]) -> int:
    if len(argv) != 2:
        print(__doc__, file=sys.stderr)
        return 2
    bundle_id = argv[1]

    key_id = os.environ.get("APPSTORE_CONNECT_API_KEY_ID", "")
    issuer_id = os.environ.get("APPSTORE_CONNECT_API_ISSUER_ID", "")
    if not key_id or not issuer_id:
        print(
            "next_build_number: set APPSTORE_CONNECT_API_KEY_ID and APPSTORE_CONNECT_API_ISSUER_ID",
            file=sys.stderr,
        )
        return 1

    key_path = pathlib.Path.home() / ".appstoreconnect/private_keys" / f"AuthKey_{key_id}.p8"
    if not key_path.is_file():
        print(f"next_build_number: no private key at {key_path}", file=sys.stderr)
        return 1

    try:
        bearer = token(key_id, issuer_id, key_path)
        apps = get(f"/apps?filter[bundleId]={bundle_id}&limit=1", bearer)
        if not apps.get("data"):
            print(
                f"next_build_number: no app record for {bundle_id}",
                file=sys.stderr,
            )
            return 1
        app_id = apps["data"][0]["id"]
        builds = get(
            f"/builds?filter[app]={app_id}&limit=200&fields[builds]=version",
            bearer,
        )
    except urllib.error.HTTPError as error:
        detail = error.read().decode(errors="replace")[:400]
        print(
            f"next_build_number: {error.code} from Apple: {detail}",
            file=sys.stderr,
        )
        return 1
    except OSError as error:
        print(f"next_build_number: {error}", file=sys.stderr)
        return 1

    numbers = []
    for build in builds.get("data", []):
        version = build.get("attributes", {}).get("version")
        if version and version.isdigit():
            numbers.append(int(version))
    print(max(numbers, default=0) + 1)
    return 0


if __name__ == "__main__":
    raise SystemExit(main(sys.argv))
