from __future__ import annotations

from fastapi.testclient import TestClient
from sqlalchemy import select

from tide_and_seek_server.app import create_app
from tide_and_seek_server.models import VoyageJoinCode

from .conftest import voyage_token

SECRET = "0123456789abcdef0123456789abcdef"
RESOLVE_TOKEN = "resolve-token-0123456789abcdef"


def _register(
    client,
    *,
    code: str = "123456",
    voyage_id: str = "voyage-join-code",
    resolve_token: str = RESOLVE_TOKEN,
):
    return client.put(
        f"/api/v1/join-codes/{code}",
        json={"voyageId": voyage_id, "inviteSecret": SECRET, "resolveToken": resolve_token},
        headers={"authorization": f"Bearer {voyage_token(voyage_id, SECRET)}"},
    )


def test_register_and_resolve_six_digit_voyage_code(client, settings) -> None:
    registered = _register(client)
    assert registered.status_code == 204

    resolved = client.get("/api/v1/join-codes/123456")
    assert resolved.status_code == 200
    assert resolved.json() == {
        "voyageId": "voyage-join-code",
        "voyageCode": "123456",
        "inviteSecret": SECRET,
        "resolveToken": RESOLVE_TOKEN,
    }

    factory = client.app.state.session_factory
    with factory() as session:
        stored = session.scalar(select(VoyageJoinCode).where(VoyageJoinCode.code == "123456"))
        assert stored is not None
        assert SECRET.encode() not in stored.secret_ciphertext
        assert RESOLVE_TOKEN.encode() not in stored.secret_ciphertext


def test_resolve_with_correct_token_succeeds(client) -> None:
    assert _register(client).status_code == 204

    resolved = client.get(
        "/api/v1/join-codes/123456",
        headers={"x-tide-and-seek-join-token": RESOLVE_TOKEN},
    )
    assert resolved.status_code == 200
    assert resolved.json()["inviteSecret"] == SECRET


def test_resolve_with_wrong_token_is_rejected(client) -> None:
    assert _register(client).status_code == 204

    resolved = client.get(
        "/api/v1/join-codes/123456",
        headers={"x-tide-and-seek-join-token": "not-the-right-token-at-all"},
    )
    assert resolved.status_code == 404


def test_registration_requires_a_resolve_token(client) -> None:
    response = client.put(
        "/api/v1/join-codes/123456",
        json={"voyageId": "voyage-join-code", "inviteSecret": SECRET},
        headers={"authorization": f"Bearer {voyage_token('voyage-join-code', SECRET)}"},
    )
    assert response.status_code == 400


def test_a_valid_token_is_exempt_from_the_global_rate_limit(settings) -> None:
    limited = settings.model_copy(update={"join_code_global_rate_limit_requests": 1})

    with TestClient(create_app(limited)) as client:
        assert _register(client).status_code == 204
        # Exhaust the global (token-less) budget.
        assert client.get("/api/v1/join-codes/123456").status_code == 200
        assert client.get("/api/v1/join-codes/123456").status_code == 429
        # A request carrying the correct token is unaffected.
        authenticated = client.get(
            "/api/v1/join-codes/123456",
            headers={"x-tide-and-seek-join-token": RESOLVE_TOKEN},
        )
        assert authenticated.status_code == 200


def test_token_less_lookups_share_a_global_budget_across_callers(settings) -> None:
    limited = settings.model_copy(
        update={
            "join_code_global_rate_limit_requests": 1,
            "join_code_lookup_rate_limit_requests": 1000,
        }
    )

    with TestClient(create_app(limited)) as client:
        assert _register(client, code="111111", voyage_id="voyage-a").status_code == 204
        assert _register(client, code="222222", voyage_id="voyage-b").status_code == 204

        assert client.get("/api/v1/join-codes/111111").status_code == 200
        # A different code, same (unauthenticated) global budget: still capped.
        rejected = client.get("/api/v1/join-codes/222222")
        assert rejected.status_code == 429


def test_registering_the_same_voyage_code_is_idempotent(client) -> None:
    assert _register(client).status_code == 204
    assert _register(client).status_code == 204


def test_voyage_code_cannot_be_claimed_by_another_voyage(client) -> None:
    assert _register(client).status_code == 204
    response = _register(client, voyage_id="another-voyage")
    assert response.status_code == 409
    assert response.json() == {"error": "Voyage code is already in use"}


def test_voyage_code_registration_requires_matching_credential(client) -> None:
    response = client.put(
        "/api/v1/join-codes/123456",
        json={
            "voyageId": "voyage-join-code",
            "inviteSecret": SECRET,
            "resolveToken": RESOLVE_TOKEN,
        },
        headers={
            "authorization": f"Bearer {voyage_token('voyage-join-code', 'wrong-secret-value')}"
        },
    )
    assert response.status_code == 403


def test_voyage_code_lookup_is_numeric_and_rate_limited(settings) -> None:
    limited = settings.model_copy(update={"join_code_lookup_rate_limit_requests": 1})

    with TestClient(create_app(limited)) as client:
        assert _register(client).status_code == 204
        invalid = client.get("/api/v1/join-codes/12345x")
        assert client.get("/api/v1/join-codes/123456").status_code == 200
        rejected = client.get("/api/v1/join-codes/123456")

    assert invalid.status_code == 400
    assert rejected.status_code == 429
