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
        self.assertIn("live_state_agent_rows_for(current, agentLimit)", body)
        self.assertIn("live_state_job_rows_for(current, jobLimit)", body)
        self.assertNotIn("visible_agent_rows_for(current)", body)
        self.assertNotIn("visible_job_rows_for(current)", body)
        self.assertNotIn(".map((job) => public_job_payload(job))", body)
        self.assertNotIn("snapshots:", body)
        self.assertIn("limits:", body)
        self.assertIn("truncated:", body)

    def test_live_state_limits_stay_small_enough_for_dashboard_polling(self):
        source = (ROOT / "business" / "control_plane.tru").read_text(
            encoding="utf-8"
        )
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

    def test_live_state_removes_snapshot_queries(self):
        source = (ROOT / "business" / "control_plane.tru").read_text(
            encoding="utf-8"
        )
        self.assertNotIn("function live_state_snapshot_limit()", source)
        self.assertNotIn("function live_state_snapshot_rows_for(", source)

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

    def test_sync_jobs_carry_merge_replication_metadata(self):
        source = (ROOT / "business" / "control_plane.tru").read_text(
            encoding="utf-8"
        )
        client_api = (
            ROOT / "sync_windows_agent" / "lib" / "live_sync_api.dart"
        ).read_text(encoding="utf-8")

        self.assertIn("field replicationUseWindowsAuth: bool", source)
        self.assertIn("field replicationUser: string min=0 max=256", source)
        self.assertIn("field replicationPassword: string min=0 max=256", source)
        self.assertIn("field mergeRole: string min=0 max=32", source)
        self.assertIn("field publisherServer: string min=0 max=256", source)
        self.assertIn("field publisherDatabase: string min=0 max=256", source)
        self.assertIn("field publicationName: string min=0 max=256", source)
        self.assertIn("field publisherUseWindowsAuth: bool", source)
        self.assertIn("publisherUser: job.publisherUser", source)
        self.assertIn("publisherPassword: job.publisherPassword", source)
        self.assertIn("required this.publisherServer,", client_api)
        self.assertIn("required this.publisherDatabase,", client_api)
        self.assertIn("required this.publicationName,", client_api)

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

    def test_agent_heartbeat_persists_replication_connection_settings(self):
        source = (ROOT / "business" / "control_plane.tru").read_text(
            encoding="utf-8"
        )

        self.assertIn("replicationUseWindowsAuth: bool = true", source)
        self.assertIn("replicationUser: string = ''", source)
        self.assertIn("replicationPassword: string = ''", source)
        self.assertIn("replicationUseWindowsAuth,", source)
        self.assertIn("replicationUser,", source)
        self.assertIn("replicationPassword,", source)

    def test_ensure_agent_repairs_stale_rows_before_recreating_them(self):
        source = (ROOT / "business" / "control_plane.tru").read_text(
            encoding="utf-8"
        )
        ensure_agent_match = re.search(
            r"function ensure_agent\(.*?\): map<json> \{(?P<body>.*?)\n\}",
            source,
            flags=re.S,
        )
        self.assertIsNotNone(ensure_agent_match)
        body = ensure_agent_match.group("body")

        self.assertIn("try {", body)
        self.assertIn("const existing = db.selectOne(Agent, { clientName });", body)
        self.assertIn("} catch (err) {", body)
        self.assertIn("const repaired = db.update(Agent, { clientName }, {", body)
        self.assertIn("tableRelationships: [],", body)
        self.assertIn("diagnosticStatus: 'idle',", body)
        self.assertIn("db.delete(Agent, { clientName });", body)
        self.assertIn("return db.insert(Agent, {", body)

    def test_jobs_create_pairs_publication_and_subscription_for_remote_source(self):
        source = (ROOT / "business" / "control_plane.tru").read_text(
            encoding="utf-8"
        )

        self.assertIn("sourceAgent = db.selectOne(Agent, { clientName: resolvedSourceClientName });", source)
        self.assertIn("return raw_json_error(404, 'source client not found');", source)
        self.assertIn("mergeRole: 'publisher'", source)
        self.assertIn("mergeRole: 'subscriber'", source)
        self.assertIn("message: string.concat('Queued merge publication for ', table, '.')", source)
        self.assertIn("message: string.concat('Queued merge subscription for ', table, '.')", source)

    def test_windows_agent_uses_replication_procedures_instead_of_snapshot_transport(self):
        source = (ROOT / "sync_windows_agent" / "lib" / "agent_page.dart").read_text(
            encoding="utf-8"
        )

        self.assertIn("Future<void> _processReplicationPublisherJob(RemoteSyncJob job) async {", source)
        self.assertIn("Future<void> _processReplicationSubscriberJob(RemoteSyncJob job) async {", source)
        self.assertIn("EXEC sp_addmergepublication", source)
        self.assertIn("EXEC sp_addmergearticle", source)
        self.assertIn("EXEC sp_addmergepullsubscription", source)
        self.assertIn("EXEC sp_addmergepullsubscription_agent", source)
        self.assertNotIn("Future<void> _processUploadJob(RemoteSyncJob job) async {", source)

    def test_control_plane_advertises_merge_replication_engine(self):
        source = (ROOT / "business" / "control_plane.tru").read_text(
            encoding="utf-8"
        )

        self.assertIn("function sync_engine_metadata(): map<json>", source)
        self.assertIn("mode: 'mergeReplication'", source)
        self.assertIn("centralStore: 'sqlserver'", source)
        self.assertIn("sqlServerMergeReplication: true", source)
        self.assertIn("legacySnapshotCompatibility: false", source)
        self.assertIn("syncEngine: sync_engine_metadata()", source)


if __name__ == "__main__":
    unittest.main()
