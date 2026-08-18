"""#49. The app renamed its `lead` role to `skipper`.

`lead` is the road group-riding role the app was scaffolded from; on a boat the
word is skipper. The rename matters here because the relay pinned the old name
in `Literal` types, so an app sending `skipper` would have been rejected with a
422 on every presence position, every roster projection and every push
registration - crew sharing failing silently, mid-passage, with no error a
sailor would understand.

Both spellings are therefore accepted. These tests hold that open in both
directions: a current app must work, and an app that has not updated must not
be cut off.
"""

from __future__ import annotations

import pytest
from pydantic import ValidationError

from tide_and_seek_server.membership import COORDINATOR_ROLES, KNOWN_ROLES, safe_role
from tide_and_seek_server.schemas import (
    PresencePositionRequest,
    PushRegistrationRequest,
)


def _position(role: str) -> dict:
    return {
        "displayName": "Alex",
        "role": role,
        "motorcycleStyle": "adventure",
        "sailorColor": "blue",
        "sample": {
            "position": {"latitude": 50.75, "longitude": -1.52},
            "recordedAt": "2026-08-19T00:00:00Z",
            "accuracyMeters": 4,
        },
    }


@pytest.mark.parametrize("role", ["skipper", "lead", "sailor", "sweeper", "marker"])
def test_a_presence_position_is_accepted_under_either_spelling(role: str) -> None:
    assert PresencePositionRequest.model_validate(_position(role)).role == role


def test_a_presence_position_still_refuses_an_invented_role() -> None:
    with pytest.raises(ValidationError):
        PresencePositionRequest.model_validate(_position("harbourmaster"))


@pytest.mark.parametrize("role", ["skipper", "lead"])
def test_push_registration_accepts_either_spelling(role: str) -> None:
    request = PushRegistrationRequest.model_validate(
        {
            "platform": "ios",
            "provider": "apns",
            "token": "0123456789abcdef0123456789abcdef",
            "role": role,
        }
    )
    assert request.role == role


@pytest.mark.parametrize("role", sorted(KNOWN_ROLES))
def test_a_projected_roster_keeps_every_known_role(role: str) -> None:
    assert safe_role(role) == role


def test_an_unknown_role_falls_back_to_sailor_rather_than_failing() -> None:
    # A roster rebuilt from stored events must not lose a member because a
    # newer app sent a role this relay has never heard of.
    assert safe_role("harbourmaster") == "sailor"
    assert safe_role(None) == "sailor"


def test_both_spellings_of_the_skipper_coordinate_a_voyage() -> None:
    # Push routing asks "is this a coordinator". A skipper on a current app and
    # a skipper on an older one are the same person, and both must be told.
    assert {"skipper", "lead"} <= COORDINATOR_ROLES
    assert "sailor" not in COORDINATOR_ROLES
