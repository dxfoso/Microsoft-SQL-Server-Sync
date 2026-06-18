import pathlib
import re
import unittest


ROOT = pathlib.Path(__file__).resolve().parents[1]


class ControlPlaneContractsTests(unittest.TestCase):
    def test_live_state_uses_bounded_payload_helpers(self):
        source = (ROOT / "business" / "control_plane.tru").read_text(
            encoding="utf-8"
        )
        live_state_match = re.search(
            r"function live_state\(.*?\): map<json> \{(?P<body>.*?)\n\}",
            source,
            flags=re.S,
        )
        self.assertIsNotNone(live_state_match)
        body = live_state_match.group("body")

        self.assertIn("bounded_public_agent_payloads", body)
        self.assertIn("bounded_public_job_payloads", body)
        self.assertIn("bounded_public_snapshot_payloads", body)
        self.assertNotIn(".map((job) => public_job_payload(job))", body)
        self.assertIn("limits:", body)
        self.assertIn("truncated:", body)

    def test_live_state_limits_stay_small_enough_for_dashboard_polling(self):
        source = (ROOT / "business" / "control_plane.tru").read_text(
            encoding="utf-8"
        )
        limits = {
            name: int(value)
            for name, value in re.findall(
                r"function live_state_(agent|job|snapshot)_limit\(\): int \{\s+return (\d+);",
                source,
                flags=re.S,
            )
        }

        self.assertEqual(limits["agent"], 500)
        self.assertLessEqual(limits["job"], 200)
        self.assertLessEqual(limits["snapshot"], 200)


if __name__ == "__main__":
    unittest.main()
