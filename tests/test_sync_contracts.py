import unittest
from pathlib import Path


ROOT = Path(__file__).resolve().parents[1]


def read_text(relative_path: str) -> str:
    return (ROOT / relative_path).read_text(encoding="utf-8")


class SyncContractsTests(unittest.TestCase):
    def test_windows_agent_applies_merge_only_without_destructive_table_clear(self):
        agent_page = read_text("sync_windows_agent/lib/agent_page.dart")

        self.assertIn("MERGE $qualifiedTable AS target", agent_page)
        self.assertIn("WHEN NOT MATCHED BY TARGET THEN", agent_page)
        self.assertNotIn("WHEN MATCHED", agent_page)
        self.assertNotIn("DELETE FROM $qualifiedTable", agent_page)
        self.assertNotIn("TRUNCATE TABLE", agent_page)

    def test_windows_merge_preserves_identity_primary_keys_for_missing_rows(self):
        agent_page = read_text("sync_windows_agent/lib/agent_page.dart")

        self.assertIn("final writeColumns = writableSnapshotColumns;", agent_page)
        self.assertIn("if (primaryKeys.isNotEmpty) {\n      return primaryKeys;", agent_page)
        self.assertIn("if (hasIdentity) 'SET IDENTITY_INSERT $qualifiedTable ON;'", agent_page)
        self.assertIn("if (hasIdentity) {\n      statements.add('SET IDENTITY_INSERT $qualifiedTable OFF;');", agent_page)
        self.assertIn("jsonEncode(keyColumns.map((column) => row[column]).toList())", agent_page)
        self.assertNotIn("nonIdentityWritableColumns", agent_page)

    def test_snapshot_download_uses_bounded_manifest_only(self):
        client_api = read_text("sync_windows_agent/lib/live_sync_api.dart")
        control_plane = read_text("business/control_plane.tru")

        self.assertIn("jobs_download_snapshot_manifest", client_api)
        self.assertIn("jobs_download_snapshot_chunk", client_api)
        self.assertNotIn("_downloadSnapshotLegacy", client_api)
        self.assertNotIn("function jobs_download_snapshot(", control_plane)

    def test_control_plane_defaults_to_merge_sync_jobs(self):
        control_plane = read_text("business/control_plane.tru")

        self.assertIn(
            "function jobs_create(clientName: string, tables: array<string>, direction: string = 'sync'",
            control_plane,
        )
        self.assertIn("direction: direction_for_sync_mode(resolvedMode)", control_plane)
        self.assertIn("message: string.concat('Queued merge sync for ', table, '.')", control_plane)

    def test_legacy_sync_modes_and_direct_upload_endpoint_are_removed(self):
        control_plane = read_text("business/control_plane.tru")
        sync_state = read_text("sync_windows_agent/lib/sync_state.dart")

        self.assertNotIn("function jobs_upload(", control_plane)
        for legacy_alias in (
            "'bidirectional'",
            "'twoWay'",
            "'masterMix'",
            "'mix'",
            "'master'",
            "'upload'",
            "'client'",
            "'download'",
        ):
            self.assertNotIn(legacy_alias, sync_state)
        for legacy_condition in (
            "value == 'bidirectional'",
            "value == 'twoWay'",
            "value == 'masterMix'",
            "value == 'mix'",
            "value == 'master'",
            "value == 'upload'",
            "value == 'client'",
            "value == 'download'",
        ):
            self.assertNotIn(legacy_condition, control_plane)

    def test_related_table_metadata_stays_in_app_state(self):
        control_plane = read_text("business/control_plane.tru")
        agent_page = read_text("sync_windows_agent/lib/agent_page.dart")
        client_api = read_text("sync_windows_agent/lib/live_sync_api.dart")

        self.assertIn("field tableRelationships: array<json>", control_plane)
        self.assertIn("table_dependency_policy_set", control_plane)
        self.assertIn("tableDependencies: table_dependency_payloads_for_database", control_plane)
        self.assertIn("tableRelationships: _tableRelationshipsPayload()", agent_page)
        self.assertIn("RemoteTableDependency", client_api)

    def test_selected_sync_queues_related_table_package(self):
        control_plane = read_text("business/control_plane.tru")
        agent_page = read_text("sync_windows_agent/lib/agent_page.dart")

        self.assertIn("function expand_sync_job_tables_for_owner", control_plane)
        self.assertIn("related_table_sync_keys_for_policy(ownerUserId, normalizedTable)", control_plane)
        self.assertIn("const expandedTables = expand_sync_job_tables_for_owner(agent.ownerUserId, tables)", control_plane)
        self.assertIn("const rows = tablesToCreate.map((table) =>", control_plane)
        self.assertIn("const expandedTables = expand_sync_job_tables_for_owner(ownerId, tables)", control_plane)
        self.assertIn("const createdJobsRaw = tablesToCreate.map((table) =>", control_plane)
        self.assertIn("return raw_json_success({ jobs: [] }, 201);", control_plane)
        self.assertIn("final tablesToQueue = <String>{", agent_page)
        self.assertIn("..._relatedSyncKeysFor(syncKey)", agent_page)
        self.assertIn("tables: tablesToQueue", agent_page)
        self.assertIn("Queue sync for $selectedTable and related tables", agent_page)
        self.assertIn("for (const dependency of dependencies)", control_plane)
        self.assertIn("state.related.length == previousRelatedCount", control_plane)
        self.assertNotIn(
            "state = expand_related_table_sync_keys_once(dependencies, databaseName, state.visited, state.related);\n"
            "  state = expand_related_table_sync_keys_once(dependencies, databaseName, state.visited, state.related);\n"
            "  state = expand_related_table_sync_keys_once(dependencies, databaseName, state.visited, state.related);\n"
            "  state = expand_related_table_sync_keys_once(dependencies, databaseName, state.visited, state.related);\n"
            "  state = expand_related_table_sync_keys_once(dependencies, databaseName, state.visited, state.related);\n"
            "  state = expand_related_table_sync_keys_once(dependencies, databaseName, state.visited, state.related);\n"
            "  state = expand_related_table_sync_keys_once(dependencies, databaseName, state.visited, state.related);\n"
            "  state = expand_related_table_sync_keys_once(dependencies, databaseName, state.visited, state.related);",
            control_plane,
        )

    def test_web_dashboard_exposes_merge_sync_not_push_pull_jobs(self):
        dashboard = read_text("frontend/lib/dashboard_page.dart")
        web_api = read_text("frontend/lib/live_sync_api.dart")
        models = read_text("frontend/lib/models.dart")

        self.assertIn("label: 'Sync'", dashboard)
        self.assertIn("Merge sync queued", dashboard)
        self.assertIn("'direction': 'sync'", web_api)
        self.assertIn("'syncMode': 'sync'", web_api)
        self.assertIn("syncMode: json['syncMode'] as String? ?? 'sync'", models)
        self.assertNotIn("label: 'Push'", dashboard)
        self.assertNotIn("label: 'Pull'", dashboard)
        self.assertNotIn("direction: 'upload'", dashboard)
        self.assertNotIn("direction: 'download'", dashboard)

    def test_visible_sync_copy_uses_merge_namespace_terms(self):
        dashboard = read_text("frontend/lib/dashboard_page.dart")
        sample_data = read_text("sync_windows_agent/lib/sample_data.dart")
        visible_copy = dashboard + sample_data

        self.assertIn("cloud namespace snapshot sources", dashboard)
        self.assertIn("Uploaded by namespace source", dashboard)
        self.assertIn("Orders and Inventory rows were merged through the cloud namespace.", sample_data)
        for legacy_text in (
            "finance-master",
            "sink agents",
            "batches pushed",
            "Uploaded by master",
            "master snapshot",
            "merged this master",
        ):
            self.assertNotIn(legacy_text, visible_copy)

    def test_helm_declares_merge_replication_mode_for_central_server(self):
        values = read_text("deployment/chart/values.yaml")
        backend_deployment = read_text("deployment/chart/templates/backend-deployment.yaml")
        frontend_deployment = read_text("deployment/chart/templates/deployment.yaml")

        self.assertIn("syncEngine:\n  mode: mergeReplication", values)
        self.assertIn("SQL_SYNC_ENGINE_MODE", backend_deployment)
        self.assertIn("SQL_SYNC_ENGINE_MODE", frontend_deployment)


if __name__ == "__main__":
    unittest.main()
