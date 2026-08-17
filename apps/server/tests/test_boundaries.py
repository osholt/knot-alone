from __future__ import annotations

import base64
import hashlib
import json
from datetime import UTC, datetime, timedelta

from fastapi.testclient import TestClient
from sqlalchemy import event as sqlalchemy_event
from sqlalchemy import func, select

from tide_and_seek_server.app import create_app
from tide_and_seek_server.models import Voyage, StoredEvent
from tide_and_seek_server.rate_limit import SlidingWindowRateLimiter
from tide_and_seek_server.service import purge_expired

from .conftest import voyage_token

SECRET = "0123456789abcdef0123456789abcdef"


def test_health_and_metrics_do_not_require_voyage_credentials(client) -> None:
    assert client.get("/health/live").json() == {"status": "ok"}
    assert client.get("/health/ready").json() == {"status": "ready"}
    metrics = client.get("/metrics")
    assert metrics.status_code == 200
    assert "tide_and_seek_sync_requests_total" in metrics.text


def test_rejects_21_event_batch(client, synchronize, make_event) -> None:
    voyage_id = "voyage-bounds"
    response = synchronize(
        client,
        voyage_id=voyage_id,
        secret=SECRET,
        events=[make_event(voyage_id, f"event-{index}") for index in range(21)],
    )
    assert response.status_code == 400


def test_device_header_must_match_body(client, synchronize) -> None:
    voyage_id = "voyage-device"
    body = json.dumps(
        {"protocolVersion": 1, "deviceId": "body-device", "cursor": None, "events": []},
        separators=(",", ":"),
    ).encode()
    digest = base64.urlsafe_b64encode(hashlib.sha256(body).digest()).decode().rstrip("=")
    response = client.post(
        f"/api/v1/voyages/{voyage_id}/events:sync",
        content=body,
        headers={
            "authorization": f"Bearer {voyage_token(voyage_id, SECRET)}",
            "content-type": "application/json",
            "idempotency-key": f"rr1-{digest}",
            "x-tide-and-seek-device": "header-device",
        },
    )
    assert response.status_code == 400


def test_streamed_body_limit_cannot_be_bypassed_by_content_length(client) -> None:
    voyage_id = "voyage-stream-limit"
    body = b"{" + (b" " * (64 * 1024)) + b"}"
    digest = base64.urlsafe_b64encode(hashlib.sha256(body).digest()).decode().rstrip("=")

    response = client.post(
        f"/api/v1/voyages/{voyage_id}/events:sync",
        content=body,
        headers={
            "authorization": f"Bearer {voyage_token(voyage_id, SECRET)}",
            "content-length": "1",
            "content-type": "application/json",
            "idempotency-key": f"rr1-{digest}",
            "x-tide-and-seek-device": "device-a",
        },
    )

    assert response.status_code == 413


def test_non_finite_payload_number_is_rejected(client, synchronize, make_event) -> None:
    voyage_id = "voyage-nan"
    response = synchronize(
        client,
        voyage_id=voyage_id,
        secret=SECRET,
        events=[make_event(voyage_id, "event-nan", payload={"value": float("nan")})],
    )

    assert response.status_code == 400
    assert "finite" in response.json()["error"].lower()


def test_per_voyage_event_quota_is_atomic(settings, synchronize, make_event) -> None:
    bounded = settings.model_copy(update={"maximum_events_per_voyage": 100})
    voyage_id = "voyage-quota"
    with TestClient(create_app(bounded)) as client:
        for batch_index in range(5):
            response = synchronize(
                client,
                voyage_id=voyage_id,
                secret=SECRET,
                events=[
                    make_event(voyage_id, f"event-{batch_index * 20 + index:03d}")
                    for index in range(20)
                ],
            )
            assert response.status_code == 200

        rejected = synchronize(
            client,
            voyage_id=voyage_id,
            secret=SECRET,
            events=[make_event(voyage_id, "event-100")],
        )

    assert rejected.status_code == 413
    assert rejected.json() == {"error": "Voyage storage quota exceeded"}


def test_event_upload_query_count_does_not_grow_with_voyage_history(
    settings,
    synchronize,
    make_event,
) -> None:
    bounded = settings.model_copy(
        update={
            "maximum_events_per_voyage": 5_000,
            "maximum_upload_events": 100,
        }
    )
    voyage_id = "voyage-query-count"
    with TestClient(create_app(bounded)) as client:
        first = synchronize(
            client,
            voyage_id=voyage_id,
            secret=SECRET,
            events=[make_event(voyage_id, "history-0000")],
        )
        assert first.status_code == 200
        now = datetime.now(UTC)
        cipher = client.app.state.service._cipher
        with client.app.state.session_factory() as session, session.begin():
            voyage = session.get(Voyage, voyage_id)
            assert voyage is not None
            rows = []
            total_bytes = 0
            for index in range(1, 4_900):
                event_id = f"history-{index:04d}"
                body_ciphertext = cipher.encrypt_json(
                    make_event(
                        voyage_id,
                        event_id,
                        event_type="sailorLocationUpdated",
                        created_at=now,
                    ),
                    associated_data=f"event:{voyage_id}:{event_id}".encode(),
                )
                total_bytes += len(body_ciphertext)
                rows.append(
                    StoredEvent(
                        voyage_id=voyage_id,
                        event_id=event_id,
                        device_id="device-a",
                        event_type="sailorLocationUpdated",
                        created_at=now,
                        expires_at=now + timedelta(minutes=20),
                        body_hash=hashlib.sha256(event_id.encode()).digest(),
                        body_ciphertext=body_ciphertext,
                    )
                )
            session.add_all(rows)
            voyage.stored_event_count += len(rows)
            voyage.stored_event_bytes += total_bytes

        voyage_event_statements: list[str] = []

        def record_statement(_conn, _cursor, statement, _parameters, _context, _many) -> None:
            if statement.lstrip().upper().startswith("SELECT") and "voyage_events" in statement:
                voyage_event_statements.append(statement)

        sqlalchemy_event.listen(
            client.app.state.engine,
            "before_cursor_execute",
            record_statement,
        )
        try:
            response = synchronize(
                client,
                voyage_id=voyage_id,
                secret=SECRET,
                events=[make_event(voyage_id, f"latest-{index:03d}") for index in range(100)],
            )
        finally:
            sqlalchemy_event.remove(
                client.app.state.engine,
                "before_cursor_execute",
                record_statement,
            )

        assert response.status_code == 200
        # At the default 5,000-event limit and configurable 100-event batch max:
        # expiry accounting, one bulk identity lookup, and the bounded download.
        # The old path issued 103 voyage-event SELECTs here: two full-history
        # aggregates, one bulk identity lookup, and one lookup per upload event.
        assert len(voyage_event_statements) <= 3
        with client.app.state.session_factory() as session:
            voyage = session.get(Voyage, voyage_id)
            assert voyage is not None
            assert voyage.stored_event_count == 5_000
            assert voyage.stored_event_bytes == session.scalar(
                select(func.sum(func.length(StoredEvent.body_ciphertext))).where(
                    StoredEvent.voyage_id == voyage_id
                )
            )


def test_global_expiry_cleanup_decrements_event_usage_counters(
    client,
    synchronize,
    make_event,
) -> None:
    voyage_id = "voyage-expiry-counters"
    now = datetime.now(UTC)
    assert (
        synchronize(
            client,
            voyage_id=voyage_id,
            secret=SECRET,
            events=[
                make_event(
                    voyage_id,
                    "short-lived",
                    expires_at=now + timedelta(minutes=1),
                )
            ],
        ).status_code
        == 200
    )

    with client.app.state.session_factory() as session:
        purge_expired(session, now=now + timedelta(minutes=2))
    with client.app.state.session_factory() as session:
        voyage = session.get(Voyage, voyage_id)
        assert voyage is not None
        assert voyage.stored_event_count == 0
        assert voyage.stored_event_bytes == 0


def test_rate_limiter_bounds_tracked_identities() -> None:
    limiter = SlidingWindowRateLimiter(
        maximum_requests=10,
        window_seconds=60,
        maximum_keys=2,
    )

    assert limiter.check("first") is None
    assert limiter.check("second") is None
    assert limiter.check("third") == 60


def test_active_voyage_capacity_rejects_new_claims(settings, synchronize) -> None:
    bounded = settings.model_copy(update={"maximum_active_voyages": 1})
    with TestClient(create_app(bounded)) as client:
        assert synchronize(client, voyage_id="voyage-first", secret=SECRET).status_code == 200
        rejected = synchronize(client, voyage_id="voyage-second", secret=SECRET)

    assert rejected.status_code == 503
    assert rejected.json() == {"error": "Relay voyage capacity reached"}


def test_per_voyage_replay_quota_is_atomic(settings, synchronize, make_event) -> None:
    bounded = settings.model_copy(update={"maximum_replays_per_voyage": 1})
    voyage_id = "voyage-replay-quota"
    # Only an upload is replay-protected, so only an upload consumes the quota.
    with TestClient(create_app(bounded)) as client:
        assert (
            synchronize(
                client,
                voyage_id=voyage_id,
                secret=SECRET,
                events=[make_event(voyage_id, "event-a")],
            ).status_code
            == 200
        )
        rejected = synchronize(
            client,
            voyage_id=voyage_id,
            secret=SECRET,
            device_id="device-b",
            events=[make_event(voyage_id, "event-b", device_id="device-b")],
        )

    assert rejected.status_code == 413
    assert rejected.json() == {"error": "Voyage replay quota exceeded"}


def test_rate_limit_returns_bounded_retry_after(settings, synchronize) -> None:
    limited = settings.model_copy(update={"rate_limit_requests": 2})
    with TestClient(create_app(limited)) as client:
        assert synchronize(client, voyage_id="voyage-rate", secret=SECRET).status_code == 200
        assert (
            synchronize(
                client, voyage_id="voyage-rate", secret=SECRET, device_id="device-b"
            ).status_code
            == 200
        )
        response = synchronize(client, voyage_id="voyage-rate", secret=SECRET, device_id="device-c")
    assert response.status_code == 429
    assert 1 <= int(response.headers["retry-after"]) <= 300
