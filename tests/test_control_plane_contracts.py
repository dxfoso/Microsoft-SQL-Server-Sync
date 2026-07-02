import pathlib
import re
import unittest


ROOT = pathlib.Path(__file__).resolve().parents[1]


def read_text(relative_path: str) -> str:
    return (ROOT / relative_path).read_text(encoding="utf-8")


class ControlPlaneContractsTests(unittest.TestCase):
    def test_live_state_uses_bounded_payload_helpers(self):
        source = read_text("business/control_plane.tru")
        live_state_match = re.search(
            r"function live_state\(.*?\): map<json> \{(?P<body>.*?)\n\}",
            source,
            flags=re.S,
        )
        self.assertIsNotNone(live_state_match)
        body = live_state_match.group("body")

        self.assertIn("bounded_public_agent_payloads", body)
        self.assertIn("bounded_public_job_payloads", body)
        self.assertIn("live_state_agent_rows_for(current, agentLimit)", body)
        self.assertIn("live_state_job_rows_for(current, jobLimit)", body)
        self.assertNotIn("syncEngine:", body)

    def test_live_state_limits_stay_bounded(self):
        source = read_text("business/control_plane.tru")
        limits = {
            name: int(value)
            for name, value in re.findall(
                r"function live_state_(agent|job)_limit\(\): int \{\s+return (\d+);",
                source,
                flags=re.S,
            )
        }

        self.assertEqual(limits["agent"], 100)
        self.assertLessEqual(limits["job"], 50)

    def test_agent_rows_omit_heavy_payload_fields(self):
        source = read_text("business/control_plane.tru")
        match = re.search(
            r"function live_state_agent_rows_for\(.*?\): array<json> \{(?P<body>.*?)\n\}",
            source,
            flags=re.S,
        )
        self.assertIsNotNone(match)
        body = match.group("body")

        self.assertIn("limit: limit + 1", body)
        self.assertNotIn("'tables'", body)
        self.assertNotIn("diagnosticPayload", body)

    def test_job_schema_keeps_only_current_snapshot_fields(self):
        source = read_text("business/control_plane.tru")
        client_api = read_text("sync_windows_agent/lib/live_sync_api.dart")

        self.assertIn("field sourceClientName: string min=0 max=128", source)
        self.assertIn("field subscriberClientName: string min=0 max=128", source)
        self.assertIn("field publisherServer: string min=0 max=256", source)
        self.assertIn("field publisherDatabase: string min=0 max=256", source)
        self.assertIn("field publisherUseWindowsAuth: bool", source)
        self.assertIn("field publisherUser: string min=0 max=256", source)
        self.assertIn("field publisherPassword: string min=0 max=256", source)
        self.assertNotIn("field mergeRole: string min=0 max=32", source)
        self.assertNotIn("field publicationName: string min=0 max=256", source)
        self.assertIn("required this.publisherServer,", client_api)
        self.assertIn("required this.publisherDatabase,", client_api)
        self.assertNotIn("required this.mergeRole,", client_api)
        self.assertNotIn("required this.publicationName,", client_api)
        self.assertNotIn("final String syncMode;", client_api)
        self.assertNotIn("required String direction,", client_api)

    def test_agent_heartbeat_persists_replication_connection_settings(self):
        source = read_text("business/control_plane.tru")

        self.assertIn("replicationUseWindowsAuth: bool = true", source)
        self.assertIn("replicationUser: string = ''", source)
        self.assertIn("replicationPassword: string = ''", source)
        self.assertIn("clientUpdate: agent_client_update_payload(nextAgent)", source)
        self.assertNotIn("symmetricDsStatus", source)
        self.assertNotIn("agent_symmetricds_status_post", source)

    def test_control_plane_exposes_server_requested_client_updates(self):
        source = read_text("business/control_plane.tru")

        self.assertIn("field clientUpdateRequestId: string? min=0 max=64", source)
        self.assertIn("field clientUpdateStatus: string min=0 max=32", source)
        self.assertIn("function agent_client_update_payload(agent: map<json>): map<json> {", source)
        self.assertIn("function agent_client_update_request(clientName: string, targetVersion: string? = null, token: string? = null): map<json> {", source)
        self.assertIn("function agent_client_update_request_all(targetVersion: string? = null, token: string? = null): map<json> {", source)
        self.assertIn("function agent_client_update_ack(clientName: string? = null, requestId: string? = null, status: string = 'current', installedVersion: string = '', message: string = '', token: string? = null): map<json> {", source)

    def test_ensure_agent_repairs_stale_rows_before_recreating_them(self):
        source = read_text("business/control_plane.tru")
        match = re.search(
            r"function ensure_agent\(.*?\): map<json> \{(?P<body>.*?)\n\}",
            source,
            flags=re.S,
        )
        self.assertIsNotNone(match)
        body = match.group("body")

        self.assertIn("const repaired = db.update(Agent, { clientName }, {", body)
        self.assertIn("tableRelationships: [],", body)
        self.assertIn("diagnosticStatus: 'idle',", body)
        self.assertNotIn("symmetricDsStatus", body)

    def test_table_policy_path_no_longer_keeps_legacy_key_normalizers(self):
        source = read_text("business/control_plane.tru")
        agent_page = read_text("sync_windows_agent/lib/agent_page.dart")

        self.assertNotIn("function normalize_stored_table_sync_policy(", source)
        self.assertNotIn("const compatible = db.selectOne(TableSyncPolicy", source)
        self.assertNotIn("const keyed = db.selectOne(TableSyncPolicy", source)
        self.assertNotIn("compatibleKey =", agent_page)
        self.assertNotIn("dbo.$localTable", agent_page)

    def test_jobs_create_queues_snapshot_sync_for_remote_source(self):
        source = read_text("business/control_plane.tru")

        self.assertIn(
            "const targetAgent = db.selectOne(Agent, { clientName: resolvedClientName });",
            source,
        )
        self.assertIn(
            "nextSourceClientName = preferred_source_client_name_for_agent_table(targetAgent, table, visibleAgents);",
            source,
        )
        self.assertIn(
            "const nextJobs = create_sync_jobs_for_agent(targetAgent, [table], nextSourceClientName);",
            source,
        )
        self.assertIn(
            "function jobs_progress(jobId: string, status: string = 'running', progress: int, message: string, rowCount: int, token: string? = null): map<json> {",
            source,
        )
        self.assertIn("return raw_json_error(404, 'source client not found');", source)
        self.assertIn(
            "message: string.concat('Waiting for source snapshot upload for ', table, '.')",
            source,
        )
        self.assertIn("field syncMode: string min=1 max=32", source)
        self.assertNotIn("mergeRole", source)
        self.assertNotIn("publicationName", source)
        self.assertNotIn("direction: 'sync'", source)
        self.assertNotIn("rowCount: int, direction: string, token: string? = null", source)
        self.assertNotIn("Queued SymmetricDS sync", source)

    def test_snapshot_transport_contract_remains_present(self):
        source = read_text("business/control_plane.tru")
        agent_page = read_text("sync_windows_agent/lib/agent_page.dart")

        self.assertIn("function jobs_upload_chunk_start(", source)
        self.assertIn("function jobs_upload_chunk_complete(", source)
        self.assertIn("function jobs_download_snapshot_manifest(", source)
        self.assertIn("function jobs_download_snapshot_chunk(", source)
        self.assertIn("Future<void> _processSnapshotJob(", agent_page)
        self.assertIn("Future<void> _processSnapshotRelayUploadJob(", agent_page)
        self.assertIn("Future<void> _processSnapshotRelayDownloadJob(", agent_page)
        self.assertNotIn("_runDirectQueuedTableSync(", agent_page)

    def test_source_selection_and_related_tables_remain_active(self):
        source = read_text("business/control_plane.tru")
        agent_page = read_text("sync_windows_agent/lib/agent_page.dart")

        self.assertIn(
            "function preferred_source_client_name_for_agent_table(targetAgent: map<json>, table: string, visibleAgents: array<json>): string {",
            source,
        )
        self.assertIn("const sourceClientName = preferred_source_client_name_for_agent_table(agent, table, visibleAgents);", source)
        self.assertIn("function expand_sync_job_tables_for_owner", source)
        self.assertNotIn("latest_completed_job_tables_for_client", source)
        self.assertNotIn("enabledTables = latest_completed_job_tables_for_client(agent.clientName);", source)
        self.assertIn("final tablesToQueue = <String>{", agent_page)
        self.assertIn("..._relatedSyncKeysFor(syncKey)", agent_page)

    def test_control_plane_no_longer_advertises_old_sync_engine(self):
        source = read_text("business/control_plane.tru")

        self.assertNotIn("function sync_engine_metadata(): map<json>", source)
        self.assertNotIn("syncEngine: sync_engine_metadata()", source)
        self.assertNotIn("centralStore: 'symmetricds'", source)
        self.assertNotIn("mode: 'symmetricDs'", source)


if __name__ == "__main__":
    unittest.main()
