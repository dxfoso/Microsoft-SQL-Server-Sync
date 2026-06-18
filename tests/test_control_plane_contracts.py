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
        self.assertIn("live_state_agent_rows_for(current, agentLimit)", body)
        self.assertIn("live_state_job_rows_for(current, jobLimit)", body)
        self.assertIn("live_state_snapshot_rows_for(current, snapshotLimit)", body)
        self.assertNotIn("visible_agent_rows_for(current)", body)
        self.assertNotIn("visible_job_rows_for(current)", body)
        self.assertNotIn("visible_snapshot_rows_for(current)", body)
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

        self.assertEqual(limits["agent"], 100)
        self.assertLessEqual(limits["job"], 50)
        self.assertLessEqual(limits["snapshot"], 20)

    def test_live_state_snapshot_query_omits_heavy_preview_rows(self):
        source = (ROOT / "business" / "control_plane.tru").read_text(
            encoding="utf-8"
        )
        snapshot_rows_match = re.search(
            r"function live_state_snapshot_rows_for\(.*?\): array<json> \{(?P<body>.*?)\n\}",
            source,
            flags=re.S,
        )
        self.assertIsNotNone(snapshot_rows_match)
        body = snapshot_rows_match.group("body")

        self.assertIn("limit: limit + 1", body)
        self.assertNotIn("previewRows", body)
        self.assertNotIn("'rows'", body)

    def test_row_uploads_have_server_side_snapshot_bounds(self):
        source = (ROOT / "business" / "control_plane.tru").read_text(
            encoding="utf-8"
        )

        self.assertIn("function max_server_rows_snapshot_count(): int", source)
        self.assertIn("return 50000;", source)
        self.assertIn(
            "rowCount > max_server_rows_snapshot_count()",
            source,
        )
        self.assertIn(
            "(resolvedPageCount * resolvedPageSize) > max_server_rows_snapshot_count()",
            source,
        )
        self.assertIn(
            "normalizedRows.length > session.chunkSizeBytes",
            source,
        )
        self.assertIn(
            "normalizedRows.length > max_server_rows_snapshot_count()",
            source,
        )
        self.assertIn(
            "(existingOwnerSnapshot.rows.length + normalizedRows.length) > max_server_rows_snapshot_count()",
            source,
        )
        self.assertGreaterEqual(source.count("raw_json_error(413"), 5)


if __name__ == "__main__":
    unittest.main()
