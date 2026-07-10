import importlib.util
import io
import pathlib
import sys
import unittest
from datetime import datetime, timedelta, timezone
from contextlib import redirect_stdout, redirect_stderr


ROOT = pathlib.Path(__file__).resolve().parents[1]


def load_script_module(name: str, relative_path: str):
    path = ROOT / relative_path
    spec = importlib.util.spec_from_file_location(name, path)
    module = importlib.util.module_from_spec(spec)
    assert spec.loader is not None
    spec.loader.exec_module(module)
    return module


class LiveVerifierScriptsTests(unittest.TestCase):
    def test_bulk_diagnostics_request_includes_batch_size_when_provided(self):
        verifier = load_script_module(
            "verify_live_bulk_diagnostics_script",
            "scripts/verify_live_bulk_diagnostics.py",
        )

        captured = {}

        def fake_invoke(base_url: str, name: str, args: dict) -> dict:
            captured["base_url"] = base_url
            captured["name"] = name
            captured["args"] = args
            return {"ok": True}

        verifier.invoke_function = fake_invoke

        verifier.request_all_diagnostics("https://sync.velvet-leaf.com", "token-1", 5)

        self.assertEqual(captured["name"], "agent_diagnostics_request_all")
        self.assertEqual(captured["args"]["token"], "token-1")
        self.assertEqual(captured["args"]["batchSize"], 5)

    def test_bulk_diagnostics_parse_request_result_rejects_missing_request_id(self):
        verifier = load_script_module(
            "verify_live_bulk_diagnostics_script",
            "scripts/verify_live_bulk_diagnostics.py",
        )

        with self.assertRaises(verifier.ApiError):
            verifier.parse_diagnostics_request_result(
                {
                    "requestedClientCount": 1,
                    "requestedClientNames": ["c1"],
                }
            )

    def test_bulk_diagnostics_parse_request_result_rejects_mismatched_requested_count(self):
        verifier = load_script_module(
            "verify_live_bulk_diagnostics_script",
            "scripts/verify_live_bulk_diagnostics.py",
        )

        with self.assertRaises(verifier.ApiError):
            verifier.parse_diagnostics_request_result(
                {
                    "requestId": "req-1",
                    "requestedClientCount": 2,
                    "requestedClientNames": ["c1"],
                }
            )

    def test_bulk_diagnostics_parse_request_result_rejects_duplicate_names(self):
        verifier = load_script_module(
            "verify_live_bulk_diagnostics_script",
            "scripts/verify_live_bulk_diagnostics.py",
        )

        with self.assertRaises(verifier.ApiError):
            verifier.parse_diagnostics_request_result(
                {
                    "requestId": "req-1",
                    "requestedClientCount": 2,
                    "requestedClientNames": ["c1", "c1"],
                }
            )

    def test_bulk_diagnostics_parse_request_result_accepts_valid_payload(self):
        verifier = load_script_module(
            "verify_live_bulk_diagnostics_script",
            "scripts/verify_live_bulk_diagnostics.py",
        )

        request_id, names = verifier.parse_diagnostics_request_result(
            {
                "requestId": "req-1",
                "requestedClientCount": 2,
                "requestedClientNames": ["c1", "c2"],
            }
        )

        self.assertEqual(request_id, "req-1")
        self.assertEqual(names, ["c1", "c2"])

    def test_client_update_heartbeat_age_minutes_parses_iso_timestamp(self):
        verifier = load_script_module(
            "verify_live_client_update_script",
            "scripts/verify_live_client_update.py",
        )
        now = datetime(2026, 7, 8, 21, 0, tzinfo=timezone.utc)
        observed = (now - timedelta(minutes=7, seconds=30)).isoformat()

        age = verifier.heartbeat_age_minutes(observed, now=now)

        self.assertIsNotNone(age)
        assert age is not None
        self.assertGreater(age, 7.4)
        self.assertLess(age, 7.6)

    def test_client_update_heartbeat_age_minutes_clamps_future_skew_to_zero(self):
        verifier = load_script_module(
            "verify_live_client_update_script",
            "scripts/verify_live_client_update.py",
        )
        now = datetime(2026, 7, 8, 21, 0, tzinfo=timezone.utc)
        observed = (now + timedelta(seconds=2)).isoformat()

        age = verifier.heartbeat_age_minutes(observed, now=now)

        self.assertEqual(age, 0.0)

    def test_client_update_summarize_client_includes_pending_update_fields(self):
        verifier = load_script_module(
            "verify_live_client_update_script",
            "scripts/verify_live_client_update.py",
        )
        agent = {
            "clientName": "c1",
            "machineName": "DESKTOP-1",
            "clientVersion": "1.0.90+94",
            "isOnline": True,
            "serverConnected": True,
            "sqlConnected": True,
            "lastHeartbeat": "2026-07-08T20:49:56.402410997+00:00",
            "clientUpdate": {
                "pending": True,
                "requestId": "req-1",
                "requestedAt": "2026-07-08T20:50:00+00:00",
                "lastRequestId": "req-0",
                "acknowledgedAt": "2026-07-08T20:49:00+00:00",
                "status": "requested",
                "message": "",
                "targetVersion": "1.0.91+95",
            },
        }

        summary = verifier.summarize_client(agent)

        self.assertEqual(summary["clientName"], "c1")
        self.assertEqual(summary["machineName"], "DESKTOP-1")
        self.assertEqual(summary["version"], "1.0.90+94")
        self.assertTrue(summary["online"])
        self.assertTrue(summary["serverConnected"])
        self.assertTrue(summary["sqlConnected"])
        self.assertTrue(summary["pending"])
        self.assertEqual(summary["requestId"], "req-1")
        self.assertEqual(summary["requestedAt"], "2026-07-08T20:50:00+00:00")
        self.assertEqual(summary["lastRequestId"], "req-0")
        self.assertEqual(summary["acknowledgedAt"], "2026-07-08T20:49:00+00:00")
        self.assertEqual(summary["status"], "requested")
        self.assertEqual(summary["targetVersion"], "1.0.91+95")
        self.assertIsInstance(summary["heartbeatAgeMinutes"], float)

    def test_client_update_find_agent_summary_rejects_missing_client(self):
        verifier = load_script_module(
            "verify_live_client_update_script",
            "scripts/verify_live_client_update.py",
        )

        with self.assertRaises(verifier.ApiError):
            verifier.find_agent_summary({"agents": [{"clientName": "c2"}]}, "c1")

    def test_client_update_retryable_transport_error_matches_connection_reset(self):
        verifier = load_script_module(
            "verify_live_client_update_script",
            "scripts/verify_live_client_update.py",
        )

        self.assertTrue(
            verifier.retryable_transport_error(
                verifier.ApiError(
                    "request failed: <urlopen error [WinError 10054] An existing connection was forcibly closed by the remote host>"
                )
            )
        )
        self.assertFalse(verifier.retryable_transport_error(verifier.ApiError("HTTP 408: timeout")))

    def test_client_update_post_json_retries_transient_transport_reset(self):
        verifier = load_script_module(
            "verify_live_client_update_script",
            "scripts/verify_live_client_update.py",
        )

        calls = {"count": 0}

        class FakeResponse:
            def __enter__(self):
                return self

            def __exit__(self, exc_type, exc, tb):
                return False

            def read(self):
                return b'{"ok": true}'

        def fake_urlopen(request, timeout=30):
            self.assertEqual(timeout, 30)
            calls["count"] += 1
            if calls["count"] == 1:
                raise verifier.urllib.error.URLError(
                    ConnectionResetError(
                        10054,
                        "An existing connection was forcibly closed by the remote host",
                    )
                )
            return FakeResponse()

        verifier.urllib.request.urlopen = fake_urlopen
        verifier.time.sleep = lambda seconds: None

        decoded = verifier.post_json("https://sync.velvet-leaf.com/call", {"name": "x"})

        self.assertEqual(decoded, {"ok": True})
        self.assertEqual(calls["count"], 2)

    def test_client_update_post_json_rejects_non_map_payloads(self):
        verifier = load_script_module(
            "verify_live_client_update_script",
            "scripts/verify_live_client_update.py",
        )

        class FakeResponse:
            def __enter__(self):
                return self

            def __exit__(self, exc_type, exc, tb):
                return False

            def read(self):
                return b'["not-a-map"]'

        verifier.urllib.request.urlopen = lambda request, timeout=30: FakeResponse()

        with self.assertRaises(verifier.ApiError):
            verifier.post_json("https://sync.velvet-leaf.com/call", {"name": "x"})

    def test_client_update_post_json_rejects_invalid_json_payloads(self):
        verifier = load_script_module(
            "verify_live_client_update_script",
            "scripts/verify_live_client_update.py",
        )

        class FakeResponse:
            def __enter__(self):
                return self

            def __exit__(self, exc_type, exc, tb):
                return False

            def read(self):
                return b"{not-json"

        verifier.urllib.request.urlopen = lambda request, timeout=30: FakeResponse()

        with self.assertRaises(verifier.ApiError):
            verifier.post_json("https://sync.velvet-leaf.com/call", {"name": "x"})

    def test_client_update_invoke_function_rejects_non_map_success_value(self):
        verifier = load_script_module(
            "verify_live_client_update_script",
            "scripts/verify_live_client_update.py",
        )

        verifier.post_json = lambda url, payload: {"status": "success", "value": ["not-a-map"]}

        with self.assertRaises(verifier.ApiError):
            verifier.invoke_function("https://sync.velvet-leaf.com", "live_state", {"token": "x"})

    def test_client_update_invoke_function_surfaces_failed_status_payload(self):
        verifier = load_script_module(
            "verify_live_client_update_script",
            "scripts/verify_live_client_update.py",
        )

        verifier.post_json = lambda url, payload: {"status": "failed", "error": "boom"}

        with self.assertRaises(verifier.ApiError):
            verifier.invoke_function("https://sync.velvet-leaf.com", "live_state", {"token": "x"})

    def test_client_update_fetch_health_retries_transient_transport_reset(self):
        verifier = load_script_module(
            "verify_live_client_update_script",
            "scripts/verify_live_client_update.py",
        )

        calls = {"count": 0}

        class FakeResponse:
            def __enter__(self):
                return self

            def __exit__(self, exc_type, exc, tb):
                return False

            def read(self):
                return b'{"ready": true, "compile_errors": 0, "build": {"git_commit": "commit-1"}}'

        def fake_urlopen(request, timeout=30):
            self.assertEqual(timeout, 30)
            calls["count"] += 1
            if calls["count"] == 1:
                raise verifier.urllib.error.URLError(ConnectionResetError(10054, "Connection reset by peer"))
            return FakeResponse()

        verifier.urllib.request.urlopen = fake_urlopen
        verifier.time.sleep = lambda seconds: None

        decoded = verifier.fetch_health("https://sync.velvet-leaf.com")

        self.assertEqual(decoded["ready"], True)
        self.assertEqual(decoded["build"]["git_commit"], "commit-1")
        self.assertEqual(calls["count"], 2)

    def test_client_update_fetch_health_rejects_non_map_payloads(self):
        verifier = load_script_module(
            "verify_live_client_update_script",
            "scripts/verify_live_client_update.py",
        )

        class FakeResponse:
            def __enter__(self):
                return self

            def __exit__(self, exc_type, exc, tb):
                return False

            def read(self):
                return b'["not-a-map"]'

        verifier.urllib.request.urlopen = lambda request, timeout=30: FakeResponse()

        with self.assertRaises(verifier.ApiError):
            verifier.fetch_health("https://sync.velvet-leaf.com")

    def test_client_update_main_returns_success_when_target_version_is_acknowledged(self):
        verifier = load_script_module(
            "verify_live_client_update_script",
            "scripts/verify_live_client_update.py",
        )
        stdout = io.StringIO()
        stderr = io.StringIO()

        verifier.fetch_health = lambda base_url: {
            "ready": True,
            "compile_errors": 0,
            "build": {"git_commit": "commit-1"},
        }
        verifier.login = lambda base_url, username, password: (
            "token-1",
            {"username": username, "role": "admin"},
        )
        verifier.request_client_update = (
            lambda base_url, token, client_name, target_version: {
                "requestId": "req-1",
                "clientName": client_name,
                "targetVersion": target_version,
            }
        )
        verifier.live_state = lambda base_url, token: {
            "agents": [
                {
                    "clientName": "c1",
                    "machineName": "DESKTOP-1",
                    "clientVersion": "1.0.105+109",
                    "isOnline": True,
                    "serverConnected": True,
                    "sqlConnected": True,
                    "lastHeartbeat": "2026-07-09T10:00:00+00:00",
                    "clientUpdate": {
                        "pending": False,
                        "requestId": "req-1",
                        "requestedAt": "2026-07-09T09:59:00+00:00",
                        "lastRequestId": "req-1",
                        "acknowledgedAt": "2026-07-09T10:00:00+00:00",
                        "status": "current",
                        "message": "",
                        "targetVersion": "1.0.105+109",
                    },
                }
            ]
        }
        verifier.time.sleep = lambda seconds: None
        ticks = iter([1000.0, 1000.5])
        verifier.time.time = lambda: next(ticks, 1000.5)

        argv = sys.argv
        sys.argv = [
            "verify_live_client_update.py",
            "c1",
            "1.0.105+109",
            "--expect-commit",
            "commit-1",
            "--wait-seconds",
            "1",
            "--poll-seconds",
            "1",
        ]
        try:
            with redirect_stdout(stdout), redirect_stderr(stderr):
                exit_code = verifier.main()
        finally:
            sys.argv = argv

        self.assertEqual(exit_code, 0)
        self.assertEqual(stderr.getvalue(), "")
        self.assertIn("request=", stdout.getvalue())
        self.assertIn("client=c1 machine=DESKTOP-1", stdout.getvalue())

    def test_client_update_main_returns_stale_timeout_code(self):
        verifier = load_script_module(
            "verify_live_client_update_script",
            "scripts/verify_live_client_update.py",
        )
        stdout = io.StringIO()
        stderr = io.StringIO()

        verifier.fetch_health = lambda base_url: {
            "ready": True,
            "compile_errors": 0,
            "build": {"git_commit": "commit-1"},
        }
        verifier.login = lambda base_url, username, password: (
            "token-1",
            {"username": username, "role": "admin"},
        )
        verifier.request_client_update = (
            lambda base_url, token, client_name, target_version: {
                "requestId": "req-1",
                "clientName": client_name,
                "targetVersion": target_version,
            }
        )
        verifier.live_state = lambda base_url, token: {
            "agents": [
                {
                    "clientName": "c1",
                    "machineName": "DESKTOP-1",
                    "clientVersion": "1.0.104+108",
                    "isOnline": False,
                    "serverConnected": False,
                    "sqlConnected": False,
                    "lastHeartbeat": "2026-07-09T00:00:00+00:00",
                    "clientUpdate": {
                        "pending": True,
                        "requestId": "req-1",
                        "requestedAt": "2026-07-09T09:59:00+00:00",
                        "lastRequestId": "req-1",
                        "acknowledgedAt": "",
                        "status": "requested",
                        "message": "",
                        "targetVersion": "1.0.105+109",
                    },
                }
            ]
        }
        verifier.time.sleep = lambda seconds: None
        ticks = iter([1000.0, 1000.5, 1002.0])
        verifier.time.time = lambda: next(ticks, 1002.0)

        argv = sys.argv
        sys.argv = [
            "verify_live_client_update.py",
            "c1",
            "1.0.105+109",
            "--expect-commit",
            "commit-1",
            "--wait-seconds",
            "1",
            "--poll-seconds",
            "1",
            "--stale-heartbeat-minutes",
            "20",
        ]
        try:
            with redirect_stdout(stdout), redirect_stderr(stderr):
                exit_code = verifier.main()
        finally:
            sys.argv = argv

        self.assertEqual(exit_code, 3)
        self.assertIn("timed out waiting for c1 to update; client is offline/stale", stderr.getvalue())
        self.assertIn("client=c1 machine=DESKTOP-1", stdout.getvalue())

    def test_client_update_main_returns_pending_timeout_code_for_online_client(self):
        verifier = load_script_module(
            "verify_live_client_update_script",
            "scripts/verify_live_client_update.py",
        )
        stdout = io.StringIO()
        stderr = io.StringIO()

        verifier.fetch_health = lambda base_url: {
            "ready": True,
            "compile_errors": 0,
            "build": {"git_commit": "commit-1"},
        }
        verifier.login = lambda base_url, username, password: (
            "token-1",
            {"username": username, "role": "admin"},
        )
        verifier.request_client_update = (
            lambda base_url, token, client_name, target_version: {
                "requestId": "req-1",
                "clientName": client_name,
                "targetVersion": target_version,
            }
        )
        verifier.live_state = lambda base_url, token: {
            "agents": [
                {
                    "clientName": "c1",
                    "machineName": "DESKTOP-1",
                    "clientVersion": "1.0.104+108",
                    "isOnline": True,
                    "serverConnected": True,
                    "sqlConnected": True,
                    "lastHeartbeat": datetime.now(timezone.utc).isoformat(),
                    "clientUpdate": {
                        "pending": True,
                        "requestId": "req-1",
                        "requestedAt": "2026-07-09T09:59:00+00:00",
                        "lastRequestId": "req-1",
                        "acknowledgedAt": "",
                        "status": "requested",
                        "message": "",
                        "targetVersion": "1.0.105+109",
                    },
                }
            ]
        }
        verifier.time.sleep = lambda seconds: None
        ticks = iter([1000.0, 1000.5, 1002.0])
        verifier.time.time = lambda: next(ticks, 1002.0)

        argv = sys.argv
        sys.argv = [
            "verify_live_client_update.py",
            "c1",
            "1.0.105+109",
            "--expect-commit",
            "commit-1",
            "--wait-seconds",
            "1",
            "--poll-seconds",
            "1",
            "--stale-heartbeat-minutes",
            "20",
        ]
        try:
            with redirect_stdout(stdout), redirect_stderr(stderr):
                exit_code = verifier.main()
        finally:
            sys.argv = argv

        self.assertEqual(exit_code, 1)
        self.assertIn("timed out waiting for c1 to update; last observed state:", stderr.getvalue())
        self.assertIn("client=c1 machine=DESKTOP-1", stdout.getvalue())

    def test_client_update_main_returns_commit_mismatch_code(self):
        verifier = load_script_module(
            "verify_live_client_update_script",
            "scripts/verify_live_client_update.py",
        )
        stdout = io.StringIO()
        stderr = io.StringIO()

        verifier.fetch_health = lambda base_url: {
            "ready": True,
            "compile_errors": 0,
            "build": {"git_commit": "commit-live"},
        }

        argv = sys.argv
        sys.argv = [
            "verify_live_client_update.py",
            "c1",
            "1.0.105+109",
            "--expect-commit",
            "commit-expected",
        ]
        try:
            with redirect_stdout(stdout), redirect_stderr(stderr):
                exit_code = verifier.main()
        finally:
            sys.argv = argv

        self.assertEqual(exit_code, 2)
        self.assertIn("build.git_commit=commit-live", stdout.getvalue())
        self.assertIn("expected live commit commit-expected but found commit-live", stderr.getvalue())

    def test_client_update_main_returns_no_live_state_observed_code(self):
        verifier = load_script_module(
            "verify_live_client_update_script",
            "scripts/verify_live_client_update.py",
        )
        stdout = io.StringIO()
        stderr = io.StringIO()

        verifier.fetch_health = lambda base_url: {
            "ready": True,
            "compile_errors": 0,
            "build": {"git_commit": "commit-1"},
        }
        verifier.login = lambda base_url, username, password: (
            "token-1",
            {"username": username, "role": "admin"},
        )
        verifier.request_client_update = (
            lambda base_url, token, client_name, target_version: {
                "requestId": "req-1",
                "clientName": client_name,
                "targetVersion": target_version,
            }
        )
        verifier.time.sleep = lambda seconds: None
        ticks = iter([1000.0, 1002.0])
        verifier.time.time = lambda: next(ticks, 1002.0)

        argv = sys.argv
        sys.argv = [
            "verify_live_client_update.py",
            "c1",
            "1.0.105+109",
            "--expect-commit",
            "commit-1",
            "--wait-seconds",
            "1",
            "--poll-seconds",
            "1",
        ]
        try:
            with redirect_stdout(stdout), redirect_stderr(stderr):
                exit_code = verifier.main()
        finally:
            sys.argv = argv

        self.assertEqual(exit_code, 1)
        self.assertIn("no live state observed", stderr.getvalue())

    def test_client_update_run_cli_converts_api_error_to_clean_exit(self):
        verifier = load_script_module(
            "verify_live_client_update_script",
            "scripts/verify_live_client_update.py",
        )
        stderr = io.StringIO()

        verifier.main = lambda: (_ for _ in ()).throw(verifier.ApiError("client update boom"))

        with redirect_stderr(stderr):
            exit_code = verifier.run_cli()

        self.assertEqual(exit_code, 1)
        self.assertEqual(stderr.getvalue().strip(), "client update boom")

    def test_bulk_diagnostics_pending_client_summary_includes_online_and_heartbeat(self):
        verifier = load_script_module(
            "verify_live_bulk_diagnostics_script",
            "scripts/verify_live_bulk_diagnostics.py",
        )
        state = {
            "agents": [
                {
                    "clientName": "c1",
                    "isOnline": False,
                    "lastHeartbeat": "2026-07-09T23:54:45.759043585+00:00",
                    "diagnostics": {
                        "status": "requested",
                        "lastRequestId": "req-0",
                        "uploadedAt": "",
                    },
                }
            ]
        }

        summaries = verifier.summarize_pending_clients(state, ["c1"])

        self.assertEqual(len(summaries), 1)
        summary = summaries[0]
        self.assertEqual(summary["clientName"], "c1")
        self.assertFalse(summary["online"])
        self.assertEqual(summary["diagnosticsStatus"], "requested")
        self.assertEqual(summary["lastRequestId"], "req-0")
        self.assertEqual(summary["uploadedAt"], "")
        self.assertIsInstance(summary["heartbeatAgeMinutes"], float)

    def test_bulk_diagnostics_heartbeat_age_minutes_clamps_future_skew_to_zero(self):
        verifier = load_script_module(
            "verify_live_bulk_diagnostics_script",
            "scripts/verify_live_bulk_diagnostics.py",
        )
        now = datetime(2026, 7, 9, 23, 55, tzinfo=timezone.utc)
        observed = (now + timedelta(seconds=2)).isoformat()

        age = verifier.heartbeat_age_minutes(observed, now=now)

        self.assertEqual(age, 0.0)

    def test_bulk_diagnostics_pending_client_summary_handles_missing_agent(self):
        verifier = load_script_module(
            "verify_live_bulk_diagnostics_script",
            "scripts/verify_live_bulk_diagnostics.py",
        )

        summaries = verifier.summarize_pending_clients({"agents": []}, ["c9"])

        self.assertEqual(
            summaries,
            [
                {
                    "clientName": "c9",
                    "online": False,
                    "lastHeartbeat": "",
                    "heartbeatAgeMinutes": None,
                    "diagnosticsStatus": "",
                    "lastRequestId": "",
                    "uploadedAt": "",
                }
            ],
        )

    def test_bulk_diagnostics_retryable_transport_error_matches_connection_reset(self):
        verifier = load_script_module(
            "verify_live_bulk_diagnostics_script",
            "scripts/verify_live_bulk_diagnostics.py",
        )

        self.assertTrue(
            verifier.retryable_transport_error(
                verifier.ApiError(
                    "request failed: <urlopen error [WinError 10054] An existing connection was forcibly closed by the remote host>"
                )
            )
        )
        self.assertFalse(verifier.retryable_transport_error(verifier.ApiError("HTTP 408: timeout")))

    def test_bulk_diagnostics_post_json_retries_transient_transport_reset(self):
        verifier = load_script_module(
            "verify_live_bulk_diagnostics_script",
            "scripts/verify_live_bulk_diagnostics.py",
        )

        calls = {"count": 0}

        class FakeResponse:
            def __enter__(self):
                return self

            def __exit__(self, exc_type, exc, tb):
                return False

            def read(self):
                return b'{"ok": true}'

        def fake_urlopen(request, timeout=30):
            self.assertEqual(timeout, 30)
            calls["count"] += 1
            if calls["count"] == 1:
                raise verifier.urllib.error.URLError(
                    ConnectionResetError(
                        10054,
                        "An existing connection was forcibly closed by the remote host",
                    )
                )
            return FakeResponse()

        verifier.urllib.request.urlopen = fake_urlopen
        verifier.time.sleep = lambda seconds: None

        decoded = verifier.post_json("https://sync.velvet-leaf.com/call", {"name": "x"})

        self.assertEqual(decoded, {"ok": True})
        self.assertEqual(calls["count"], 2)

    def test_bulk_diagnostics_post_json_rejects_non_map_payloads(self):
        verifier = load_script_module(
            "verify_live_bulk_diagnostics_script",
            "scripts/verify_live_bulk_diagnostics.py",
        )

        class FakeResponse:
            def __enter__(self):
                return self

            def __exit__(self, exc_type, exc, tb):
                return False

            def read(self):
                return b'["not-a-map"]'

        verifier.urllib.request.urlopen = lambda request, timeout=30: FakeResponse()

        with self.assertRaises(verifier.ApiError):
            verifier.post_json("https://sync.velvet-leaf.com/call", {"name": "x"})

    def test_bulk_diagnostics_post_json_rejects_invalid_json_payloads(self):
        verifier = load_script_module(
            "verify_live_bulk_diagnostics_script",
            "scripts/verify_live_bulk_diagnostics.py",
        )

        class FakeResponse:
            def __enter__(self):
                return self

            def __exit__(self, exc_type, exc, tb):
                return False

            def read(self):
                return b"{not-json"

        verifier.urllib.request.urlopen = lambda request, timeout=30: FakeResponse()

        with self.assertRaises(verifier.ApiError):
            verifier.post_json("https://sync.velvet-leaf.com/call", {"name": "x"})

    def test_bulk_diagnostics_invoke_function_rejects_non_map_success_value(self):
        verifier = load_script_module(
            "verify_live_bulk_diagnostics_script",
            "scripts/verify_live_bulk_diagnostics.py",
        )

        verifier.post_json = lambda url, payload: {"status": "success", "value": ["not-a-map"]}

        with self.assertRaises(verifier.ApiError):
            verifier.invoke_function("https://sync.velvet-leaf.com", "live_state", {"token": "x"})

    def test_bulk_diagnostics_invoke_function_surfaces_failed_status_payload(self):
        verifier = load_script_module(
            "verify_live_bulk_diagnostics_script",
            "scripts/verify_live_bulk_diagnostics.py",
        )

        verifier.post_json = lambda url, payload: {"status": "failed", "error": "boom"}

        with self.assertRaises(verifier.ApiError):
            verifier.invoke_function("https://sync.velvet-leaf.com", "live_state", {"token": "x"})

    def test_bulk_diagnostics_fetch_health_retries_transient_transport_reset(self):
        verifier = load_script_module(
            "verify_live_bulk_diagnostics_script",
            "scripts/verify_live_bulk_diagnostics.py",
        )

        calls = {"count": 0}

        class FakeResponse:
            def __enter__(self):
                return self

            def __exit__(self, exc_type, exc, tb):
                return False

            def read(self):
                return b'{"ready": true, "compile_errors": 0, "build": {"git_commit": "commit-1"}}'

        def fake_urlopen(request, timeout=30):
            self.assertEqual(timeout, 30)
            calls["count"] += 1
            if calls["count"] == 1:
                raise verifier.urllib.error.URLError(ConnectionResetError(10054, "Connection reset by peer"))
            return FakeResponse()

        verifier.urllib.request.urlopen = fake_urlopen
        verifier.time.sleep = lambda seconds: None

        decoded = verifier.fetch_health("https://sync.velvet-leaf.com")

        self.assertEqual(decoded["ready"], True)
        self.assertEqual(decoded["build"]["git_commit"], "commit-1")
        self.assertEqual(calls["count"], 2)

    def test_bulk_diagnostics_fetch_health_rejects_non_map_payloads(self):
        verifier = load_script_module(
            "verify_live_bulk_diagnostics_script",
            "scripts/verify_live_bulk_diagnostics.py",
        )

        class FakeResponse:
            def __enter__(self):
                return self

            def __exit__(self, exc_type, exc, tb):
                return False

            def read(self):
                return b'["not-a-map"]'

        verifier.urllib.request.urlopen = lambda request, timeout=30: FakeResponse()

        with self.assertRaises(verifier.ApiError):
            verifier.fetch_health("https://sync.velvet-leaf.com")

    def test_bulk_diagnostics_main_returns_offline_stale_timeout_code(self):
        verifier = load_script_module(
            "verify_live_bulk_diagnostics_script",
            "scripts/verify_live_bulk_diagnostics.py",
        )
        stdout = io.StringIO()
        stderr = io.StringIO()

        verifier.fetch_health = lambda base_url: {
            "ready": True,
            "compile_errors": 0,
            "build": {"git_commit": "commit-1"},
        }
        verifier.login = lambda base_url, username, password: ("token-1", {"username": username, "role": "admin"})
        verifier.request_all_diagnostics = lambda base_url, token, batch_size: {
            "requestId": "req-1",
            "requestedClientCount": 1,
            "requestedClientNames": ["c1"],
        }
        verifier.live_state = lambda base_url, token: {
            "agents": [
                {
                    "clientName": "c1",
                    "isOnline": False,
                    "lastHeartbeat": "2026-07-09T00:00:00+00:00",
                    "diagnostics": {
                        "status": "requested",
                        "lastRequestId": "req-1",
                        "uploadedAt": "",
                    },
                }
            ]
        }
        verifier.time.sleep = lambda seconds: None
        ticks = iter([1000.0, 1000.5, 1002.0])
        verifier.time.time = lambda: next(ticks, 1002.0)

        argv = sys.argv
        sys.argv = [
            "verify_live_bulk_diagnostics.py",
            "--expect-commit",
            "commit-1",
            "--wait-seconds",
            "1",
            "--poll-seconds",
            "1",
            "--stale-heartbeat-minutes",
            "20",
        ]
        try:
            with redirect_stdout(stdout), redirect_stderr(stderr):
                exit_code = verifier.main()
        finally:
            sys.argv = argv

        self.assertEqual(exit_code, 3)
        self.assertIn("pending clients are offline/stale", stderr.getvalue())
        self.assertIn("uploaded=[] pending=['c1']", stdout.getvalue())

    def test_bulk_diagnostics_main_returns_pending_timeout_code_for_online_client(self):
        verifier = load_script_module(
            "verify_live_bulk_diagnostics_script",
            "scripts/verify_live_bulk_diagnostics.py",
        )
        stdout = io.StringIO()
        stderr = io.StringIO()

        verifier.fetch_health = lambda base_url: {
            "ready": True,
            "compile_errors": 0,
            "build": {"git_commit": "commit-1"},
        }
        verifier.login = lambda base_url, username, password: ("token-1", {"username": username, "role": "admin"})
        verifier.request_all_diagnostics = lambda base_url, token, batch_size: {
            "requestId": "req-1",
            "requestedClientCount": 1,
            "requestedClientNames": ["c1"],
        }
        verifier.live_state = lambda base_url, token: {
            "agents": [
                {
                    "clientName": "c1",
                    "isOnline": True,
                    "lastHeartbeat": "2026-07-10T04:00:00+00:00",
                    "diagnostics": {
                        "status": "requested",
                        "lastRequestId": "req-1",
                        "uploadedAt": "",
                    },
                }
            ]
        }
        verifier.time.sleep = lambda seconds: None
        ticks = iter([1000.0, 1000.5, 1002.0])
        verifier.time.time = lambda: next(ticks, 1002.0)

        argv = sys.argv
        sys.argv = [
            "verify_live_bulk_diagnostics.py",
            "--expect-commit",
            "commit-1",
            "--wait-seconds",
            "1",
            "--poll-seconds",
            "1",
            "--stale-heartbeat-minutes",
            "20",
        ]
        try:
            with redirect_stdout(stdout), redirect_stderr(stderr):
                exit_code = verifier.main()
        finally:
            sys.argv = argv

        self.assertEqual(exit_code, 1)
        self.assertIn("timed out waiting for diagnostics uploads; still pending: ['c1']", stderr.getvalue())
        self.assertIn("uploaded=[] pending=['c1']", stdout.getvalue())

    def test_bulk_diagnostics_main_returns_success_when_no_visible_clients_are_targeted(self):
        verifier = load_script_module(
            "verify_live_bulk_diagnostics_script",
            "scripts/verify_live_bulk_diagnostics.py",
        )
        stdout = io.StringIO()
        stderr = io.StringIO()

        verifier.fetch_health = lambda base_url: {
            "ready": True,
            "compile_errors": 0,
            "build": {"git_commit": "commit-1"},
        }
        verifier.login = lambda base_url, username, password: (
            "token-1",
            {"username": username, "role": "admin"},
        )
        verifier.request_all_diagnostics = lambda base_url, token, batch_size: {
            "requestId": "req-1",
            "requestedClientCount": 0,
            "requestedClientNames": [],
        }

        argv = sys.argv
        sys.argv = [
            "verify_live_bulk_diagnostics.py",
            "--expect-commit",
            "commit-1",
        ]
        try:
            with redirect_stdout(stdout), redirect_stderr(stderr):
                exit_code = verifier.main()
        finally:
            sys.argv = argv

        self.assertEqual(exit_code, 0)
        self.assertEqual(stderr.getvalue(), "")
        self.assertIn("no visible clients were returned by the live control plane", stdout.getvalue())

    def test_bulk_diagnostics_main_returns_commit_mismatch_code(self):
        verifier = load_script_module(
            "verify_live_bulk_diagnostics_script",
            "scripts/verify_live_bulk_diagnostics.py",
        )
        stdout = io.StringIO()
        stderr = io.StringIO()

        verifier.fetch_health = lambda base_url: {
            "ready": True,
            "compile_errors": 0,
            "build": {"git_commit": "commit-live"},
        }

        argv = sys.argv
        sys.argv = [
            "verify_live_bulk_diagnostics.py",
            "--expect-commit",
            "commit-expected",
        ]
        try:
            with redirect_stdout(stdout), redirect_stderr(stderr):
                exit_code = verifier.main()
        finally:
            sys.argv = argv

        self.assertEqual(exit_code, 2)
        self.assertIn("build.git_commit=commit-live", stdout.getvalue())
        self.assertIn("expected live commit commit-expected but found commit-live", stderr.getvalue())

    def test_bulk_diagnostics_run_cli_converts_api_error_to_clean_exit(self):
        verifier = load_script_module(
            "verify_live_bulk_diagnostics_script",
            "scripts/verify_live_bulk_diagnostics.py",
        )
        stderr = io.StringIO()

        verifier.main = lambda: (_ for _ in ()).throw(verifier.ApiError("bulk diagnostics boom"))

        with redirect_stderr(stderr):
            exit_code = verifier.run_cli()

        self.assertEqual(exit_code, 1)
        self.assertEqual(stderr.getvalue().strip(), "bulk diagnostics boom")

    def test_scheduler_stress_extract_perf_row_returns_named_row(self):
        verifier = load_script_module(
            "verify_live_scheduler_stress_script",
            "scripts/verify_live_scheduler_stress.py",
        )

        row = verifier.extract_perf_row(
            [
                {"name": "auth_login", "calls": 1},
                {"name": "auto_sync_tick", "calls": 3, "avg_ms": 2500},
            ],
            "auto_sync_tick",
        )

        self.assertEqual(row["calls"], 3)
        self.assertEqual(row["avg_ms"], 2500)

    def test_scheduler_stress_transport_error_detection_matches_winerror_reset(self):
        verifier = load_script_module(
            "verify_live_scheduler_stress_script",
            "scripts/verify_live_scheduler_stress.py",
        )

        self.assertTrue(verifier.scheduler_transport_error(verifier.ApiError("request failed: <urlopen error [WinError 10054] An existing connection was forcibly closed by the remote host>")))
        self.assertTrue(verifier.scheduler_transport_error(verifier.ApiError("request failed: <urlopen error [Errno 10054] Connection reset by peer>")))
        self.assertFalse(verifier.scheduler_transport_error(verifier.ApiError("HTTP 408: timeout")))

    def test_scheduler_stress_post_json_retries_transient_transport_reset(self):
        verifier = load_script_module(
            "verify_live_scheduler_stress_script",
            "scripts/verify_live_scheduler_stress.py",
        )

        calls = {"count": 0}

        class FakeResponse:
            def __enter__(self):
                return self

            def __exit__(self, exc_type, exc, tb):
                return False

            def read(self):
                return b'{"ok": true}'

        def fake_urlopen(request, timeout=30):
            self.assertEqual(timeout, 30)
            calls["count"] += 1
            if calls["count"] == 1:
                raise verifier.urllib.error.URLError(
                    ConnectionResetError(
                        10054,
                        "An existing connection was forcibly closed by the remote host",
                    )
                )
            return FakeResponse()

        verifier.urllib.request.urlopen = fake_urlopen
        verifier.time.sleep = lambda seconds: None

        decoded = verifier.post_json("https://sync.velvet-leaf.com/call", {"name": "x"})

        self.assertEqual(decoded, {"ok": True})
        self.assertEqual(calls["count"], 2)

    def test_scheduler_stress_post_json_rejects_non_map_payloads(self):
        verifier = load_script_module(
            "verify_live_scheduler_stress_script",
            "scripts/verify_live_scheduler_stress.py",
        )

        class FakeResponse:
            def __enter__(self):
                return self

            def __exit__(self, exc_type, exc, tb):
                return False

            def read(self):
                return b'["not-a-map"]'

        verifier.urllib.request.urlopen = lambda request, timeout=30: FakeResponse()

        with self.assertRaises(verifier.ApiError):
            verifier.post_json("https://sync.velvet-leaf.com/call", {"name": "x"})

    def test_scheduler_stress_post_json_rejects_invalid_json_payloads(self):
        verifier = load_script_module(
            "verify_live_scheduler_stress_script",
            "scripts/verify_live_scheduler_stress.py",
        )

        class FakeResponse:
            def __enter__(self):
                return self

            def __exit__(self, exc_type, exc, tb):
                return False

            def read(self):
                return b"{not-json"

        verifier.urllib.request.urlopen = lambda request, timeout=30: FakeResponse()

        with self.assertRaises(verifier.ApiError):
            verifier.post_json("https://sync.velvet-leaf.com/call", {"name": "x"})

    def test_scheduler_stress_invoke_function_rejects_non_map_success_value(self):
        verifier = load_script_module(
            "verify_live_scheduler_stress_script",
            "scripts/verify_live_scheduler_stress.py",
        )

        verifier.post_json = lambda url, payload: {"status": "success", "value": ["not-a-map"]}

        with self.assertRaises(verifier.ApiError):
            verifier.invoke_function("https://sync.velvet-leaf.com", "auto_sync_tick", {"token": "x"})

    def test_scheduler_stress_invoke_function_surfaces_failed_status_payload(self):
        verifier = load_script_module(
            "verify_live_scheduler_stress_script",
            "scripts/verify_live_scheduler_stress.py",
        )

        verifier.post_json = lambda url, payload: {"status": "failed", "error": "boom"}

        with self.assertRaises(verifier.ApiError):
            verifier.invoke_function("https://sync.velvet-leaf.com", "auto_sync_tick", {"token": "x"})

    def test_scheduler_stress_fetch_health_retries_transient_transport_reset(self):
        verifier = load_script_module(
            "verify_live_scheduler_stress_script",
            "scripts/verify_live_scheduler_stress.py",
        )

        calls = {"count": 0}

        class FakeResponse:
            def __enter__(self):
                return self

            def __exit__(self, exc_type, exc, tb):
                return False

            def read(self):
                return b'{"ready": true, "compile_errors": 0, "build": {"git_commit": "commit-1"}}'

        def fake_urlopen(request, timeout=30):
            self.assertEqual(timeout, 30)
            calls["count"] += 1
            if calls["count"] == 1:
                raise verifier.urllib.error.URLError(
                    ConnectionResetError(10054, "Connection reset by peer")
                )
            return FakeResponse()

        verifier.urllib.request.urlopen = fake_urlopen
        verifier.time.sleep = lambda seconds: None

        decoded = verifier.fetch_health("https://sync.velvet-leaf.com")

        self.assertEqual(decoded["ready"], True)
        self.assertEqual(decoded["build"]["git_commit"], "commit-1")
        self.assertEqual(calls["count"], 2)

    def test_scheduler_stress_fetch_health_rejects_non_map_payloads(self):
        verifier = load_script_module(
            "verify_live_scheduler_stress_script",
            "scripts/verify_live_scheduler_stress.py",
        )

        class FakeResponse:
            def __enter__(self):
                return self

            def __exit__(self, exc_type, exc, tb):
                return False

            def read(self):
                return b'["not-a-map"]'

        verifier.urllib.request.urlopen = lambda request, timeout=30: FakeResponse()

        with self.assertRaises(verifier.ApiError):
            verifier.fetch_health("https://sync.velvet-leaf.com")

    def test_scheduler_stress_fetch_perf_rejects_non_list_payloads(self):
        verifier = load_script_module(
            "verify_live_scheduler_stress_script",
            "scripts/verify_live_scheduler_stress.py",
        )

        class FakeResponse:
            def __enter__(self):
                return self

            def __exit__(self, exc_type, exc, tb):
                return False

            def read(self):
                return b'{"not": "a-list"}'

        verifier.urllib.request.urlopen = lambda request, timeout=30: FakeResponse()

        with self.assertRaises(verifier.ApiError):
            verifier.fetch_perf("https://sync.velvet-leaf.com")

    def test_scheduler_stress_reset_stats_rejects_non_map_payloads(self):
        verifier = load_script_module(
            "verify_live_scheduler_stress_script",
            "scripts/verify_live_scheduler_stress.py",
        )

        class FakeResponse:
            def __enter__(self):
                return self

            def __exit__(self, exc_type, exc, tb):
                return False

            def read(self):
                return b'["not-a-map"]'

        verifier.urllib.request.urlopen = lambda request, timeout=30: FakeResponse()

        with self.assertRaises(verifier.ApiError):
            verifier.reset_stats("https://sync.velvet-leaf.com")

    def test_scheduler_stress_collects_successes_transport_and_fatal_errors(self):
        verifier = load_script_module(
            "verify_live_scheduler_stress_script",
            "scripts/verify_live_scheduler_stress.py",
        )

        calls = {"count": 0}

        def fake_invoke(base_url: str, name: str, args: dict) -> dict:
            self.assertEqual(base_url, "https://sync.velvet-leaf.com")
            self.assertEqual(name, "auto_sync_tick")
            self.assertEqual(args["token"], "token-1")
            calls["count"] += 1
            if calls["count"] == 1:
                return {"ok": True, "createdJobCount": 0}
            if calls["count"] == 2:
                raise verifier.ApiError(
                    "request failed: <urlopen error [WinError 10054] An existing connection was forcibly closed by the remote host>"
                )
            raise verifier.ApiError("HTTP 408: timeout")

        verifier.invoke_function = fake_invoke

        result = verifier.run_scheduler_stress("https://sync.velvet-leaf.com", "token-1", 3, 0)

        self.assertEqual(len(result["successes"]), 1)
        self.assertEqual(result["successes"][0]["run"], 1)
        self.assertEqual(result["successes"][0]["response"]["createdJobCount"], 0)
        self.assertEqual(
            result["transportErrors"],
            [
                {
                    "run": 2,
                    "error": "request failed: <urlopen error [WinError 10054] An existing connection was forcibly closed by the remote host>",
                }
            ],
        )

    def test_scheduler_stress_main_returns_success_for_healthy_run(self):
        verifier = load_script_module(
            "verify_live_scheduler_stress_script",
            "scripts/verify_live_scheduler_stress.py",
        )
        stdout = io.StringIO()
        stderr = io.StringIO()

        health_payload = {
            "ready": True,
            "compile_errors": 0,
            "timeout": 0,
            "fail": 0,
            "build": {"git_commit": "commit-1"},
        }
        verifier.fetch_health = lambda base_url: health_payload
        verifier.reset_stats = lambda base_url: {"ok": True}
        verifier.login = lambda base_url, username, password: (
            "token-1",
            {"username": username, "role": "admin"},
        )
        verifier.run_scheduler_stress = lambda base_url, token, runs, poll_seconds: {
            "successes": [{"run": 1, "elapsedMs": 10.0, "response": {"createdJobCount": 0}}],
            "transportErrors": [],
            "fatalErrors": [],
        }
        verifier.fetch_perf = lambda base_url: [
            {"name": "auto_sync_tick", "calls": 1, "error_count": 0, "avg_ms": 25.0},
            {"name": "agents_heartbeat", "calls": 1, "error_count": 0, "avg_ms": 30.0},
        ]

        argv = sys.argv
        sys.argv = [
            "verify_live_scheduler_stress.py",
            "--expect-commit",
            "commit-1",
            "--runs",
            "1",
        ]
        try:
            with redirect_stdout(stdout), redirect_stderr(stderr):
                exit_code = verifier.main()
        finally:
            sys.argv = argv

        self.assertEqual(exit_code, 0)
        self.assertEqual(stderr.getvalue(), "")
        self.assertIn("stats_reset=", stdout.getvalue())
        self.assertIn("scheduler_runs=", stdout.getvalue())
        self.assertIn("auto_sync_tick_perf=", stdout.getvalue())
        self.assertIn("post_health.ready=True post_health.timeout=0 post_health.fail=0", stdout.getvalue())

    def test_scheduler_stress_main_returns_commit_mismatch_code(self):
        verifier = load_script_module(
            "verify_live_scheduler_stress_script",
            "scripts/verify_live_scheduler_stress.py",
        )
        stdout = io.StringIO()
        stderr = io.StringIO()

        verifier.fetch_health = lambda base_url: {
            "ready": True,
            "compile_errors": 0,
            "build": {"git_commit": "commit-live"},
        }

        argv = sys.argv
        sys.argv = [
            "verify_live_scheduler_stress.py",
            "--expect-commit",
            "commit-expected",
        ]
        try:
            with redirect_stdout(stdout), redirect_stderr(stderr):
                exit_code = verifier.main()
        finally:
            sys.argv = argv

        self.assertEqual(exit_code, 2)
        self.assertIn("build.git_commit=commit-live", stdout.getvalue())
        self.assertIn("expected live commit commit-expected but found commit-live", stderr.getvalue())

    def test_scheduler_stress_main_returns_transport_error_limit_code(self):
        verifier = load_script_module(
            "verify_live_scheduler_stress_script",
            "scripts/verify_live_scheduler_stress.py",
        )
        stdout = io.StringIO()
        stderr = io.StringIO()

        health_payload = {
            "ready": True,
            "compile_errors": 0,
            "timeout": 0,
            "fail": 0,
            "build": {"git_commit": "commit-1"},
        }
        verifier.fetch_health = lambda base_url: health_payload
        verifier.reset_stats = lambda base_url: {"ok": True}
        verifier.login = lambda base_url, username, password: (
            "token-1",
            {"username": username, "role": "admin"},
        )
        verifier.run_scheduler_stress = lambda base_url, token, runs, poll_seconds: {
            "successes": [{"run": 1, "elapsedMs": 10.0, "response": {"createdJobCount": 0}}],
            "transportErrors": [{"run": 2, "error": "request failed: reset"}],
            "fatalErrors": [],
        }
        verifier.fetch_perf = lambda base_url: [
            {"name": "auto_sync_tick", "calls": 1, "error_count": 0, "avg_ms": 25.0},
            {"name": "agents_heartbeat", "calls": 1, "error_count": 0, "avg_ms": 30.0},
        ]

        argv = sys.argv
        sys.argv = [
            "verify_live_scheduler_stress.py",
            "--expect-commit",
            "commit-1",
            "--max-transport-errors",
            "0",
        ]
        try:
            with redirect_stdout(stdout), redirect_stderr(stderr):
                exit_code = verifier.main()
        finally:
            sys.argv = argv

        self.assertEqual(exit_code, 3)
        self.assertIn("transport errors exceeded limit: observed=1 allowed=0", stderr.getvalue())
        self.assertIn("scheduler_runs=", stdout.getvalue())

    def test_scheduler_stress_main_returns_missing_perf_row_code(self):
        verifier = load_script_module(
            "verify_live_scheduler_stress_script",
            "scripts/verify_live_scheduler_stress.py",
        )
        stdout = io.StringIO()
        stderr = io.StringIO()

        health_payload = {
            "ready": True,
            "compile_errors": 0,
            "timeout": 0,
            "fail": 0,
            "build": {"git_commit": "commit-1"},
        }
        verifier.fetch_health = lambda base_url: health_payload
        verifier.reset_stats = lambda base_url: {"ok": True}
        verifier.login = lambda base_url, username, password: (
            "token-1",
            {"username": username, "role": "admin"},
        )
        verifier.run_scheduler_stress = lambda base_url, token, runs, poll_seconds: {
            "successes": [{"run": 1, "elapsedMs": 10.0, "response": {"createdJobCount": 0}}],
            "transportErrors": [],
            "fatalErrors": [],
        }
        verifier.fetch_perf = lambda base_url: [
            {"name": "agents_heartbeat", "calls": 1, "error_count": 0, "avg_ms": 30.0},
        ]

        argv = sys.argv
        sys.argv = ["verify_live_scheduler_stress.py", "--expect-commit", "commit-1"]
        try:
            with redirect_stdout(stdout), redirect_stderr(stderr):
                exit_code = verifier.main()
        finally:
            sys.argv = argv

        self.assertEqual(exit_code, 4)
        self.assertIn("auto_sync_tick perf row missing after stress run", stderr.getvalue())

    def test_scheduler_stress_main_returns_perf_call_count_code(self):
        verifier = load_script_module(
            "verify_live_scheduler_stress_script",
            "scripts/verify_live_scheduler_stress.py",
        )
        stdout = io.StringIO()
        stderr = io.StringIO()

        health_payload = {
            "ready": True,
            "compile_errors": 0,
            "timeout": 0,
            "fail": 0,
            "build": {"git_commit": "commit-1"},
        }
        verifier.fetch_health = lambda base_url: health_payload
        verifier.reset_stats = lambda base_url: {"ok": True}
        verifier.login = lambda base_url, username, password: (
            "token-1",
            {"username": username, "role": "admin"},
        )
        verifier.run_scheduler_stress = lambda base_url, token, runs, poll_seconds: {
            "successes": [
                {"run": 1, "elapsedMs": 10.0, "response": {"createdJobCount": 0}},
                {"run": 2, "elapsedMs": 12.0, "response": {"createdJobCount": 0}},
            ],
            "transportErrors": [],
            "fatalErrors": [],
        }
        verifier.fetch_perf = lambda base_url: [
            {"name": "auto_sync_tick", "calls": 1, "error_count": 0, "avg_ms": 25.0},
            {"name": "agents_heartbeat", "calls": 1, "error_count": 0, "avg_ms": 30.0},
        ]

        argv = sys.argv
        sys.argv = ["verify_live_scheduler_stress.py", "--expect-commit", "commit-1"]
        try:
            with redirect_stdout(stdout), redirect_stderr(stderr):
                exit_code = verifier.main()
        finally:
            sys.argv = argv

        self.assertEqual(exit_code, 5)
        self.assertIn("auto_sync_tick perf calls 1 is lower than successful runs 2", stderr.getvalue())

    def test_scheduler_stress_main_returns_application_error_code(self):
        verifier = load_script_module(
            "verify_live_scheduler_stress_script",
            "scripts/verify_live_scheduler_stress.py",
        )
        stdout = io.StringIO()
        stderr = io.StringIO()

        health_payload = {
            "ready": True,
            "compile_errors": 0,
            "timeout": 0,
            "fail": 0,
            "build": {"git_commit": "commit-1"},
        }
        verifier.fetch_health = lambda base_url: health_payload
        verifier.reset_stats = lambda base_url: {"ok": True}
        verifier.login = lambda base_url, username, password: (
            "token-1",
            {"username": username, "role": "admin"},
        )
        verifier.run_scheduler_stress = lambda base_url, token, runs, poll_seconds: {
            "successes": [{"run": 1, "elapsedMs": 10.0, "response": {"createdJobCount": 0}}],
            "transportErrors": [],
            "fatalErrors": [],
        }
        verifier.fetch_perf = lambda base_url: [
            {"name": "auto_sync_tick", "calls": 1, "error_count": 2, "avg_ms": 25.0},
            {"name": "agents_heartbeat", "calls": 1, "error_count": 0, "avg_ms": 30.0},
        ]

        argv = sys.argv
        sys.argv = ["verify_live_scheduler_stress.py", "--expect-commit", "commit-1"]
        try:
            with redirect_stdout(stdout), redirect_stderr(stderr):
                exit_code = verifier.main()
        finally:
            sys.argv = argv

        self.assertEqual(exit_code, 6)
        self.assertIn("auto_sync_tick reported 2 application errors", stderr.getvalue())

    def test_scheduler_stress_main_returns_avg_latency_limit_code(self):
        verifier = load_script_module(
            "verify_live_scheduler_stress_script",
            "scripts/verify_live_scheduler_stress.py",
        )
        stdout = io.StringIO()
        stderr = io.StringIO()

        health_payload = {
            "ready": True,
            "compile_errors": 0,
            "timeout": 0,
            "fail": 0,
            "build": {"git_commit": "commit-1"},
        }
        verifier.fetch_health = lambda base_url: health_payload
        verifier.reset_stats = lambda base_url: {"ok": True}
        verifier.login = lambda base_url, username, password: (
            "token-1",
            {"username": username, "role": "admin"},
        )
        verifier.run_scheduler_stress = lambda base_url, token, runs, poll_seconds: {
            "successes": [{"run": 1, "elapsedMs": 10.0, "response": {"createdJobCount": 0}}],
            "transportErrors": [],
            "fatalErrors": [],
        }
        verifier.fetch_perf = lambda base_url: [
            {"name": "auto_sync_tick", "calls": 1, "error_count": 0, "avg_ms": 9500.0},
            {"name": "agents_heartbeat", "calls": 1, "error_count": 0, "avg_ms": 30.0},
        ]

        argv = sys.argv
        sys.argv = [
            "verify_live_scheduler_stress.py",
            "--expect-commit",
            "commit-1",
            "--max-avg-ms",
            "9000",
        ]
        try:
            with redirect_stdout(stdout), redirect_stderr(stderr):
                exit_code = verifier.main()
        finally:
            sys.argv = argv

        self.assertEqual(exit_code, 7)
        self.assertIn("auto_sync_tick avg_ms 9500.0 exceeded limit 9000", stderr.getvalue())

    def test_scheduler_stress_main_returns_post_health_not_ready_code(self):
        verifier = load_script_module(
            "verify_live_scheduler_stress_script",
            "scripts/verify_live_scheduler_stress.py",
        )
        stdout = io.StringIO()
        stderr = io.StringIO()

        health_calls = {"count": 0}

        def fake_fetch_health(base_url):
            health_calls["count"] += 1
            if health_calls["count"] == 1:
                return {"ready": True, "compile_errors": 0, "build": {"git_commit": "commit-1"}}
            return {"ready": False, "compile_errors": 0, "timeout": 1, "fail": 0, "build": {"git_commit": "commit-1"}}

        verifier.fetch_health = fake_fetch_health
        verifier.reset_stats = lambda base_url: {"ok": True}
        verifier.login = lambda base_url, username, password: (
            "token-1",
            {"username": username, "role": "admin"},
        )
        verifier.run_scheduler_stress = lambda base_url, token, runs, poll_seconds: {
            "successes": [{"run": 1, "elapsedMs": 10.0, "response": {"createdJobCount": 0}}],
            "transportErrors": [],
            "fatalErrors": [],
        }
        verifier.fetch_perf = lambda base_url: [
            {"name": "auto_sync_tick", "calls": 1, "error_count": 0, "avg_ms": 25.0},
            {"name": "agents_heartbeat", "calls": 1, "error_count": 0, "avg_ms": 30.0},
        ]

        argv = sys.argv
        sys.argv = ["verify_live_scheduler_stress.py", "--expect-commit", "commit-1"]
        try:
            with redirect_stdout(stdout), redirect_stderr(stderr):
                exit_code = verifier.main()
        finally:
            sys.argv = argv

        self.assertEqual(exit_code, 8)
        self.assertIn("post-run health is not ready", stderr.getvalue())

    def test_scheduler_stress_main_returns_post_compile_errors_code(self):
        verifier = load_script_module(
            "verify_live_scheduler_stress_script",
            "scripts/verify_live_scheduler_stress.py",
        )
        stdout = io.StringIO()
        stderr = io.StringIO()

        health_calls = {"count": 0}

        def fake_fetch_health(base_url):
            health_calls["count"] += 1
            if health_calls["count"] == 1:
                return {"ready": True, "compile_errors": 0, "build": {"git_commit": "commit-1"}}
            return {"ready": True, "compile_errors": 1, "timeout": 0, "fail": 0, "build": {"git_commit": "commit-1"}}

        verifier.fetch_health = fake_fetch_health
        verifier.reset_stats = lambda base_url: {"ok": True}
        verifier.login = lambda base_url, username, password: (
            "token-1",
            {"username": username, "role": "admin"},
        )
        verifier.run_scheduler_stress = lambda base_url, token, runs, poll_seconds: {
            "successes": [{"run": 1, "elapsedMs": 10.0, "response": {"createdJobCount": 0}}],
            "transportErrors": [],
            "fatalErrors": [],
        }
        verifier.fetch_perf = lambda base_url: [
            {"name": "auto_sync_tick", "calls": 1, "error_count": 0, "avg_ms": 25.0},
            {"name": "agents_heartbeat", "calls": 1, "error_count": 0, "avg_ms": 30.0},
        ]

        argv = sys.argv
        sys.argv = ["verify_live_scheduler_stress.py", "--expect-commit", "commit-1"]
        try:
            with redirect_stdout(stdout), redirect_stderr(stderr):
                exit_code = verifier.main()
        finally:
            sys.argv = argv

        self.assertEqual(exit_code, 9)
        self.assertIn("post-run compile errors detected", stderr.getvalue())

    def test_scheduler_stress_main_returns_fatal_error_code(self):
        verifier = load_script_module(
            "verify_live_scheduler_stress_script",
            "scripts/verify_live_scheduler_stress.py",
        )
        stdout = io.StringIO()
        stderr = io.StringIO()

        health_payload = {
            "ready": True,
            "compile_errors": 0,
            "timeout": 0,
            "fail": 0,
            "build": {"git_commit": "commit-1"},
        }
        verifier.fetch_health = lambda base_url: health_payload
        verifier.reset_stats = lambda base_url: {"ok": True}
        verifier.login = lambda base_url, username, password: (
            "token-1",
            {"username": username, "role": "admin"},
        )
        verifier.run_scheduler_stress = lambda base_url, token, runs, poll_seconds: {
            "successes": [],
            "transportErrors": [],
            "fatalErrors": [{"run": 1, "error": "HTTP 500: boom"}],
        }
        verifier.fetch_perf = lambda base_url: [
            {"name": "auto_sync_tick", "calls": 0, "error_count": 0, "avg_ms": 0.0},
            {"name": "agents_heartbeat", "calls": 1, "error_count": 0, "avg_ms": 30.0},
        ]

        argv = sys.argv
        sys.argv = ["verify_live_scheduler_stress.py", "--expect-commit", "commit-1"]
        try:
            with redirect_stdout(stdout), redirect_stderr(stderr):
                exit_code = verifier.main()
        finally:
            sys.argv = argv

        self.assertEqual(exit_code, 1)
        self.assertIn("fatal scheduler errors observed:", stderr.getvalue())

    def test_scheduler_stress_run_cli_converts_api_error_to_clean_exit(self):
        verifier = load_script_module(
            "verify_live_scheduler_stress_script",
            "scripts/verify_live_scheduler_stress.py",
        )
        stderr = io.StringIO()

        verifier.main = lambda: (_ for _ in ()).throw(verifier.ApiError("scheduler boom"))

        with redirect_stderr(stderr):
            exit_code = verifier.run_cli()

        self.assertEqual(exit_code, 1)
        self.assertEqual(stderr.getvalue().strip(), "scheduler boom")

    def test_clients_state_summarize_agent_captures_diagnostics_update_and_window_action(self):
        verifier = load_script_module(
            "verify_live_clients_state_script",
            "scripts/verify_live_clients_state.py",
        )
        agent = {
            "clientName": "c1",
            "machineName": "DESKTOP-1",
            "clientVersion": "1.0.105+109",
            "isOnline": True,
            "serverConnected": True,
            "sqlConnected": True,
            "lastHeartbeat": "2026-07-10T02:31:31+00:00",
            "diagnostics": {
                "status": "uploaded",
                "uploadedAt": "2026-07-10T02:30:00+00:00",
            },
            "clientUpdate": {
                "status": "current",
                "pending": False,
                "targetVersion": "1.0.105+109",
            },
            "windowAction": {
                "status": "completed",
                "pending": False,
                "action": "minimize",
            },
        }

        summary = verifier.summarize_agent(agent)

        self.assertEqual(summary["clientName"], "c1")
        self.assertEqual(summary["version"], "1.0.105+109")
        self.assertTrue(summary["online"])
        self.assertEqual(summary["diagnosticsStatus"], "uploaded")
        self.assertEqual(summary["clientUpdateStatus"], "current")
        self.assertFalse(summary["clientUpdatePending"])
        self.assertEqual(summary["windowActionName"], "minimize")
        self.assertEqual(summary["windowActionStatus"], "completed")
        self.assertIsInstance(summary["heartbeatAgeMinutes"], float)

    def test_clients_state_heartbeat_age_minutes_clamps_future_skew_to_zero(self):
        verifier = load_script_module(
            "verify_live_clients_state_script",
            "scripts/verify_live_clients_state.py",
        )
        now = datetime(2026, 7, 10, 2, 31, tzinfo=timezone.utc)
        observed = (now + timedelta(seconds=2)).isoformat()

        age = verifier.heartbeat_age_minutes(observed, now=now)

        self.assertEqual(age, 0.0)

    def test_clients_state_find_agent_summary_rejects_missing_client(self):
        verifier = load_script_module(
            "verify_live_clients_state_script",
            "scripts/verify_live_clients_state.py",
        )

        with self.assertRaises(verifier.ApiError):
            verifier.find_agent_summary({"agents": [{"clientName": "c2"}]}, "c1")

    def test_clients_state_validate_summary_reports_mismatches(self):
        verifier = load_script_module(
            "verify_live_clients_state_script",
            "scripts/verify_live_clients_state.py",
        )
        summary = {
            "clientName": "c1",
            "version": "1.0.104+108",
            "online": False,
            "serverConnected": False,
            "sqlConnected": False,
            "heartbeatAgeMinutes": 25.0,
            "diagnosticsStatus": "requested",
            "diagnosticsUploadedAt": "",
            "clientUpdatePending": True,
            "clientUpdateStatus": "requested",
            "windowActionPending": True,
            "windowActionName": "restore",
            "windowActionStatus": "requested",
        }

        failures = verifier.validate_summary(summary, "1.0.105+109", 5.0, True)

        self.assertIn("client offline", failures)
        self.assertIn("server not connected", failures)
        self.assertIn("sql not connected", failures)
        self.assertIn("version mismatch: observed=1.0.104+108 expected=1.0.105+109", failures)
        self.assertIn("heartbeat stale: observed=25.00 minutes limit=5.0", failures)
        self.assertIn("diagnostics status is requested", failures)
        self.assertIn("diagnostics uploadedAt missing", failures)
        self.assertIn("client update still pending", failures)
        self.assertIn("client update status is requested", failures)
        self.assertIn("window action still pending", failures)
        self.assertIn("window action is restore", failures)
        self.assertIn("window action status is requested", failures)

    def test_clients_state_retryable_transport_error_matches_connection_reset(self):
        verifier = load_script_module(
            "verify_live_clients_state_script",
            "scripts/verify_live_clients_state.py",
        )

        self.assertTrue(
            verifier.retryable_transport_error(
                verifier.ApiError(
                    "request failed: <urlopen error [WinError 10054] An existing connection was forcibly closed by the remote host>"
                )
            )
        )
        self.assertFalse(verifier.retryable_transport_error(verifier.ApiError("HTTP 408: timeout")))

    def test_clients_state_post_json_retries_transient_transport_reset(self):
        verifier = load_script_module(
            "verify_live_clients_state_script",
            "scripts/verify_live_clients_state.py",
        )

        calls = {"count": 0}

        class FakeResponse:
            def __enter__(self):
                return self

            def __exit__(self, exc_type, exc, tb):
                return False

            def read(self):
                return b'{"ok": true}'

        def fake_urlopen(request, timeout=30):
            self.assertEqual(timeout, 30)
            calls["count"] += 1
            if calls["count"] == 1:
                raise verifier.urllib.error.URLError(
                    ConnectionResetError(
                        10054,
                        "An existing connection was forcibly closed by the remote host",
                    )
                )
            return FakeResponse()

        verifier.urllib.request.urlopen = fake_urlopen
        verifier.time.sleep = lambda seconds: None

        decoded = verifier.post_json("https://sync.velvet-leaf.com/call", {"name": "x"})

        self.assertEqual(decoded, {"ok": True})
        self.assertEqual(calls["count"], 2)

    def test_clients_state_post_json_rejects_non_map_payloads(self):
        verifier = load_script_module(
            "verify_live_clients_state_script",
            "scripts/verify_live_clients_state.py",
        )

        class FakeResponse:
            def __enter__(self):
                return self

            def __exit__(self, exc_type, exc, tb):
                return False

            def read(self):
                return b'["not-a-map"]'

        verifier.urllib.request.urlopen = lambda request, timeout=30: FakeResponse()

        with self.assertRaises(verifier.ApiError):
            verifier.post_json("https://sync.velvet-leaf.com/call", {"name": "x"})

    def test_clients_state_post_json_rejects_invalid_json_payloads(self):
        verifier = load_script_module(
            "verify_live_clients_state_script",
            "scripts/verify_live_clients_state.py",
        )

        class FakeResponse:
            def __enter__(self):
                return self

            def __exit__(self, exc_type, exc, tb):
                return False

            def read(self):
                return b"{not-json"

        verifier.urllib.request.urlopen = lambda request, timeout=30: FakeResponse()

        with self.assertRaises(verifier.ApiError):
            verifier.post_json("https://sync.velvet-leaf.com/call", {"name": "x"})

    def test_clients_state_invoke_function_rejects_non_map_success_value(self):
        verifier = load_script_module(
            "verify_live_clients_state_script",
            "scripts/verify_live_clients_state.py",
        )

        verifier.post_json = lambda url, payload: {"status": "success", "value": ["not-a-map"]}

        with self.assertRaises(verifier.ApiError):
            verifier.invoke_function("https://sync.velvet-leaf.com", "live_state", {"token": "x"})

    def test_clients_state_invoke_function_surfaces_failed_status_payload(self):
        verifier = load_script_module(
            "verify_live_clients_state_script",
            "scripts/verify_live_clients_state.py",
        )

        verifier.post_json = lambda url, payload: {"status": "failed", "error": "boom"}

        with self.assertRaises(verifier.ApiError):
            verifier.invoke_function("https://sync.velvet-leaf.com", "live_state", {"token": "x"})

    def test_clients_state_fetch_health_retries_transient_transport_reset(self):
        verifier = load_script_module(
            "verify_live_clients_state_script",
            "scripts/verify_live_clients_state.py",
        )

        calls = {"count": 0}

        class FakeResponse:
            def __enter__(self):
                return self

            def __exit__(self, exc_type, exc, tb):
                return False

            def read(self):
                return b'{"ready": true, "compile_errors": 0, "build": {"git_commit": "commit-1"}}'

        def fake_urlopen(request, timeout=30):
            self.assertEqual(timeout, 30)
            calls["count"] += 1
            if calls["count"] == 1:
                raise verifier.urllib.error.URLError(ConnectionResetError(10054, "Connection reset by peer"))
            return FakeResponse()

        verifier.urllib.request.urlopen = fake_urlopen
        verifier.time.sleep = lambda seconds: None

        decoded = verifier.fetch_health("https://sync.velvet-leaf.com")

        self.assertEqual(decoded["ready"], True)
        self.assertEqual(decoded["build"]["git_commit"], "commit-1")
        self.assertEqual(calls["count"], 2)

    def test_clients_state_fetch_health_rejects_non_map_payloads(self):
        verifier = load_script_module(
            "verify_live_clients_state_script",
            "scripts/verify_live_clients_state.py",
        )

        class FakeResponse:
            def __enter__(self):
                return self

            def __exit__(self, exc_type, exc, tb):
                return False

            def read(self):
                return b'["not-a-map"]'

        verifier.urllib.request.urlopen = lambda request, timeout=30: FakeResponse()

        with self.assertRaises(verifier.ApiError):
            verifier.fetch_health("https://sync.velvet-leaf.com")

    def test_clients_state_main_returns_success_for_healthy_minimized_clients(self):
        verifier = load_script_module(
            "verify_live_clients_state_script",
            "scripts/verify_live_clients_state.py",
        )
        stdout = io.StringIO()
        stderr = io.StringIO()
        fresh_heartbeat = datetime.now(timezone.utc).isoformat()
        fresh_diagnostics = datetime.now(timezone.utc).isoformat()

        verifier.fetch_health = lambda base_url: {
            "ready": True,
            "compile_errors": 0,
            "build": {"git_commit": "commit-1"},
        }
        verifier.login = lambda base_url, username, password: (
            "token-1",
            {"username": username, "role": "admin"},
        )
        verifier.live_state = lambda base_url, token: {
            "agents": [
                {
                    "clientName": "c1",
                    "machineName": "DESKTOP-1",
                    "clientVersion": "1.0.105+109",
                    "isOnline": True,
                    "serverConnected": True,
                    "sqlConnected": True,
                    "lastHeartbeat": fresh_heartbeat,
                    "diagnostics": {"status": "uploaded", "uploadedAt": fresh_diagnostics},
                    "clientUpdate": {"pending": False, "status": "current", "targetVersion": "1.0.105+109"},
                    "windowAction": {"pending": False, "action": "minimize", "status": "completed"},
                },
                {
                    "clientName": "c2",
                    "machineName": "DESKTOP-2",
                    "clientVersion": "1.0.105+109",
                    "isOnline": True,
                    "serverConnected": True,
                    "sqlConnected": True,
                    "lastHeartbeat": fresh_heartbeat,
                    "diagnostics": {"status": "uploaded", "uploadedAt": fresh_diagnostics},
                    "clientUpdate": {"pending": False, "status": "current", "targetVersion": "1.0.105+109"},
                    "windowAction": {"pending": False, "action": "minimize", "status": "completed"},
                },
            ]
        }

        argv = sys.argv
        sys.argv = [
            "verify_live_clients_state.py",
            "--clients",
            "c1",
            "c2",
            "--expected-version",
            "1.0.105+109",
            "--expect-commit",
            "commit-1",
            "--require-window-minimized",
        ]
        try:
            with redirect_stdout(stdout), redirect_stderr(stderr):
                exit_code = verifier.main()
        finally:
            sys.argv = argv

        self.assertEqual(exit_code, 0)
        self.assertEqual(stderr.getvalue(), "")
        self.assertIn("client_summaries=", stdout.getvalue())
        self.assertIn("client_state_ok clients=2 online=2 minimized=2", stdout.getvalue())

    def test_clients_state_main_returns_failure_for_unhealthy_client(self):
        verifier = load_script_module(
            "verify_live_clients_state_script",
            "scripts/verify_live_clients_state.py",
        )
        stdout = io.StringIO()
        stderr = io.StringIO()

        verifier.fetch_health = lambda base_url: {
            "ready": True,
            "compile_errors": 0,
            "build": {"git_commit": "commit-1"},
        }
        verifier.login = lambda base_url, username, password: (
            "token-1",
            {"username": username, "role": "admin"},
        )
        verifier.live_state = lambda base_url, token: {
            "agents": [
                {
                    "clientName": "c1",
                    "machineName": "DESKTOP-1",
                    "clientVersion": "1.0.104+108",
                    "isOnline": False,
                    "serverConnected": False,
                    "sqlConnected": False,
                    "lastHeartbeat": "",
                    "diagnostics": {"status": "requested", "uploadedAt": ""},
                    "clientUpdate": {"pending": True, "status": "requested", "targetVersion": "1.0.105+109"},
                    "windowAction": {"pending": True, "action": "restore", "status": "requested"},
                }
            ]
        }

        argv = sys.argv
        sys.argv = [
            "verify_live_clients_state.py",
            "--clients",
            "c1",
            "--expected-version",
            "1.0.105+109",
            "--expect-commit",
            "commit-1",
            "--require-window-minimized",
        ]
        try:
            with redirect_stdout(stdout), redirect_stderr(stderr):
                exit_code = verifier.main()
        finally:
            sys.argv = argv

        self.assertEqual(exit_code, 1)
        self.assertIn("client_summaries=", stdout.getvalue())
        self.assertIn("client validation failures:", stderr.getvalue())
        self.assertIn("client offline", stderr.getvalue())
        self.assertIn("client update still pending", stderr.getvalue())

    def test_clients_state_main_returns_commit_mismatch_code(self):
        verifier = load_script_module(
            "verify_live_clients_state_script",
            "scripts/verify_live_clients_state.py",
        )
        stdout = io.StringIO()
        stderr = io.StringIO()

        verifier.fetch_health = lambda base_url: {
            "ready": True,
            "compile_errors": 0,
            "build": {"git_commit": "commit-live"},
        }

        argv = sys.argv
        sys.argv = [
            "verify_live_clients_state.py",
            "--expect-commit",
            "commit-expected",
        ]
        try:
            with redirect_stdout(stdout), redirect_stderr(stderr):
                exit_code = verifier.main()
        finally:
            sys.argv = argv

        self.assertEqual(exit_code, 2)
        self.assertIn("build.git_commit=commit-live", stdout.getvalue())
        self.assertIn("expected live commit commit-expected but found commit-live", stderr.getvalue())

    def test_clients_state_run_cli_converts_api_error_to_clean_exit(self):
        verifier = load_script_module(
            "verify_live_clients_state_script",
            "scripts/verify_live_clients_state.py",
        )
        stderr = io.StringIO()

        verifier.main = lambda: (_ for _ in ()).throw(verifier.ApiError("clients state boom"))

        with redirect_stderr(stderr):
            exit_code = verifier.run_cli()

        self.assertEqual(exit_code, 1)
        self.assertEqual(stderr.getvalue().strip(), "clients state boom")

    def test_sync_state_retryable_transport_error_matches_connection_reset(self):
        verifier = load_script_module(
            "verify_live_sync_state_script",
            "scripts/verify_live_sync_state.py",
        )

        self.assertTrue(
            verifier.retryable_transport_error(
                verifier.ApiError(
                    "request failed: <urlopen error [WinError 10054] An existing connection was forcibly closed by the remote host>"
                )
            )
        )
        self.assertFalse(verifier.retryable_transport_error(verifier.ApiError("HTTP 408: timeout")))

    def test_sync_state_post_json_retries_transient_transport_reset(self):
        verifier = load_script_module(
            "verify_live_sync_state_script",
            "scripts/verify_live_sync_state.py",
        )

        calls = {"count": 0}

        class FakeResponse:
            def __enter__(self):
                return self

            def __exit__(self, exc_type, exc, tb):
                return False

            def read(self):
                return b'{"ok": true}'

        def fake_urlopen(request, timeout=30):
            self.assertEqual(timeout, 30)
            calls["count"] += 1
            if calls["count"] == 1:
                raise verifier.urllib.error.URLError(
                    ConnectionResetError(
                        10054,
                        "An existing connection was forcibly closed by the remote host",
                    )
                )
            return FakeResponse()

        verifier.urllib.request.urlopen = fake_urlopen
        verifier.time.sleep = lambda seconds: None

        decoded = verifier.post_json("https://sync.velvet-leaf.com/call", {"name": "x"})

        self.assertEqual(decoded, {"ok": True})
        self.assertEqual(calls["count"], 2)

    def test_sync_state_post_json_rejects_non_map_payloads(self):
        verifier = load_script_module(
            "verify_live_sync_state_script",
            "scripts/verify_live_sync_state.py",
        )

        class FakeResponse:
            def __enter__(self):
                return self

            def __exit__(self, exc_type, exc, tb):
                return False

            def read(self):
                return b'["not-a-map"]'

        verifier.urllib.request.urlopen = lambda request, timeout=30: FakeResponse()

        with self.assertRaises(verifier.ApiError):
            verifier.post_json("https://sync.velvet-leaf.com/call", {"name": "x"})

    def test_sync_state_post_json_rejects_invalid_json_payloads(self):
        verifier = load_script_module(
            "verify_live_sync_state_script",
            "scripts/verify_live_sync_state.py",
        )

        class FakeResponse:
            def __enter__(self):
                return self

            def __exit__(self, exc_type, exc, tb):
                return False

            def read(self):
                return b"{not-json"

        verifier.urllib.request.urlopen = lambda request, timeout=30: FakeResponse()

        with self.assertRaises(verifier.ApiError):
            verifier.post_json("https://sync.velvet-leaf.com/call", {"name": "x"})

    def test_sync_state_invoke_function_rejects_non_map_success_value(self):
        verifier = load_script_module(
            "verify_live_sync_state_script",
            "scripts/verify_live_sync_state.py",
        )

        verifier.post_json = lambda url, payload: {"status": "success", "value": ["not-a-map"]}

        with self.assertRaises(verifier.ApiError):
            verifier.invoke_function("https://sync.velvet-leaf.com", "live_state", {"token": "x"})

    def test_sync_state_invoke_function_surfaces_failed_status_payload(self):
        verifier = load_script_module(
            "verify_live_sync_state_script",
            "scripts/verify_live_sync_state.py",
        )

        verifier.post_json = lambda url, payload: {"status": "failed", "error": "boom"}

        with self.assertRaises(verifier.ApiError):
            verifier.invoke_function("https://sync.velvet-leaf.com", "live_state", {"token": "x"})

    def test_sync_state_fetch_health_retries_transient_transport_reset(self):
        verifier = load_script_module(
            "verify_live_sync_state_script",
            "scripts/verify_live_sync_state.py",
        )

        calls = {"count": 0}

        class FakeResponse:
            def __enter__(self):
                return self

            def __exit__(self, exc_type, exc, tb):
                return False

            def read(self):
                return b'{"ready": true, "compile_errors": 0, "build": {"git_commit": "commit-1"}}'

        def fake_urlopen(request, timeout=30):
            self.assertEqual(timeout, 30)
            calls["count"] += 1
            if calls["count"] == 1:
                raise verifier.urllib.error.URLError(ConnectionResetError(10054, "Connection reset by peer"))
            return FakeResponse()

        verifier.urllib.request.urlopen = fake_urlopen
        verifier.time.sleep = lambda seconds: None

        decoded = verifier.fetch_health("https://sync.velvet-leaf.com")

        self.assertEqual(decoded["ready"], True)
        self.assertEqual(decoded["build"]["git_commit"], "commit-1")
        self.assertEqual(calls["count"], 2)

    def test_sync_state_fetch_health_rejects_non_map_payloads(self):
        verifier = load_script_module(
            "verify_live_sync_state_script",
            "scripts/verify_live_sync_state.py",
        )

        class FakeResponse:
            def __enter__(self):
                return self

            def __exit__(self, exc_type, exc, tb):
                return False

            def read(self):
                return b'["not-a-map"]'

        verifier.urllib.request.urlopen = lambda request, timeout=30: FakeResponse()

        with self.assertRaises(verifier.ApiError):
            verifier.fetch_health("https://sync.velvet-leaf.com")

    def test_sync_state_summarize_enabled_tables_collects_non_completed_enabled_rows(self):
        verifier = load_script_module(
            "verify_live_sync_state_script",
            "scripts/verify_live_sync_state.py",
        )
        agent = {
            "tables": [
                {"table": "db::a", "enabled": True, "status": "Completed", "message": "Up to date.", "lastSync": "x"},
                {"table": "db::b", "enabled": True, "status": "Uploading", "message": "Sending rows.", "lastSync": ""},
                {"table": "db::c", "enabled": False, "status": "Paused", "message": "Disabled.", "lastSync": ""},
            ]
        }

        summary = verifier.summarize_enabled_tables(agent)

        self.assertEqual(summary["enabledCount"], 2)
        self.assertEqual(summary["statusCounts"]["Completed"], 1)
        self.assertEqual(summary["statusCounts"]["Uploading"], 1)
        self.assertEqual(
            summary["nonCompleted"],
            [
                {
                    "table": "db::b",
                    "status": "Uploading",
                    "message": "Sending rows.",
                    "lastSync": "",
                }
            ],
        )

    def test_sync_state_summarize_jobs_for_clients_collects_active_and_failed(self):
        verifier = load_script_module(
            "verify_live_sync_state_script",
            "scripts/verify_live_sync_state.py",
        )
        state = {
            "jobs": [
                {"id": "1", "clientName": "c1", "table": "db::a", "direction": "upload", "status": "running", "progress": 40, "message": "Working", "error": None},
                {"id": "2", "clientName": "c2", "table": "db::b", "direction": "download", "status": "failed", "progress": 10, "message": "Failed", "error": "boom"},
                {"id": "3", "clientName": "c9", "table": "db::c", "direction": "download", "status": "completed", "progress": 100, "message": "Done", "error": None},
            ]
        }

        summary = verifier.summarize_jobs_for_clients(state, ["c1", "c2"])

        self.assertEqual(summary["visibleCount"], 2)
        self.assertEqual(len(summary["active"]), 1)
        self.assertEqual(summary["active"][0]["id"], "1")
        self.assertEqual(len(summary["failed"]), 1)
        self.assertEqual(summary["failed"][0]["id"], "2")
        self.assertEqual(len(summary["visible"]), 2)

    def test_sync_state_summarize_jobs_keeps_full_visible_history_for_unresolved_checks(self):
        verifier = load_script_module(
            "verify_live_sync_state_script",
            "scripts/verify_live_sync_state.py",
        )
        jobs = [
            {
                "id": f"noise-{index}",
                "clientName": "c1",
                "table": f"db::noise{index}",
                "direction": "download",
                "status": "completed",
                "progress": 100,
                "message": "Done",
                "error": None,
                "updatedAt": f"2026-07-09T08:{index:02d}:00+00:00",
                "completedAt": f"2026-07-09T08:{index:02d}:00+00:00",
            }
            for index in range(10)
        ]
        jobs.extend(
            [
                {
                    "id": "old-fail",
                    "clientName": "c1",
                    "table": "db::a",
                    "direction": "download",
                    "status": "failed",
                    "progress": 100,
                    "message": "Failed",
                    "error": "boom",
                    "updatedAt": "2026-07-09T09:00:00+00:00",
                    "completedAt": "2026-07-09T09:00:00+00:00",
                },
                {
                    "id": "new-success",
                    "clientName": "c1",
                    "table": "db::a",
                    "direction": "download",
                    "status": "completed",
                    "progress": 100,
                    "message": "Recovered",
                    "error": None,
                    "updatedAt": "2026-07-09T10:00:00+00:00",
                    "completedAt": "2026-07-09T10:00:00+00:00",
                },
            ]
        )

        summary = verifier.summarize_jobs_for_clients({"jobs": jobs}, ["c1"])
        unresolved = verifier.unresolved_failed_jobs(summary)

        self.assertEqual(summary["visibleCount"], len(jobs))
        self.assertEqual(len(summary["sample"]), 10)
        self.assertEqual(summary["sample"][0]["id"], "noise-0")
        self.assertEqual(len(summary["visible"]), len(jobs))
        self.assertEqual(unresolved, [])

    def test_sync_state_validate_helpers_report_failures(self):
        verifier = load_script_module(
            "verify_live_sync_state_script",
            "scripts/verify_live_sync_state.py",
        )

        agent_failures = verifier.validate_agent_sync_state(
            {"enabledCount": 0, "nonCompleted": [{"table": "db::b"}]},
            1,
        )
        jobs_failures = verifier.validate_jobs_summary(
            {"active": [{"id": "1"}], "failed": [{"id": "2"}]}
        )

        self.assertIn("enabled table count 0 is lower than required minimum 1", agent_failures)
        self.assertIn('enabled tables not completed: [{"table": "db::b"}]', agent_failures)
        self.assertIn('active jobs present: [{"id": "1"}]', jobs_failures)
        self.assertIn('unresolved failed jobs present: [{"id": "2"}]', jobs_failures)

    def test_sync_state_unresolved_failed_jobs_ignores_failures_superseded_by_later_success(self):
        verifier = load_script_module(
            "verify_live_sync_state_script",
            "scripts/verify_live_sync_state.py",
        )
        summary = {
            "failed": [
                {
                    "id": "old-fail",
                    "clientName": "c1",
                    "table": "db::a",
                    "direction": "download",
                    "updatedAt": "2026-07-09T08:00:00+00:00",
                    "completedAt": "2026-07-09T08:00:00+00:00",
                },
                {
                    "id": "new-fail",
                    "clientName": "c2",
                    "table": "db::b",
                    "direction": "upload",
                    "updatedAt": "2026-07-09T09:00:00+00:00",
                    "completedAt": "2026-07-09T09:00:00+00:00",
                },
            ],
            "visible": [
                {
                    "id": "old-fail",
                    "clientName": "c1",
                    "table": "db::a",
                    "direction": "download",
                    "status": "failed",
                    "updatedAt": "2026-07-09T08:00:00+00:00",
                    "completedAt": "2026-07-09T08:00:00+00:00",
                },
                {
                    "id": "new-success",
                    "clientName": "c1",
                    "table": "db::a",
                    "direction": "download",
                    "status": "completed",
                    "updatedAt": "2026-07-09T10:00:00+00:00",
                    "completedAt": "2026-07-09T10:00:00+00:00",
                },
                {
                    "id": "new-fail",
                    "clientName": "c2",
                    "table": "db::b",
                    "direction": "upload",
                    "status": "failed",
                    "updatedAt": "2026-07-09T09:00:00+00:00",
                    "completedAt": "2026-07-09T09:00:00+00:00",
                },
            ],
        }

        unresolved = verifier.unresolved_failed_jobs(summary)

        self.assertEqual(len(unresolved), 1)
        self.assertEqual(unresolved[0]["id"], "new-fail")

    def test_sync_state_main_returns_success_for_clean_clients_and_jobs(self):
        verifier = load_script_module(
            "verify_live_sync_state_script",
            "scripts/verify_live_sync_state.py",
        )
        stdout = io.StringIO()
        stderr = io.StringIO()

        verifier.fetch_health = lambda base_url: {
            "ready": True,
            "compile_errors": 0,
            "build": {"git_commit": "commit-1"},
        }
        verifier.login = lambda base_url, username, password: (
            "token-1",
            {"username": username, "role": "admin"},
        )
        verifier.live_state = lambda base_url, token: {
            "agents": [
                {
                    "clientName": "c1",
                    "tables": [
                        {
                            "table": "db::a",
                            "enabled": True,
                            "status": "Completed",
                            "message": "Done",
                            "lastSync": "2026-07-09T10:00:00+00:00",
                        }
                    ],
                },
                {
                    "clientName": "c2",
                    "tables": [
                        {
                            "table": "db::b",
                            "enabled": True,
                            "status": "Completed",
                            "message": "Done",
                            "lastSync": "2026-07-09T10:00:00+00:00",
                        }
                    ],
                },
            ],
            "jobs": [
                {
                    "id": "job-1",
                    "clientName": "c1",
                    "table": "db::a",
                    "direction": "download",
                    "status": "completed",
                    "progress": 100,
                    "message": "Done",
                    "error": None,
                    "updatedAt": "2026-07-09T10:00:00+00:00",
                    "completedAt": "2026-07-09T10:00:00+00:00",
                }
            ],
        }

        argv = sys.argv
        sys.argv = [
            "verify_live_sync_state.py",
            "--clients",
            "c1",
            "c2",
            "--min-enabled-tables",
            "1",
            "--expect-commit",
            "commit-1",
        ]
        try:
            with redirect_stdout(stdout), redirect_stderr(stderr):
                exit_code = verifier.main()
        finally:
            sys.argv = argv

        self.assertEqual(exit_code, 0)
        self.assertEqual(stderr.getvalue(), "")
        self.assertIn("client_sync_summaries=", stdout.getvalue())
        self.assertIn("jobs_summary=", stdout.getvalue())
        self.assertIn("sync_state_ok clients=2 enabled_tables=2 active_jobs=0 unresolved_failed_jobs=0", stdout.getvalue())

    def test_sync_state_main_returns_failure_for_unresolved_jobs_and_non_completed_tables(self):
        verifier = load_script_module(
            "verify_live_sync_state_script",
            "scripts/verify_live_sync_state.py",
        )
        stdout = io.StringIO()
        stderr = io.StringIO()

        verifier.fetch_health = lambda base_url: {
            "ready": True,
            "compile_errors": 0,
            "build": {"git_commit": "commit-1"},
        }
        verifier.login = lambda base_url, username, password: (
            "token-1",
            {"username": username, "role": "admin"},
        )
        verifier.live_state = lambda base_url, token: {
            "agents": [
                {
                    "clientName": "c1",
                    "tables": [
                        {
                            "table": "db::a",
                            "enabled": True,
                            "status": "Uploading",
                            "message": "Sending rows",
                            "lastSync": "",
                        }
                    ],
                }
            ],
            "jobs": [
                {
                    "id": "job-fail-1",
                    "clientName": "c1",
                    "table": "db::a",
                    "direction": "download",
                    "status": "failed",
                    "progress": 100,
                    "message": "boom",
                    "error": "boom",
                    "updatedAt": "2026-07-09T10:00:00+00:00",
                    "completedAt": "2026-07-09T10:00:00+00:00",
                }
            ],
        }

        argv = sys.argv
        sys.argv = [
            "verify_live_sync_state.py",
            "--clients",
            "c1",
            "--min-enabled-tables",
            "1",
            "--expect-commit",
            "commit-1",
        ]
        try:
            with redirect_stdout(stdout), redirect_stderr(stderr):
                exit_code = verifier.main()
        finally:
            sys.argv = argv

        self.assertEqual(exit_code, 1)
        self.assertIn("client_sync_summaries=", stdout.getvalue())
        self.assertIn("jobs_summary=", stdout.getvalue())
        self.assertIn("sync state validation failures:", stderr.getvalue())
        self.assertIn("enabled tables not completed", stderr.getvalue())
        self.assertIn("unresolved failed jobs present", stderr.getvalue())

    def test_sync_state_main_returns_commit_mismatch_code(self):
        verifier = load_script_module(
            "verify_live_sync_state_script",
            "scripts/verify_live_sync_state.py",
        )
        stdout = io.StringIO()
        stderr = io.StringIO()

        verifier.fetch_health = lambda base_url: {
            "ready": True,
            "compile_errors": 0,
            "build": {"git_commit": "commit-live"},
        }

        argv = sys.argv
        sys.argv = [
            "verify_live_sync_state.py",
            "--expect-commit",
            "commit-expected",
        ]
        try:
            with redirect_stdout(stdout), redirect_stderr(stderr):
                exit_code = verifier.main()
        finally:
            sys.argv = argv

        self.assertEqual(exit_code, 2)
        self.assertIn("build.git_commit=commit-live", stdout.getvalue())
        self.assertIn("expected live commit commit-expected but found commit-live", stderr.getvalue())

    def test_sync_state_run_cli_converts_api_error_to_clean_exit(self):
        verifier = load_script_module(
            "verify_live_sync_state_script",
            "scripts/verify_live_sync_state.py",
        )
        stderr = io.StringIO()

        verifier.main = lambda: (_ for _ in ()).throw(verifier.ApiError("sync state boom"))

        with redirect_stderr(stderr):
            exit_code = verifier.run_cli()

        self.assertEqual(exit_code, 1)
        self.assertEqual(stderr.getvalue().strip(), "sync state boom")

    def test_window_action_parse_request_result_validates_shape(self):
        verifier = load_script_module(
            "verify_live_window_action_script",
            "scripts/verify_live_window_action.py",
        )

        action, request_id, requested_names = verifier.parse_window_action_request_result(
            {
                "action": "minimize",
                "requestId": "req-1",
                "requestedClientCount": 2,
                "requestedClientNames": ["c1", "c2"],
            }
        )

        self.assertEqual(action, "minimize")
        self.assertEqual(request_id, "req-1")
        self.assertEqual(requested_names, ["c1", "c2"])

    def test_window_action_summarize_progress_tracks_completed_and_pending(self):
        verifier = load_script_module(
            "verify_live_window_action_script",
            "scripts/verify_live_window_action.py",
        )

        pending, completed = verifier.summarize_progress(
            {
                "agents": [
                    {
                        "clientName": "c1",
                        "windowAction": {"lastRequestId": "req-1", "status": "completed"},
                    },
                    {
                        "clientName": "c2",
                        "windowAction": {"lastRequestId": "req-0", "status": "requested"},
                    },
                ]
            },
            "req-1",
            ["c1", "c2"],
        )

        self.assertEqual(completed, ["c1"])
        self.assertEqual(pending, ["c2"])

    def test_window_action_main_returns_success_when_all_acks_arrive(self):
        verifier = load_script_module(
            "verify_live_window_action_script",
            "scripts/verify_live_window_action.py",
        )
        stdout = io.StringIO()
        stderr = io.StringIO()
        fresh_heartbeat = datetime.now(timezone.utc).isoformat()

        verifier.fetch_health = lambda base_url: {
            "ready": True,
            "compile_errors": 0,
            "build": {"git_commit": "commit-1"},
        }
        verifier.login = lambda base_url, username, password: (
            "token-1",
            {"username": username, "role": "admin"},
        )
        verifier.request_all_window_actions = lambda base_url, token, action: {
            "action": action,
            "requestId": "req-1",
            "requestedClientCount": 2,
            "requestedClientNames": ["c1", "c2"],
        }
        verifier.live_state = lambda base_url, token: {
            "agents": [
                {
                    "clientName": "c1",
                    "isOnline": True,
                    "lastHeartbeat": fresh_heartbeat,
                    "windowAction": {"lastRequestId": "req-1", "status": "completed", "action": "minimize"},
                },
                {
                    "clientName": "c2",
                    "isOnline": True,
                    "lastHeartbeat": fresh_heartbeat,
                    "windowAction": {"lastRequestId": "req-1", "status": "completed", "action": "minimize"},
                },
            ]
        }

        argv = sys.argv
        sys.argv = ["verify_live_window_action.py", "--expect-commit", "commit-1"]
        try:
            with redirect_stdout(stdout), redirect_stderr(stderr):
                exit_code = verifier.main()
        finally:
            sys.argv = argv

        self.assertEqual(exit_code, 0)
        self.assertEqual(stderr.getvalue(), "")
        self.assertIn("window_action_ok requested=2 completed=2 action=minimize", stdout.getvalue())

    def test_window_action_main_returns_stale_timeout_code(self):
        verifier = load_script_module(
            "verify_live_window_action_script_stale",
            "scripts/verify_live_window_action.py",
        )
        stdout = io.StringIO()
        stderr = io.StringIO()
        stale_heartbeat = "2026-07-10T00:00:00+00:00"

        verifier.fetch_health = lambda base_url: {
            "ready": True,
            "compile_errors": 0,
            "build": {"git_commit": "commit-1"},
        }
        verifier.login = lambda base_url, username, password: (
            "token-1",
            {"username": username, "role": "admin"},
        )
        verifier.request_all_window_actions = lambda base_url, token, action: {
            "action": action,
            "requestId": "req-1",
            "requestedClientCount": 1,
            "requestedClientNames": ["c1"],
        }
        verifier.live_state = lambda base_url, token: {
            "agents": [
                {
                    "clientName": "c1",
                    "isOnline": False,
                    "lastHeartbeat": stale_heartbeat,
                    "windowAction": {"lastRequestId": "", "status": "requested", "action": "minimize"},
                }
            ]
        }
        verifier.time.sleep = lambda seconds: None
        time_values = iter([100.0, 100.5, 102.0])
        verifier.time.time = lambda: next(time_values, 102.0)

        argv = sys.argv
        sys.argv = [
            "verify_live_window_action.py",
            "--expect-commit",
            "commit-1",
            "--wait-seconds",
            "1",
            "--poll-seconds",
            "1",
            "--stale-heartbeat-minutes",
            "5",
        ]
        try:
            with redirect_stdout(stdout), redirect_stderr(stderr):
                exit_code = verifier.main()
        finally:
            sys.argv = argv

        self.assertEqual(exit_code, 3)
        self.assertIn("pending clients are offline/stale", stderr.getvalue())

    def test_window_action_run_cli_converts_api_error_to_clean_exit(self):
        verifier = load_script_module(
            "verify_live_window_action_script_cli",
            "scripts/verify_live_window_action.py",
        )
        stderr = io.StringIO()

        verifier.main = lambda: (_ for _ in ()).throw(verifier.ApiError("window action boom"))

        with redirect_stderr(stderr):
            exit_code = verifier.run_cli()

        self.assertEqual(exit_code, 1)
        self.assertEqual(stderr.getvalue().strip(), "window action boom")

    def test_state_recovery_summary_recovered_requires_fresh_online_state(self):
        verifier = load_script_module(
            "verify_live_state_recovery_script",
            "scripts/verify_live_state_recovery.py",
        )

        self.assertTrue(
            verifier.summary_recovered(
                {
                    "clientName": "c1",
                    "version": "1.0.105+109",
                    "online": True,
                    "serverConnected": True,
                    "sqlConnected": True,
                    "heartbeatAgeMinutes": 0.5,
                    "tableCount": 11,
                },
                "1.0.105+109",
                1,
                5.0,
            )
        )
        self.assertFalse(
            verifier.summary_recovered(
                {
                    "clientName": "c1",
                    "version": "1.0.105+109",
                    "online": True,
                    "serverConnected": True,
                    "sqlConnected": True,
                    "heartbeatAgeMinutes": None,
                    "tableCount": 0,
                },
                "1.0.105+109",
                1,
                5.0,
            )
        )

    def test_state_recovery_main_resets_then_runs_live_system(self):
        verifier = load_script_module(
            "verify_live_state_recovery_script_main",
            "scripts/verify_live_state_recovery.py",
        )
        stdout = io.StringIO()
        stderr = io.StringIO()
        fresh_heartbeat = datetime.now(timezone.utc).isoformat()

        verifier.fetch_health = lambda base_url: {
            "ready": True,
            "compile_errors": 0,
            "build": {"git_commit": "commit-1"},
        }
        verifier.login = lambda base_url, username, password: (
            "token-1",
            {"username": username, "role": "admin"},
        )
        verifier.reset_server_saved_data = lambda base_url, token: {
            "ok": True,
            "jobDeletedCount": 5,
            "agentResetCount": 2,
        }
        verifier.live_state = lambda base_url, token: {
            "agents": [
                {
                    "clientName": "c1",
                    "clientVersion": "1.0.105+109",
                    "isOnline": True,
                    "serverConnected": True,
                    "sqlConnected": True,
                    "lastHeartbeat": fresh_heartbeat,
                    "tables": [{"table": "t1"}],
                },
                {
                    "clientName": "c2",
                    "clientVersion": "1.0.105+109",
                    "isOnline": True,
                    "serverConnected": True,
                    "sqlConnected": True,
                    "lastHeartbeat": fresh_heartbeat,
                    "tables": [{"table": "t1"}],
                },
            ]
        }
        verifier.run_command = lambda command: {
            "command": command,
            "returncode": 0,
            "stdout": "line-1\nfull_system_ok\n",
            "stderr": "",
        }

        argv = sys.argv
        sys.argv = [
            "verify_live_state_recovery.py",
            "--expect-commit",
            "commit-1",
            "--expected-version",
            "1.0.105+109",
        ]
        try:
            with redirect_stdout(stdout), redirect_stderr(stderr):
                exit_code = verifier.main()
        finally:
            sys.argv = argv

        self.assertEqual(exit_code, 0)
        self.assertEqual(stderr.getvalue(), "")
        self.assertIn("reset=", stdout.getvalue())
        self.assertIn("command=", stdout.getvalue())
        self.assertIn("recovery_ok clients=2", stdout.getvalue())

    def test_state_recovery_main_returns_commit_mismatch_code(self):
        verifier = load_script_module(
            "verify_live_state_recovery_script_commit",
            "scripts/verify_live_state_recovery.py",
        )
        stdout = io.StringIO()
        stderr = io.StringIO()

        verifier.fetch_health = lambda base_url: {
            "ready": True,
            "compile_errors": 0,
            "build": {"git_commit": "commit-live"},
        }

        argv = sys.argv
        sys.argv = [
            "verify_live_state_recovery.py",
            "--expected-commit",
            "commit-expected",
        ]
        try:
            with redirect_stdout(stdout), redirect_stderr(stderr):
                exit_code = verifier.main()
        finally:
            sys.argv = argv

        self.assertEqual(exit_code, 2)
        self.assertIn("build.git_commit=commit-live", stdout.getvalue())
        self.assertIn("expected live commit commit-expected but found commit-live", stderr.getvalue())

    def test_state_recovery_main_returns_timeout_code_when_clients_do_not_recover(self):
        verifier = load_script_module(
            "verify_live_state_recovery_script_timeout",
            "scripts/verify_live_state_recovery.py",
        )
        stdout = io.StringIO()
        stderr = io.StringIO()
        stale_heartbeat = "2026-07-10T00:00:00+00:00"

        verifier.fetch_health = lambda base_url: {
            "ready": True,
            "compile_errors": 0,
            "build": {"git_commit": "commit-1"},
        }
        verifier.login = lambda base_url, username, password: (
            "token-1",
            {"username": username, "role": "admin"},
        )
        verifier.reset_server_saved_data = lambda base_url, token: {
            "ok": True,
            "jobDeletedCount": 5,
            "agentResetCount": 2,
        }
        verifier.live_state = lambda base_url, token: {
            "agents": [
                {
                    "clientName": "c1",
                    "clientVersion": "1.0.105+109",
                    "isOnline": False,
                    "serverConnected": False,
                    "sqlConnected": False,
                    "lastHeartbeat": stale_heartbeat,
                    "tables": [],
                },
                {
                    "clientName": "c2",
                    "clientVersion": "1.0.105+109",
                    "isOnline": False,
                    "serverConnected": False,
                    "sqlConnected": False,
                    "lastHeartbeat": stale_heartbeat,
                    "tables": [],
                },
            ]
        }
        verifier.time.sleep = lambda seconds: None
        time_values = iter([100.0, 100.5, 102.0])
        verifier.time.time = lambda: next(time_values, 102.0)

        argv = sys.argv
        sys.argv = [
            "verify_live_state_recovery.py",
            "--expected-commit",
            "commit-1",
            "--expected-version",
            "1.0.105+109",
            "--wait-seconds",
            "1",
            "--poll-seconds",
            "1",
        ]
        try:
            with redirect_stdout(stdout), redirect_stderr(stderr):
                exit_code = verifier.main()
        finally:
            sys.argv = argv

        self.assertEqual(exit_code, 3)
        self.assertIn("timed out waiting for client state recovery after reset", stderr.getvalue())
        self.assertIn("recovery_summaries=", stdout.getvalue())

    def test_state_recovery_main_returns_failure_when_live_system_verifier_fails(self):
        verifier = load_script_module(
            "verify_live_state_recovery_script_verify_fail",
            "scripts/verify_live_state_recovery.py",
        )
        stdout = io.StringIO()
        stderr = io.StringIO()
        fresh_heartbeat = datetime.now(timezone.utc).isoformat()

        verifier.fetch_health = lambda base_url: {
            "ready": True,
            "compile_errors": 0,
            "build": {"git_commit": "commit-1"},
        }
        verifier.login = lambda base_url, username, password: (
            "token-1",
            {"username": username, "role": "admin"},
        )
        verifier.reset_server_saved_data = lambda base_url, token: {
            "ok": True,
            "jobDeletedCount": 5,
            "agentResetCount": 2,
        }
        verifier.live_state = lambda base_url, token: {
            "agents": [
                {
                    "clientName": "c1",
                    "clientVersion": "1.0.105+109",
                    "isOnline": True,
                    "serverConnected": True,
                    "sqlConnected": True,
                    "lastHeartbeat": fresh_heartbeat,
                    "tables": [{"table": "t1"}],
                },
                {
                    "clientName": "c2",
                    "clientVersion": "1.0.105+109",
                    "isOnline": True,
                    "serverConnected": True,
                    "sqlConnected": True,
                    "lastHeartbeat": fresh_heartbeat,
                    "tables": [{"table": "t1"}],
                },
            ]
        }
        verifier.run_command = lambda command: {
            "command": command,
            "returncode": 1,
            "stdout": "",
            "stderr": "live system failed",
        }

        argv = sys.argv
        sys.argv = [
            "verify_live_state_recovery.py",
            "--expected-commit",
            "commit-1",
            "--expected-version",
            "1.0.105+109",
        ]
        try:
            with redirect_stdout(stdout), redirect_stderr(stderr):
                exit_code = verifier.main()
        finally:
            sys.argv = argv

        self.assertEqual(exit_code, 1)
        self.assertIn("command=", stdout.getvalue())
        self.assertIn("stderr_last=live system failed", stderr.getvalue())
        self.assertIn("recovery verification failed during live system verification", stderr.getvalue())

    def test_state_recovery_run_cli_converts_api_error_to_clean_exit(self):
        verifier = load_script_module(
            "verify_live_state_recovery_script_cli_api",
            "scripts/verify_live_state_recovery.py",
        )
        stderr = io.StringIO()

        verifier.main = lambda: (_ for _ in ()).throw(verifier.ApiError("state recovery boom"))

        with redirect_stderr(stderr):
            exit_code = verifier.run_cli()

        self.assertEqual(exit_code, 1)
        self.assertEqual(stderr.getvalue().strip(), "state recovery boom")

    def test_state_recovery_run_cli_converts_unexpected_error_to_clean_exit(self):
        verifier = load_script_module(
            "verify_live_state_recovery_script_cli_runtime",
            "scripts/verify_live_state_recovery.py",
        )
        stderr = io.StringIO()

        verifier.main = lambda: (_ for _ in ()).throw(RuntimeError("state recovery runtime boom"))

        with redirect_stderr(stderr):
            exit_code = verifier.run_cli()

        self.assertEqual(exit_code, 1)
        self.assertEqual(stderr.getvalue().strip(), "state recovery runtime boom")

    def test_state_recovery_retryable_transport_error_matches_connection_reset(self):
        verifier = load_script_module(
            "verify_live_state_recovery_script_transport",
            "scripts/verify_live_state_recovery.py",
        )

        self.assertTrue(
            verifier.retryable_transport_error(
                verifier.ApiError(
                    "request failed: <urlopen error [WinError 10054] An existing connection was forcibly closed by the remote host>"
                )
            )
        )
        self.assertFalse(verifier.retryable_transport_error(verifier.ApiError("HTTP 408: timeout")))

    def test_state_recovery_post_json_retries_transient_transport_reset(self):
        verifier = load_script_module(
            "verify_live_state_recovery_script_post_retry",
            "scripts/verify_live_state_recovery.py",
        )

        calls = {"count": 0}

        class FakeResponse:
            def __enter__(self):
                return self

            def __exit__(self, exc_type, exc, tb):
                return False

            def read(self):
                return b'{"ok": true}'

        def fake_urlopen(request, timeout=30):
            self.assertEqual(timeout, 30)
            calls["count"] += 1
            if calls["count"] == 1:
                raise verifier.urllib.error.URLError(
                    ConnectionResetError(
                        10054,
                        "An existing connection was forcibly closed by the remote host",
                    )
                )
            return FakeResponse()

        verifier.urllib.request.urlopen = fake_urlopen
        verifier.time.sleep = lambda seconds: None

        decoded = verifier.post_json("https://sync.velvet-leaf.com/call", {"name": "x"})

        self.assertEqual(decoded, {"ok": True})
        self.assertEqual(calls["count"], 2)

    def test_state_recovery_post_json_rejects_non_map_payloads(self):
        verifier = load_script_module(
            "verify_live_state_recovery_script_post_map",
            "scripts/verify_live_state_recovery.py",
        )

        class FakeResponse:
            def __enter__(self):
                return self

            def __exit__(self, exc_type, exc, tb):
                return False

            def read(self):
                return b'["not-a-map"]'

        verifier.urllib.request.urlopen = lambda request, timeout=30: FakeResponse()

        with self.assertRaises(verifier.ApiError):
            verifier.post_json("https://sync.velvet-leaf.com/call", {"name": "x"})

    def test_state_recovery_post_json_rejects_invalid_json_payloads(self):
        verifier = load_script_module(
            "verify_live_state_recovery_script_post_json",
            "scripts/verify_live_state_recovery.py",
        )

        class FakeResponse:
            def __enter__(self):
                return self

            def __exit__(self, exc_type, exc, tb):
                return False

            def read(self):
                return b"{not-json"

        verifier.urllib.request.urlopen = lambda request, timeout=30: FakeResponse()

        with self.assertRaises(verifier.ApiError):
            verifier.post_json("https://sync.velvet-leaf.com/call", {"name": "x"})

    def test_state_recovery_invoke_function_rejects_non_map_success_value(self):
        verifier = load_script_module(
            "verify_live_state_recovery_script_invoke_map",
            "scripts/verify_live_state_recovery.py",
        )

        verifier.post_json = lambda url, payload: {"status": "success", "value": ["not-a-map"]}

        with self.assertRaises(verifier.ApiError):
            verifier.invoke_function("https://sync.velvet-leaf.com", "live_state", {"token": "x"})

    def test_state_recovery_invoke_function_surfaces_failed_status_payload(self):
        verifier = load_script_module(
            "verify_live_state_recovery_script_invoke_fail",
            "scripts/verify_live_state_recovery.py",
        )

        verifier.post_json = lambda url, payload: {"status": "failed", "error": "boom"}

        with self.assertRaises(verifier.ApiError):
            verifier.invoke_function("https://sync.velvet-leaf.com", "live_state", {"token": "x"})

    def test_state_recovery_fetch_health_retries_transient_transport_reset(self):
        verifier = load_script_module(
            "verify_live_state_recovery_script_health_retry",
            "scripts/verify_live_state_recovery.py",
        )

        calls = {"count": 0}

        class FakeResponse:
            def __enter__(self):
                return self

            def __exit__(self, exc_type, exc, tb):
                return False

            def read(self):
                return b'{"ready": true, "compile_errors": 0, "build": {"git_commit": "commit-1"}}'

        def fake_urlopen(request, timeout=30):
            self.assertEqual(timeout, 30)
            calls["count"] += 1
            if calls["count"] == 1:
                raise verifier.urllib.error.URLError(ConnectionResetError(10054, "Connection reset by peer"))
            return FakeResponse()

        verifier.urllib.request.urlopen = fake_urlopen
        verifier.time.sleep = lambda seconds: None

        decoded = verifier.fetch_health("https://sync.velvet-leaf.com")

        self.assertEqual(decoded["ready"], True)
        self.assertEqual(decoded["build"]["git_commit"], "commit-1")
        self.assertEqual(calls["count"], 2)

    def test_state_recovery_fetch_health_rejects_non_map_payloads(self):
        verifier = load_script_module(
            "verify_live_state_recovery_script_health_map",
            "scripts/verify_live_state_recovery.py",
        )

        class FakeResponse:
            def __enter__(self):
                return self

            def __exit__(self, exc_type, exc, tb):
                return False

            def read(self):
                return b'["not-a-map"]'

        verifier.urllib.request.urlopen = lambda request, timeout=30: FakeResponse()

        with self.assertRaises(verifier.ApiError):
            verifier.fetch_health("https://sync.velvet-leaf.com")

    def test_state_recovery_run_command_decodes_byte_output_with_replacement(self):
        verifier = load_script_module(
            "verify_live_state_recovery_script_run_bytes",
            "scripts/verify_live_state_recovery.py",
        )

        class FakeCompleted:
            returncode = 0
            stdout = b"ok\x90out"
            stderr = b"warn\x90err"

        original_run = verifier.subprocess.run
        verifier.subprocess.run = lambda *args, **kwargs: FakeCompleted()
        try:
            result = verifier.run_command(["python", "bytes.py"])
        finally:
            verifier.subprocess.run = original_run

        self.assertEqual(result["returncode"], 0)
        self.assertEqual(result["stdout"], "ok\ufffdout")
        self.assertEqual(result["stderr"], "warn\ufffderr")

    def test_state_recovery_run_command_converts_launch_oserror_to_failed_result(self):
        verifier = load_script_module(
            "verify_live_state_recovery_script_run_oserror",
            "scripts/verify_live_state_recovery.py",
        )
        original_run = verifier.subprocess.run
        verifier.subprocess.run = lambda *args, **kwargs: (_ for _ in ()).throw(
            OSError("launch failed")
        )
        try:
            result = verifier.run_command(["python", "missing.py"])
        finally:
            verifier.subprocess.run = original_run

        self.assertEqual(result["returncode"], 1)
        self.assertEqual(result["stdout"], "")
        self.assertEqual(result["stderr"], "launch failed")

    def test_live_system_builds_expected_verifier_commands(self):
        verifier = load_script_module(
            "verify_live_system_script",
            "scripts/verify_live_system.py",
        )

        commands = verifier.build_verifier_commands("commit-1", "1.2.3+4")

        self.assertEqual(len(commands), 7)
        self.assertIn("verify_live_bulk_diagnostics.py", commands[0][1])
        self.assertEqual(commands[0][-1], "commit-1")
        self.assertIn("verify_live_client_update.py", commands[1][1])
        self.assertEqual(commands[1][2], "c1")
        self.assertEqual(commands[1][3], "1.2.3+4")
        self.assertIn("verify_live_scheduler_stress.py", commands[3][1])
        self.assertIn("verify_live_window_action.py", commands[4][1])
        self.assertIn("verify_live_clients_state.py", commands[5][1])
        self.assertIn("verify_live_sync_state.py", commands[6][1])

    def test_live_system_run_command_captures_stdout_stderr_and_returncode(self):
        verifier = load_script_module(
            "verify_live_system_script",
            "scripts/verify_live_system.py",
        )

        result = verifier.run_command(
            [
                sys.executable,
                "-c",
                "import sys; print('ok-out'); print('ok-err', file=sys.stderr); raise SystemExit(3)",
            ]
        )

        self.assertEqual(result["returncode"], 3)
        self.assertIn("ok-out", result["stdout"])
        self.assertIn("ok-err", result["stderr"])

    def test_live_system_run_command_decodes_byte_output_with_replacement(self):
        verifier = load_script_module(
            "verify_live_system_script",
            "scripts/verify_live_system.py",
        )

        class FakeCompleted:
            returncode = 0
            stdout = b"ok\x90out"
            stderr = b"warn\x90err"

        original_run = verifier.subprocess.run
        verifier.subprocess.run = lambda *args, **kwargs: FakeCompleted()
        try:
            result = verifier.run_command(["python", "bytes.py"])
        finally:
            verifier.subprocess.run = original_run

        self.assertEqual(result["returncode"], 0)
        self.assertEqual(result["stdout"], "ok\ufffdout")
        self.assertEqual(result["stderr"], "warn\ufffderr")

    def test_live_system_run_command_converts_launch_oserror_to_failed_result(self):
        verifier = load_script_module(
            "verify_live_system_script",
            "scripts/verify_live_system.py",
        )
        original_run = verifier.subprocess.run
        verifier.subprocess.run = lambda *args, **kwargs: (_ for _ in ()).throw(
            OSError("launch failed")
        )
        try:
            result = verifier.run_command(["python", "missing.py"])
        finally:
            verifier.subprocess.run = original_run

        self.assertEqual(result["returncode"], 1)
        self.assertEqual(result["stdout"], "")
        self.assertEqual(result["stderr"], "launch failed")

    def test_live_system_summarize_results_reports_last_lines_and_status(self):
        verifier = load_script_module(
            "verify_live_system_script",
            "scripts/verify_live_system.py",
        )

        summary = verifier.summarize_results(
            [
                {
                    "command": ["python", "one.py"],
                    "returncode": 0,
                    "stdout": "line-1\nline-2\n",
                    "stderr": "",
                },
                {
                    "command": ["python", "two.py"],
                    "returncode": 1,
                    "stdout": "",
                    "stderr": "warn-1\nerror-last\n",
                },
            ]
        )

        self.assertEqual(summary[0]["command"], ["python", "one.py"])
        self.assertTrue(summary[0]["ok"])
        self.assertEqual(summary[0]["stdoutLineCount"], 2)
        self.assertEqual(summary[0]["lastStdoutLine"], "line-2")
        self.assertFalse(summary[1]["ok"])
        self.assertEqual(summary[1]["stderrLineCount"], 2)
        self.assertEqual(summary[1]["lastStderrLine"], "error-last")

    def test_live_system_print_result_output_summary_mode_prints_only_last_lines(self):
        verifier = load_script_module(
            "verify_live_system_script",
            "scripts/verify_live_system.py",
        )
        stdout = io.StringIO()
        stderr = io.StringIO()

        with redirect_stdout(stdout), redirect_stderr(stderr):
            verifier.print_result_output(
                {
                    "stdout": "line-1\nline-2\n",
                    "stderr": "warn-1\nwarn-2\n",
                },
                False,
            )

        self.assertEqual(stdout.getvalue().strip(), "stdout_last=line-2")
        self.assertEqual(stderr.getvalue().strip(), "stderr_last=warn-2")

    def test_live_system_print_result_output_verbose_mode_prints_full_streams(self):
        verifier = load_script_module(
            "verify_live_system_script",
            "scripts/verify_live_system.py",
        )
        stdout = io.StringIO()
        stderr = io.StringIO()

        with redirect_stdout(stdout), redirect_stderr(stderr):
            verifier.print_result_output(
                {
                    "stdout": "line-1\nline-2\n",
                    "stderr": "warn-1\nwarn-2\n",
                },
                True,
            )

        self.assertEqual(stdout.getvalue().strip(), "line-1\nline-2")
        self.assertEqual(stderr.getvalue().strip(), "warn-1\nwarn-2")

    def test_full_system_builds_local_and_live_commands(self):
        verifier = load_script_module(
            "verify_full_system_script",
            "scripts/verify_full_system.py",
        )

        commands = verifier.build_verification_commands("commit-2", "2.3.4+5")

        self.assertEqual(len(commands), 3)
        self.assertEqual(commands[0]["name"], "python_contracts")
        self.assertEqual(commands[0]["command"][0], sys.executable)
        self.assertIn("pytest", commands[0]["command"])
        self.assertEqual(commands[1]["name"], "flutter_agent_tests")
        self.assertEqual(commands[1]["command"], ["powershell", "-NoProfile", "-Command", "flutter test"])
        self.assertEqual(commands[2]["name"], "live_system")
        self.assertIn("verify_live_system.py", commands[2]["command"][1])
        self.assertEqual(
            commands[2]["command"][-4:],
            ["--expected-commit", "commit-2", "--expected-version", "2.3.4+5"],
        )

    def test_full_system_builds_recovery_command_when_requested(self):
        verifier = load_script_module(
            "verify_full_system_script_recovery",
            "scripts/verify_full_system.py",
        )

        commands = verifier.build_verification_commands("commit-2", "2.3.4+5", include_recovery=True)

        self.assertEqual(len(commands), 4)
        self.assertEqual(commands[3]["name"], "live_state_recovery")
        self.assertIn("verify_live_state_recovery.py", commands[3]["command"][1])
        self.assertEqual(
            commands[3]["command"][-4:],
            ["--expected-commit", "commit-2", "--expected-version", "2.3.4+5"],
        )

    def test_full_system_run_command_uses_workdir_and_captures_output(self):
        verifier = load_script_module(
            "verify_full_system_script",
            "scripts/verify_full_system.py",
        )

        result = verifier.run_command(
            [
                sys.executable,
                "-c",
                "import os,sys; print(os.getcwd()); print('full-err', file=sys.stderr)",
            ],
            str(ROOT),
        )

        self.assertEqual(result["returncode"], 0)
        self.assertIn(str(ROOT), result["stdout"])
        self.assertIn("full-err", result["stderr"])

    def test_full_system_run_command_decodes_byte_output_with_replacement(self):
        verifier = load_script_module(
            "verify_full_system_script",
            "scripts/verify_full_system.py",
        )

        class FakeCompleted:
            returncode = 0
            stdout = b"ok\x90out"
            stderr = b"warn\x90err"

        original_run = verifier.subprocess.run
        verifier.subprocess.run = lambda *args, **kwargs: FakeCompleted()
        try:
            result = verifier.run_command(["python", "bytes.py"], str(ROOT))
        finally:
            verifier.subprocess.run = original_run

        self.assertEqual(result["returncode"], 0)
        self.assertEqual(result["stdout"], "ok\ufffdout")
        self.assertEqual(result["stderr"], "warn\ufffderr")
        self.assertEqual(result["workdir"], str(ROOT))

    def test_full_system_run_command_converts_launch_oserror_to_failed_result(self):
        verifier = load_script_module(
            "verify_full_system_script",
            "scripts/verify_full_system.py",
        )
        original_run = verifier.subprocess.run
        verifier.subprocess.run = lambda *args, **kwargs: (_ for _ in ()).throw(
            OSError("launch failed")
        )
        try:
            result = verifier.run_command(["python", "missing.py"], str(ROOT))
        finally:
            verifier.subprocess.run = original_run

        self.assertEqual(result["returncode"], 1)
        self.assertEqual(result["stdout"], "")
        self.assertEqual(result["stderr"], "launch failed")
        self.assertEqual(result["workdir"], str(ROOT))

    def test_full_system_summarize_results_reports_last_lines_and_status(self):
        verifier = load_script_module(
            "verify_full_system_script",
            "scripts/verify_full_system.py",
        )

        summary = verifier.summarize_results(
            [
                {
                    "name": "python_contracts",
                    "returncode": 0,
                    "stdout": "line-1\nline-2\n",
                    "stderr": "",
                },
                {
                    "name": "live_system",
                    "returncode": 1,
                    "stdout": "",
                    "stderr": "warn-1\nerror-last\n",
                },
            ]
        )

        self.assertEqual(summary[0]["name"], "python_contracts")
        self.assertTrue(summary[0]["ok"])
        self.assertEqual(summary[0]["stdoutLineCount"], 2)
        self.assertEqual(summary[0]["lastStdoutLine"], "line-2")
        self.assertEqual(summary[1]["name"], "live_system")
        self.assertFalse(summary[1]["ok"])
        self.assertEqual(summary[1]["stderrLineCount"], 2)
        self.assertEqual(summary[1]["lastStderrLine"], "error-last")

    def test_full_system_print_result_output_summary_mode_prints_only_last_lines(self):
        verifier = load_script_module(
            "verify_full_system_script",
            "scripts/verify_full_system.py",
        )
        stdout = io.StringIO()
        stderr = io.StringIO()

        with redirect_stdout(stdout), redirect_stderr(stderr):
            verifier.print_result_output(
                {
                    "stdout": "line-1\nline-2\n",
                    "stderr": "warn-1\nwarn-2\n",
                },
                False,
            )

        self.assertEqual(stdout.getvalue().strip(), "stdout_last=line-2")
        self.assertEqual(stderr.getvalue().strip(), "stderr_last=warn-2")

    def test_full_system_print_result_output_verbose_mode_prints_full_streams(self):
        verifier = load_script_module(
            "verify_full_system_script",
            "scripts/verify_full_system.py",
        )
        stdout = io.StringIO()
        stderr = io.StringIO()

        with redirect_stdout(stdout), redirect_stderr(stderr):
            verifier.print_result_output(
                {
                    "stdout": "line-1\nline-2\n",
                    "stderr": "warn-1\nwarn-2\n",
                },
                True,
            )

        self.assertEqual(stdout.getvalue().strip(), "line-1\nline-2")
        self.assertEqual(stderr.getvalue().strip(), "warn-1\nwarn-2")

    def test_full_system_ok_line_is_the_default_terminal_output_line(self):
        verifier = load_script_module(
            "verify_full_system_script",
            "scripts/verify_full_system.py",
        )
        stdout = io.StringIO()
        stderr = io.StringIO()

        verifier.build_verification_commands = lambda expected_commit, expected_version, include_recovery=False: [
            {"name": "python_contracts", "command": ["python", "one.py"], "workdir": str(ROOT)}
        ]
        verifier.run_command = lambda command, workdir: {
            "command": command,
            "workdir": workdir,
            "returncode": 0,
            "stdout": "line-1\n",
            "stderr": "",
        }
        argv = sys.argv
        sys.argv = ["verify_full_system.py"]
        try:
            with redirect_stdout(stdout), redirect_stderr(stderr):
                exit_code = verifier.main()
        finally:
            sys.argv = argv

        self.assertEqual(exit_code, 0)
        self.assertEqual(stderr.getvalue(), "")
        self.assertIn("stdout_last=line-1", stdout.getvalue())
        self.assertTrue(stdout.getvalue().strip().splitlines()[-1].startswith("full_system_ok "))

    def test_full_system_main_passes_include_recovery_flag_into_command_builder(self):
        verifier = load_script_module(
            "verify_full_system_script_include_recovery",
            "scripts/verify_full_system.py",
        )
        stdout = io.StringIO()
        stderr = io.StringIO()
        observed = {}

        def fake_build(expected_commit, expected_version, include_recovery=False):
            observed["expected_commit"] = expected_commit
            observed["expected_version"] = expected_version
            observed["include_recovery"] = include_recovery
            return []

        verifier.build_verification_commands = fake_build
        argv = sys.argv
        sys.argv = [
            "verify_full_system.py",
            "--expected-commit",
            "commit-1",
            "--expected-version",
            "1.2.3+4",
            "--include-recovery",
        ]
        try:
            with redirect_stdout(stdout), redirect_stderr(stderr):
                exit_code = verifier.main()
        finally:
            sys.argv = argv

        self.assertEqual(exit_code, 0)
        self.assertEqual(stderr.getvalue(), "")
        self.assertEqual(observed["expected_commit"], "commit-1")
        self.assertEqual(observed["expected_version"], "1.2.3+4")
        self.assertTrue(observed["include_recovery"])
        self.assertIn("full_system_ok steps=0 passed=0 failed=0", stdout.getvalue())

    def test_live_system_summary_is_the_default_terminal_output_line(self):
        verifier = load_script_module(
            "verify_live_system_script",
            "scripts/verify_live_system.py",
        )
        stdout = io.StringIO()
        stderr = io.StringIO()

        verifier.build_verifier_commands = lambda expected_commit, expected_version: [["python", "one.py"]]
        verifier.run_command = lambda command: {
            "command": command,
            "returncode": 0,
            "stdout": "inner-line\n",
            "stderr": "",
        }
        argv = sys.argv
        sys.argv = ["verify_live_system.py"]
        try:
            with redirect_stdout(stdout), redirect_stderr(stderr):
                exit_code = verifier.main()
        finally:
            sys.argv = argv

        self.assertEqual(exit_code, 0)
        self.assertEqual(stderr.getvalue(), "")
        self.assertIn("stdout_last=inner-line", stdout.getvalue())
        self.assertTrue(stdout.getvalue().strip().splitlines()[-1].startswith("live_system_summary="))

    def test_live_system_main_returns_failure_when_a_verifier_command_fails(self):
        verifier = load_script_module(
            "verify_live_system_script",
            "scripts/verify_live_system.py",
        )
        stdout = io.StringIO()
        stderr = io.StringIO()

        verifier.build_verifier_commands = lambda expected_commit, expected_version: [
            ["python", "one.py"],
            ["python", "two.py"],
        ]

        def fake_run_command(command):
            if command[-1] == "one.py":
                return {
                    "command": command,
                    "returncode": 0,
                    "stdout": "first-ok\n",
                    "stderr": "",
                }
            return {
                "command": command,
                "returncode": 1,
                "stdout": "",
                "stderr": "second-failed\n",
            }

        verifier.run_command = fake_run_command
        argv = sys.argv
        sys.argv = ["verify_live_system.py"]
        try:
            with redirect_stdout(stdout), redirect_stderr(stderr):
                exit_code = verifier.main()
        finally:
            sys.argv = argv

        self.assertEqual(exit_code, 1)
        self.assertIn('command=["python", "one.py"] returncode=0', stdout.getvalue())
        self.assertIn('command=["python", "two.py"] returncode=1', stdout.getvalue())
        self.assertIn("live verification failed for command:", stderr.getvalue())
        self.assertIn("stderr_last=second-failed", stderr.getvalue())

    def test_live_system_main_reports_failed_launch_result_cleanly(self):
        verifier = load_script_module(
            "verify_live_system_script",
            "scripts/verify_live_system.py",
        )
        stdout = io.StringIO()
        stderr = io.StringIO()

        verifier.build_verifier_commands = lambda expected_commit, expected_version: [
            ["python", "missing.py"],
        ]
        verifier.run_command = lambda command: {
            "command": command,
            "returncode": 1,
            "stdout": "",
            "stderr": "launch failed",
        }
        argv = sys.argv
        sys.argv = ["verify_live_system.py"]
        try:
            with redirect_stdout(stdout), redirect_stderr(stderr):
                exit_code = verifier.main()
        finally:
            sys.argv = argv

        self.assertEqual(exit_code, 1)
        self.assertIn('command=["python", "missing.py"] returncode=1', stdout.getvalue())
        self.assertIn("stderr_last=launch failed", stderr.getvalue())
        self.assertIn("live verification failed for command:", stderr.getvalue())

    def test_live_system_run_cli_converts_unexpected_error_to_clean_exit(self):
        verifier = load_script_module(
            "verify_live_system_script",
            "scripts/verify_live_system.py",
        )
        stderr = io.StringIO()

        verifier.main = lambda: (_ for _ in ()).throw(RuntimeError("live system boom"))

        with redirect_stderr(stderr):
            exit_code = verifier.run_cli()

        self.assertEqual(exit_code, 1)
        self.assertEqual(stderr.getvalue().strip(), "live system boom")

    def test_full_system_main_returns_failure_when_a_step_fails(self):
        verifier = load_script_module(
            "verify_full_system_script",
            "scripts/verify_full_system.py",
        )
        stdout = io.StringIO()
        stderr = io.StringIO()

        verifier.build_verification_commands = lambda expected_commit, expected_version, include_recovery=False: [
            {"name": "python_contracts", "command": ["python", "one.py"], "workdir": str(ROOT)},
            {"name": "live_system", "command": ["python", "two.py"], "workdir": str(ROOT)},
        ]

        def fake_run_command(command, workdir):
            if command[-1] == "one.py":
                return {
                    "command": command,
                    "workdir": workdir,
                    "returncode": 0,
                    "stdout": "first-ok\n",
                    "stderr": "",
                }
            return {
                "command": command,
                "workdir": workdir,
                "returncode": 1,
                "stdout": "",
                "stderr": "step-failed\n",
            }

        verifier.run_command = fake_run_command
        argv = sys.argv
        sys.argv = ["verify_full_system.py"]
        try:
            with redirect_stdout(stdout), redirect_stderr(stderr):
                exit_code = verifier.main()
        finally:
            sys.argv = argv

        self.assertEqual(exit_code, 1)
        self.assertIn("step=python_contracts", stdout.getvalue())
        self.assertIn("step=live_system", stdout.getvalue())
        self.assertIn("full-system verification failed at step live_system", stderr.getvalue())
        self.assertIn("stderr_last=step-failed", stderr.getvalue())

    def test_full_system_main_reports_failed_launch_result_cleanly(self):
        verifier = load_script_module(
            "verify_full_system_script",
            "scripts/verify_full_system.py",
        )
        stdout = io.StringIO()
        stderr = io.StringIO()

        verifier.build_verification_commands = lambda expected_commit, expected_version, include_recovery=False: [
            {"name": "python_contracts", "command": ["python", "missing.py"], "workdir": str(ROOT)},
        ]
        verifier.run_command = lambda command, workdir: {
            "command": command,
            "workdir": workdir,
            "returncode": 1,
            "stdout": "",
            "stderr": "launch failed",
        }
        argv = sys.argv
        sys.argv = ["verify_full_system.py"]
        try:
            with redirect_stdout(stdout), redirect_stderr(stderr):
                exit_code = verifier.main()
        finally:
            sys.argv = argv

        self.assertEqual(exit_code, 1)
        self.assertIn("step=python_contracts", stdout.getvalue())
        self.assertIn("stderr_last=launch failed", stderr.getvalue())
        self.assertIn("full-system verification failed at step python_contracts", stderr.getvalue())

    def test_full_system_run_cli_converts_unexpected_error_to_clean_exit(self):
        verifier = load_script_module(
            "verify_full_system_script",
            "scripts/verify_full_system.py",
        )
        stderr = io.StringIO()

        verifier.main = lambda: (_ for _ in ()).throw(RuntimeError("full system boom"))

        with redirect_stderr(stderr):
            exit_code = verifier.run_cli()

        self.assertEqual(exit_code, 1)
        self.assertEqual(stderr.getvalue().strip(), "full system boom")


if __name__ == "__main__":
    unittest.main()
