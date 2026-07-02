import unittest
from pathlib import Path


ROOT = Path(__file__).resolve().parents[1]


def read_text(relative_path: str) -> str:
    return (ROOT / relative_path).read_text(encoding="utf-8")


class SyncContractsTests(unittest.TestCase):
    def test_legacy_sync_migration_records_are_removed(self):
        self.assertFalse((ROOT / "business/migration/mig_20260619_221054.json").exists())
        self.assertFalse((ROOT / "business/migration/mig_20260626_151213.json").exists())
        self.assertFalse((ROOT / "business/migration/mig_20260628_232845.json").exists())
        self.assertFalse((ROOT / "business/migration/mig_20260630_181319.json").exists())

    def test_windows_agent_uses_snapshot_transport_only(self):
        agent_page = read_text("sync_windows_agent/lib/agent_page.dart")
        client_api = read_text("sync_windows_agent/lib/live_sync_api.dart")

        self.assertIn("Future<void> _processSnapshotJob(", agent_page)
        self.assertIn("Future<void> _processSnapshotRelayUploadJob(", agent_page)
        self.assertIn("Future<void> _processSnapshotRelayDownloadJob(", agent_page)
        self.assertIn(
            "throw Exception('Unsupported sync job direction: ${job.direction}')",
            agent_page,
        )
        self.assertIn("uploadSnapshot(", client_api)
        self.assertIn("downloadSnapshot(", client_api)
        self.assertNotIn("_processUnsupportedLegacyJob(job)", agent_page)
        self.assertNotIn("job.mergeRole == 'snapshot'", agent_page)
        self.assertNotIn("_runDirectQueuedTableSync(", agent_page)
        self.assertNotIn("_RemoteTableSyncResult", agent_page)

    def test_symmetricds_client_service_is_removed(self):
        self.assertFalse(
            (ROOT / "sync_windows_agent/lib/symmetricds_service.dart").exists()
        )

        agent_page = read_text("sync_windows_agent/lib/agent_page.dart")
        self.assertNotIn("SymmetricDsService", agent_page)
        self.assertNotIn("_writeSymmetricDsConfig", agent_page)
        self.assertNotIn("_applySymmetricDsBootstrapIfReady", agent_page)

    def test_portable_build_no_longer_bundles_symmetricds(self):
        build_script = read_text("build_portable.ps1")
        publish_script = read_text("scripts/publish_windows_client_update.ps1")

        self.assertNotIn("SymmetricDsVersion", build_script)
        self.assertNotIn("SymmetricDsDownloadUrl", build_script)
        self.assertNotIn("Install-SymmetricDsRuntime", build_script)
        self.assertNotIn("symmetricds\\bin\\sym.bat", build_script)
        self.assertNotIn("symmetricds/bin/sym.bat", publish_script)

    def test_frontend_server_only_serves_static_assets_and_client_updates(self):
        node_server = read_text("frontend/server.js")

        self.assertIn("async function tryServeClientUpdate(", node_server)
        self.assertIn("async function tryServeStatic(", node_server)
        self.assertIn('pathname === "/api/env"', node_server)
        self.assertIn('pathname === "/health"', node_server)
        self.assertNotIn('pathname === "/api/health"', node_server)
        self.assertNotIn('pathname === "/api/ready"', node_server)
        self.assertNotIn('pathname === "/env.js"', node_server)
        self.assertNotIn('pathname === "/api/jobs"', node_server)
        self.assertNotIn('pathname === "/api/auth/login"', node_server)
        self.assertNotIn('pathname === "/api/agents/heartbeat"', node_server)

    def test_flutter_web_uses_tru_call_endpoint(self):
        web_api = read_text("frontend/lib/live_sync_api.dart")
        dashboard = read_text("frontend/lib/dashboard_page.dart")
        web_models = read_text("frontend/lib/models.dart")
        sync_state = read_text("sync_windows_agent/lib/sync_state.dart")

        self.assertIn("defaultValue: '/call'", web_api)
        self.assertIn("_invokeFunction('live_state', {})", web_api)
        self.assertNotIn('"/api/jobs"', web_api)
        self.assertNotIn("SYMMETRICDS", dashboard)
        self.assertNotIn("'syncMode': 'sync'", web_api)
        self.assertNotIn("final String syncMode;", web_models)
        admin_table_state = web_models.split("class AdminTableState {", 1)[1].split(
            "class AdminJob {", 1
        )[0]
        sync_table_state = sync_state.split("class SyncTableState {", 1)[1].split(
            "class SyncClientState {", 1
        )[0]
        self.assertNotIn("required this.direction,", admin_table_state)
        self.assertNotIn("final String direction;", admin_table_state)
        self.assertNotIn("required this.direction,", sync_table_state)
        self.assertNotIn("final String direction;", sync_table_state)
        self.assertNotIn("this.direction = 'sync'", sync_state)
        self.assertNotIn("'direction': direction", sync_state)
        self.assertNotIn("json['direction'] as String? ?? 'sync'", sync_state)
        self.assertNotIn("final bool hasMore;", web_models)
        self.assertNotIn("final int totalDeletedCount;", web_models)

    def test_control_plane_exposes_snapshot_sync_jobs(self):
        control_plane = read_text("business/control_plane.tru")

        self.assertIn(
            "function jobs_create(clientName: string, tables: array<string>, sourceClientName: string = ''",
            control_plane,
        )
        self.assertIn("function jobs_upload_chunk_start(", control_plane)
        self.assertIn("function jobs_download_snapshot_manifest(", control_plane)
        self.assertNotIn("mergeRole", control_plane)
        self.assertNotIn("publicationName", control_plane)
        self.assertNotIn("syncMode", control_plane)
        self.assertNotIn("direction: 'sync'", control_plane)
        self.assertNotIn("Queued SymmetricDS sync", control_plane)

    def test_unused_business_info_route_is_removed(self):
        self.assertFalse((ROOT / "business" / "sql_sync_api.tru").exists())

    def test_backend_health_file_only_keeps_current_health_routes(self):
        health = read_text("business/health.tru")

        self.assertIn("route GET /call/health", health)
        self.assertIn("route GET /call/ready", health)
        self.assertNotIn("/call/api/health", health)
        self.assertNotIn("/call/api/ready", health)

    def test_control_plane_no_longer_exposes_old_engine_metadata(self):
        control_plane = read_text("business/control_plane.tru")

        self.assertNotIn("function sync_engine_metadata(): map<json>", control_plane)
        self.assertNotIn("syncEngine: sync_engine_metadata()", control_plane)
        self.assertNotIn("agent_symmetricds_status_post", control_plane)

    def test_live_job_models_no_longer_require_merge_role_or_publication_name(self):
        web_models = read_text("frontend/lib/models.dart")
        client_api = read_text("sync_windows_agent/lib/live_sync_api.dart")

        self.assertNotIn("required this.mergeRole", web_models)
        self.assertNotIn("required this.publicationName", web_models)
        self.assertNotIn("final String mergeRole;", web_models)
        self.assertNotIn("final String publicationName;", web_models)
        self.assertNotIn("required this.mergeRole", client_api)
        self.assertNotIn("required this.publicationName", client_api)
        create_jobs_signature = client_api.split(
            "Future<List<RemoteSyncJob>> createJobs({", 1
        )[1].split("}) async {", 1)[0]
        self.assertNotIn("required String direction,", create_jobs_signature)
        self.assertNotIn("String? syncMode,", create_jobs_signature)
        self.assertNotIn("final String syncMode;", client_api)

    def test_related_table_metadata_stays_in_app_state(self):
        control_plane = read_text("business/control_plane.tru")
        agent_page = read_text("sync_windows_agent/lib/agent_page.dart")
        client_api = read_text("sync_windows_agent/lib/live_sync_api.dart")

        self.assertIn("field tableRelationships: array<json>", control_plane)
        self.assertIn("table_dependency_policy_set", control_plane)
        self.assertIn("tableDependencies: table_dependency_payloads_for_database", control_plane)
        self.assertIn("tableRelationships: _tableRelationshipsPayload()", agent_page)
        self.assertIn("RemoteTableDependency", client_api)

    def test_selected_sync_queues_related_tables(self):
        control_plane = read_text("business/control_plane.tru")
        agent_page = read_text("sync_windows_agent/lib/agent_page.dart")

        self.assertIn("function expand_sync_job_tables_for_owner", control_plane)
        self.assertIn(
            "const expandedTables = expand_sync_job_tables_for_owner(agent.ownerUserId, tables)",
            control_plane,
        )
        self.assertIn("final tablesToQueue = <String>{", agent_page)
        self.assertIn("..._relatedSyncKeysFor(syncKey)", agent_page)

    def test_windows_update_script_stops_existing_instances(self):
        update_script = read_text("update.ps1")
        publish_script = read_text("scripts/publish_windows_client_update.ps1")

        self.assertIn("function Get-AgentProcesses {", update_script)
        self.assertIn("function Stop-AgentProcesses {", update_script)
        self.assertIn(
            "Timed out waiting for sync_windows_agent.exe to exit from $TargetInstallDir",
            update_script,
        )
        self.assertNotIn("manifest.latestZipUrl", update_script)
        self.assertNotIn("latestZipUrl =", publish_script)

    def test_windows_agent_can_apply_server_requested_client_updates(self):
        control_plane = read_text("business/control_plane.tru")
        agent_page = read_text("sync_windows_agent/lib/agent_page.dart")
        client_api = read_text("sync_windows_agent/lib/live_sync_api.dart")
        web_api = read_text("frontend/lib/live_sync_api.dart")
        web_models = read_text("frontend/lib/models.dart")
        dashboard = read_text("frontend/lib/dashboard_page.dart")

        self.assertIn("agent_client_update_request", control_plane)
        self.assertIn("agent_client_update_request_all", control_plane)
        self.assertIn("agent_client_update_ack", control_plane)
        self.assertIn("await _handleRequestedClientUpdate(heartbeat.clientUpdate);", agent_page)
        self.assertIn("Future<void> _handleRequestedClientUpdate(", agent_page)
        self.assertIn("Future<RemoteAgentClientUpdate> acknowledgeClientUpdate(", client_api)
        self.assertIn("class RemoteAgentClientUpdate {", client_api)
        self.assertIn("requestAllAgentClientUpdates() async {", web_api)
        self.assertIn("Future<AdminAgentClientUpdate> requestAgentClientUpdate({", web_api)
        self.assertIn("class AdminAgentClientUpdate {", web_models)
        self.assertIn("class AdminBulkClientUpdateRequestResult {", web_models)
        self.assertIn("Update All Clients", dashboard)
        self.assertIn("Update Client", dashboard)

    def test_windows_client_production_build_uses_live_control_plane(self):
        client_api = read_text("sync_windows_agent/lib/live_sync_api.dart")
        build_helpers = read_text("scripts/windows_agent_build.ps1")
        publish_script = read_text("scripts/publish_windows_client_update.ps1")
        build_script = read_text("build_portable.ps1")

        self.assertIn(
            "defaultValue: 'https://sync.velvet-leaf.com/call'",
            client_api,
        )
        self.assertIn("'--dart-define', \"BACKEND_BASE_URL=$BackendBaseUrl\"", build_helpers)
        self.assertIn(
            "[string] $BackendBaseUrl = 'https://sync.velvet-leaf.com/call'",
            publish_script,
        )
        self.assertIn(
            "[string] $BackendBaseUrl = 'https://sync.velvet-leaf.com/call'",
            build_script,
        )
        self.assertNotIn(
            "defaultValue: 'http://127.0.0.1:6006/call'",
            client_api,
        )

    def test_windows_client_build_clears_stale_flutter_aot_cache(self):
        build_helpers = read_text("scripts/windows_agent_build.ps1")

        self.assertIn(
            "(Join-Path -Path $ProjectPath -ChildPath '.dart_tool\\flutter_build')",
            build_helpers,
        )
        cleanup_function = build_helpers.split(
            "function Remove-WindowsAgentBuildArtifacts {", 1
        )[1].split("function Initialize-WindowsAgentBuildEnvironment {", 1)[0]
        self.assertIn(".dart_tool\\flutter_build", cleanup_function)
        self.assertIn("Remove-WindowsAgentBuildPath -Path $path", cleanup_function)
        self.assertIn("Restore-WindowsAgentAotLibrary", build_helpers)

    def test_auto_sync_interval_is_web_owned_not_heartbeat_owned(self):
        control_plane = read_text("business/control_plane.tru")
        web_api = read_text("frontend/lib/live_sync_api.dart")
        dashboard = read_text("frontend/lib/dashboard_page.dart")
        heartbeat_body = control_plane.split("function agents_heartbeat(", 1)[1].split(
            "function auto_sync_tick(", 1
        )[0]
        settings_post_body = control_plane.split(
            "function agent_sync_settings_post(", 1
        )[1].split("function agent_jobs(", 1)[0]
        settings_post_all_body = control_plane.split(
            "function agent_sync_settings_post_all(", 1
        )[1].split("function agent_jobs(", 1)[0]

        self.assertIn(
            "autoSyncIntervalMinutes: clamp_auto_sync_interval(agent.autoSyncIntervalMinutes)",
            heartbeat_body,
        )
        self.assertNotIn(
            "autoSyncIntervalMinutes: clamp_auto_sync_interval(autoSyncIntervalMinutes)",
            heartbeat_body,
        )
        self.assertIn(
            "autoSyncIntervalMinutes: clamp_auto_sync_interval(autoSyncIntervalMinutes)",
            settings_post_body,
        )
        self.assertIn("agent_sync_settings_post_all", web_api)
        self.assertIn("updateAllAgentSyncSettings", dashboard)
        self.assertIn("Applies to all ${agents.length} client", dashboard)
        self.assertNotIn("labelText: 'Sync Client'", dashboard)
        self.assertIn("for (const agent of visible_agent_rows_for(current))", settings_post_all_body)

    def test_windows_client_target_apply_is_transactional(self):
        agent_page = read_text("sync_windows_agent/lib/agent_page.dart")
        target_apply = agent_page.split("Future<void> _applySourceRowsToTarget(", 1)[1].split(
            "String _sourceBatchTargetLiteral(", 1
        )[0]

        self.assertIn("SET XACT_ABORT ON;", target_apply)
        self.assertIn("BEGIN TRANSACTION;", target_apply)
        self.assertIn("COMMIT TRANSACTION;", target_apply)
        self.assertIn("sourceInsertBatchSize = 200", target_apply)
        self.assertLess(
            target_apply.index("BEGIN TRANSACTION;"),
            target_apply.index("MERGE ${_quoteIdentifier(database)}"),
        )
        self.assertLess(
            target_apply.index("MERGE ${_quoteIdentifier(database)}"),
            target_apply.index("COMMIT TRANSACTION;"),
        )

    def test_server_owns_periodic_sync_job_creation(self):
        control_plane = read_text("business/control_plane.tru")
        agent_page = read_text("sync_windows_agent/lib/agent_page.dart")
        heartbeat_body = control_plane.split("function agents_heartbeat(", 1)[1].split(
            "function auto_sync_tick(", 1
        )[0]
        scheduler_body = control_plane.split(
            "function queue_due_periodic_sync_jobs_for_agent(", 1
        )[1].split("function queue_due_periodic_sync_jobs_for_owner(", 1)[0]

        self.assertIn("function queue_due_periodic_sync_jobs_for_agent", control_plane)
        self.assertIn("function queue_due_periodic_sync_jobs_for_owner", control_plane)
        self.assertIn("function claim_periodic_sync_scheduler_for_owner", control_plane)
        self.assertIn("function auto_sync_tick", control_plane)
        self.assertIn("class PeriodicSyncState", control_plane)
        self.assertNotIn("queue_due_periodic_sync_jobs_for_owner", heartbeat_body)
        self.assertIn("queue_due_periodic_sync_jobs_for_owner(ownerUserId);", control_plane)
        self.assertIn("function safe_date_diff_minutes_since", control_plane)
        self.assertIn(
            "safe_date_diff_minutes_since(string.from(existing.lastCheckedAt ?? ''))",
            control_plane,
        )
        self.assertIn("return 1;", control_plane)
        self.assertIn("function periodic_sync_scheduler_agent_limit", control_plane)
        self.assertIn("function periodic_sync_scheduler_table_limit", control_plane)
        self.assertIn("function agent_recent_enough_for_periodic_sync", control_plane)
        self.assertIn("queuedTableCount >= periodic_sync_scheduler_table_limit()", control_plane)
        self.assertNotIn("!effective_agent_online(agent)", scheduler_body)
        self.assertIn("function json_payload_changed", control_plane)
        self.assertIn("if (tablesChanged || relationshipsChanged)", heartbeat_body)
        self.assertIn("await _refreshSelectedTableFingerprints();", agent_page)
        self.assertNotIn("_prepareAutomaticSyncQueueIfDue", agent_page)
        self.assertNotIn("_queueEnabledRoleJobs", agent_page)

    def test_repo_uses_run_ps1_as_single_local_launcher(self):
        build_helpers = read_text("scripts/windows_agent_build.ps1")

        self.assertFalse((ROOT / "client.ps1").exists())
        self.assertNotIn("client.ps1", build_helpers)

    def test_unused_windows_agent_sample_data_is_removed(self):
        self.assertFalse((ROOT / "sync_windows_agent/lib/sample_data.dart").exists())

    def test_obsolete_root_debug_artifacts_are_removed(self):
        self.assertFalse((ROOT / "control_plane.b64").exists())
        self.assertFalse((ROOT / "agent_fix.sql").exists())
        self.assertFalse((ROOT / "agents_fix.sql").exists())
        self.assertFalse((ROOT / "agents_schema.sql").exists())
        self.assertFalse((ROOT / "agents_probe.sql").exists())
        self.assertFalse((ROOT / "user_probe.sql").exists())
        self.assertFalse((ROOT / "inject_velvet_random_data.ps1").exists())
        self.assertFalse((ROOT / "file_selector_windows_plugin.dll").exists())
        self.assertFalse((ROOT / "PRODUCT.md").exists())
        self.assertFalse((ROOT / "database" / "env.template").exists())
        self.assertFalse((ROOT / "database" / "seed.ps1").exists())
        self.assertFalse((ROOT / "database" / "seed_velvet.sql").exists())

    def test_repo_docs_no_longer_describe_mock_or_prototype_state(self):
        root_readme = read_text("README.md")
        frontend_readme = read_text("frontend/README.md")
        client_readme = read_text("sync_windows_agent/README.md")

        self.assertNotIn("mock data", root_readme.lower())
        self.assertNotIn("ui prototype", root_readme.lower())
        self.assertNotIn("mock data", frontend_readme.lower())
        self.assertNotIn("prototype", frontend_readme.lower())
        self.assertNotIn("mock", client_readme.lower())
        self.assertNotIn("prototype", client_readme.lower())

    def test_windows_runner_no_longer_ships_default_flutter_company_metadata(self):
        runner_rc = read_text("sync_windows_agent/windows/runner/Runner.rc")

        self.assertNotIn("com.example", runner_rc)

    def test_run_launcher_backend_health_wait_uses_health_endpoint_only(self):
        launcher = read_text("run.ps1")
        backend_wait = launcher.split("function Wait-BackendHealthy {", 1)[1].split(
            "function Start-LocalDatabase {", 1
        )[0]

        self.assertIn(
            'Invoke-WebRequest -Uri $healthUrl -UseBasicParsing -TimeoutSec 3',
            backend_wait,
        )
        self.assertNotIn("[System.Diagnostics.Process]$Process = $null", backend_wait)
        self.assertNotIn("$Process.HasExited", backend_wait)

    def test_run_launcher_clears_stale_repo_backend_processes_before_restart(self):
        launcher = read_text("run.ps1")

        self.assertIn("function Get-RepoBackendProcesses {", launcher)
        self.assertIn("function Stop-RepoBackendProcesses {", launcher)
        self.assertIn("Stop-RepoBackendProcesses", launcher.split("function Start-Stack {", 1)[1])
        self.assertIn("Stopping stale backend process", launcher)

    def test_windows_state_loader_no_longer_backfills_old_login_fields(self):
        sync_state = read_text("sync_windows_agent/lib/sync_state.dart")

        self.assertNotIn(
            "json['accountUsername'] as String? ??\n            json['accountEmail'] as String?",
            sync_state,
        )
        self.assertNotIn(
            "json['rememberedLoginName'] as String? ??\n            json['accountUsername'] as String? ??\n            json['accountEmail'] as String?",
            sync_state,
        )

    def test_helm_does_not_keep_dead_sync_engine_mode(self):
        values = read_text("deployment/chart/values.yaml")
        frontend_deployment = read_text("deployment/chart/templates/deployment.yaml")
        backend_deployment = read_text(
            "deployment/chart/templates/backend-deployment.yaml"
        )

        self.assertNotIn("syncEngine:", values)
        self.assertNotIn("SQL_SYNC_ENGINE_MODE", frontend_deployment)
        self.assertNotIn("SQL_SYNC_ENGINE_MODE", backend_deployment)
        self.assertNotIn("symmetricds:", values)


if __name__ == "__main__":
    unittest.main()
