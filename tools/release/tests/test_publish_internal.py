import importlib.util
import unittest
from pathlib import Path

MODULE_PATH = Path(__file__).resolve().parents[1] / "publish_internal.py"
SPEC = importlib.util.spec_from_file_location("publish_internal", MODULE_PATH)
assert SPEC is not None and SPEC.loader is not None
publish_internal = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(publish_internal)

AppStoreConnectError = publish_internal.AppStoreConnectError


class FakeClient:
    """Records requests and replays queued responses."""

    def __init__(self, responses):
        self._responses = list(responses)
        self.calls = []

    def request(self, method, path, *, query=None, body=None, expected=(200,)):
        self.calls.append((method, path, query, body))
        if not self._responses:
            raise AssertionError(f"No queued response for {method} {path}")
        return self._responses.pop(0)


def build(state, build_id="b1"):
    return {"id": build_id, "attributes": {"processingState": state}}


class WaitForBuildTests(unittest.TestCase):
    def test_returns_the_build_once_it_is_valid(self):
        client = FakeClient([{"data": [build("VALID")]}])
        result = publish_internal.wait_for_build(
            client,
            app_id="app",
            build_number="23",
            timeout_seconds=60,
            poll_seconds=1,
        )
        self.assertEqual(result["id"], "b1")

    def test_waits_through_a_build_that_is_not_visible_yet(self):
        # altool reports success well before the build appears; build 23 took
        # about two and a half minutes. "Not found" is a state to wait through.
        client = FakeClient(
            [
                {"data": []},
                {"data": []},
                {"data": [build("PROCESSING")]},
                {"data": [build("VALID")]},
            ]
        )
        slept = []
        clock = iter([0, 1, 2, 3, 4, 5])
        result = publish_internal.wait_for_build(
            client,
            app_id="app",
            build_number="23",
            timeout_seconds=60,
            poll_seconds=7,
            sleep=slept.append,
            now=lambda: next(clock),
        )
        self.assertEqual(result["id"], "b1")
        self.assertEqual(slept, [7, 7, 7])

    def test_a_failed_build_stops_immediately(self):
        client = FakeClient([{"data": [build("INVALID")]}])
        with self.assertRaises(AppStoreConnectError) as caught:
            publish_internal.wait_for_build(
                client,
                app_id="app",
                build_number="23",
                timeout_seconds=60,
                poll_seconds=1,
            )
        self.assertIn("INVALID", str(caught.exception))

    def test_a_timeout_reports_the_last_state_seen(self):
        client = FakeClient([{"data": [build("PROCESSING")]}])
        clock = iter([0, 100])
        with self.assertRaises(AppStoreConnectError) as caught:
            publish_internal.wait_for_build(
                client,
                app_id="app",
                build_number="23",
                timeout_seconds=10,
                poll_seconds=1,
                sleep=lambda _: None,
                now=lambda: next(clock),
            )
        self.assertIn("PROCESSING", str(caught.exception))


class FindInternalGroupTests(unittest.TestCase):
    def test_finds_the_named_internal_group(self):
        client = FakeClient(
            [
                {
                    "data": [
                        {
                            "id": "g1",
                            "attributes": {"name": "Internal Testing", "isInternalGroup": True},
                        },
                        {
                            "id": "g2",
                            "attributes": {"name": "Public Beta", "isInternalGroup": False},
                        },
                    ]
                }
            ]
        )
        group = publish_internal.find_internal_group(
            client, app_id="app", group_name="Internal Testing"
        )
        self.assertEqual(group["id"], "g1")

    def test_refuses_an_external_group_with_a_matching_name(self):
        # Attaching to an external group needs beta review and is a different
        # act. Being pointed at the wrong name must fail, not escalate.
        client = FakeClient(
            [
                {
                    "data": [
                        {
                            "id": "g2",
                            "attributes": {"name": "Internal Testing", "isInternalGroup": False},
                        }
                    ]
                }
            ]
        )
        with self.assertRaises(AppStoreConnectError):
            publish_internal.find_internal_group(
                client, app_id="app", group_name="Internal Testing"
            )


class EnsureGroupAccessTests(unittest.TestCase):
    def test_attaches_a_build_that_is_not_in_the_group(self):
        client = FakeClient([{"data": []}, {}])
        changed = publish_internal.ensure_group_access(
            client, build_id="b1", group={"id": "g1"}, dry_run=False
        )
        self.assertTrue(changed)
        self.assertEqual(client.calls[1][0], "POST")

    def test_is_idempotent(self):
        client = FakeClient([{"data": [{"id": "g1"}]}])
        changed = publish_internal.ensure_group_access(
            client, build_id="b1", group={"id": "g1"}, dry_run=False
        )
        self.assertFalse(changed)
        self.assertEqual(len(client.calls), 1)

    def test_a_dry_run_reports_without_posting(self):
        client = FakeClient([{"data": []}])
        self.assertTrue(
            publish_internal.ensure_group_access(
                client, build_id="b1", group={"id": "g1"}, dry_run=True
            )
        )
        self.assertEqual(len(client.calls), 1)


class SetWhatsNewTests(unittest.TestCase):
    def test_patches_the_localisation_app_store_connect_made_itself(self):
        # The reason this function exists. App Store Connect creates an empty
        # record for the primary locale, and POSTing over it 409s with
        # "There is an entity with same 'locale'".
        client = FakeClient([{"data": [{"id": "loc1", "attributes": {"locale": "en-GB"}}]}, {}])
        outcome = publish_internal.set_whats_new(
            client, build_id="b1", locale="en-GB", notes="What changed", dry_run=False
        )
        self.assertEqual(outcome, "updated")
        method, path, _, body = client.calls[1]
        self.assertEqual(method, "PATCH")
        self.assertEqual(path, "/betaBuildLocalizations/loc1")
        self.assertEqual(body["data"]["attributes"]["whatsNew"], "What changed")

    def test_creates_a_localisation_for_a_locale_that_has_none(self):
        client = FakeClient([{"data": [{"id": "loc1", "attributes": {"locale": "en-US"}}]}, {}])
        outcome = publish_internal.set_whats_new(
            client, build_id="b1", locale="en-GB", notes="What changed", dry_run=False
        )
        self.assertEqual(outcome, "created")
        self.assertEqual(client.calls[1][0], "POST")

    def test_refuses_empty_notes(self):
        # A build with no notes tells the tester nothing about what to try, and
        # the whole point of keeping them in the repo is that they get written.
        client = FakeClient([])
        with self.assertRaises(AppStoreConnectError):
            publish_internal.set_whats_new(
                client, build_id="b1", locale="en-GB", notes="   \n ", dry_run=False
            )

    def test_refuses_notes_longer_than_app_store_connect_accepts(self):
        client = FakeClient([])
        with self.assertRaises(AppStoreConnectError) as caught:
            publish_internal.set_whats_new(
                client,
                build_id="b1",
                locale="en-GB",
                notes="x" * (publish_internal.MAX_WHATS_NEW + 1),
                dry_run=False,
            )
        self.assertIn("limit", str(caught.exception))


class ParseArgsTests(unittest.TestCase):
    def test_defaults_to_the_internal_group_and_uk_english(self):
        args = publish_internal.parse_args(
            [
                "--bundle-id",
                "dev.osholt.tideandseek",
                "--build-number",
                "23",
                "--notes",
                "RELEASE_NOTES.md",
                "--issuer-id",
                "i",
                "--key-id",
                "k",
                "--private-key",
                "k.p8",
            ]
        )
        self.assertEqual(args.group, "Internal Testing")
        self.assertEqual(args.locale, "en-GB")


if __name__ == "__main__":
    unittest.main()
