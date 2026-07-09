import importlib.util
import pathlib
import unittest
from datetime import datetime, timedelta, timezone


ROOT = pathlib.Path(__file__).resolve().parents[1]


def load_script_module(name: str, relative_path: str):
    path = ROOT / relative_path
    spec = importlib.util.spec_from_file_location(name, path)
    module = importlib.util.module_from_spec(spec)
    assert spec.loader is not None
    spec.loader.exec_module(module)
    return module


class LiveVerifierScriptsTests(unittest.TestCase):
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

    def test_client_update_summarize_client_includes_pending_update_fields(self):
        verifier = load_script_module(
            "verify_live_client_update_script",
            "scripts/verify_live_client_update.py",
        )
        agent = {
            "clientName": "c1",
            "clientVersion": "1.0.90+94",
            "isOnline": True,
            "lastHeartbeat": "2026-07-08T20:49:56.402410997+00:00",
            "clientUpdate": {
                "pending": True,
                "requestId": "req-1",
                "lastRequestId": "req-0",
                "status": "requested",
                "message": "",
                "targetVersion": "1.0.91+95",
            },
        }

        summary = verifier.summarize_client(agent)

        self.assertEqual(summary["clientName"], "c1")
        self.assertEqual(summary["version"], "1.0.90+94")
        self.assertTrue(summary["online"])
        self.assertTrue(summary["pending"])
        self.assertEqual(summary["requestId"], "req-1")
        self.assertEqual(summary["lastRequestId"], "req-0")
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


if __name__ == "__main__":
    unittest.main()
