from __future__ import annotations

from contextlib import contextmanager

from fastapi.testclient import TestClient
from pydantic import SecretStr

from ride_relay_server.app import create_app


@contextmanager
def _admin_client(settings):
    configured = settings.model_copy(
        update={
            "discovery_admin_token": SecretStr("admin-token-at-least-32-characters"),
            "discovery_admin_name": "test-reviewer",
        }
    )
    with TestClient(create_app(configured)) as client:
        yield client


def _suggestion(client_submission_id: str = "browser-draft-1") -> dict:
    return {
        "clientSubmissionId": client_submission_id,
        "category": "mountain_pass",
        "action": "add",
        "targetFeatureId": None,
        "name": "Test summit",
        "reason": "Mapped summit sign and public road access",
        "evidenceUrl": "https://www.openstreetmap.org/copyright",
        "geometry": {"type": "Point", "coordinates": [-3.115, 52.01]},
        "createdAt": "2026-07-22T12:00:00Z",
    }


def test_unreviewed_suggestion_is_private_until_admin_approval(settings):
    with _admin_client(settings) as client:
        submitted = client.post(
            "/api/v1/discovery/suggestions",
            json=_suggestion(),
        )
        assert submitted.status_code == 202
        suggestion_id = submitted.json()["id"]
        assert set(submitted.json()) == {
            "id",
            "clientSubmissionId",
            "status",
            "submittedAt",
            "updatedAt",
            "publishedFeatureId",
        }

        bounds = (
            "/api/v1/discovery/features"
            "?west=-3.2&south=51.9&east=-3&north=52.1&categories=mountain_pass"
        )
        assert client.get(bounds).json()["features"] == []
        assert client.get("/api/v1/admin/discovery/suggestions").status_code == 401

        admin_headers = {"authorization": "Bearer admin-token-at-least-32-characters"}
        queue = client.get(
            "/api/v1/admin/discovery/suggestions",
            headers=admin_headers,
        )
        assert queue.status_code == 200
        assert queue.json()["suggestions"][0]["reason"].startswith("Mapped summit")

        approved = client.post(
            f"/api/v1/admin/discovery/suggestions/{suggestion_id}:moderate",
            headers=admin_headers,
            json={"action": "approve", "reason": "Location and licence checked"},
        )
        assert approved.status_code == 200
        assert approved.json()["status"] == "approved"
        assert approved.json()["auditTrail"][0]["actor"] == "test-reviewer"

        public = client.get(bounds)
        assert public.status_code == 200
        feature = public.json()["features"][0]
        assert feature["properties"]["moderationStatus"] == "approved"
        assert feature["properties"]["approvedRevisionId"] == suggestion_id
        assert public.headers["cache-control"].startswith("public")


def test_rejected_and_superseded_suggestions_never_publish(settings):
    with _admin_client(settings) as client:
        headers = {"authorization": "Bearer admin-token-at-least-32-characters"}
        for index, action in enumerate(("reject", "supersede"), start=1):
            response = client.post(
                "/api/v1/discovery/suggestions",
                json=_suggestion(f"rejected-{index}"),
            )
            moderated = client.post(
                f"/api/v1/admin/discovery/suggestions/{response.json()['id']}:moderate",
                headers=headers,
                json={"action": action, "reason": "Duplicate or unsuitable evidence"},
            )
            assert moderated.status_code == 200
            assert moderated.json()["publishedFeatureId"] is None

        public = client.get(
            "/api/v1/discovery/features"
            "?west=-3.2&south=51.9&east=-3&north=52.1&categories=mountain_pass"
        )
        assert public.json()["features"] == []


def test_submission_identifier_is_idempotent_but_cannot_change_body(client):
    first = client.post("/api/v1/discovery/suggestions", json=_suggestion())
    replay = client.post("/api/v1/discovery/suggestions", json=_suggestion())
    assert replay.status_code == 202
    assert replay.json()["id"] == first.json()["id"]

    changed = _suggestion()
    changed["name"] = "Different summit"
    conflict = client.post("/api/v1/discovery/suggestions", json=changed)
    assert conflict.status_code == 409


def test_public_discovery_requests_must_be_geographically_bounded(client):
    response = client.get(
        "/api/v1/discovery/features?west=-10&south=40&east=10&north=60&categories=mountain_pass"
    )
    assert response.status_code == 400
