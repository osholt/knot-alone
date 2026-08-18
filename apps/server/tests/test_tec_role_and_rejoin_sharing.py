"""Issue #128 on the relay: two additive event types plus their capabilities.

The relay stays deliberately dumb about voyage semantics - it authenticates, bounds
and forwards - so what has to be tested here is that the new types are carried at
all, that their retention is capped tightly enough for what they contain, and that
neither of them can reach a trusted observer (#36) through the observer channel.
"""

from __future__ import annotations

from datetime import UTC, datetime, timedelta

from sqlalchemy import select

from tide_and_seek_server.models import StoredEvent
from tide_and_seek_server.service import RelayService

from .conftest import event, sync_request, voyage_token

SECRET = "0123456789abcdef0123456789abcdef"
OBSERVER_SECRET = "observer-rejoin-secret-0123456789"

TEC_CAPABILITY = "sweeper-role-assignment-v1"
REJOIN_CAPABILITY = "rejoin-route-sharing-v1"


def test_compatibility_advertises_both_new_capabilities(client) -> None:
    capabilities = client.get("/api/v1/compatibility").json()["capabilities"]

    assert TEC_CAPABILITY in capabilities
    assert REJOIN_CAPABILITY in capabilities
    # Additive: nothing that was already advertised has gone.
    assert {"live-presence-v2", "membership-v1", "route-revisions-v1"} <= set(capabilities)


def test_sweeper_role_events_are_accepted_and_relayed(client, synchronize, make_event) -> None:
    voyage_id = "voyage-sweeper-role"
    shared = [
        make_event(
            voyage_id,
            "event-sweeper-request",
            event_type="sweeperRoleRequested",
            payload={
                "requestId": "req-1",
                "skipperSailorId": "device-a",
                "targetSailorId": "device-b",
                "targetDisplayName": "Bill",
            },
        ),
        make_event(
            voyage_id,
            "event-sweeper-response",
            event_type="sweeperRoleResponded",
            payload={
                "requestId": "req-1",
                "targetSailorId": "device-b",
                "accepted": True,
            },
        ),
    ]

    uploaded = synchronize(client, voyage_id=voyage_id, secret=SECRET, events=shared)
    assert uploaded.status_code == 200
    assert uploaded.json()["acceptedEventIds"] == [event["id"] for event in shared]

    downloaded = synchronize(client, voyage_id=voyage_id, secret=SECRET, device_id="device-b")
    assert downloaded.status_code == 200
    assert downloaded.json()["events"] == shared


def test_rejoin_route_share_is_accepted_and_relayed(client, synchronize, make_event) -> None:
    voyage_id = "voyage-rejoin-share"
    share = make_event(
        voyage_id,
        "event-rejoin-1",
        event_type="rejoinRouteShared",
        payload={
            "share": {
                "sailorId": "device-a",
                "displayName": "Bill",
                "computedAt": "2026-07-26T11:00:00Z",
                "expiresAt": "2026-07-26T11:10:00Z",
                "routeRevision": 2,
                "severity": "offRoute",
                "status": "routed",
                "breadcrumb": [[51.5, -0.1], [51.51, -0.09]],
            },
            "recipientSailorIds": ["device-b"],
        },
    )

    uploaded = synchronize(client, voyage_id=voyage_id, secret=SECRET, events=[share])
    assert uploaded.status_code == 200
    assert uploaded.json()["acceptedEventIds"] == ["event-rejoin-1"]

    downloaded = synchronize(client, voyage_id=voyage_id, secret=SECRET, device_id="device-b")
    assert downloaded.status_code == 200
    assert downloaded.json()["events"] == [share]


def test_a_full_size_breadcrumb_is_within_the_event_size_limit(
    client, synchronize, make_event
) -> None:
    voyage_id = "voyage-rejoin-big"
    # The client caps a relayed breadcrumb at 60 points; 96 is its absolute
    # decoder ceiling. Even the ceiling has to fit the relay's per-event limit.
    share = make_event(
        voyage_id,
        "event-rejoin-big",
        event_type="rejoinRouteShared",
        payload={
            "share": {
                "sailorId": "device-a",
                "displayName": "Bill",
                "computedAt": "2026-07-26T11:00:00Z",
                "expiresAt": "2026-07-26T11:10:00Z",
                "routeRevision": 2,
                "breadcrumb": [[51.50000 + index / 10000, -0.12345] for index in range(96)],
            },
            "recipientSailorIds": ["device-b"],
        },
    )

    response = synchronize(client, voyage_id=voyage_id, secret=SECRET, events=[share])

    assert response.status_code == 200
    assert response.json()["acceptedEventIds"] == ["event-rejoin-big"]


def test_new_event_retention_is_capped_tightly(client, synchronize, make_event) -> None:
    voyage_id = "voyage-rejoin-retention"
    before = datetime.now(UTC)
    events = [
        make_event(voyage_id, "event-rejoin-1", event_type="rejoinRouteShared"),
        make_event(voyage_id, "event-sweeper-1", event_type="sweeperRoleRequested"),
        make_event(voyage_id, "event-plain", event_type="statusMessage"),
    ]

    assert synchronize(client, voyage_id=voyage_id, secret=SECRET, events=events).status_code == 200

    factory = client.app.state.session_factory
    with factory() as session:
        stored = {
            row.event_id: row.expires_at.replace(tzinfo=UTC)
            for row in session.scalars(
                select(StoredEvent).where(StoredEvent.voyage_id == voyage_id)
            )
        }

    # A sailor's intended path is treated as perishably as where they actually
    # are: the same 30-minute band as sailorLocationUpdated.
    assert stored["event-rejoin-1"] < before + timedelta(minutes=31)
    assert stored["event-rejoin-1"] > before + timedelta(minutes=29)
    # Coordination about who covers the back is voyage-scoped, not voyage history.
    assert stored["event-sweeper-1"] < before + timedelta(hours=3)
    assert stored["event-sweeper-1"] > before + timedelta(hours=1)


def test_retention_table_matches_the_documented_bands() -> None:
    retention = RelayService._maximum_event_retention
    assert retention("rejoinRouteShared") == timedelta(minutes=30)
    assert retention("rejoinRouteShared") == retention("sailorLocationUpdated")
    assert retention("sweeperRoleRequested") == timedelta(hours=2)
    assert retention("sweeperRoleResponded") == timedelta(hours=2)
    # Issue #188. A sailor's own phone number gets exactly the cap an ICE share
    # gets, and is capped independently of whatever expiry a client asks for.
    assert retention("sailorContactShared") == timedelta(hours=2)
    assert retention("sailorContactShared") == retention("iceInfoShared")


def test_a_shared_phone_number_is_accepted_and_capped(client, synchronize, make_event) -> None:
    voyage_id = "voyage-sailor-contact"
    before = datetime.now(UTC)
    contact_event = make_event(
        voyage_id,
        "event-contact-1",
        event_type="sailorContactShared",
        payload={
            "contact": {
                "sailorId": "device-a",
                "displayName": "Sailor A",
                # A reserved, non-dialable placeholder: no real number belongs in
                # a fixture.
                "phone": "+00 0000 000000",
                "sharedByRole": "sailor",
            },
            "recipientSailorIds": ["device-b"],
        },
    )

    response = synchronize(client, voyage_id=voyage_id, secret=SECRET, events=[contact_event])

    assert response.status_code == 200
    assert response.json()["acceptedEventIds"] == ["event-contact-1"]

    factory = client.app.state.session_factory
    with factory() as session:
        stored = session.scalars(
            select(StoredEvent).where(StoredEvent.voyage_id == voyage_id)
        ).one()

    expires_at = stored.expires_at.replace(tzinfo=UTC)
    assert expires_at < before + timedelta(hours=3)
    assert expires_at > before + timedelta(hours=1)


def test_an_unknown_event_type_is_still_refused(client, synchronize, make_event) -> None:
    voyage_id = "voyage-unknown-type"
    response = synchronize(
        client,
        voyage_id=voyage_id,
        secret=SECRET,
        events=[make_event(voyage_id, "event-future", event_type="sweeperRoleRevoked")],
    )

    # The relay's allowlist is deliberately closed: a client that invents a type
    # is rejected here, and forward compatibility is the *client's* per-event
    # skip, not a server that stores anything at all.
    assert response.status_code == 400
    assert "type" in response.json()["error"].lower()


def test_a_rejoin_share_is_not_a_field_an_observer_snapshot_can_carry(client) -> None:
    """#36 observers get their own authorisation decision, so the observer channel
    has no field a rejoin route could travel in - and adding one has to be a
    deliberate change that fails this test first."""
    voyage_id = "voyage-observer-rejoin"
    now = datetime.now(UTC)
    assert (
        sync_request(
            client,
            voyage_id=voyage_id,
            secret=OBSERVER_SECRET,
            events=[event(voyage_id, "created")],
        ).status_code
        == 200
    )
    grant = client.post(
        f"/api/v1/voyages/{voyage_id}/observer-grants",
        headers={
            "authorization": f"Bearer {voyage_token(voyage_id, OBSERVER_SECRET)}",
            "x-tide-and-seek-device": "device-a",
        },
        json={"label": "Home contact", "durationMinutes": 60, "consentConfirmed": True},
    )
    assert grant.status_code == 201
    body = grant.json()

    snapshot = {
        "subjectName": "Bill",
        "snapshotGeneratedAt": now.isoformat(),
        "voyageStatus": "active",
        "statusUpdatedAt": now.isoformat(),
        "position": None,
        "assistanceUpdatedAt": now.isoformat(),
        "assistance": None,
    }
    accepted = client.put(
        f"/api/v1/observer-grants/{body['id']}/snapshot",
        headers={"authorization": f"Bearer {body['publisherToken']}"},
        json=snapshot,
    )
    assert accepted.status_code == 204

    smuggled = client.put(
        f"/api/v1/observer-grants/{body['id']}/snapshot",
        headers={"authorization": f"Bearer {body['publisherToken']}"},
        json={
            **snapshot,
            "rejoinRoute": {"breadcrumb": [[51.5, -0.1], [51.51, -0.09]]},
        },
    )
    # `extra="forbid"` on the publish schema: an unrecognised field is refused
    # outright rather than stored and quietly served on.
    assert smuggled.status_code == 400

    observed = client.get(
        f"/api/v1/observer-grants/{body['id']}",
        headers={"authorization": f"Bearer {body['observerToken']}"},
    )
    assert observed.status_code == 200
    served = observed.json()
    assert "rejoinRoute" not in served
    assert "breadcrumb" not in str(served)
