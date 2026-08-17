"""Live presence that spans both voyage phases, and joins that do not wait for
the bulk event batch.

Every test here is written against the field failure in issue #99: a joiner
could see the skipper's route but never the skipper's advancing position, and the
skipper never learned the joiner had joined at all.
"""

from __future__ import annotations

from datetime import UTC, datetime, timedelta

from sqlalchemy import func, select

from tide_and_seek_server.models import PreStartPosition, Voyage
from tide_and_seek_server.schemas import PresenceSyncRequest

from .conftest import event, voyage_token

SECRET = "0123456789abcdef0123456789abcdef"
LIVE = ["pre-start-presence-v1", "live-presence-v2"]
LEGACY = ["pre-start-presence-v1"]


def _position(latitude: float, *, name: str = "Alex", recorded_at: datetime | None = None) -> dict:
    return {
        "displayName": name,
        "role": "sailor",
        "motorcycleStyle": "adventure",
        "sailorColor": "blue",
        "sample": {
            "position": {"latitude": latitude, "longitude": -2.4},
            "recordedAt": (recorded_at or datetime.now(UTC)).isoformat().replace("+00:00", "Z"),
            "accuracyMeters": 4,
            "speedMetersPerSecond": 0,
            "headingDegrees": 90,
        },
    }


def _presence(
    client,
    voyage_id: str,
    device_id: str,
    *,
    capabilities: list[str] | None = None,
    protocol: str = "1",
    **body,
):
    headers = {
        "authorization": f"Bearer {voyage_token(voyage_id, SECRET)}",
        "x-tide-and-seek-device": device_id,
        "x-tailendcharlie-protocol": protocol,
        "x-tailendcharlie-capabilities": ",".join(
            capabilities if capabilities is not None else LIVE
        ),
    }
    return client.post(
        f"/api/v1/voyages/{voyage_id}/presence:sync",
        json={"protocolVersion": 1, "deviceId": device_id, **body},
        headers=headers,
    )


def _membership_event(voyage_id: str, event_id: str, device_id: str, name: str, role: str) -> dict:
    return event(
        voyage_id,
        event_id,
        device_id=device_id,
        event_type="sailorJoined",
        payload={"displayName": name, "role": role},
    )


def _start(client, synchronize, voyage_id: str, device_id: str = "skipper"):
    return synchronize(
        client,
        voyage_id=voyage_id,
        secret=SECRET,
        device_id=device_id,
        events=[
            event(
                voyage_id,
                f"{voyage_id}-started",
                device_id=device_id,
                event_type="voyageStarted",
                payload={"skipperSailorId": device_id},
            )
        ],
    )


def test_presence_survives_the_voyage_started_transition(client, synchronize) -> None:
    voyage_id = "voyage-continuity"
    assert (
        synchronize(client, voyage_id=voyage_id, secret=SECRET, device_id="skipper").status_code == 200
    )
    assert _presence(client, voyage_id, "skipper", position=_position(51.0, name="Lead")).status_code
    before = _presence(client, voyage_id, "sailor-a", position=_position(51.5)).json()
    assert {item["sailorId"] for item in before["positions"]} == {"skipper", "sailor-a"}
    assert before["phase"] == "open"

    assert _start(client, synchronize, voyage_id).status_code == 200

    after = _presence(client, voyage_id, "sailor-a", position=_position(51.6)).json()
    assert after["phase"] == "started"
    # No gap and no duplicate identity across the transition.
    assert {item["sailorId"] for item in after["positions"]} == {"skipper", "sailor-a"}
    assert len(after["positions"]) == 2


def test_a_sailor_joining_an_already_started_voyage_appears_without_a_cursor(
    client, synchronize
) -> None:
    voyage_id = "voyage-late-join"
    assert (
        synchronize(client, voyage_id=voyage_id, secret=SECRET, device_id="skipper").status_code == 200
    )
    assert (
        synchronize(
            client,
            voyage_id=voyage_id,
            secret=SECRET,
            device_id="skipper",
            events=[_membership_event(voyage_id, "created", "skipper", "Lead", "lead")],
        ).status_code
        == 200
    )
    assert _start(client, synchronize, voyage_id).status_code == 200

    # The joiner uploads only its own membership event.
    assert (
        synchronize(
            client,
            voyage_id=voyage_id,
            secret=SECRET,
            device_id="sailor-late",
            events=[_membership_event(voyage_id, "joined-late", "sailor-late", "Bill", "sailor")],
        ).status_code
        == 200
    )
    assert (
        _presence(client, voyage_id, "sailor-late", position=_position(51.9, name="Bill")).status_code
        == 200
    )

    # The skipper never advances a cursor here: presence alone must reveal both
    # the new member and their live position.
    observed = _presence(client, voyage_id, "skipper").json()
    members = {item["sailorId"]: item for item in observed["members"]}
    assert members["sailor-late"]["displayName"] == "Bill"
    assert members["sailor-late"]["left"] is False
    assert members["skipper"]["displayName"] == "Lead"
    assert {item["sailorId"] for item in observed["positions"]} == {"sailor-late"}


def test_roster_is_served_even_when_the_event_batch_never_advances(client, synchronize) -> None:
    voyage_id = "voyage-wedged-batch"
    assert (
        synchronize(client, voyage_id=voyage_id, secret=SECRET, device_id="skipper").status_code == 200
    )
    assert (
        synchronize(
            client,
            voyage_id=voyage_id,
            secret=SECRET,
            device_id="sailor-a",
            events=[_membership_event(voyage_id, "joined-a", "sailor-a", "Alex", "sailor")],
        ).status_code
        == 200
    )

    # A wedged sync is modelled by simply never calling events:sync again.
    observed = _presence(client, voyage_id, "skipper").json()

    assert [item["sailorId"] for item in observed["members"]] == ["sailor-a"]


def test_sailor_left_marks_the_member_rather_than_hiding_the_history(client, synchronize) -> None:
    voyage_id = "voyage-left"
    assert (
        synchronize(client, voyage_id=voyage_id, secret=SECRET, device_id="skipper").status_code == 200
    )
    assert (
        synchronize(
            client,
            voyage_id=voyage_id,
            secret=SECRET,
            device_id="sailor-a",
            events=[
                _membership_event(voyage_id, "joined-a", "sailor-a", "Alex", "sailor"),
                event(
                    voyage_id,
                    "left-a",
                    device_id="sailor-a",
                    event_type="sailorLeft",
                    payload={"sailorId": "sailor-a", "reason": "left"},
                ),
            ],
        ).status_code
        == 200
    )

    members = _presence(client, voyage_id, "skipper").json()["members"]

    assert len(members) == 1
    assert members[0]["sailorId"] == "sailor-a"
    assert members[0]["left"] is True
    # Issue #144: the record a departed sailor leaves behind has to say *when*
    # they went, and a caller must be able to order the departure against a later
    # rejoin without waiting for the bulk event batch to deliver either.
    assert members[0]["leftAt"] is not None
    assert members[0]["leftAt"] >= members[0]["joinedAt"]


def test_a_rejoin_clears_the_departure_and_its_time(client, synchronize) -> None:
    voyage_id = "voyage-left-then-back"
    assert (
        synchronize(client, voyage_id=voyage_id, secret=SECRET, device_id="skipper").status_code == 200
    )
    assert (
        synchronize(
            client,
            voyage_id=voyage_id,
            secret=SECRET,
            device_id="sailor-a",
            events=[
                _membership_event(voyage_id, "joined-a", "sailor-a", "Alex", "sailor"),
                event(
                    voyage_id,
                    "left-a",
                    device_id="sailor-a",
                    event_type="sailorLeft",
                    payload={"sailorId": "sailor-a", "reason": "left"},
                ),
                _membership_event(voyage_id, "rejoined-a", "sailor-a", "Alex", "sailor"),
            ],
        ).status_code
        == 200
    )

    members = _presence(client, voyage_id, "skipper").json()["members"]

    # One identity, and it is not carrying a stale departure that would let a
    # client mark a sailor who is back as gone.
    assert len(members) == 1
    assert members[0]["sailorId"] == "sailor-a"
    assert members[0]["left"] is False
    assert members[0]["leftAt"] is None


def test_voyage_ended_discards_live_positions(client, synchronize) -> None:
    voyage_id = "voyage-ended-presence"
    assert (
        synchronize(client, voyage_id=voyage_id, secret=SECRET, device_id="skipper").status_code == 200
    )
    assert _presence(client, voyage_id, "sailor-a", position=_position(51.0)).status_code == 200
    assert (
        synchronize(
            client,
            voyage_id=voyage_id,
            secret=SECRET,
            device_id="skipper",
            events=[
                event(
                    voyage_id,
                    "ended",
                    device_id="skipper",
                    event_type="voyageEnded",
                    payload={},
                )
            ],
        ).status_code
        == 200
    )

    with client.app.state.session_factory() as session:
        assert session.scalar(select(func.count()).select_from(PreStartPosition)) == 0
    observed = _presence(client, voyage_id, "skipper").json()
    assert observed["positions"] == []
    assert observed["phase"] == "ended"


def test_reopening_a_voyage_restores_its_running_phase(client, synchronize) -> None:
    """Issues #206/#207.

    A voyage the skipper ends by mistake can be un-ended, and presence has to come
    back with it: a reopened voyage that still reported ``ended`` would leave every
    sailor's app refusing to publish a position to a voyage that is running.
    """
    voyage_id = "voyage-reopened-presence"
    assert (
        synchronize(client, voyage_id=voyage_id, secret=SECRET, device_id="skipper").status_code == 200
    )
    for index, event_type in enumerate(("voyageStarted", "voyageEnded", "voyageReopened")):
        assert (
            synchronize(
                client,
                voyage_id=voyage_id,
                secret=SECRET,
                device_id="skipper",
                events=[
                    event(
                        voyage_id,
                        f"lifecycle-{index}",
                        device_id="skipper",
                        event_type=event_type,
                        payload={},
                    )
                ],
            ).status_code
            == 200
        )

    assert _presence(client, voyage_id, "skipper").json()["phase"] == "started"
    # A position published after the reopen is kept, because the voyage is running.
    assert _presence(client, voyage_id, "sailor-a", position=_position(51.0)).status_code == 200
    with client.app.state.session_factory() as session:
        assert session.scalar(select(func.count()).select_from(PreStartPosition)) == 1
        voyage = session.get(Voyage, voyage_id)
        assert voyage is not None
        assert voyage.ended_at is None


def test_ending_after_a_reopen_ends_the_voyage_again(client, synchronize) -> None:
    voyage_id = "voyage-reended-presence"
    assert (
        synchronize(client, voyage_id=voyage_id, secret=SECRET, device_id="skipper").status_code == 200
    )
    assert _presence(client, voyage_id, "sailor-a", position=_position(51.0)).status_code == 200
    for index, event_type in enumerate(("voyageEnded", "voyageReopened", "voyageEnded")):
        assert (
            synchronize(
                client,
                voyage_id=voyage_id,
                secret=SECRET,
                device_id="skipper",
                events=[
                    event(
                        voyage_id,
                        f"lifecycle-{index}",
                        device_id="skipper",
                        event_type=event_type,
                        payload={},
                    )
                ],
            ).status_code
            == 200
        )

    assert _presence(client, voyage_id, "skipper").json()["phase"] == "ended"
    with client.app.state.session_factory() as session:
        assert session.scalar(select(func.count()).select_from(PreStartPosition)) == 0
        voyage = session.get(Voyage, voyage_id)
        assert voyage is not None
        assert voyage.ended_at is not None


def test_a_legacy_publisher_stays_visible_to_a_live_presence_peer_and_is_flagged(
    client, synchronize
) -> None:
    """Older client to newer client: the position still arrives, and the newer
    device is told the peer's build is older."""
    voyage_id = "voyage-mixed-versions"
    assert (
        synchronize(client, voyage_id=voyage_id, secret=SECRET, device_id="skipper").status_code == 200
    )
    assert (
        _presence(
            client, voyage_id, "sailor-old", capabilities=LEGACY, position=_position(51.3, name="Bill")
        ).status_code
        == 200
    )
    assert (
        _presence(client, voyage_id, "skipper", position=_position(51.0, name="Lead")).status_code
        == 200
    )
    assert _start(client, synchronize, voyage_id).status_code == 200

    observed = _presence(client, voyage_id, "skipper", position=_position(51.01, name="Lead")).json()

    flags = {item["sailorId"]: item["livePresence"] for item in observed["positions"]}
    assert flags["sailor-old"] is False
    assert flags["skipper"] is True


def test_a_legacy_reader_after_start_does_not_destroy_a_live_peers_position(
    client, synchronize
) -> None:
    voyage_id = "voyage-legacy-nondestructive"
    assert (
        synchronize(client, voyage_id=voyage_id, secret=SECRET, device_id="skipper").status_code == 200
    )
    assert _presence(client, voyage_id, "sailor-a", position=_position(51.4)).status_code == 200
    assert _start(client, synchronize, voyage_id).status_code == 200

    assert _presence(client, voyage_id, "sailor-old", capabilities=LEGACY).json()["positions"] == []

    still_there = _presence(client, voyage_id, "skipper").json()["positions"]
    assert [item["sailorId"] for item in still_there] == ["sailor-a"]


def test_unknown_capability_strings_are_ignored(client, synchronize) -> None:
    voyage_id = "voyage-unknown-capability"
    assert (
        synchronize(client, voyage_id=voyage_id, secret=SECRET, device_id="skipper").status_code == 200
    )

    response = _presence(
        client,
        voyage_id,
        "sailor-a",
        capabilities=[*LIVE, "teleportation-v9", "", "  "],
        position=_position(51.0),
    )

    assert response.status_code == 200
    assert response.json()["members"] == []


def test_presence_requires_at_least_one_presence_capability(client, synchronize) -> None:
    voyage_id = "voyage-no-capability"
    assert (
        synchronize(client, voyage_id=voyage_id, secret=SECRET, device_id="skipper").status_code == 200
    )

    response = _presence(client, voyage_id, "sailor-a", capabilities=["voyage-start-v1"])

    assert response.status_code == 400
    assert response.json() == {"error": "A live presence capability is required"}


def test_presence_rejects_a_client_below_the_minimum_protocol(client, synchronize) -> None:
    voyage_id = "voyage-presence-old-client"
    assert (
        synchronize(client, voyage_id=voyage_id, secret=SECRET, device_id="skipper").status_code == 200
    )
    client.app.state.settings.minimum_client_protocol = 2

    response = _presence(client, voyage_id, "sailor-a", position=_position(51.0))

    assert response.status_code == 426
    assert response.json()["code"] == "update_required"


def test_presence_rejects_a_client_newer_than_the_service(client, synchronize) -> None:
    voyage_id = "voyage-presence-new-client"
    assert (
        synchronize(client, voyage_id=voyage_id, secret=SECRET, device_id="skipper").status_code == 200
    )

    response = client.post(
        f"/api/v1/voyages/{voyage_id}/presence:sync",
        json={"protocolVersion": 1, "deviceId": "sailor-a"},
        headers={
            "authorization": f"Bearer {voyage_token(voyage_id, SECRET)}",
            "x-tide-and-seek-device": "sailor-a",
            "x-tailendcharlie-protocol": "2",
            "x-tailendcharlie-capabilities": ",".join(LIVE),
        },
    )

    assert response.status_code == 409
    assert response.json()["code"] == "server_upgrade_required"


def test_a_started_voyage_still_expires_a_position_by_ttl(client, synchronize) -> None:
    voyage_id = "voyage-started-ttl"
    assert (
        synchronize(client, voyage_id=voyage_id, secret=SECRET, device_id="skipper").status_code == 200
    )
    assert _presence(client, voyage_id, "sailor-a", position=_position(51.0)).status_code == 200
    assert _start(client, synchronize, voyage_id).status_code == 200
    ttl = client.app.state.settings.pre_start_presence_ttl_seconds

    service = client.app.state.service
    with client.app.state.session_factory() as session:
        observed = service.synchronize_pre_start_presence(
            session,
            voyage_id=voyage_id,
            bearer_token=voyage_token(voyage_id, SECRET),
            device_header="skipper",
            request=PresenceSyncRequest(protocolVersion=1, deviceId="skipper"),
            live_presence=True,
            now=datetime.now(UTC) + timedelta(seconds=ttl + 1),
        )

    assert observed["positions"] == []
    assert observed["phase"] == "started"


def test_members_are_withheld_from_a_legacy_reader(client, synchronize) -> None:
    voyage_id = "voyage-legacy-members"
    assert (
        synchronize(client, voyage_id=voyage_id, secret=SECRET, device_id="skipper").status_code == 200
    )
    assert (
        synchronize(
            client,
            voyage_id=voyage_id,
            secret=SECRET,
            device_id="sailor-a",
            events=[_membership_event(voyage_id, "joined-a", "sailor-a", "Alex", "sailor")],
        ).status_code
        == 200
    )

    legacy = _presence(client, voyage_id, "skipper", capabilities=LEGACY).json()

    assert legacy["members"] == []


def test_a_membership_event_without_a_usable_payload_is_skipped(client, synchronize) -> None:
    voyage_id = "voyage-bad-membership"
    assert (
        synchronize(client, voyage_id=voyage_id, secret=SECRET, device_id="skipper").status_code == 200
    )
    assert (
        synchronize(
            client,
            voyage_id=voyage_id,
            secret=SECRET,
            device_id="sailor-a",
            events=[
                event(
                    voyage_id,
                    "joined-nameless",
                    device_id="sailor-a",
                    event_type="sailorJoined",
                    payload={"role": "sailor"},
                )
            ],
        ).status_code
        == 200
    )

    observed = _presence(client, voyage_id, "skipper").json()

    assert observed["members"] == []
    assert observed["phase"] == "open"


def test_a_repeated_publish_replaces_rather_than_duplicating(client, synchronize) -> None:
    voyage_id = "voyage-duplicate-publish"
    assert (
        synchronize(client, voyage_id=voyage_id, secret=SECRET, device_id="skipper").status_code == 200
    )
    body = _position(51.0)

    for _ in range(4):
        assert _presence(client, voyage_id, "sailor-a", position=body).status_code == 200

    observed = _presence(client, voyage_id, "skipper").json()["positions"]
    assert len(observed) == 1
    with client.app.state.session_factory() as session:
        assert session.scalar(select(func.count()).select_from(PreStartPosition)) == 1


def test_presence_reports_the_relay_clock_alongside_its_arrival_stamps(client, synchronize) -> None:
    """Two phones share no clock, so the relay supplies the one they can both use.

    Issue #132: a peer's position was aged by this phone's clock minus the peer's
    own timestamp, which measures the difference between two clocks as well as
    the age. The relay's arrival stamp and its current time are one clock, so a
    caller can age a peer's position honestly.
    """
    voyage_id = "voyage-server-time"
    assert (
        synchronize(client, voyage_id=voyage_id, secret=SECRET, device_id="skipper").status_code == 200
    )
    assert _presence(client, voyage_id, "sailor-a", position=_position(51.0)).status_code == 200

    before = datetime.now(UTC)
    body = _presence(client, voyage_id, "skipper").json()
    after = datetime.now(UTC)

    server_time = datetime.fromisoformat(body["serverTime"])
    assert before - timedelta(seconds=5) <= server_time <= after + timedelta(seconds=5)
    received_at = datetime.fromisoformat(body["positions"][0]["receivedAt"])
    expires_at = datetime.fromisoformat(body["positions"][0]["expiresAt"])
    # Every stamp in the reply is on that same clock.
    assert received_at <= server_time < expires_at


def test_presence_serves_a_position_whose_publisher_clock_is_behind(client, synchronize) -> None:
    """A phone with a wrong clock still publishes, and is still served."""
    voyage_id = "voyage-skewed-publisher"
    assert (
        synchronize(client, voyage_id=voyage_id, secret=SECRET, device_id="skipper").status_code == 200
    )
    recorded_at = datetime.now(UTC) - timedelta(minutes=4)

    published = _presence(
        client,
        voyage_id,
        "sailor-a",
        position=_position(51.0, recorded_at=recorded_at),
    )

    assert published.status_code == 200
    served = _presence(client, voyage_id, "skipper").json()["positions"][0]
    # The publisher's own timestamp is preserved, and the relay's arrival stamp
    # is what a reader can age it by.
    assert datetime.fromisoformat(served["sample"]["recordedAt"]) == recorded_at
    assert datetime.fromisoformat(served["receivedAt"]) > recorded_at
