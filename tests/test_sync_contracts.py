import unittest
from pathlib import Path


ROOT = Path(__file__).resolve().parents[1]


def read_text(relative_path: str) -> str:
    return (ROOT / relative_path).read_text(encoding="utf-8")


class SyncContractsTests(unittest.TestCase):
    def test_windows_agent_writes_symmetricds_config_without_snapshot_apply(self):
        agent_page = read_text("sync_windows_agent/lib/agent_page.dart")
        symmetricds_service = read_text("sync_windows_agent/lib/symmetricds_service.dart")

        self.assertIn("SymmetricDsService", agent_page)
        self.assertIn("writeNodeConfig", agent_page)
        self.assertIn("registrationUrl", symmetricds_service)
        self.assertIn("path: '/sync/server'", agent_page)
        self.assertIn("db.driver=com.microsoft.sqlserver.jdbc.SQLServerDriver", symmetricds_service)
        self.assertIn("sqlsync.table.selection.file", symmetricds_service)
        self.assertIn("bootstrapSqlPath", symmetricds_service)
        self.assertIn("runtimeStatus", symmetricds_service)
        self.assertIn("Process.start", symmetricds_service)
        self.assertIn("'--properties', propertiesPath", symmetricds_service)
        self.assertIn("'--server'", symmetricds_service)
        self.assertIn("workingDirectory: command.installRoot", symmetricds_service)
        self.assertIn("class _SymmetricDsCommand", symmetricds_service)
        self.assertIn("runtime-missing", symmetricds_service)
        self.assertIn("sym_trigger", symmetricds_service)
        self.assertIn("sym_router", symmetricds_service)
        self.assertIn("sym_trigger_router", symmetricds_service)
        self.assertIn("client_2_server", symmetricds_service)
        self.assertIn("server_2_client", symmetricds_service)
        self.assertIn("_applySymmetricDsBootstrapIfReady", agent_page)
        self.assertIn("OBJECT_ID(N'dbo.sym_trigger'", agent_page)
        self.assertIn("OBJECT_ID(N'dbo.sym_router'", agent_page)
        self.assertIn("OBJECT_ID(N'dbo.sym_trigger_router'", agent_page)
        self.assertIn("bootstrap-applied", agent_page)
        self.assertIn("SymmetricDS bootstrap SQL applied.", agent_page)
        self.assertNotIn("MERGE $qualifiedTable AS target", agent_page)
        self.assertNotIn("DELETE FROM $qualifiedTable", agent_page)
        self.assertNotIn("TRUNCATE TABLE", agent_page)

    def test_portable_build_bundles_symmetricds_runtime(self):
        build_script = read_text("build_portable.ps1")
        publish_script = read_text("scripts/publish_windows_client_update.ps1")
        windows_build_script = read_text("scripts/windows_agent_build.ps1")

        self.assertIn("^Flutter\\s+[0-9]+\\.[0-9]+\\.[0-9]+\\b", build_script)
        self.assertIn("$SymmetricDsVersion = '3.16.10'", build_script)
        self.assertIn("Install-SymmetricDsRuntime", build_script)
        self.assertIn("symmetric-server-$Version.zip", build_script)
        self.assertIn("Test-ZipFileSignature", build_script)
        self.assertIn("Resolve-SourceForgeMirrorUrl", build_script)
        self.assertIn("Save-VerifiedZip", build_script)
        self.assertIn("symmetricds-$minorVersion", build_script)
        self.assertIn('return "$commit-dirty"', windows_build_script)
        self.assertIn('return "$commit-dirty"', publish_script)
        self.assertIn("symmetricds\\bin\\sym.bat", build_script)
        self.assertIn("$PortableName/symmetricds/bin/sym.bat", build_script)
        self.assertIn("Assert-ClientUpdateZipContents", publish_script)
        self.assertIn("$PortableName/symmetricds/bin/sym.bat", publish_script)
        self.assertIn("Portable client update ZIP is missing required entry", publish_script)
        self.assertIn("SymmetricDsVersion = '3.16.10'", publish_script)
        self.assertIn("Remove-Item -LiteralPath $debugKernelPath -Force", build_script)
        self.assertIn("-arch=x64 -host_arch=x64", windows_build_script)
        self.assertIn(
            "Invoke-FlutterCommand `\n            -FlutterCommand $flutterCommand `\n            -Arguments $buildArguments `\n            -WorkingDirectory $ProjectPath",
            build_script,
        )

    def test_windows_agent_restores_local_snapshot_relay_helpers(self):
        agent_page = read_text("sync_windows_agent/lib/agent_page.dart")

        self.assertIn("Future<void> _processSnapshotRelayUploadJob(", agent_page)
        self.assertIn("Future<void> _processSnapshotRelayDownloadJob(", agent_page)
        self.assertIn("Future<_RelaySnapshotDocument> _createRelaySnapshotForJob(", agent_page)
        self.assertIn("Future<int> _applyDownloadedSnapshotToTarget(", agent_page)
        self.assertIn("required RemoteSnapshot snapshot", agent_page)
        self.assertIn("Downloading compressed snapshot", agent_page)

    def test_windows_agent_prefers_server_published_update_script(self):
        agent_page = read_text("sync_windows_agent/lib/agent_page.dart")

        self.assertIn("List<String> _clientUpdatePowerShellArgs(ClientUpdateInfo updateInfo)", agent_page)
        self.assertIn("if (scriptUrl.isNotEmpty) {", agent_page)
        self.assertIn("Invoke-WebRequest -UseBasicParsing ", agent_page)
        self.assertIn("if (localScriptPath != null) {", agent_page)

    def test_windows_agent_client_restores_snapshot_transport_endpoints(self):
        client_api = read_text("sync_windows_agent/lib/live_sync_api.dart")
        agent_page = read_text("sync_windows_agent/lib/agent_page.dart")

        self.assertIn("Future<UploadSnapshotResult> uploadSnapshot(", client_api)
        self.assertIn("Future<RemoteSnapshot> downloadSnapshot(", client_api)
        self.assertIn("jobs_upload_chunk_start", client_api)
        self.assertIn("jobs_download_snapshot_manifest", client_api)
        self.assertIn("Future<void> _processSnapshotRelayUploadJob(", agent_page)
        self.assertIn("Future<void> _processSnapshotRelayDownloadJob(", agent_page)
        self.assertIn("_processUnsupportedLegacyJob(job);", agent_page)

    def test_control_plane_defaults_to_symmetricds_sync_jobs(self):
        control_plane = read_text("business/control_plane.tru")

        self.assertIn(
            "function jobs_create(clientName: string, tables: array<string>, direction: string = 'sync'",
            control_plane,
        )
        self.assertIn("direction: direction_for_sync_mode(resolvedMode)", control_plane)
        self.assertIn("message: string.concat('Queued SymmetricDS sync for ', table, '.')", control_plane)
        self.assertIn("mergeRole: 'symmetricds'", control_plane)
        self.assertIn("function merge_publication_name(clientName: string, table: string): string", control_plane)

    def test_legacy_sync_modes_and_custom_transport_fallback_are_removed(self):
        control_plane = read_text("business/control_plane.tru")
        sync_state = read_text("sync_windows_agent/lib/sync_state.dart")
        client_api = read_text("sync_windows_agent/lib/live_sync_api.dart")
        agent_page = read_text("sync_windows_agent/lib/agent_page.dart")
        node_server = read_text("frontend/server.js")

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
        self.assertIn("uploadSnapshot(", client_api)
        self.assertIn("downloadSnapshot(", client_api)
        self.assertNotIn("_processUploadJob(job)", agent_page)
        self.assertIn("SymmetricDS config", agent_page + read_text("sync_windows_agent/lib/symmetricds_service.dart"))
        self.assertNotIn("/api/snapshots/latest", node_server)
        self.assertNotIn("/api/snapshots/import", node_server)
        self.assertNotIn("download-snapshot-manifest", node_server)
        self.assertNotIn("upload-chunk-start", node_server)

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
        self.assertIn("let createdJobsRaw = [];", control_plane)
        self.assertIn("for (const table of tablesToCreate) {", control_plane)
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

    def test_windows_agent_normalizes_database_qualified_table_names(self):
        agent_page = read_text("sync_windows_agent/lib/agent_page.dart")

        self.assertIn("String _stripKnownDatabaseAndDefaultSchema(", agent_page)
        self.assertIn("final databasePrefix = '$databaseName.';", agent_page)
        self.assertIn("tableName = tableName.substring(databasePrefix.length);", agent_page)
        self.assertIn(
            "_stripKnownDatabaseAndDefaultSchema(\n      table,\n      database: databaseName,",
            agent_page,
        )
        self.assertNotIn("velvet::velvet.dbo", agent_page)

    def test_windows_agent_does_not_execute_legacy_merge_roles(self):
        agent_page = read_text("sync_windows_agent/lib/agent_page.dart")
        symmetricds_service = read_text("sync_windows_agent/lib/symmetricds_service.dart")

        self.assertNotIn("CASE WHEN uk.column_id IS NULL THEN 0 ELSE 1 END AS is_unique_key", agent_page)
        self.assertNotIn("uniqueKeyOrdinal", agent_page)
        self.assertNotIn("job.mergeRole == 'publisher'", agent_page)
        self.assertNotIn("job.mergeRole == 'subscriber'", agent_page)
        self.assertIn("sym_trigger", symmetricds_service)
        self.assertIn("sym_trigger_router", symmetricds_service)

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

    def test_visible_sync_copy_uses_symmetricds_namespace_terms(self):
        dashboard = read_text("frontend/lib/dashboard_page.dart")
        sample_data = read_text("sync_windows_agent/lib/sample_data.dart")
        agent_page = read_text("sync_windows_agent/lib/agent_page.dart")
        visible_copy = dashboard + sample_data + agent_page

        self.assertIn("SymmetricDS", agent_page)
        self.assertIn("SymmetricDS config", visible_copy)
        self.assertIn("SymmetricDS", dashboard)
        self.assertIn("agent.symmetricDs", dashboard)
        for legacy_text in (
            "finance-master",
            "sink agents",
            "batches pushed",
            "POSTGRES CUSTOM SYNC",
            "cloud namespace snapshot sources",
            "Uploaded by namespace source",
            "master snapshot",
        ):
            self.assertNotIn(legacy_text, visible_copy)

    def test_helm_declares_symmetricds_engine_mode(self):
        values = read_text("deployment/chart/values.yaml")
        backend_deployment = read_text("deployment/chart/templates/backend-deployment.yaml")
        frontend_deployment = read_text("deployment/chart/templates/deployment.yaml")
        control_plane = read_text("business/control_plane.tru")

        self.assertIn("syncEngine:\n  mode: symmetricDs", values)
        self.assertNotIn("postgresCustomSync", values)
        self.assertIn("SQL_SYNC_ENGINE_MODE", backend_deployment)
        self.assertIn("SQL_SYNC_ENGINE_MODE", frontend_deployment)
        self.assertIn("function sync_engine_metadata(): map<json>", control_plane)
        self.assertIn("mode: 'symmetricDs'", control_plane)
        self.assertIn("centralStore: 'symmetricds'", control_plane)
        self.assertIn("sqlServerMergeReplication: false", control_plane)
        self.assertIn("symmetricDs: true", control_plane)
        self.assertIn("syncEngine: sync_engine_metadata()", control_plane)


if __name__ == "__main__":
    unittest.main()
