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

    def test_live_state_agent_query_omits_heavy_agent_json(self):
        source = (ROOT / "business" / "control_plane.tru").read_text(
            encoding="utf-8"
        )
        agent_rows_match = re.search(
            r"function live_state_agent_rows_for\(.*?\): array<json> \{(?P<body>.*?)\n\}",
            source,
            flags=re.S,
        )
        self.assertIsNotNone(agent_rows_match)
        body = agent_rows_match.group("body")

        self.assertIn("limit: limit + 1", body)
        self.assertNotIn("'tables'", body)
        self.assertNotIn("diagnosticPayload", body)

    def test_sync_uploads_use_chunked_owner_snapshots_only(self):
        source = (ROOT / "business" / "control_plane.tru").read_text(
            encoding="utf-8"
        )
        client_api = (
            ROOT / "sync_windows_agent" / "lib" / "live_sync_api.dart"
        ).read_text(encoding="utf-8")

        self.assertIn("function max_server_rows_snapshot_count(): int", source)
        self.assertIn("return 50000;", source)
        self.assertIn("function jobs_upload_chunk_start", source)
        self.assertIn("function jobs_upload_chunk_complete", source)
        self.assertIn(
            "chunkCount < 1 || chunkCount > max_chunk_count()",
            source,
        )
        self.assertIn("session.publishOwnerSnapshot == true", source)
        self.assertIn("snapshotClientName = uploadOwnerUserId", source)
        self.assertIn("jobs_upload_chunk_start", client_api)
        self.assertIn("jobs_upload_chunk_complete", client_api)
        self.assertNotIn("jobs_upload_rows_", source)
        self.assertNotIn("jobs_upload_rows_", client_api)
        self.assertNotIn("uploadSnapshotRows", client_api)

    def test_agent_payloads_bound_table_lists_before_policy_application(self):
        source = (ROOT / "business" / "control_plane.tru").read_text(
            encoding="utf-8"
        )

        self.assertIn("function agent_table_payload_limit(): int", source)
        self.assertIn("return 150;", source)
        self.assertIn("function bounded_agent_tables", source)
        self.assertIn(
            "apply_table_sync_policies(agent.ownerUserId, bounded_agent_tables(agent.tables, agent.selectedTable), string.from(agent.database))",
            source,
        )

        heartbeat_match = re.search(
            r"function agents_heartbeat\(.*?\): map<json> \{(?P<body>.*?)\n\}",
            source,
            flags=re.S,
        )
        self.assertIsNotNone(heartbeat_match)
        heartbeat_body = heartbeat_match.group("body")

        self.assertIn(
            "nextTables = bounded_agent_tables(nextTables, selectedTable);",
            heartbeat_body,
        )
        self.assertIn(
            "nextTables = apply_table_sync_policies(ownerUserId, nextTables, database);",
            heartbeat_body,
        )
        self.assertLess(
            heartbeat_body.index("bounded_agent_tables"),
            heartbeat_body.index("apply_table_sync_policies"),
        )

    def test_owner_namespace_uploads_use_chunked_snapshots(self):
        source = (ROOT / "business" / "control_plane.tru").read_text(
            encoding="utf-8"
        )

        self.assertIn("field publishOwnerSnapshot: bool", source)
        self.assertIn("publishOwnerSnapshot: bool = false", source)
        self.assertIn("publishOwnerSnapshot,", source)
        self.assertIn("session.publishOwnerSnapshot == true", source)
        self.assertIn("snapshotClientName = uploadOwnerUserId", source)
        self.assertIn("clientName: snapshotClientName", source)

    def test_chunked_snapshots_can_be_downloaded_by_later_jobs(self):
        source = (ROOT / "business" / "control_plane.tru").read_text(
            encoding="utf-8"
        )

        self.assertIn("function find_download_session_for_snapshot", source)
        self.assertIn("const storedSession = find_download_session_for_snapshot(snapshot.id)", source)
        self.assertIn("storedSession.encoding != 'rows'", source)
        self.assertIn("chunks: storedSession.chunks", source)

    def test_windows_two_way_sync_uses_chunked_owner_snapshot_upload(self):
        source = (ROOT / "sync_windows_agent" / "lib" / "agent_page.dart").read_text(
            encoding="utf-8"
        )
        method_match = re.search(
            r"Future<void> _processUploadJob\(RemoteSyncJob job\) async \{(?P<body>.*?)\n  Future<void> _markRemoteJobFailed",
            source,
            flags=re.S,
        )
        self.assertIsNotNone(method_match)
        body = method_match.group("body")

        self.assertIn("_appendMissingOwnerSnapshotRows", body)
        self.assertIn("_rowsMissingFromOwnerSnapshot", body)
        self.assertNotIn("_rowsMissingOrChangedInOwnerSnapshot", body)
        self.assertIn("uploadSnapshot(", body)
        self.assertIn("publishOwnerSnapshot: true", body)
        self.assertNotIn("uploadSnapshotRows", body)


if __name__ == "__main__":
    unittest.main()
