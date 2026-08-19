#!/usr/bin/env python3
"""Put an uploaded build in front of the internal testers.

The half of a release that talks to App Store Connect: wait for processing,
attach the build to an internal beta group, and set the "What to Test" notes
from a file in the repository so they are reviewed in a pull request rather
than typed into a web form.

Separate from `tools/testflight/submit_external.py`, which handles external
groups and beta review. Internal testing needs neither, and conflating them
would put a review submission one flag away from an internal build.

Two behaviours here exist because both were learned the hard way:

* A build is not visible in `/v1/builds` the moment `altool` reports success.
  It took about 2.5 minutes to appear for build 23, so "not found" is a state
  to wait through rather than an error.
* App Store Connect creates an empty `betaBuildLocalizations` record for the
  app's primary locale by itself. POSTing one 409s with "There is an entity
  with same 'locale'", so notes are written with PATCH when a record exists.
"""

from __future__ import annotations

import argparse
import json
import sys
import time
import urllib.error
import urllib.parse
import urllib.request
from pathlib import Path
from typing import Any

API_ROOT = "https://api.appstoreconnect.apple.com/v1"
TERMINAL_PROCESSING_FAILURES = {"FAILED", "INVALID"}

# App Store Connect rejects longer notes outright.
MAX_WHATS_NEW = 4_000


class AppStoreConnectError(RuntimeError):
    """An App Store Connect request or release precondition failed."""


class AppStoreConnectClient:
    def __init__(self, *, issuer_id: str, key_id: str, private_key_path: Path):
        import jwt

        now = int(time.time())
        self._token = jwt.encode(
            {
                "iss": issuer_id,
                "iat": now,
                "exp": now + 1_200,
                "aud": "appstoreconnect-v1",
            },
            private_key_path.read_text(encoding="utf-8"),
            algorithm="ES256",
            headers={"kid": key_id, "typ": "JWT"},
        )

    def request(
        self,
        method: str,
        path: str,
        *,
        query: dict[str, str] | None = None,
        body: dict[str, Any] | None = None,
        expected: tuple[int, ...] = (200,),
    ) -> dict[str, Any]:
        url = f"{API_ROOT}{path}"
        if query:
            url = f"{url}?{urllib.parse.urlencode(query)}"
        request = urllib.request.Request(  # noqa: S310 - see below
            url,
            data=None if body is None else json.dumps(body).encode(),
            method=method,
            headers={
                "Authorization": f"Bearer {self._token}",
                "Content-Type": "application/json",
            },
        )
        try:
            # S310 guards against attacker-chosen schemes. Every URL here is
            # API_ROOT, a literal https:// constant, plus a path this module
            # writes - there is no scheme to choose.
            with urllib.request.urlopen(request, timeout=30) as response:  # noqa: S310
                payload = response.read()
                if response.status not in expected:
                    raise AppStoreConnectError(f"{method} {path} returned HTTP {response.status}")
                return {} if not payload else json.loads(payload)
        except urllib.error.HTTPError as error:
            body_text = error.read().decode(errors="replace")
            try:
                errors = json.loads(body_text).get("errors", [])
                detail = "; ".join(
                    item.get("detail") or item.get("title") or "unknown error" for item in errors
                )
            except json.JSONDecodeError:
                detail = body_text[:500]
            raise AppStoreConnectError(
                f"{method} {path} returned HTTP {error.code}: {detail}"
            ) from error


def _single(items: list[dict[str, Any]], description: str) -> dict[str, Any]:
    if len(items) != 1:
        raise AppStoreConnectError(
            f"Expected one {description}, App Store Connect returned {len(items)}"
        )
    return items[0]


def find_app(client: Any, bundle_id: str) -> dict[str, Any]:
    payload = client.request("GET", "/apps", query={"filter[bundleId]": bundle_id, "limit": "2"})
    return _single(payload.get("data", []), f"app for {bundle_id}")


def wait_for_build(
    client: Any,
    *,
    app_id: str,
    build_number: str,
    timeout_seconds: int,
    poll_seconds: int,
    sleep: Any = time.sleep,
    now: Any = time.monotonic,
) -> dict[str, Any]:
    """Poll until the build processes, treating "not yet visible" as normal."""
    deadline = now() + timeout_seconds
    last_state = "not uploaded yet"
    while True:
        payload = client.request(
            "GET",
            "/builds",
            query={
                "filter[app]": app_id,
                "filter[version]": build_number,
                "sort": "-uploadedDate",
                "limit": "1",
            },
        )
        builds = payload.get("data", [])
        if builds:
            build = builds[0]
            last_state = build.get("attributes", {}).get("processingState", "unknown")
            if last_state == "VALID":
                return build
            if last_state in TERMINAL_PROCESSING_FAILURES:
                raise AppStoreConnectError(f"Build {build_number} processing ended in {last_state}")
        if now() >= deadline:
            raise AppStoreConnectError(
                f"Build {build_number} did not become VALID within "
                f"{timeout_seconds}s (last state: {last_state})"
            )
        print(f"Build {build_number}: {last_state}; waiting for App Store Connect")
        sleep(poll_seconds)


def find_internal_group(client: Any, *, app_id: str, group_name: str) -> dict[str, Any]:
    """The named internal group.

    Internal-only on purpose. Attaching a build to an external group is a
    different act with different consequences - it needs beta review - and this
    script must not be able to do it by being pointed at the wrong name.
    """
    payload = client.request("GET", "/betaGroups", query={"filter[app]": app_id, "limit": "200"})
    matches = [
        group
        for group in payload.get("data", [])
        if group.get("attributes", {}).get("name") == group_name
        and group.get("attributes", {}).get("isInternalGroup", False)
    ]
    return _single(matches, f'internal beta group named "{group_name}"')


def ensure_group_access(
    client: Any, *, build_id: str, group: dict[str, Any], dry_run: bool
) -> bool:
    """Attach the build to the group. Returns whether anything changed."""
    payload = client.request(
        "GET", "/betaGroups", query={"filter[builds]": build_id, "limit": "200"}
    )
    if any(item.get("id") == group["id"] for item in payload.get("data", [])):
        return False
    if not dry_run:
        client.request(
            "POST",
            f"/builds/{build_id}/relationships/betaGroups",
            body={"data": [{"type": "betaGroups", "id": group["id"]}]},
            expected=(204,),
        )
    return True


def set_whats_new(client: Any, *, build_id: str, locale: str, notes: str, dry_run: bool) -> str:
    """Write the tester-facing notes, creating or updating as required.

    App Store Connect creates an empty localisation for the app's primary
    locale by itself, and POSTing over it 409s on the duplicate locale. So the
    existing record is looked for first.
    """
    notes = notes.strip()
    if not notes:
        raise AppStoreConnectError("Release notes are empty; refusing to publish")
    if len(notes) > MAX_WHATS_NEW:
        raise AppStoreConnectError(
            f"Release notes are {len(notes)} characters; the limit is {MAX_WHATS_NEW}"
        )

    payload = client.request(
        "GET", f"/builds/{build_id}/betaBuildLocalizations", query={"limit": "200"}
    )
    existing = [
        item
        for item in payload.get("data", [])
        if item.get("attributes", {}).get("locale") == locale
    ]
    if dry_run:
        return "updated" if existing else "created"
    if existing:
        localization_id = existing[0]["id"]
        client.request(
            "PATCH",
            f"/betaBuildLocalizations/{localization_id}",
            body={
                "data": {
                    "type": "betaBuildLocalizations",
                    "id": localization_id,
                    "attributes": {"whatsNew": notes},
                }
            },
        )
        return "updated"
    client.request(
        "POST",
        "/betaBuildLocalizations",
        body={
            "data": {
                "type": "betaBuildLocalizations",
                "attributes": {"locale": locale, "whatsNew": notes},
                "relationships": {"build": {"data": {"type": "builds", "id": build_id}}},
            }
        },
        expected=(201,),
    )
    return "created"


def parse_args(argv: list[str] | None = None) -> argparse.Namespace:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--bundle-id", required=True)
    parser.add_argument("--build-number", required=True)
    parser.add_argument("--group", default="Internal Testing")
    parser.add_argument("--locale", default="en-GB")
    parser.add_argument("--notes", required=True, type=Path)
    parser.add_argument("--issuer-id", required=True)
    parser.add_argument("--key-id", required=True)
    parser.add_argument("--private-key", required=True, type=Path)
    parser.add_argument("--timeout-seconds", type=int, default=1_800)
    parser.add_argument("--poll-seconds", type=int, default=30)
    parser.add_argument("--dry-run", action="store_true")
    return parser.parse_args(argv)


def main(argv: list[str] | None = None) -> int:
    args = parse_args(argv)
    try:
        notes = args.notes.read_text(encoding="utf-8")
    except OSError as error:
        print(f"Cannot read release notes: {error}", file=sys.stderr)
        return 1

    try:
        client = AppStoreConnectClient(
            issuer_id=args.issuer_id,
            key_id=args.key_id,
            private_key_path=args.private_key,
        )
        app = find_app(client, args.bundle_id)
        app_id = app["id"]
        build = wait_for_build(
            client,
            app_id=app_id,
            build_number=args.build_number,
            timeout_seconds=args.timeout_seconds,
            poll_seconds=args.poll_seconds,
        )
        group = find_internal_group(client, app_id=app_id, group_name=args.group)
        attached = ensure_group_access(
            client, build_id=build["id"], group=group, dry_run=args.dry_run
        )
        outcome = set_whats_new(
            client,
            build_id=build["id"],
            locale=args.locale,
            notes=notes,
            dry_run=args.dry_run,
        )
    except AppStoreConnectError as error:
        print(f"Release failed: {error}", file=sys.stderr)
        return 1

    prefix = "Would have" if args.dry_run else ""
    print(
        f"{prefix or 'Build'} {args.build_number} is VALID; "
        f'{"attached to" if attached else "already in"} "{args.group}"; '
        f"notes {outcome} for {args.locale}"
    )
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
