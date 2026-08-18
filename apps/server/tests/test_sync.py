from __future__ import annotations

from datetime import UTC, datetime, timedelta

from sqlalchemy import func, select

from tide_and_seek_server.models import IdempotencyReplay, StoredEvent, Voyage
from tide_and_seek_server.service import purge_expired

from .conftest import voyage_token

SECRET = "0123456789abcdef0123456789abcdef"


def test_token_matches_mobile_golden_vector() -> None:
    # Pins the derivation shared with the mobile client: the
    # `ride-relay-internet-token-v1` domain string, HMAC-SHA256 over
    # "<domain>\n<voyage id>", the `rr1_` prefix, and unpadded base64url.
    #
    # The vector was recomputed when `ride/alpha` became `voyage/alpha` with the
    # rest of the domain. The algorithm did not change: the previous value,
    # rr1_uXTs1vSdBpQTOadPV9VW51wrlt2Cf6E-aaolArBPAac, still reproduces exactly
    # from this code for the old input, which is what made recomputing safe.
    # The identifier is opaque test data; the domain string is not, and is
    # pinned in docs/source-baseline.md.
    assert voyage_token("voyage/alpha", SECRET) == (
        "rr1_qOZ8vsV4fveP6QaRJbWAn1MEaxemgbtnwRxr8nmHXzI"
    )


def test_first_sync_claims_voyage_and_another_device_receives_event(
    client, synchronize, make_event
) -> None:
    voyage_id = "voyage-alpha"
    uploaded = make_event(voyage_id, "event-1")

    first = synchronize(
        client,
        voyage_id=voyage_id,
        secret=SECRET,
        events=[uploaded],
    )

    assert first.status_code == 200
    assert first.json()["acceptedEventIds"] == ["event-1"]
    assert first.json()["events"] == [uploaded]

    second = synchronize(
        client,
        voyage_id=voyage_id,
        secret=SECRET,
        device_id="device-b",
    )
    assert second.status_code == 200
    assert second.json()["events"] == [uploaded]


def test_ice_info_shared_event_is_accepted_and_relayed(client, synchronize, make_event) -> None:
    voyage_id = "voyage-ice"
    shared = make_event(
        voyage_id,
        "event-ice-1",
        event_type="iceInfoShared",
        payload={"contactName": "A", "contactPhone": "555", "medicalNotes": ""},
    )

    uploaded = synchronize(client, voyage_id=voyage_id, secret=SECRET, events=[shared])
    assert uploaded.status_code == 200
    assert uploaded.json()["acceptedEventIds"] == ["event-ice-1"]

    downloaded = synchronize(client, voyage_id=voyage_id, secret=SECRET, device_id="device-b")
    assert downloaded.status_code == 200
    assert downloaded.json()["events"] == [shared]


def test_voyage_start_event_is_accepted_and_relayed(client, synchronize, make_event) -> None:
    voyage_id = "voyage-start"
    started = make_event(
        voyage_id,
        "event-started",
        event_type="voyageStarted",
        payload={"skipperSailorId": "device-a", "skipperDisplayName": "Lead"},
    )

    uploaded = synchronize(client, voyage_id=voyage_id, secret=SECRET, events=[started])
    assert uploaded.status_code == 200
    assert uploaded.json()["acceptedEventIds"] == ["event-started"]

    downloaded = synchronize(client, voyage_id=voyage_id, secret=SECRET, device_id="device-b")
    assert downloaded.status_code == 200
    assert downloaded.json()["events"] == [started]


def test_membership_and_route_events_are_accepted_and_relayed(
    client, synchronize, make_event
) -> None:
    voyage_id = "voyage-group-state"
    shared = [
        make_event(voyage_id, "event-left", event_type="sailorLeft"),
        make_event(voyage_id, "event-route-chunk", event_type="routeRevisionChunk"),
        make_event(
            voyage_id,
            "event-route-published",
            event_type="routeRevisionPublished",
        ),
        make_event(voyage_id, "event-route-cleared", event_type="routeCleared"),
    ]

    uploaded = synchronize(client, voyage_id=voyage_id, secret=SECRET, events=shared)
    assert uploaded.status_code == 200
    assert uploaded.json()["acceptedEventIds"] == [event["id"] for event in shared]

    downloaded = synchronize(client, voyage_id=voyage_id, secret=SECRET, device_id="device-b")
    assert downloaded.status_code == 200
    assert downloaded.json()["events"] == shared


def test_wrong_credential_cannot_read_claimed_voyage(client, synchronize) -> None:
    voyage_id = "voyage-private"
    assert synchronize(client, voyage_id=voyage_id, secret=SECRET).status_code == 200

    rejected = synchronize(
        client,
        voyage_id=voyage_id,
        secret="fedcba9876543210fedcba9876543210",
        device_id="intruder",
    )
    assert rejected.status_code == 403
    assert rejected.json() == {"error": "Voyage credential rejected"}


def test_idempotency_replays_the_upload_answer_but_not_the_download(
    client, synchronize, make_event
) -> None:
    """A repeated upload is answered identically; its download is still fresh.

    Replaying the stored *download* is what made an idle device deaf to its
    peers (#132): upload and download share one request, so the same batch
    offered twice must not resurrect the event list from the first attempt.
    """
    voyage_id = "voyage-replay"
    first_event = make_event(voyage_id, "event-1")
    first = synchronize(client, voyage_id=voyage_id, secret=SECRET, events=[first_event])

    synchronize(
        client,
        voyage_id=voyage_id,
        secret=SECRET,
        device_id="device-b",
        events=[make_event(voyage_id, "event-2", device_id="device-b")],
    )
    replay = synchronize(client, voyage_id=voyage_id, secret=SECRET, events=[first_event])

    assert replay.status_code == 200
    assert replay.json()["acceptedEventIds"] == first.json()["acceptedEventIds"] == ["event-1"]
    assert [event["id"] for event in replay.json()["events"]] == ["event-1", "event-2"]
    factory = client.app.state.session_factory
    with factory() as session:
        stored = session.scalars(
            select(StoredEvent.event_id).where(StoredEvent.voyage_id == voyage_id)
        ).all()
        assert sorted(stored) == ["event-1", "event-2"]


def test_idle_device_with_nothing_to_upload_still_receives_peer_events(
    client, synchronize, make_event
) -> None:
    """The #132 field failure: a phone with an empty outbound queue.

    A device with nothing to send repeats a byte-identical sync body on every
    poll, so it used to be answered from the idempotency replay cache and
    received nothing at all until it happened to have an event of its own.
    """
    voyage_id = "voyage-idle"
    first = synchronize(client, voyage_id=voyage_id, secret=SECRET, device_id="device-a")
    assert first.status_code == 200
    cursor = first.json()["cursor"]

    # A second, byte-identical idle poll: same cursor, same empty batch.
    repeated = synchronize(
        client, voyage_id=voyage_id, secret=SECRET, device_id="device-a", cursor=cursor
    )
    assert repeated.status_code == 200
    assert repeated.json()["events"] == []

    uploaded = make_event(voyage_id, "event-b1", device_id="device-b")
    assert (
        synchronize(
            client,
            voyage_id=voyage_id,
            secret=SECRET,
            device_id="device-b",
            events=[uploaded],
        ).status_code
        == 200
    )

    # Still idle, still byte-identical to the poll before the peer uploaded.
    received = synchronize(
        client, voyage_id=voyage_id, secret=SECRET, device_id="device-a", cursor=cursor
    )

    assert received.status_code == 200
    assert [event["id"] for event in received.json()["events"]] == ["event-b1"]


def test_idle_polling_does_not_accumulate_replay_records(client, synchronize) -> None:
    """An empty batch has nothing to be idempotent about, so it stores nothing."""
    voyage_id = "voyage-idle-replays"
    cursor = None
    for _ in range(4):
        response = synchronize(
            client, voyage_id=voyage_id, secret=SECRET, device_id="device-a", cursor=cursor
        )
        assert response.status_code == 200
        cursor = response.json()["cursor"]
    factory = client.app.state.session_factory
    with factory() as session:
        assert (
            session.scalar(
                select(func.count(IdempotencyReplay.id)).where(
                    IdempotencyReplay.voyage_id == voyage_id
                )
            )
            == 0
        )


def test_conflicting_event_identity_is_rejected_atomically(client, synchronize, make_event) -> None:
    voyage_id = "voyage-conflict"
    original = make_event(voyage_id, "event-1", payload={"value": 1})
    assert (
        synchronize(client, voyage_id=voyage_id, secret=SECRET, events=[original]).status_code
        == 200
    )

    conflict = make_event(voyage_id, "event-1", payload={"value": 2})
    response = synchronize(client, voyage_id=voyage_id, secret=SECRET, events=[conflict])

    assert response.status_code == 409
    assert "conflict" in response.json()["error"].lower()


def test_cursor_paginates_without_skipping_101_events(client, synchronize, make_event) -> None:
    voyage_id = "voyage-pages"
    for batch_index in range(6):
        batch = [
            make_event(
                voyage_id,
                f"event-{batch_index * 20 + index:03d}",
                device_id="uploader",
            )
            for index in range(20)
            if batch_index * 20 + index < 101
        ]
        response = synchronize(
            client,
            voyage_id=voyage_id,
            secret=SECRET,
            device_id="uploader",
            events=batch,
        )
        assert response.status_code == 200

    page_one = synchronize(
        client,
        voyage_id=voyage_id,
        secret=SECRET,
        device_id="reader",
    )
    page_two = synchronize(
        client,
        voyage_id=voyage_id,
        secret=SECRET,
        device_id="reader",
        cursor=page_one.json()["cursor"],
    )

    assert len(page_one.json()["events"]) == 100
    assert len(page_two.json()["events"]) == 1
    assert {event["id"] for event in page_one.json()["events"] + page_two.json()["events"]} == {
        f"event-{index:03d}" for index in range(101)
    }


def test_expired_event_is_acknowledged_but_not_relayed(client, synchronize, make_event) -> None:
    voyage_id = "voyage-expired"
    expired = make_event(
        voyage_id,
        "event-old",
        expires_at=datetime.now(UTC) - timedelta(seconds=1),
    )
    response = synchronize(client, voyage_id=voyage_id, secret=SECRET, events=[expired])

    assert response.status_code == 200
    assert response.json()["acceptedEventIds"] == ["event-old"]
    assert response.json()["events"] == []


def test_events_are_encrypted_at_rest(client, settings, synchronize, make_event) -> None:
    voyage_id = "voyage-encrypted"
    synchronize(
        client,
        voyage_id=voyage_id,
        secret=SECRET,
        events=[make_event(voyage_id, "event-secret", payload={"latitude": 51.5})],
    )
    factory = client.app.state.session_factory
    with factory() as session:
        stored = session.scalar(select(StoredEvent).where(StoredEvent.voyage_id == voyage_id))
        assert stored is not None
        assert b"latitude" not in stored.body_ciphertext
        assert b"51.5" not in stored.body_ciphertext


def test_tampered_cursor_is_rejected(client, synchronize, make_event) -> None:
    voyage_id = "voyage-cursor"
    first = synchronize(
        client,
        voyage_id=voyage_id,
        secret=SECRET,
        events=[make_event(voyage_id, "event-1")],
    )
    cursor = first.json()["cursor"]
    tampered = f"{cursor[:-1]}{'A' if cursor[-1] != 'A' else 'B'}"

    response = synchronize(
        client,
        voyage_id=voyage_id,
        secret=SECRET,
        device_id="reader",
        cursor=tampered,
    )

    assert response.status_code == 400
    assert response.json() == {"error": "Invalid cursor"}


def test_future_event_is_rejected(client, synchronize, make_event) -> None:
    voyage_id = "voyage-future"
    response = synchronize(
        client,
        voyage_id=voyage_id,
        secret=SECRET,
        events=[
            make_event(
                voyage_id,
                "event-future",
                created_at=datetime.now(UTC) + timedelta(minutes=11),
            )
        ],
    )

    assert response.status_code == 400
    assert "future" in response.json()["error"].lower()


def test_voyage_end_shortens_retention_and_cleanup_deletes_voyage(
    client, settings, synchronize, make_event
) -> None:
    voyage_id = "voyage-ended"
    before = datetime.now(UTC)
    response = synchronize(
        client,
        voyage_id=voyage_id,
        secret=SECRET,
        events=[make_event(voyage_id, "event-ended", event_type="voyageEnded")],
    )
    assert response.status_code == 200

    factory = client.app.state.session_factory
    with factory() as session:
        voyage = session.get(Voyage, voyage_id)
        assert voyage is not None
        delete_after = voyage.delete_after.replace(tzinfo=UTC)
        assert before + timedelta(hours=23) < delete_after
        assert delete_after < before + timedelta(hours=25)

    with factory() as session:
        purge_expired(session, now=before + timedelta(hours=25))
    with factory() as session:
        assert session.get(Voyage, voyage_id) is None
