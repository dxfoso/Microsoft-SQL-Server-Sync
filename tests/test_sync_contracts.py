import re
import unittest
from pathlib import Path


ROOT = Path(__file__).resolve().parents[1]


def read_text(relative_path: str) -> str:
    return (ROOT / relative_path).read_text(encoding="utf-8")


class SyncContractsTests(unittest.TestCase):
    def test_remote_support_self_test_is_server_driven_sanitized_and_staged(self):
        agent_page = read_text("sync_windows_agent/lib/agent_page.dart")
        client_api = read_text("sync_windows_agent/lib/live_sync_api.dart")
        frontend = read_text("frontend/lib/dashboard_page.dart")

        self.assertIn("reportDiagnosticsProgress", client_api)
        self.assertIn("agent_diagnostics_progress", client_api)
        self.assertIn("stage: 'collecting-client-state'", agent_page)
        self.assertIn("stage: 'running-self-tests'", agent_page)
        self.assertIn("stage: 'refreshing-table-fingerprints'", agent_page)
        self.assertIn("_buildDiagnosticsSelfTests", agent_page)
        self.assertIn("_buildDiagnosticsTimeline", agent_page)
        self.assertIn("'supportReport':", agent_page)
        self.assertIn("'accountIdentityIncluded': false", agent_page)
        self.assertNotIn("'username': widget.authenticatedAccountUsername", agent_page)
        self.assertNotIn("'email': widget.authenticatedAccountEmail", agent_page)
        self.assertIn("Run Remote Self-Test", frontend)
        self.assertIn("Download support report", frontend)
        self.assertIn("Unified client timeline", frontend)

    def test_windows_snapshot_staging_uses_resumable_sql_bulk_copy(self):
        agent = read_text("sync_windows_agent/lib/agent_page.dart")
        bulk_policy = read_text("sync_windows_agent/lib/sql_bulk_stage.dart")
        bulk_script = read_text("sync_windows_agent/assets/sql_bulk_stage.ps1")
        bulk_source = read_text("sync_windows_agent/assets/SqlBulkStage.cs")

        self.assertIn("_runSqlBulkStageRows(", agent)
        self.assertGreaterEqual(agent.count("bulkCopyAvailable = Platform.isWindows"), 2)
        self.assertIn("targetSnapshotBulkRowsPerInvocation = 10000", bulk_policy)
        self.assertIn("targetSnapshotBulkCommitRows = 1000", bulk_policy)
        self.assertIn("SqlSync.BulkStageLoader", bulk_script)
        self.assertIn("SqlBulkCopyOptions.TableLock", bulk_source)
        self.assertIn("SqlBulkCopyOptions.UseInternalTransaction", bulk_source)
        self.assertIn("bulkCopy.BatchSize", bulk_source)
        self.assertIn("_queryTargetSnapshotStageRowCount(", agent)
        self.assertIn("sync.apply.bulk_stage_fallback", agent)
        self.assertIn("buildTargetSnapshotStageInsertSql(", agent)

    def test_heartbeat_prioritizes_complete_selected_database_inventory(self):
        agent_page = read_text("sync_windows_agent/lib/agent_page.dart")
        body = agent_page.split(
            "List<String> _boundedHeartbeatTableNames() {", 1
        )[1].split("List<Map<String, String>> _tableRelationshipsPayload", 1)[0]

        self.assertIn("static const int _heartbeatTablePayloadLimit = 600;", agent_page)
        self.assertIn("final selectedDatabase = (_selectedDatabase ?? '').trim().toLowerCase();", body)
        self.assertIn("bool belongsToSelectedDatabase(String table)", body)
        self.assertIn("entry.value.enabled && belongsToSelectedDatabase(entry.key)", body)
        self.assertLess(body.index("for (final table in _tables)"), body.index("for (final table in _syncState.tables.keys)"))
        self.assertIn("if (belongsToSelectedDatabase(table))", body)

    def test_complete_snapshot_verification_accepts_only_protected_hot_rows(self):
        agent_page = read_text("sync_windows_agent/lib/agent_page.dart")
        apply_body = agent_page.split(
            "Future<int> _applyDownloadedSnapshotToTarget({", 1
        )[1].split("Future<int> _refreshTargetStateAfterRemoteApply(", 1)[0]

        self.assertIn("var protectedFullSnapshotUpsertRows = 0;", apply_body)
        self.assertIn(
            "protectedFullSnapshotUpsertRows = applyResult.protectedUpsertRows;",
            apply_body,
        )
        self.assertIn(
            "unexpectedCompleteSnapshotMismatchCount(",
            apply_body,
        )
        self.assertIn(
            "were not applied and were not protected local changes",
            apply_body,
        )
        self.assertIn(
            "the next delta will upload them",
            apply_body,
        )

    def test_first_time_eligible_tables_are_enrolled_automatically(self):
        agent_page = read_text("sync_windows_agent/lib/agent_page.dart")
        api = read_text("sync_windows_agent/lib/live_sync_api.dart")
        discovery = read_text(
            "sync_windows_agent/lib/automatic_change_discovery.dart"
        )

        self.assertIn(
            ".then((_) => _autoEnrollEligibleTables(database))",
            agent_page,
        )
        auto_enroll = agent_page.split(
            "Future<void> _autoEnrollEligibleTables(", 1
        )[1].split(
            "Future<void> _discoverNewTablesForAutomaticEnrollment(", 1
        )[0]
        self.assertIn("changeTrackingStatus == 'enabled'", auto_enroll)
        self.assertIn("autoEnrollTableSyncPolicies(", auto_enroll)
        self.assertIn("_applyRemoteTablePolicies(policies)", auto_enroll)
        periodic_discovery = agent_page.split(
            "Future<void> _discoverNewTablesForAutomaticEnrollment(", 1
        )[1].split("Future<void> _discoverAndEnableChangedTables(", 1)[0]
        self.assertIn("_queryTables(", periodic_discovery)
        self.assertIn("_ensureSyncTablesLoaded(newTables)", periodic_discovery)
        self.assertIn(
            "_ensureChangeTrackingEnabledForDatabase(",
            periodic_discovery,
        )
        self.assertIn(
            "_autoEnrollEligibleTables(database, candidates: newSyncKeys)",
            periodic_discovery,
        )
        changed_discovery = agent_page.split(
            "Future<void> _discoverAndEnableChangedTables(", 1
        )[1].split("Future<void> _selectDatabase(", 1)[0]
        self.assertIn(
            "await _discoverNewTablesForAutomaticEnrollment(database)",
            changed_discovery,
        )
        self.assertIn("'table_sync_policy_auto_enroll'", api)
        self.assertIn("N'unsupported'", discovery)
        self.assertIn("column_type.name IN", discovery)

    def test_legacy_sync_migration_records_are_removed(self):
        self.assertFalse((ROOT / "business/migration/mig_20260619_221054.json").exists())
        self.assertFalse((ROOT / "business/migration/mig_20260626_151213.json").exists())
        self.assertFalse((ROOT / "business/migration/mig_20260628_232845.json").exists())
        self.assertFalse((ROOT / "business/migration/mig_20260630_181319.json").exists())

    def test_deployment_backend_image_runs_validated_as_non_root(self):
        dockerfile = read_text("Dockerfile.backend")

        self.assertIn("FROM docker.io/library/rust:1.89-bullseye AS builder", dockerfile)
        self.assertIn("FROM docker.io/library/debian:bullseye-slim AS runtime", dockerfile)
        self.assertEqual(
            dockerfile.count(
                "id=tru-backend-target-rust189-bullseye,"
                "target=/app/server/target,sharing=locked"
            ),
            2,
        )
        self.assertIn("useradd --system --uid 10001 --home-dir /app", dockerfile)
        self.assertIn(
            "RUN TRU_VALIDATE_ONLY=1 TRU_CONFIG_PATH=/app/business/tru.json "
            "tru_server /app/business",
            dockerfile,
        )
        self.assertIn("RUN chown -R 10001:10001 /app", dockerfile)
        self.assertIn("USER 10001:10001", dockerfile)

    def test_windows_agent_uses_snapshot_transport_only(self):
        agent_page = read_text("sync_windows_agent/lib/agent_page.dart")
        client_api = read_text("sync_windows_agent/lib/live_sync_api.dart")

        self.assertIn("Future<void> _processSnapshotJob(", agent_page)
        self.assertIn("Future<void> _processSnapshotRelayUploadJob(", agent_page)
        self.assertIn("if (!activeJob.isActive) {", agent_page)
        self.assertIn("because the control plane returned terminal status", agent_page)
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

    def test_windows_agent_reports_change_tracking_diagnostics(self):
        agent_page = read_text("sync_windows_agent/lib/agent_page.dart")

        self.assertIn("Future<Map<String, dynamic>> _queryChangeTrackingDiagnostics()", agent_page)
        self.assertIn("sys.change_tracking_databases", agent_page)
        self.assertIn("sys.change_tracking_tables", agent_page)
        self.assertIn("CHANGE_TRACKING_CURRENT_VERSION()", agent_page)
        self.assertIn("CHANGE_TRACKING_MIN_VALID_VERSION", agent_page)
        self.assertIn("'changeTracking': changeTracking", agent_page)
        self.assertIn("'databases': databaseResults", agent_page)
        self.assertIn("_databaseNameFromSyncKey(syncKey)", agent_page)
        self.assertIn("_ensureChangeTrackingEnabledForDatabase", agent_page)
        self.assertIn("ALTER DATABASE ${_quoteIdentifier(trimmedDatabase)}", agent_page)
        self.assertIn("ENABLE CHANGE_TRACKING", agent_page)
        self.assertIn(
            "({String status, String message})? _extractChangeTrackingDatabaseStatus(",
            agent_page,
        )
        self.assertIn(
            "bool _isAlreadyEnabledChangeTrackingFailure(ProcessResult processResult)",
            agent_page,
        )
        self.assertIn(
            "details.contains('change tracking is already enabled for database')",
            agent_page,
        )
        self.assertIn("databaseStatus = 'already_enabled';", agent_page)
        self.assertIn("_isSystemDatabase", agent_page)
        self.assertIn("System databases are not modified automatically.", agent_page)
        self.assertIn("_buildChangeTrackingBadge", agent_page)
        self.assertIn("_queryChangeTrackingDiagnostics()", agent_page)
        self.assertIn(
            ".then((_) => _autoEnrollEligibleTables(database))",
            agent_page,
        )
        self.assertIn(
            ".whenComplete(() => _discoverAndEnableChangedTables())",
            agent_page,
        )
        self.assertIn("_discoverAndEnableChangedTables()", agent_page)
        self.assertIn("changeTrackingStatus", read_text("sync_windows_agent/lib/sync_state.dart"))

    def test_requested_client_logs_are_detailed_complete_and_redacted(self):
        agent_page = read_text("sync_windows_agent/lib/agent_page.dart")
        client_api = read_text("sync_windows_agent/lib/live_sync_api.dart")
        startup_log = read_text("sync_windows_agent/lib/startup_log.dart")
        dashboard = read_text("frontend/lib/dashboard_page.dart")

        self.assertIn("void logAgentDiagnostic(", startup_log)
        self.assertIn("String redactAgentLogText(", startup_log)
        self.assertIn("_maxRetainedAgentLogChars = 40 * 1024", startup_log)
        self.assertIn("current file plus one rotated segment", agent_page)
        self.assertIn("'completeRetainedLog': true", agent_page)
        self.assertIn("final startupLogTail = _readStartupLogTail()", agent_page)
        self.assertIn("'startupLogTail': startupLogTail", agent_page)
        self.assertIn("readRetainedAgentLog()", agent_page)
        self.assertIn("'control_plane.request.completed'", client_api)
        self.assertIn("'sync.job.processing.started'", agent_page)
        self.assertIn("'sync.upload.chunk.completed'", agent_page)
        self.assertIn("'sync.apply.committed'", agent_page)
        self.assertIn("'sqlcmd.completed'", agent_page)
        self.assertIn("'Run Remote Self-Test'", dashboard)
        self.assertIn("'View Support Report'", dashboard)

    def test_change_tracking_delta_query_avoids_reserved_current_alias(self):
        agent_page = read_text("sync_windows_agent/lib/agent_page.dart")

        delta_body = agent_page.split(
            "Future<List<Map<String, String?>>> _fetchChangeTrackingRows(",
            1,
        )[1].split("String _sourceBatchEncodedColumnExpression(", 1)[0]
        self.assertIn("AS existing_row ON", delta_body)
        self.assertIn("existing_row.", delta_body)
        self.assertNotIn("AS current ON", delta_body)
        self.assertNotIn("current.", delta_body)
        self.assertNotIn("FOR JSON PATH", delta_body)
        self.assertIn("decodeSqlServerHexRows(", delta_body)
        self.assertIn("sqlSyncHexRowTerminator", delta_body)
        self.assertIn("CONVERT(varbinary(max), CONVERT(nvarchar(max)", delta_body)
        self.assertNotIn("Change tracking delta returned", delta_body)
        self.assertNotIn("USE ${_quoteIdentifier(database)};", delta_body)

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
        self.assertNotIn("Stop-ProcessesUnderPath", build_script)
        self.assertNotIn("Stop-Process", build_script)
        self.assertIn("artifacts\\portable-builds\\", build_script)
        self.assertIn("$publishedZipTemp", build_script)
        self.assertIn("Move-Item -LiteralPath $publishedZipTemp", build_script)
        self.assertNotIn('Write-Host "Splitting zip archive into 10 parts..."', build_script)
        self.assertNotIn('$zipPartsDir = Join-Path -Path $OutputRoot -ChildPath "$PortableName-zip-parts"', build_script)
        self.assertNotIn('Write-Host "Parts:  $($zipPartsInfo.PartsDir)"', build_script)
        self.assertIn("function New-PortableZipParts {", publish_script)
        self.assertIn("if ([System.IO.Path]::IsPathRooted(`$OutputZip)) {", publish_script)
        self.assertIn("if ([System.IO.Path]::IsPathRooted(`$OutputDir)) {", publish_script)
        self.assertNotIn("New-PortableZipParts `", publish_script)
        self.assertNotIn("$PortableZipPartsDir = Join-Path -Path $RepoRoot -ChildPath \"$PortableName-zip-parts\"", publish_script)

    def test_frontend_server_only_serves_static_assets_and_client_updates(self):
        node_server = read_text("frontend/server.js")

        self.assertIn("async function tryServeClientUpdate(", node_server)
        self.assertIn('"Cache-Control": "no-store, no-cache, must-revalidate, max-age=0"', node_server)
        self.assertIn('requestedPath === "update.ps1"', node_server)
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

    def test_web_workspace_has_dashboard_and_client_log_navigation(self):
        app = read_text("frontend/lib/app.dart")
        clients_page = read_text("frontend/lib/clients_page.dart")
        dashboard = read_text("frontend/lib/dashboard_page.dart")
        web_models = read_text("frontend/lib/models.dart")

        self.assertIn("class _AdminWorkspace extends StatefulWidget", app)
        self.assertIn("_navItem(0, Icons.dashboard_outlined, 'Dashboard'", app)
        self.assertIn("Icons.devices_other_outlined", app)
        self.assertIn("'Clients',", app)
        self.assertIn("return ClientsPage(", app)
        self.assertIn("class ClientsPage extends StatefulWidget", clients_page)
        self.assertIn("_api.fetchLiveState()", clients_page)
        self.assertIn("Table activity", clients_page)
        self.assertIn("Sync log", clients_page)
        self.assertIn("Changed rows", clients_page)
        self.assertIn("changedRowCount", clients_page)
        self.assertNotIn("changedRowsOverride", clients_page)
        self.assertNotIn("return 'Not reported';", clients_page)
        self.assertIn("return '-';", clients_page)
        self.assertIn(
            "job.sourceClientName == 'server-authoritative-reconcile'",
            clients_page,
        )
        self.assertNotIn("server-anti-entropy", clients_page)
        self.assertIn("'Reconciliation'", clients_page)
        self.assertIn("'Snapshot'", clients_page)
        self.assertIn("Filter clients", clients_page)
        self.assertIn("_ClientSortField", clients_page)
        self.assertIn("label: const Text('View')", clients_page)
        self.assertIn("Table sync readiness", clients_page)
        self.assertNotIn("SegmentedButton<_ClientDetailView>", clients_page)
        self.assertIn("All sync is stopped", clients_page)
        self.assertIn("Choose resolution", clients_page)
        self.assertIn("_changedRowsLabel", clients_page)
        client_list = clients_page.split(
            "Widget _buildClientList() {", 1
        )[1].split("Widget _buildClientFilters()", 1)[0]
        self.assertNotIn("DataColumn(label: Text('Changed rows'))", client_list)
        self.assertNotIn("DataColumn(label: Text('Rows uploaded'))", client_list)
        self.assertNotIn("DataColumn(label: Text('Rows downloaded'))", client_list)
        self.assertIn("_clientActivityStatus(", clients_page)
        self.assertIn("serverActivities:", clients_page)
        self.assertIn("clientActivities", clients_page)
        self.assertIn("return 'Ready';", clients_page)

        self.assertIn("'Cleaning…'", clients_page)
        self.assertIn("'Cleaned · Automatic sync paused'", clients_page)
        self.assertIn("Live client connectivity was preserved.", clients_page)
        self.assertIn("'Cleaned'", dashboard)
        self.assertIn("'downloading' => 'Downloading'", clients_page)
        self.assertIn("'uploading' || 'snapshotting' => 'Uploading'", clients_page)
        self.assertIn("_replaceRoute", clients_page)
        self.assertNotIn("Additional rows not reported", clients_page)
        self.assertIn("+${_number(changedRows)} rows", clients_page)
        self.assertIn("Filter log", clients_page)
        self.assertIn("Downloaded new", clients_page)
        self.assertIn("Uploaded new", clients_page)
        self.assertIn("Sync / updated", clients_page)
        sync_log = clients_page.split("Widget _buildJobLog(", 1)[1].split(
            "DataRow _buildSyncDataRow(", 1
        )[0]
        self.assertLess(
            sync_log.index("DataColumn(label: Text('Changed rows'))"),
            sync_log.index("DataColumn(label: Text('Status'))"),
        )
        self.assertIn("_buildLogDataRow", clients_page)
        self.assertIn("_ClientScreen", clients_page)
        self.assertIn("Sync log", clients_page)
        self.assertIn("Back to clients", clients_page)
        self.assertIn("Back to client", clients_page)
        self.assertIn("_buildTableDetailPage", clients_page)
        self.assertIn("required this.batchId,", web_models)
        self.assertIn("batchId: json['batchId'] as String? ?? ''", web_models)
        self.assertIn("'batch:$batch|${job.table}'", clients_page)
        self.assertIn("_buildClientDetailToolbar(agent)", clients_page)
        self.assertIn("height: 40", clients_page)
        self.assertIn("_messageContainsReportedRowCount(message)", clients_page)
        self.assertIn("'Sync completed.'", clients_page)
        self.assertIn("required this.authenticatedUser,", clients_page)
        self.assertIn("widget.authenticatedUser.canManageUsers", clients_page)
        self.assertIn("syncBlocked ? 'Sync stopped' : 'Sync All'", clients_page)
        self.assertIn("label: const Text('Minimize All')", clients_page)
        self.assertIn("label: const Text('Update All')", clients_page)
        self.assertIn("label: const Text('Run All Self-Tests')", clients_page)
        self.assertIn("DataColumn(label: Text('Last synced'))", clients_page)
        self.assertIn("DataColumn(label: Text('Last row changes'))", clients_page)
        self.assertIn("DataColumn(label: Text('Total row changes'))", clients_page)
        self.assertNotIn("DataColumn(label: Text('Row changes'))", clients_page)
        self.assertIn("ValueKey('fixed-client-name-column')", clients_page)
        self.assertIn("ValueKey('scrollable-client-details')", clients_page)
        self.assertIn("controller: _clientTableHorizontalController", clients_page)
        self.assertIn("thumbVisibility: true", clients_page)
        self.assertIn("'Uploaded: ${_number(agent.lastUploadedRows)}\\n'", clients_page)
        self.assertIn("'Downloaded: ${_number(agent.lastDownloadedRows)}'", clients_page)
        self.assertIn("'Uploaded: ${_number(agent.uploadedRowTotal)}\\n'", clients_page)
        self.assertIn("'Downloaded: ${_number(agent.downloadedRowTotal)}'", clients_page)
        self.assertIn("DataColumn(label: Text('Last sync duration'))", clients_page)
        self.assertIn("DataColumn(label: Text('Last Sync All total'))", clients_page)
        self.assertIn("_syncAllOperationForAgent(agent)?.duration()", clients_page)
        self.assertIn("'Last Sync All total: ${formatSyncDuration(operation.duration())}", clients_page)
        self.assertIn("Completed with errors", clients_page)
        self.assertIn("class AdminSyncAllOperation", web_models)
        self.assertIn("lastSyncDurationMs: (json['lastSyncDurationMs'] as num?)?.round()", web_models)
        self.assertIn("lastUploadedRows: (json['lastUploadedRows'] as num? ?? 0).round()", web_models)
        self.assertIn("lastDownloadedRows: (json['lastDownloadedRows'] as num? ?? 0).round()", web_models)
        self.assertIn("uploadedRowTotal: (json['uploadedRowTotal'] as num? ?? 0).round()", web_models)
        self.assertIn("downloadedRowTotal: (json['downloadedRowTotal'] as num? ?? 0).round()", web_models)
        self.assertIn("DataColumn(label: Text('Active'))", clients_page)
        self.assertIn("_buildClientActiveCheckbox(agent)", clients_page)
        self.assertIn("ValueKey('client-active-${agent.clientName}')", clients_page)
        self.assertIn("_setClientSyncEnabled(agent, value == true)", clients_page)
        self.assertIn("It will not synchronize until checked again.", clients_page)
        self.assertIn("if (!agent.syncEnabled) return 'Disabled';", clients_page)
        self.assertIn("setAgentSyncEnabled(", clients_page)
        self.assertIn("DataColumn(label: Text('Conflict source'))", clients_page)
        self.assertIn("_buildConflictSourceCheckbox(agent)", clients_page)
        self.assertIn("ValueKey('client-conflict-source-${agent.clientName}')", clients_page)
        self.assertIn("_api.setConflictSource(", clients_page)
        self.assertIn("client-conflict-policy-footer", clients_page)
        self.assertIn("no source client is selected", clients_page)
        self.assertNotIn("labelText: 'Duplicate business-key conflicts'", clients_page)
        self.assertIn("_ClientSortField.lastSync", clients_page)
        self.assertIn("_latestClientSync(agent)", clients_page)
        self.assertIn("_showBulkActionsInLegacyDashboard => false", dashboard)

    def test_mobile_client_filter_is_compact_and_integrated_in_card_header(self):
        clients_page = read_text("frontend/lib/clients_page.dart")
        client_list = clients_page.split(
            "Widget _buildClientList() {", 1
        )[1].split("Widget _buildClientFilters()", 1)[0]
        compact_sheet = clients_page.split(
            "Future<void> _showCompactClientFilters() async {", 1
        )[1].split("Widget _buildClientFilters()", 1)[0]

        self.assertIn(
            "final compactFilters = MediaQuery.sizeOf(context).width < 680;",
            client_list,
        )
        self.assertIn("_buildCompactClientFilterButton()", client_list)
        self.assertIn("if (!compactFilters)", client_list)
        self.assertIn("mobile-client-filter-button", client_list)
        self.assertIn("showModalBottomSheet<void>", compact_sheet)
        self.assertIn("Filter and sort clients", client_list)
        self.assertIn("MediaQuery.viewInsetsOf(context).bottom", compact_sheet)

    def test_control_plane_exposes_protocol_v2_jobs_and_explicit_bootstrap(self):
        control_plane = read_text("business/control_plane.tru")

        self.assertIn(
            "function jobs_create(clientName: string, tables: array<string>, token: string? = null)",
            control_plane,
        )
        self.assertIn("function jobs_bootstrap(clientName: string, tables: array<string>", control_plane)
        self.assertIn("'server-delta-v3'", control_plane)
        self.assertIn("'server-bootstrap-v3'", control_plane)
        self.assertIn("'server-union-bootstrap-v3'", control_plane)
        self.assertIn("'server-partial-delta-v3'", control_plane)
        self.assertNotIn("mergeRole", control_plane)
        self.assertNotIn("publicationName", control_plane)
        self.assertIn("field syncMode: string min=1 max=32", control_plane)
        self.assertNotIn("direction: 'sync'", control_plane)
        self.assertNotIn("Queued SymmetricDS sync", control_plane)

    def test_web_download_resolves_the_latest_immutable_windows_client(self):
        app = read_text("frontend/lib/app.dart")
        server = read_text("frontend/server.js")
        publisher = read_text("scripts/publish_windows_client_update.ps1")

        self.assertIn(
            "'/client/download'",
            app,
        )
        self.assertIn("'Download Windows Client'", app)
        self.assertIn("final releaseNonce = DateTime.now().millisecondsSinceEpoch", app)
        self.assertIn("?release=$releaseNonce", app)
        self.assertIn("onPressed: _downloadWindowsClient", app)
        self.assertIn("_downloadWindowsClientButton(compact: false)", app)
        self.assertIn("_downloadWindowsClientButton(compact: true)", app)
        self.assertIn('requestedPath === "download"', server)
        self.assertIn("readLatestClientManifest(roots)", server)
        self.assertIn("Location: location", server)
        self.assertIn("clientDownloadLocation(manifest)", server)
        self.assertIn('return "/client/sync_windows_agent_latest.zip"', server)
        self.assertIn('requestedPath === "sync_windows_agent_latest.zip"', server)
        self.assertIn('requestedPath === "latest-files.json"', server)
        self.assertIn('requestedPath.startsWith("packages/latest-package/")', server)
        self.assertIn('zipUrl = "$publicRoot/$zipName"', publisher)
        self.assertNotIn('zipUrl = "$publicRoot/sync_windows_agent_latest.zip"', publisher)

    def test_web_header_cache_busts_the_mutable_windows_client_download(self):
        # Preserve the original INC-038 selector while the stronger INC-047
        # regression proves that the click resolves the immutable live ZIP.
        self.test_web_download_resolves_the_latest_immutable_windows_client()

    def test_windows_snapshot_apply_uses_only_permanent_primary_identity(self):
        agent_page = read_text("sync_windows_agent/lib/agent_page.dart")
        merge_helper = read_text("sync_windows_agent/lib/sql_sync_merge.dart")

        self.assertIn("matchClauseForColumns(primaryKeyColumns, columns)", merge_helper)
        self.assertNotIn("_targetMatchColumnSets(", agent_page)
        self.assertNotIn("matchClauseForColumnSets", merge_helper)
        self.assertNotIn("updatePrimaryKeysFromUniqueMatch", merge_helper)
        self.assertIn("hasValidCanonicalSqlSyncRowHash", agent_page)
        self.assertIn("canonicalSqlSyncRowSha256", agent_page)
        self.assertIn("__sync_operation_id", agent_page)
        self.assertIn("Future<List<Map<String, dynamic>>> _rowsWhoseContentChanged(", agent_page)
        self.assertIn("targetHash == null || targetHash != incomingHash", agent_page)
        self.assertIn("Skipped ${rowsForApply.length - contentCheckedRows.length} unchanged", agent_page)
        self.assertIn("buildTargetSnapshotStageSetupSql(", agent_page)
        self.assertIn("buildTargetSnapshotStageInsertSql(", agent_page)
        self.assertIn("buildTargetSnapshotStageRowCountSql(", agent_page)
        self.assertIn("targetSnapshotInsertRowsPerStatement = 1000", merge_helper)
        stage_apply = agent_page.split(
            "Future<_TargetApplyResult> _applySourceRowsToTarget(", 1
        )[1].split("String _nextTargetSnapshotStageTableName", 1)[0]
        self.assertIn("while (stagedRowCount < rows.length)", stage_apply)
        self.assertIn("await onStageProgress?.call(stagedRowCount, rows.length)", stage_apply)
        self.assertIn("_buildSourceTempIndexStatements(", merge_helper)

    def test_table_fingerprints_only_hash_writable_sync_columns(self):
        agent_page = read_text("sync_windows_agent/lib/agent_page.dart")
        fingerprint_helper = read_text("sync_windows_agent/lib/sql_sync_fingerprint.dart")
        fingerprint_body = agent_page.split(
            "Future<Map<String, _TableFingerprint>> _queryTableFingerprints(", 1
        )[1].split("Future<Map<String, dynamic>> _queryChangeTrackingDiagnostics()", 1)[0]

        self.assertIn("assessSqlSyncColumns(definitions).writableColumns", fingerprint_body)
        self.assertIn("_computeTableFingerprint(", fingerprint_body)
        self.assertIn("SqlSyncFingerprintAccumulator", fingerprint_helper)
        self.assertIn("encodeSqlSyncFingerprintField", fingerprint_helper)
        self.assertNotIn("CHECKSUM_AGG", fingerprint_body)

    def test_uploaded_diagnostics_compact_change_tracking_payloads(self):
        agent_page = read_text("sync_windows_agent/lib/agent_page.dart")
        compact_body = agent_page.split(
            "Map<String, dynamic> _compactChangeTrackingDiagnosticsForUpload(", 1
        )[1].split("Map<String, dynamic> _compactAutomaticChangeTrackingEnable(", 1)[0]

        self.assertIn(
            "Map<String, dynamic> _compactDatabaseChangeTrackingDiagnostics(",
            agent_page,
        )
        self.assertIn(
            "return _compactDatabaseChangeTrackingDiagnostics(database);",
            compact_body,
        )
        self.assertIn("compact.remove('trackedTables');", compact_body)
        self.assertIn("compact.remove('offlineChangeDetectionNote');", compact_body)
        self.assertNotIn("trackedTables.take(100)", compact_body)

    def test_heartbeat_does_not_block_on_full_fingerprint_refresh(self):
        agent_page = read_text("sync_windows_agent/lib/agent_page.dart")
        sync_state = read_text("sync_windows_agent/lib/sync_state.dart")
        heartbeat_body = agent_page.split("Future<void> _syncWithControlPlane() async {", 1)[
            1
        ].split("Future<void> _uploadRequestedDiagnostics(", 1)[0]

        self.assertIn(
            "const Duration _tableFingerprintRefreshCooldown = Duration(minutes: 1);",
            agent_page,
        )
        self.assertIn("_tableFingerprintRefreshBatchSize = 8", agent_page)
        self.assertIn("_tableFingerprintRefreshCursor", agent_page)
        self.assertIn(
            "_tableFingerprintRefreshCursor = _syncState.fingerprintRefreshCursor",
            agent_page,
        )
        self.assertIn("fingerprintRefreshCursor: nextCursor", agent_page)
        self.assertIn("fingerprintAudit: nextAudit", agent_page)
        self.assertIn("'fingerprintRefreshCursor': fingerprintRefreshCursor", sync_state)
        self.assertIn("bool _refreshingTableFingerprints = false;", agent_page)
        self.assertIn("DateTime? _lastTableFingerprintRefreshStartedAt;", agent_page)
        self.assertIn(
            "void _scheduleSelectedTableFingerprintRefresh({bool force = false}) {",
            agent_page,
        )
        self.assertIn("_scheduleSelectedTableFingerprintRefresh();", heartbeat_body)
        self.assertNotIn("await _refreshSelectedTableFingerprints();", heartbeat_body)
        self.assertIn(
            "Selected table fingerprint refresh failed: $error",
            agent_page,
        )

    def test_integrity_audit_is_durable_visible_and_bounded(self):
        agent = read_text("sync_windows_agent/lib/agent_page.dart")
        state = read_text("sync_windows_agent/lib/sync_state.dart")
        api = read_text("sync_windows_agent/lib/live_sync_api.dart")
        control_plane = read_text("business/control_plane.tru")
        models = read_text("frontend/lib/models.dart")
        clients = read_text("frontend/lib/clients_page.dart")

        self.assertIn("final Map<String, dynamic> fingerprintAudit", state)
        self.assertIn("'fingerprintAudit': fingerprintAudit", state)
        self.assertIn("'history': nextHistory", agent)
        self.assertIn(".take(20).toList()", agent)
        self.assertIn("'fingerprintAudit': [fingerprintAudit]", api)
        self.assertIn("field fingerprintAudit: array<json>?", control_plane)
        self.assertIn("bounded_fingerprint_audit(fingerprintAudit)", control_plane)
        audit_sanitizer = control_plane.split(
            "function bounded_fingerprint_audit(", 1
        )[1].split("function bounded_agent_tables(", 1)[0]
        self.assertNotIn(".slice(", audit_sanitizer)
        self.assertIn("if (currentTables.length >= 8)", audit_sanitizer)
        self.assertIn("if (lastBatchTables.length >= 8)", audit_sanitizer)
        self.assertIn("class AdminFingerprintAudit", models)
        self.assertIn("DataColumn(label: Text('Integrity check'))", clients)
        self.assertIn("_showFingerprintAuditDialog", clients)
        self.assertIn("'Last minute: ${audit.lastBatchTables.join(', ')}'", clients)

    def test_diagnostics_force_fresh_complete_selected_table_fingerprints(self):
        agent_page = read_text("sync_windows_agent/lib/agent_page.dart")
        diagnostics_body = agent_page.split(
            "Future<String> _buildDiagnosticsPayload({", 1
        )[1].split(
            "Future<Map<String, dynamic>>\n  _buildChangeTrackingDiagnosticsForUpload", 1
        )[0]
        encoder_body = agent_page.split(
            "String _encodeDiagnosticsPayloadForUpload", 1
        )[1].split("List<dynamic> _boundedUploadList", 1)[0]

        self.assertIn("await _refreshSelectedTableFingerprints();", diagnostics_body)
        self.assertIn(
            ".where((entry) => _isTableSelectedForSync(entry.value))",
            diagnostics_body,
        )
        self.assertIn(
            "'selectedTableFingerprints': selectedTableFingerprints",
            diagnostics_body,
        )
        self.assertIn(
            "payload['selectedTableFingerprints']",
            encoder_body,
        )
        self.assertIn("_compactSelectedFingerprintsForUpload", encoder_body)
        self.assertIn("'fingerprintCapture': payload['fingerprintCapture']", encoder_body)

    def test_diagnostics_upload_logs_before_full_fingerprint_enrichment(self):
        agent_page = read_text("sync_windows_agent/lib/agent_page.dart")
        upload_body = agent_page.split(
            "Future<void> _uploadRequestedDiagnostics(", 1
        )[1].split("Future<void> _refreshAndUploadDiagnosticsFingerprints", 1)[0]
        enrichment_body = agent_page.split(
            "Future<void> _refreshAndUploadDiagnosticsFingerprints", 1
        )[1].split("void _scheduleRequestedDiagnosticsUpload", 1)[0]

        initial_payload = upload_body.index("refreshFingerprints: false")
        initial_upload = upload_body.index(
            "await _controlPlaneClient.uploadDiagnostics("
        )
        background_enrichment = upload_body.index(
            "_refreshAndUploadDiagnosticsFingerprints("
        )
        self.assertLess(initial_payload, initial_upload)
        self.assertLess(initial_upload, background_enrichment)
        self.assertIn("refreshFingerprints: true", enrichment_body)
        self.assertIn("_diagnosticsUploadRequestId != requestId", enrichment_body)
        self.assertIn("'status': refreshFingerprints ? 'completed' : 'refreshing'", agent_page)

    def test_diagnostics_emergency_payload_is_bounded_valid_json(self):
        agent_page = read_text("sync_windows_agent/lib/agent_page.dart")
        encoder = agent_page.split(
            "String _encodeDiagnosticsPayloadForUpload", 1
        )[1].split("List<dynamic> _boundedUploadList", 1)[0]

        self.assertIn("_compactSelectedFingerprintsForUpload(", encoder)
        self.assertIn("table-to-count-checksum-v1", encoder)
        self.assertIn("emergencyEncoded.length > _maxDiagnosticsUploadPayloadChars", encoder)
        self.assertIn("emergencyEncoded.length <= _maxDiagnosticsUploadPayloadChars", encoder)
        self.assertIn("logBudget = (logBudget * 0.8).floor()", encoder)
        self.assertIn("databaseAccessProblems", agent_page)

    def test_cancelled_job_forces_physical_fingerprint_refresh(self):
        agent_page = read_text("sync_windows_agent/lib/agent_page.dart")
        cancelled_body = agent_page.split(
            "} on _SyncJobCancelled catch (error)", 1
        )[1].split("} catch (error, stackTrace)", 1)[0]
        self.assertIn(
            "_scheduleSelectedTableFingerprintRefresh(force: true);",
            cancelled_body,
        )

    def test_sync_loop_suppresses_temporary_control_plane_errors_but_records_hard_failures(self):
        agent_page = read_text("sync_windows_agent/lib/agent_page.dart")
        live_sync_api = read_text("sync_windows_agent/lib/live_sync_api.dart")
        heartbeat_body = agent_page.split("Future<void> _syncWithControlPlane() async {", 1)[
            1
        ].split("Future<void> _uploadRequestedDiagnostics(", 1)[0]

        self.assertIn(
            "final temporaryControlPlaneUnavailable =",
            heartbeat_body,
        )
        self.assertIn(
            "_isTemporaryControlPlaneUnavailable(error);",
            heartbeat_body,
        )
        self.assertIn(
            "serverConnectedAfterHeartbeatFailure(",
            heartbeat_body,
        )
        self.assertIn("_serverConnected = nextServerConnected;", heartbeat_body)
        self.assertIn(
            "const Duration _defaultHeartbeatRequestTimeout = Duration(seconds: 30);",
            live_sync_api,
        )
        self.assertIn(
            "timeout: _heartbeatRequestTimeout",
            live_sync_api,
        )
        self.assertIn("_checkingServerConnection = false;", heartbeat_body)
        self.assertIn("_lastServerCheck = DateTime.now();", heartbeat_body)
        self.assertIn("_errorMessage = temporaryControlPlaneUnavailable", heartbeat_body)
        self.assertIn("? null\n            : error.toString();", heartbeat_body)

    def test_sync_loop_always_clears_busy_flag_and_retries_deferred_client_updates(self):
        agent_page = read_text("sync_windows_agent/lib/agent_page.dart")
        heartbeat_body = agent_page.split("Future<void> _syncWithControlPlane() async {", 1)[
            1
        ].split("Future<void> _uploadRequestedDiagnostics(", 1)[0]

        self.assertIn("if (!mounted || _syncLoopBusy) {", heartbeat_body)
        self.assertIn("_syncLoopBusy = true;", heartbeat_body)
        self.assertIn("} finally {", heartbeat_body)
        self.assertIn("_syncLoopBusy = false;", heartbeat_body)
        self.assertIn("_retryAutomaticClientUpdateIfReady();", heartbeat_body)
        self.assertLess(
            heartbeat_body.index("_syncLoopBusy = true;"),
            heartbeat_body.index("} finally {"),
        )
        self.assertLess(
            heartbeat_body.index("_syncLoopBusy = false;"),
            heartbeat_body.index("_retryAutomaticClientUpdateIfReady();"),
        )

    def test_sync_loop_processes_live_state_before_pending_jobs(self):
        agent_page = read_text("sync_windows_agent/lib/agent_page.dart")
        heartbeat_body = agent_page.split("Future<void> _syncWithControlPlane() async {", 1)[
            1
        ].split("Future<void> _uploadRequestedDiagnostics(", 1)[0]

        self.assertIn("_scheduleRequestedDiagnosticsUpload(heartbeat.diagnostics);", heartbeat_body)
        self.assertIn("await _flushPendingWindowActionAck();", heartbeat_body)
        self.assertIn("await _handleRequestedWindowAction(heartbeat.windowAction);", heartbeat_body)
        self.assertIn("await _handleRequestedClientUpdate(heartbeat.clientUpdate);", heartbeat_body)
        self.assertIn("_refreshAutoRequiredTables();", heartbeat_body)
        self.assertIn("unawaited(_processPendingJobs());", heartbeat_body)
        self.assertLess(
            heartbeat_body.index("_scheduleRequestedDiagnosticsUpload(heartbeat.diagnostics);"),
            heartbeat_body.index("unawaited(_processPendingJobs());"),
        )
        self.assertLess(
            heartbeat_body.index("_refreshAutoRequiredTables();"),
            heartbeat_body.index("unawaited(_processPendingJobs());"),
        )

    def test_requested_diagnostics_uploads_dedupe_by_request_id_and_release_busy_state(self):
        agent_page = read_text("sync_windows_agent/lib/agent_page.dart")
        diagnostics_body = agent_page.split(
            "void _scheduleRequestedDiagnosticsUpload(RemoteAgentDiagnostics diagnostics) {",
            1,
        )[1].split("Future<void> _handleRequestedWindowAction(", 1)[0]

        self.assertIn("if (!diagnostics.pending || _diagnosticsUploadBusy) {", diagnostics_body)
        self.assertIn("final requestId = diagnostics.requestId?.trim() ?? '';", diagnostics_body)
        self.assertIn(
            "if (requestId.isNotEmpty && _diagnosticsUploadRequestId == requestId) {",
            diagnostics_body,
        )
        self.assertIn("_diagnosticsUploadBusy = true;", diagnostics_body)
        self.assertIn(
            "_diagnosticsUploadRequestId = requestId.isEmpty ? null : requestId;",
            diagnostics_body,
        )
        self.assertIn("_uploadRequestedDiagnostics(diagnostics)", diagnostics_body)
        self.assertIn("if (requestId.isNotEmpty &&", diagnostics_body)
        self.assertIn("_diagnosticsUploadRequestId == requestId) {", diagnostics_body)
        self.assertIn("_diagnosticsUploadRequestId = null;", diagnostics_body)
        self.assertIn(".whenComplete(() {", diagnostics_body)
        self.assertIn("_diagnosticsUploadBusy = false;", diagnostics_body)

    def test_pending_window_action_ack_flush_is_non_reentrant_and_clears_only_matching_ack(self):
        agent_page = read_text("sync_windows_agent/lib/agent_page.dart")
        flush_body = agent_page.split(
            "Future<void> _flushPendingWindowActionAck() async {",
            1,
        )[1].split("Future<void> _queueWindowActionAck({", 1)[0]
        queue_body = agent_page.split(
            "Future<void> _queueWindowActionAck({",
            1,
        )[1].split("Future<void> _syncWithControlPlane() async {", 1)[0]

        self.assertIn(
            "if (pendingAck == null || _flushingPendingWindowActionAck) {",
            flush_body,
        )
        self.assertIn("_flushingPendingWindowActionAck = true;", flush_body)
        self.assertIn("await _controlPlaneClient.acknowledgeWindowAction(", flush_body)
        self.assertIn(
            "if (_pendingWindowActionAck?.requestId == pendingAck.requestId) {",
            flush_body,
        )
        self.assertIn("_pendingWindowActionAck = null;", flush_body)
        self.assertIn(
            "logStartupEvent('Window action acknowledgement retry failed: $error');",
            flush_body,
        )
        self.assertIn("_flushingPendingWindowActionAck = false;", flush_body)
        self.assertIn("_pendingWindowActionAck = _PendingWindowActionAck(", queue_body)
        self.assertIn("await _flushPendingWindowActionAck();", queue_body)

    def test_delta_apply_skips_full_table_fingerprint_after_success(self):
        agent_page = read_text("sync_windows_agent/lib/agent_page.dart")
        apply_body = agent_page.split(
            "Future<int> _applyDownloadedSnapshotToTarget({", 1
        )[1].split("Future<void> _markRemoteJobFailed(", 1)[0]

        self.assertIn("if (!applyDelta) {", apply_body)
        self.assertIn("final targetFingerprints = await _queryTableFingerprints(", apply_body)
        self.assertIn("bool refreshFingerprint = false", apply_body)
        self.assertIn("if (refreshFingerprint) {", apply_body)
        self.assertIn("selectiveRangeReconcile ||", agent_page)
        self.assertIn("(!snapshotToApply.isDelta &&", agent_page)
        self.assertIn("!authoritativeReconcile &&", agent_page)
        self.assertIn("!canonicalFullMerge", agent_page)
        self.assertIn("_applyTableFingerprints(", apply_body)
        self.assertIn("tables: [visibleTableName]", apply_body)

    def test_unique_business_key_failure_is_retryable_without_user_input(self):
        agent_page = read_text("sync_windows_agent/lib/agent_page.dart")
        failure_body = agent_page.split(
            "Future<void> _markRemoteJobFailed(RemoteSyncJob job, Object error) async {",
            1,
        )[1].split("Future<List<_SqlColumnDefinition>> _querySyncColumnDefinitions", 1)[0]

        self.assertIn(
            "job.direction == 'download' && isSyncIdentityCollision(error)",
            failure_body,
        )
        self.assertNotIn("await _controlPlaneClient.completeJob(", failure_body)
        self.assertNotIn("conflictKind: 'unique_business_key'", failure_body)
        self.assertIn("can be retried without user input", failure_body)
        self.assertIn("return;", failure_body)
        self.assertIn("await _controlPlaneClient.failJob(", failure_body)

    def test_authoritative_source_persists_the_verified_snapshot_fingerprint(self):
        agent_page = read_text("sync_windows_agent/lib/agent_page.dart")
        upload_body = agent_page.split(
            "Future<void> _processSnapshotRelayUploadJob(", 1
        )[1].split("Future<void> _processSnapshotRelayDownloadJob(", 1)[0]

        self.assertIn("rowCount:", upload_body)
        self.assertIn("snapshot.checksum.isNotEmpty", upload_body)
        self.assertIn("? snapshot.sourceRowCount", upload_body)
        self.assertIn("tableChecksum:", upload_body)
        self.assertIn("? snapshot.checksum", upload_body)
        self.assertIn("unawaited(_syncWithControlPlane());", upload_body)

    def test_job_changed_rows_never_replace_physical_table_row_count(self):
        agent_page = read_text("sync_windows_agent/lib/agent_page.dart")
        apply_state_body = agent_page.split(
            "void _applyRemoteJobState(", 1
        )[1].split("void _updateTraySyncIndicator()", 1)[0]

        self.assertIn("rowCount: current.rowCount", apply_state_body)
        self.assertNotIn("shouldApplyLocalRowCount", apply_state_body)
        self.assertNotIn("rowCount: job.rowCount,\n      message:", apply_state_body)

    def test_protocol_v4_multi_writer_is_hashed_delta_only_and_fails_closed_without_baseline(self):
        agent_page = read_text("sync_windows_agent/lib/agent_page.dart")
        client_api = read_text("sync_windows_agent/lib/live_sync_api.dart")
        sync_state = read_text("sync_windows_agent/lib/sync_state.dart")
        automatic_discovery = read_text(
            "sync_windows_agent/lib/automatic_change_discovery.dart"
        )
        control_plane = read_text("business/control_plane.tru")
        snapshot_body = agent_page.split(
            "Future<_RelaySnapshotDocument> _createRelaySnapshotForJob(", 1
        )[1].split("List<Map<String, String?>> _snapshotRows(", 1)[0]

        self.assertNotIn("server-anti-entropy", snapshot_body)
        self.assertIn("job.sourceClientName == 'server-bootstrap-v3'", snapshot_body)
        self.assertIn("if (rowCount != 0 || tracking == null)", snapshot_body)
        self.assertIn("_SyncBaselineReplanRequired", snapshot_body)
        self.assertIn("changeTrackingStatus: 'baseline_pending'", snapshot_body)
        self.assertIn("failureKind: 'baseline_required'", agent_page)
        self.assertIn("state.changeTrackingStatus != 'baseline_pending'", agent_page)
        self.assertIn("automaticBaselineMustWaitForUnion", agent_page)
        self.assertIn("probeStatus == 'baseline' && rowCount > 0", automatic_discovery)
        self.assertIn("previousVersion >= 0", snapshot_body)
        self.assertIn("const int kSyncProtocolVersion = 4", client_api)
        self.assertEqual(control_plane.count("field protocolVersion: int? min=3 max=4"), 2)
        self.assertIn("field protocolVersion: int min=3 max=4", control_plane)
        self.assertIn("__sync_row_hash", snapshot_body)
        self.assertIn("__sync_change_version", snapshot_body)
        self.assertIn("__sync_origin_client", snapshot_body)
        self.assertIn("required int protocolVersion", client_api)
        self.assertIn("required String syncEpoch", client_api)
        self.assertIn("final int protocolVersion", sync_state)
        self.assertIn("final String syncEpoch", sync_state)
        self.assertIn("void _prepareSyncProtocolJob(RemoteSyncJob job)", agent_page)
        self.assertIn("_fetchConsistentSourceTableSnapshot(", snapshot_body)

    def test_latest_change_uses_server_clock_and_filters_stale_server_rows(self):
        agent_page = read_text("sync_windows_agent/lib/agent_page.dart")
        client_api = read_text("sync_windows_agent/lib/live_sync_api.dart")
        merge = read_text("sync_windows_agent/lib/sql_sync_merge.dart")

        self.assertIn("serverTimeUtc", client_api)
        self.assertIn("serverClockOffset", client_api)
        self.assertIn("_normalizeDatabaseCommitToServerUtc", agent_page)
        self.assertIn("SYSUTCDATETIME()", agent_page)
        self.assertIn("__sync_database_modified_at_utc", agent_page)
        self.assertIn("__sync_server_received_at_utc", client_api)
        self.assertIn("__sync_server_sequence", client_api)
        self.assertIn("winnerPolicyApplied", client_api)
        self.assertIn("acceptedOperationIds.contains", client_api)
        self.assertIn("__sync_server_received_at_utc", merge)
        self.assertIn("__sync_server_sequence", merge)

    def test_complete_reconciliation_preserves_target_only_rows_and_verifies_incoming(self):
        agent_page = read_text("sync_windows_agent/lib/agent_page.dart")
        client_api = read_text("sync_windows_agent/lib/live_sync_api.dart")
        download_body = agent_page.split(
            "Future<void> _processSnapshotRelayDownloadJob(RemoteSyncJob job) async {", 1
        )[1].split("Future<_RelaySnapshotDocument> _createRelaySnapshotForJob(", 1)[0]
        snapshot_body = agent_page.split(
            "Future<_RelaySnapshotDocument> _createRelaySnapshotForJob(", 1
        )[1].split("List<Map<String, String?>> _snapshotRows(", 1)[0]
        apply_body = agent_page.split(
            "Future<int> _applyDownloadedSnapshotToTarget({", 1
        )[1].split("Future<void> _markRemoteJobFailed(", 1)[0]

        self.assertIn("server-authoritative-reconcile", download_body)
        self.assertIn("fullSnapshotApply: authoritativeReconcile", download_body)
        self.assertIn("authoritativeAppliedVersion = tracking.currentVersion", download_body)
        self.assertIn(
            "await _ensureChangeTrackingEnabledForDatabase(", download_body
        )
        self.assertIn("SqlSyncFingerprintAccumulator()", snapshot_body)
        self.assertIn("consistentSnapshot.rowCount", snapshot_body)
        self.assertIn("job.rowCount != consistentSnapshot.rowCount", snapshot_body)
        self.assertIn("sync.snapshot.inventory_refreshed", snapshot_body)
        self.assertIn(
            "await _ensureChangeTrackingEnabledForDatabase(", snapshot_body
        )
        self.assertIn(
            "canUseDelta &&\n"
            "        !multiClientUnionSnapshot &&\n"
            "        job.sourceClientName != 'server-authoritative-reconcile'",
            snapshot_body,
        )
        self.assertIn("Snapshot absence is never a delete instruction", apply_body)
        self.assertIn("isSqlSyncDurableTombstoneReassertion", apply_body)
        self.assertIn("server-validated durable tombstone reassertions", apply_body)
        self.assertIn("rowCountBefore.value - deleteRows.length", apply_body)
        self.assertIn("} else {", apply_body)
        self.assertIn("Unable to read the target row count before atomic delta apply.", apply_body)
        self.assertIn("deltaDeleteRows:", apply_body)
        self.assertNotIn("applySqlSyncRowsWithIsolation(", apply_body)
        self.assertIn("final unappliedRows = await _rowsWhoseContentChanged", apply_body)
        self.assertIn("Existing target-only rows were preserved", apply_body)
        self.assertIn("'snapshotChecksum': snapshotChecksum.trim()", client_api)

    def test_union_bootstrap_is_a_generic_atomic_non_destructive_merge(self):
        agent_page = read_text("sync_windows_agent/lib/agent_page.dart")
        client_api = read_text("sync_windows_agent/lib/live_sync_api.dart")
        merge = read_text("sync_windows_agent/lib/sql_sync_merge.dart")
        control_plane = read_text("business/control_plane.tru")
        apply_body = agent_page.split(
            "Future<int> _applyDownloadedSnapshotToTarget({", 1
        )[1].split("Future<void> _markRemoteJobFailed(", 1)[0]

        self.assertIn("!multiClientUnionSnapshot", agent_page)
        self.assertIn("downloadedSnapshot.canonicalFullMerge", agent_page)
        self.assertIn(
            "fullSnapshotApply: authoritativeReconcile || canonicalFullMerge",
            agent_page,
        )
        self.assertNotIn("requireNoLocalChangesAfterVersion", agent_page)
        self.assertIn("_deduplicateCanonicalFullMergeRows", client_api)
        self.assertIn("canonicalFullMerge", control_plane)
        self.assertIn("mergeParticipantCount", control_plane)
        self.assertNotIn("TABLOCKX", merge)
        self.assertNotIn("DELETE TOP", merge)
        self.assertIn("explicit-tombstones-only", merge)
        self.assertIn("sqlSyncDurableTombstoneReassertionField", merge)
        self.assertNotIn("authoritativeReplace", merge)
        self.assertNotIn("DELETE FROM $targetTable", merge)
        self.assertIn("resolveUniqueConflictsLatestWins", merge)
        self.assertGreaterEqual(
            apply_body.count("resolveUniqueConflictsLatestWins: true"), 2
        )
        self.assertGreaterEqual(
            apply_body.count("protectLocalChangesAfterVersion: postUploadChangeTrackingVersion"),
            2,
        )
        self.assertIn("...snapshot.uniqueKeyColumnSets", apply_body)
        self.assertIn(
            "final rowsForApply = coalesceSqlSyncDeltaRows(",
            apply_body,
        )
        self.assertNotIn(
            "applyDelta\n            ? coalesceSqlSyncDeltaRows(",
            apply_body,
        )
        self.assertIn("json['uniqueKeyColumnSets']", client_api)
        self.assertIn("RAISERROR", merge)
        self.assertNotIn("THROW 51000", merge)
        self.assertNotIn("AmnDb048", merge)

    def test_change_tracking_baselines_accept_enabled_initial_version_zero(self):
        agent_page = read_text("sync_windows_agent/lib/agent_page.dart")
        query_body = agent_page.split(
            "Future<_ChangeTrackingState?> _queryChangeTrackingState(", 1
        )[1].split(
            "Future<List<Map<String, String?>>> _fetchChangeTrackingRows(", 1
        )[0]
        upload_body = agent_page.split(
            "Future<void> _processSnapshotRelayUploadJob(RemoteSyncJob job) async {", 1
        )[1].split(
            "Future<void> _processSnapshotRelayDownloadJob(RemoteSyncJob job) async {", 1
        )[0]

        self.assertIn("FROM sys.change_tracking_databases", query_body)
        self.assertIn("FROM sys.change_tracking_tables", query_body)
        self.assertIn("values[0] != '1' || values[1] != '1'", query_body)
        self.assertIn("current < 0 || minimum < 0", query_body)
        self.assertNotIn("current <= 0", query_body)
        self.assertIn("changeTrackingVersion: uploadedVersion", upload_body)
        self.assertIn("changeTrackingOwner: widget.clientName", upload_body)

    def test_snapshot_upload_job_advances_through_start_progress_and_chunk_upload_only(self):
        agent_page = read_text("sync_windows_agent/lib/agent_page.dart")
        delta_packages = read_text("sync_windows_agent/lib/delta_package.dart")
        upload_body = agent_page.split(
            "Future<void> _processSnapshotRelayUploadJob(RemoteSyncJob job) async {", 1
        )[1].split("Future<void> _processSnapshotRelayDownloadJob(RemoteSyncJob job) async {", 1)[0]

        self.assertIn("await _controlPlaneClient.startJob(", upload_body)
        self.assertIn("status: 'snapshotting',", upload_body)
        self.assertIn("progress: 10,", upload_body)
        self.assertIn("await _controlPlaneClient.updateJobProgress(", upload_body)
        self.assertIn("status: 'uploading',", upload_body)
        self.assertIn("progress: 35,", upload_body)
        self.assertIn("await _controlPlaneClient.uploadMultiWriterDelta(", upload_body)
        self.assertIn("buildCompressedDeltaPackages(", upload_body)
        self.assertIn("maxRows: maxPackageRows", upload_body)
        self.assertIn("payloadEncoding: 'gzip-json'", upload_body)
        self.assertIn("payloadUncompressedBytes: package.uncompressedBytes", upload_body)
        self.assertIn("payloadCompressedBytes: package.compressedBytes", upload_body)
        self.assertIn("const int kDeltaPackageMaxRows = 100;", delta_packages)
        self.assertIn(
            "const int kDeltaPackageMaxUncompressedBytes = 512000;",
            delta_packages,
        )
        self.assertIn(
            "const int kDeltaPackageMaxCompressedBytes = 384000;",
            delta_packages,
        )
        self.assertNotIn("await _controlPlaneClient.uploadSnapshot(", upload_body)
        self.assertIn("_applyRemoteJobState(", upload_body)
        self.assertIn("appendHistory: true,", upload_body)
        self.assertIn("success: true,", upload_body)
        self.assertNotIn("await _controlPlaneClient.completeJob(", upload_body)

    def test_snapshot_download_job_completes_only_after_apply_succeeds(self):
        agent_page = read_text("sync_windows_agent/lib/agent_page.dart")
        download_body = agent_page.split(
            "Future<void> _processSnapshotRelayDownloadJob(RemoteSyncJob job) async {", 1
        )[1].split("Future<_RelaySnapshotDocument> _createRelaySnapshotForJob(", 1)[0]

        self.assertIn("await _controlPlaneClient.startJob(", download_body)
        self.assertIn("status: 'downloading',", download_body)
        self.assertIn("await _controlPlaneClient.downloadMultiWriterDelta(", download_body)
        self.assertNotIn("await _controlPlaneClient.downloadSnapshot(", download_body)
        self.assertIn("await _controlPlaneClient.updateJobProgress(", download_body)
        self.assertIn("status: 'applying',", download_body)
        self.assertIn("progress: 20,", download_body)
        self.assertIn("if (streamedTargetRowCount < 0)", download_body)
        self.assertIn("await _applyDownloadedSnapshotToTarget(", download_body)
        self.assertIn("await _rejectionOutbox.saveTable(", download_body)
        self.assertIn("rejectedRowCount: pendingAfterApply.length", download_body)
        self.assertIn("rejectionSummary:", download_body)
        self.assertIn("'rejectedRowCount': rejectedRowCount", read_text("sync_windows_agent/lib/live_sync_api.dart"))
        self.assertIn("'rejectionSummary': rejectionSummary.trim()", read_text("sync_windows_agent/lib/live_sync_api.dart"))
        self.assertIn("await _controlPlaneClient.completeJob(", download_body)
        self.assertIn("status: converged ? 'completed' : 'failed',", download_body)
        self.assertIn("final converged = pendingAfterApply.isEmpty;", download_body)
        self.assertIn("progress: 100,", download_body)
        self.assertLess(
            download_body.index("if (streamedTargetRowCount < 0)"),
            download_body.index("await _controlPlaneClient.completeJob("),
        )
        self.assertLess(
            download_body.index("await _rejectionOutbox.saveTable("),
            download_body.index("await _controlPlaneClient.completeJob("),
        )
        self.assertLess(
            download_body.index("await _rejectionOutbox.saveTable("),
            download_body.index("changeTrackingVersion: appliedVersion"),
        )

    def test_pending_job_failures_are_reported_back_to_control_plane_and_local_history(self):
        agent_page = read_text("sync_windows_agent/lib/agent_page.dart")
        pending_jobs_body = agent_page.split(
            "Future<void> _processPendingJobs() async {", 1
        )[1].split("List<RemoteSyncJob> _sortPendingJobsByDependencies(", 1)[0]
        fail_body = agent_page.split(
            "Future<void> _markRemoteJobFailed(RemoteSyncJob job, Object error) async {", 1
        )[1].split("Future<List<_SqlColumnDefinition>> _querySyncColumnDefinitions({", 1)[0]

        self.assertIn("await _processSnapshotJob(job);", pending_jobs_body)
        self.assertIn("await _markRemoteJobFailed(job, error);", pending_jobs_body)
        self.assertIn("Remote job ${job.id} failed during snapshot processing: $errorMessage", pending_jobs_body)
        self.assertIn("status: baselineReplan ? 'cancelled' : 'failed',", pending_jobs_body)
        self.assertIn("final baselineReplan = error is _SyncBaselineReplanRequired;", pending_jobs_body)
        self.assertIn("progress: 100,", pending_jobs_body)
        self.assertIn("completedAt: DateTime.now().toIso8601String(),", pending_jobs_body)
        self.assertIn("appendHistory: true,", pending_jobs_body)
        self.assertIn("success: false,", pending_jobs_body)
        self.assertIn("? 'Delta cancelled safely; waiting for automatic all-client baseline replan.'", pending_jobs_body)
        self.assertIn(": errorMessage,", pending_jobs_body)
        self.assertIn("await _controlPlaneClient.failJob(", fail_body)
        self.assertIn("progress: 100,", fail_body)
        self.assertIn("logStartupEvent('Unable to mark remote job ${job.id} failed: $failError');", fail_body)

    def test_only_successful_download_jobs_trigger_local_row_count_refresh(self):
        agent_page = read_text("sync_windows_agent/lib/agent_page.dart")
        pending_jobs_body = agent_page.split(
            "Future<void> _processPendingJobs() async {", 1
        )[1].split("List<RemoteSyncJob> _sortPendingJobsByDependencies(", 1)[0]

        self.assertIn("if (job.direction == 'download') {", pending_jobs_body)
        self.assertIn("unawaited(_refreshLocalRowCounts());", pending_jobs_body)
        self.assertLess(
            pending_jobs_body.index("await _processSnapshotJob(job);"),
            pending_jobs_body.index("if (job.direction == 'download') {"),
        )
        self.assertLess(
            pending_jobs_body.index("await _markRemoteJobFailed(job, error);"),
            pending_jobs_body.index("final failedJob = RemoteSyncJob("),
        )

    def test_pending_jobs_skip_duplicates_and_always_release_processing_ids(self):
        agent_page = read_text("sync_windows_agent/lib/agent_page.dart")
        pending_jobs_body = agent_page.split(
            "Future<void> _processPendingJobs() async {", 1
        )[1].split("List<RemoteSyncJob> _sortPendingJobsByDependencies(", 1)[0]

        self.assertIn(
            "if (!_processingJobIds.contains(candidate.id)) {", pending_jobs_body
        )
        self.assertIn(
            "if (!_processingJobIds.contains(nextJob.id) &&", pending_jobs_body
        )
        self.assertIn("if (_processingPendingJobsBusy) {", pending_jobs_body)
        self.assertIn("_processingPendingJobsBusy = true;", pending_jobs_body)
        self.assertIn("_processingPendingJobsBusy = false;", pending_jobs_body)
        self.assertIn("Could not prepare pending sync jobs", pending_jobs_body)
        self.assertLess(
            pending_jobs_body.index("try {"),
            pending_jobs_body.index("_sortPendingJobsByDependencies(pendingJobs)"),
        )
        self.assertIn("_processingJobIds.add(job.id);", pending_jobs_body)
        self.assertIn("} finally {", pending_jobs_body)
        self.assertIn("_processingJobIds.remove(job.id);", pending_jobs_body)
        self.assertLess(
            pending_jobs_body.index("_processingJobIds.add(job.id);"),
            pending_jobs_body.index("await _processSnapshotJob(job);"),
        )
        self.assertLess(
            pending_jobs_body.index("} finally {"),
            pending_jobs_body.index("_processingJobIds.remove(job.id);"),
        )

    def test_pending_jobs_are_ordered_by_dependency_depth_before_creation_time(self):
        agent_page = read_text("sync_windows_agent/lib/agent_page.dart")
        sort_body = agent_page.split(
            "List<RemoteSyncJob> _sortPendingJobsByDependencies(List<RemoteSyncJob> jobs) {",
            1,
        )[1].split("int _tableDependencyDepth(", 1)[0]
        depth_body = agent_page.split(
            "int _tableDependencyDepth(",
            1,
        )[1].split("Future<void> _processSnapshotJob(RemoteSyncJob job) async {", 1)[0]

        self.assertIn("if (jobs.length < 2) {", sort_body)
        self.assertIn("leftBatchUpload", sort_body)
        self.assertIn("final pendingTables = jobs.map((job) => job.table.trim()).toSet();", sort_body)
        self.assertIn("!pendingTables.contains(table)", sort_body)
        self.assertIn("!pendingTables.contains(relatedTable)", sort_body)
        self.assertIn("dependencyGraph.putIfAbsent(table, () => <String>{}).add(relatedTable);", sort_body)
        self.assertIn("final leftDepth = _tableDependencyDepth(", sort_body)
        self.assertIn("final rightDepth = _tableDependencyDepth(", sort_body)
        self.assertIn("if (leftDepth != rightDepth) {", sort_body)
        self.assertIn("return leftDepth.compareTo(rightDepth);", sort_body)
        self.assertIn("return left.createdAt.compareTo(right.createdAt);", sort_body)
        self.assertIn("if (!activeStack.add(normalizedTable)) {", depth_body)
        self.assertIn("return 0;", depth_body)
        self.assertIn("depth = math.max(", depth_body)
        self.assertIn("cache[normalizedTable] = depth;", depth_body)

    def test_server_requested_client_updates_acknowledge_unsupported_runtimes(self):
        agent_page = read_text("sync_windows_agent/lib/agent_page.dart")
        update_body = agent_page.split(
            "Future<void> _handleRequestedClientUpdate(", 1
        )[1].split("Future<String> _buildDiagnosticsPayload()", 1)[0]

        self.assertIn("if (!_supportsAutomaticClientUpdate) {", update_body)
        self.assertIn("await _controlPlaneClient.acknowledgeClientUpdate(", update_body)
        self.assertIn("status: 'unsupported',", update_body)
        self.assertIn(
            "Automatic client updates are unavailable in this runtime. Start the packaged Windows client to apply live updates.",
            update_body,
        )
        self.assertIn(
            "Server-requested client update unsupported acknowledgement failed: $error",
            update_body,
        )
        self.assertIn("_maybeAutoApplyClientUpdate(updateInfo, force: true);", update_body)
        self.assertNotIn("_pendingForcedClientUpdateInfo = updateInfo;", update_body)

    def test_sqlcmd_calls_are_bounded_by_timeout(self):
        agent_page = read_text("sync_windows_agent/lib/agent_page.dart")
        client_api = read_text("sync_windows_agent/lib/live_sync_api.dart")
        sync_schema = read_text("sync_windows_agent/lib/sql_sync_schema.dart")

        self.assertIn("const Duration _defaultSqlCmdTimeout = Duration(minutes: 2);", agent_page)
        self.assertIn("const Duration _snapshotSqlCmdTimeout = Duration(minutes: 10);", agent_page)
        self.assertIn(
            "const Duration _atomicSnapshotApplySqlCmdTimeout = Duration(hours: 4);",
            agent_page,
        )
        self.assertIn("final exitCodeFuture = process.exitCode.timeout(timeout);", agent_page)
        self.assertIn("await cancellation.race(exitCodeFuture)", agent_page)
        self.assertIn("sqlcmd timed out after ${_formatDurationForLog(timeout)}.", agent_page)
        self.assertIn("timeout: _snapshotSqlCmdTimeout,", agent_page)
        self.assertIn("'-y',", agent_page)
        self.assertIn("'0',", agent_page)
        self.assertIn("if (suppressHeaders) ...['-h', '-1']", agent_page)
        self.assertIn("List<String> _dataOutputLines(String output)", agent_page)
        self.assertIn("shouldUseSqlCmdInputFile(", agent_page)
        self.assertIn("isWindows: Platform.isWindows,", agent_page)
        self.assertIn("column.usesHexTextTransport", agent_page)
        self.assertIn("decodeSqlServerUtf16Hex(decoded.substring(2))", agent_page)
        self.assertIn("buildSqlSyncTransportValueExpression(", agent_page)
        self.assertIn(
            "CONVERT(varbinary(max), CONVERT(nvarchar(max), $columnReference))",
            sync_schema,
        )
        self.assertIn(
            "return 'CONVERT(nvarchar(100), $columnReference, 3)';",
            sync_schema,
        )
        self.assertIn("normalized == 'float' || normalized == 'real'", sync_schema)
        self.assertNotIn(
            "return 'CONVERT(nvarchar(max), $columnReference)';\n  }\n  if (normalized == 'money'",
            sync_schema,
        )
        self.assertIn("bool _looksLikeHeaderLine(List<String> lines, int index)", agent_page)
        self.assertIn("bool _isHeaderSeparatorLine(String line)", agent_page)
        self.assertIn(
            "const Duration _diagnosticsChangeTrackingTimeout = Duration(seconds: 20);",
            agent_page,
        )

    def test_atomic_full_snapshot_apply_does_not_retry_at_ten_minutes(self):
        agent_page = read_text("sync_windows_agent/lib/agent_page.dart")
        client_api = read_text("sync_windows_agent/lib/live_sync_api.dart")
        apply_body = agent_page.split(
            "Future<_TargetApplyResult> _applySourceRowsToTarget(", 1
        )[1].split("String _nextTargetSnapshotStageTableName(", 1)[0]

        self.assertEqual(
            apply_body.count("timeout: _atomicSnapshotApplySqlCmdTimeout,"),
            1,
        )
        self.assertNotIn(
            "context: 'target snapshot stage load',\n        timeout: _snapshotSqlCmdTimeout,",
            apply_body,
        )
        self.assertNotIn(
            "context: 'target snapshot merge',\n        timeout: _snapshotSqlCmdTimeout,",
            apply_body,
        )
        self.assertIn(
            "const int _maxDiagnosticsUploadPayloadChars = 60000;",
            agent_page,
        )
        self.assertIn(
            "_buildChangeTrackingDiagnosticsForUpload() async {",
            agent_page,
        )
        self.assertIn(
            "await _queryChangeTrackingDiagnostics().timeout(",
            agent_page,
        )
        self.assertIn("String _encodeDiagnosticsPayloadForUpload(", agent_page)
        self.assertIn("_compactChangeTrackingDatabasesForUpload(", agent_page)
        self.assertIn("_minimalChangeTrackingDatabaseForUpload(", agent_page)
        self.assertIn(
            "const Duration _defaultDiagnosticsUploadRequestTimeout = Duration(minutes: 2);",
            client_api,
        )
        self.assertIn(
            "timeout: _diagnosticsUploadRequestTimeout",
            client_api,
        )

    def test_atomic_stage_load_is_chunked_resumable_and_reports_progress(self):
        merge_helper = read_text("sync_windows_agent/lib/sql_sync_merge.dart")
        agent_page = read_text("sync_windows_agent/lib/agent_page.dart")

        apply_body = agent_page.split(
            "Future<_TargetApplyResult> _applySourceRowsToTarget(", 1
        )[1].split("String _nextTargetSnapshotStageTableName(", 1)[0]

        self.assertIn("targetSnapshotInsertRowsPerStatement = 1000", merge_helper)
        self.assertIn("replaceExisting: false", apply_body)
        self.assertIn("_queryTargetSnapshotStageRowCount(", apply_body)
        self.assertIn("while (stagedRowCount < rows.length)", apply_body)
        self.assertIn("buildTargetSnapshotStageInsertSql(", apply_body)
        self.assertIn("context: 'target snapshot stage chunk'", apply_body)
        self.assertIn("final resumedRowCount = stagedRowCount", apply_body)
        self.assertIn("if (mergeCompleted)", apply_body)
        self.assertIn("_targetSnapshotStageTableNameForOperation(", apply_body)
        self.assertIn("Staged $loadedRows of $totalRows rows in resumable chunks", agent_page)
        self.assertIn("Staging complete; atomically merging changes", agent_page)
        self.assertIn("SELECT __row_num, $sourceColumnList", merge_helper)
        self.assertIn("Transport/process interruption", merge_helper)
        self.assertEqual(
            merge_helper.split("String buildTargetSnapshotStageApplySql(", 1)[1]
            .split("String _buildStagedDeltaDeleteStatements(", 1)[0]
            .count("DROP TABLE $stageTarget"),
            1,
        )

    def test_atomic_stage_load_separates_sqlcmd_batches_to_bound_server_memory(self):
        # Retain the INC-055 catalog selector while the stronger INC-092
        # regression verifies durable cross-process staging and progress.
        self.test_atomic_stage_load_is_chunked_resumable_and_reports_progress()

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
        app_source = read_text("sync_windows_agent/lib/app.dart")
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
            "const requestedTables = expand_sync_job_tables_for_owner(ownerId, unique_string_values(tables))",
            control_plane,
        )
        self.assertIn("final tablesToQueue = <String>{", agent_page)
        self.assertIn("..._relatedSyncKeysFor(syncKey)", agent_page)

    def test_windows_update_script_restarts_only_the_target_install(self):
        update_script = read_text("update.ps1")
        publish_script = read_text("scripts/publish_windows_client_update.ps1")
        runner_main = read_text("sync_windows_agent/windows/runner/main.cpp")
        runner_window = read_text("sync_windows_agent/windows/runner/flutter_window.cpp")

        self.assertIn("function Get-AgentProcesses {", update_script)
        self.assertIn("function Stop-AgentProcesses {", update_script)
        self.assertIn("function Get-SupervisorScriptPath {", update_script)
        self.assertIn("function Start-SupervisorProcess {", update_script)
        self.assertIn("function Update-StartupShortcutToSupervisor {", update_script)
        self.assertIn("sync_windows_agent_supervisor.ps1", update_script)
        self.assertIn("ensureSupervisorRunning", read_text("sync_windows_agent/lib/window_settings.dart"))
        self.assertIn("unawaited(", read_text("sync_windows_agent/lib/app.dart"))
        self.assertIn("WindowsAgentWindowSettings.ensureSupervisorRunning()", read_text("sync_windows_agent/lib/app.dart"))
        self.assertIn(
            "Timed out waiting for sync_windows_agent.exe to exit from $TargetInstallDir",
            update_script,
        )
        self.assertIn(
            "Ensuring the prior client instance from this install is stopped before install.",
            update_script,
        )
        self.assertIn(
            "Stopping any remaining client instance from this install before relaunch.",
            update_script,
        )
        self.assertNotIn(
            "Stop-AgentProcesses -TargetInstallDir $InstallDir -AllInstances",
            update_script,
        )
        self.assertIn('argument == "--start-minimized"', runner_main)
        self.assertIn("GetInstanceMutexName()", runner_main)
        self.assertIn(
            'L"Local\\\\MicrosoftSqlServerSyncAgent_%016llX"',
            runner_main,
        )
        self.assertIn("launching minimized to tray", runner_window)
        self.assertIn("!start_minimized_", runner_window)
        self.assertIn("Shell_NotifyIcon(NIM_DELETE, &tray_icon_data_);", runner_window)
        self.assertIn('RegisterWindowMessageW(L"TaskbarCreated")', runner_window)
        self.assertIn("TaskbarCreated; restoring tray icon", runner_window)
        self.assertIn("StartIndependentSupervisor();", runner_main)
        self.assertIn("before Flutter initialization", runner_main)
        self.assertIn("changeTrackingOwner", read_text("sync_windows_agent/lib/sync_state.dart"))
        self.assertIn("changeTrackingOwner ==", read_text("sync_windows_agent/lib/agent_page.dart"))
        self.assertIn(
            "Applied ${applyStats.appliedRows} change",
            read_text("sync_windows_agent/lib/agent_page.dart"),
        )
        self.assertIn("Protocol-v3 jobs require a batch", read_text("sync_windows_agent/lib/agent_page.dart"))
        self.assertNotIn("manifest.latestZipUrl", update_script)
        self.assertNotIn("latestZipUrl =", publish_script)

    def test_local_launcher_reuses_backend_and_waits_for_desktop_boot(self):
        run_script = read_text("run.ps1")

        self.assertIn("$existingBackendProcess = Get-RepoBackendServerProcess", run_script)
        self.assertIn(
            'Write-Host "Reusing healthy local backend server on port $backendPort."',
            run_script,
        )
        self.assertIn("function Get-RepoDesktopLauncherProcess {", run_script)
        self.assertIn("$script:lastDesktopLaunch = $null", run_script)
        self.assertIn("$script:lastDesktopLaunch = Get-Date", run_script)
        self.assertIn("$desktopLauncherProcess = Get-RepoDesktopLauncherProcess", run_script)
        self.assertIn(
            "if ($null -ne $script:lastDesktopLaunch -and ((Get-Date) - $script:lastDesktopLaunch).TotalSeconds -lt 30)",
            run_script,
        )

    def test_shell_auto_update_stays_active_for_logged_in_clients(self):
        app_source = read_text("sync_windows_agent/lib/app.dart")
        shell_check_body = app_source.split("Future<void> _checkShellClientUpdate() async {", 1)[
            1
        ].split("Future<void> _maybeAutoApplyShellClientUpdate(", 1)[0]
        shell_apply_body = app_source.split(
            "Future<void> _maybeAutoApplyShellClientUpdate(", 1
        )[1].split("void _migrateStoredClientState(", 1)[0]

        self.assertNotIn("_dashboardSessionActive", shell_check_body)
        self.assertNotIn("_dashboardSessionActive", shell_apply_body)
        self.assertIn("Applying shell client update automatically:", app_source)

    def test_windows_updater_owns_shutdown_and_published_version_matches_binary(self):
        app_source = read_text("sync_windows_agent/lib/app.dart")
        agent_page = read_text("sync_windows_agent/lib/agent_page.dart")
        publish_script = read_text("scripts/publish_windows_client_update.ps1")
        shell_apply_body = app_source.split(
            "Future<void> _maybeAutoApplyShellClientUpdate(", 1
        )[1].split("void _migrateStoredClientState(", 1)[0]
        client_apply_body = agent_page.split(
            "Future<void> _maybeAutoApplyClientUpdate(", 1
        )[1].split("Future<void> _checkClientUpdate()", 1)[0]

        self.assertNotIn("exit(0)", shell_apply_body)
        self.assertNotIn("exit(0)", client_apply_body)
        self.assertIn("the updater owns shutdown and restart", shell_apply_body)
        self.assertIn("the updater owns shutdown and restart", client_apply_body)
        self.assertIn("VersionInfo.ProductVersion", publish_script)
        self.assertIn("does not match pubspec/manifest version", publish_script)

    def test_server_requested_update_waits_for_active_sql_job_boundary(self):
        agent_page = read_text("sync_windows_agent/lib/agent_page.dart")
        update_body = agent_page.split(
            "Future<void> _maybeAutoApplyClientUpdate(", 1
        )[1].split("String _clientUpdateCommand", 1)[0]
        job_loop = agent_page.split(
            "Future<void> _processPendingJobs() async", 1
        )[1].split("void _checkSyncJobNotCancelled", 1)[0]

        self.assertIn("_clientUpdateMustWaitForSafeSyncBoundary", update_body)
        self.assertIn("_processingPendingJobsBusy", agent_page)
        self.assertIn("_processingJobIds.isNotEmpty", agent_page)
        self.assertIn("_pendingForcedClientUpdateInfo = updateInfo", update_body)
        self.assertIn("if (_pendingForcedClientUpdateInfo != null)", job_loop)
        self.assertIn("break;", job_loop)
        self.assertIn("_retryAutomaticClientUpdateIfReady();", job_loop)

    def test_user_close_pauses_supervisor_until_manual_client_launch(self):
        update_script = read_text("update.ps1")
        supervisor = read_text("sync_windows_agent_supervisor.ps1")
        runner_main = read_text("sync_windows_agent/windows/runner/main.cpp")
        flutter_window = read_text(
            "sync_windows_agent/windows/runner/flutter_window.cpp"
        )
        marker_name = "sync_windows_agent.user-stopped"

        self.assertIn(marker_name, supervisor)
        ensure_body = supervisor.split("function Ensure-AgentRunning {", 1)[1].split(
            "function Invoke-IndependentUpdateCheck", 1
        )[0]
        self.assertIn("Test-Path -LiteralPath $userStoppedMarkerPath", ensure_body)
        update_check_body = supervisor.split(
            "function Invoke-IndependentUpdateCheck {", 1
        )[1].split("$mutexName =", 1)[0]
        self.assertIn("Test-Path -LiteralPath $userStoppedMarkerPath", update_check_body)
        self.assertIn("only a manual launch may resume it", update_check_body)
        self.assertIn(marker_name, flutter_window)
        self.assertIn("MarkUserRequestedStop();", flutter_window)
        self.assertIn("close and keep the app stopped", flutter_window)
        self.assertIn(marker_name, runner_main)
        self.assertIn("if (!start_minimized)", runner_main)
        self.assertIn("ResumeAfterManualLaunch();", runner_main)
        self.assertIn("std::filesystem::remove(marker_path", runner_main)
        self.assertLess(
            runner_main.index("if (!AcquireSingleInstanceMutex())"),
            runner_main.index("ResumeAfterManualLaunch();"),
        )
        self.assertGreaterEqual(update_script.count(marker_name), 2)
        self.assertGreaterEqual(
            update_script.count(
                "Updated client remains stopped because the user closed it. A manual launch is required."
            ),
            2,
        )

    def test_windows_agent_can_apply_server_requested_client_updates(self):
        control_plane = read_text("business/control_plane.tru")
        agent_page = read_text("sync_windows_agent/lib/agent_page.dart")
        app_source = read_text("sync_windows_agent/lib/app.dart")
        client_api = read_text("sync_windows_agent/lib/live_sync_api.dart")
        web_api = read_text("frontend/lib/live_sync_api.dart")
        web_models = read_text("frontend/lib/models.dart")
        dashboard = read_text("frontend/lib/dashboard_page.dart")

        self.assertIn("agent_client_update_request", control_plane)
        self.assertIn("agent_client_update_request_all", control_plane)
        self.assertIn("agent_client_update_ack", control_plane)
        self.assertIn("await _handleRequestedClientUpdate(heartbeat.clientUpdate);", agent_page)
        self.assertIn("Future<void> _handleRequestedClientUpdate(", agent_page)
        self.assertIn("ClientUpdateInfo? _pendingForcedClientUpdateInfo;", agent_page)
        self.assertIn("final forcedUpdateInfo = _pendingForcedClientUpdateInfo;", agent_page)
        self.assertIn("unawaited(_maybeAutoApplyClientUpdate(forcedUpdateInfo, force: true));", agent_page)
        self.assertIn("await _maybeAutoApplyClientUpdate(updateInfo, force: true);", agent_page)
        self.assertIn("_pendingForcedClientUpdateInfo = updateInfo;", agent_page)
        self.assertIn("_scheduleAutomaticClientUpdateRetry(updateInfo);", agent_page)
        self.assertIn("_clientUpdateApplyRetryTimer = Timer(_autoUpdateRetryCooldown", agent_page)
        self.assertIn("_applyingClientUpdate = false;", agent_page)
        self.assertIn("_shellClientUpdateApplyRetryTimer = Timer(", app_source)
        self.assertIn("_applyingShellClientUpdate = false;", app_source)
        self.assertIn("if (!force &&", agent_page)
        self.assertIn("if (_applyingClientUpdate || _checkingClientUpdate) {", agent_page)
        self.assertIn("if (force) {", agent_page)
        self.assertIn("_pendingForcedClientUpdateInfo = updateInfo;", agent_page)
        self.assertIn("} finally {", agent_page)
        self.assertIn("_retryAutomaticClientUpdateIfReady();", agent_page)
        self.assertIn("Process.start(\n        'powershell.exe',", agent_page)
        self.assertNotIn("Process.start('cmd.exe'", agent_page)
        self.assertIn("Process.start(\n        'powershell.exe',", app_source)
        self.assertNotIn("Process.start('cmd.exe'", app_source)
        self.assertIn("Future<RemoteAgentClientUpdate> acknowledgeClientUpdate(", client_api)
        self.assertIn("class RemoteAgentClientUpdate {", client_api)
        self.assertIn("requestAllAgentClientUpdates() async {", web_api)

    def test_update_script_keeps_noop_running_and_recovers_after_failure(self):
        update_script = read_text("update.ps1")
        self.assertIn(
            "No installation required. The current client and supervisor remain running.",
            update_script,
        )
        self.assertIn("Attempting recovery relaunch of the current client.", update_script)
        self.assertIn("Start-UpdatedClient -ExecutablePath $currentExe", update_script)
        self.assertIn("Updater failed:", update_script)

    def test_windows_update_is_bounded_transactional_and_rolls_back_failed_startup(self):
        update_script = read_text("update.ps1")

        self.assertIn("class SqlSyncAgentUpdateWebClient : WebClient", update_script)
        self.assertIn("ConnectTimeoutMilliseconds = 45000", update_script)
        self.assertIn("ReadWriteTimeoutMilliseconds = 300000", update_script)
        self.assertIn("failed after 3 bounded attempts", update_script)
        self.assertLess(
            update_script.index("$updateMutex = [System.Threading.Mutex]::new"),
            update_script.index("$manifest = Invoke-UpdateRestMethod"),
        )
        self.assertIn("function Save-InstallRollbackSnapshot {", update_script)
        self.assertIn("function Restore-InstallRollbackSnapshot {", update_script)
        self.assertIn("function Wait-AgentStartupStable {", update_script)
        self.assertIn("Saving transactional rollback snapshot", update_script)
        self.assertIn("Updated client startup verification passed.", update_script)
        self.assertIn("rolling back the complete managed-file change set", update_script)
        self.assertIn("The previous version was restored and restarted safely", update_script)
        self.assertGreaterEqual(update_script.count("no target client appeared during the bounded startup attempts"), 2)
        self.assertGreaterEqual(update_script.count("$supervisorProcess.Refresh()"), 2)

    def test_web_updater_cleanup_is_available_in_parent_and_deferred_scopes(self):
        update_script = read_text("update.ps1")
        helper_start = update_script.index("$helper = @'")
        cleanup_positions = [
            match.start()
            for match in re.finditer(
                r"function Stop-ObsoleteInstallProcesses \{", update_script
            )
        ]

        self.assertEqual(len(cleanup_positions), 2)
        self.assertLess(cleanup_positions[0], helper_start)
        self.assertGreater(cleanup_positions[1], helper_start)

    def test_updater_waits_for_existing_supervisor_to_launch_target_client(self):
        update_script = read_text("update.ps1")
        self.assertGreaterEqual(update_script.count("$attempt -le 45"), 2)
        self.assertGreaterEqual(
            update_script.count("Get-AgentProcesses -TargetInstallDir $TargetInstallDir"),
            6,
        )
        self.assertGreaterEqual(
            update_script.count("no target client appeared during the bounded startup attempts"),
            2,
        )

    def test_windows_task_cleanup_skips_non_executable_action_types(self):
        update_script = read_text("update.ps1")
        supervisor = read_text("sync_windows_agent_supervisor.ps1")
        for source in (update_script, supervisor):
            self.assertIn("$_.PSObject.Properties['Execute']", source)
            self.assertIn("$null -ne $executeProperty", source)
            self.assertNotIn('"$($_.Execute) $($_.Arguments)"', source)

    def test_windows_update_resumes_verified_differential_payloads(self):
        update_script = read_text("update.ps1")
        server = read_text("frontend/server.js")

        self.assertIn("function Invoke-ResumableUpdateWebRequest {", update_script)
        self.assertIn('$partialFile = "$OutFile.part"', update_script)
        self.assertIn("$request.AddRange($existingBytes)", update_script)
        self.assertIn("[System.IO.FileMode]::Append", update_script)
        self.assertIn("Partial bytes were preserved for the next updater run", update_script)
        self.assertIn('ChildPath ".update-cache\\$safeTargetVersion"', update_script)
        self.assertLess(
            update_script.index("$persistentCacheRoot ="),
            update_script.index("$workRoot ="),
        )
        self.assertIn("Test-InstalledFileMatchesManifest -Path $partialFile", update_script)
        self.assertIn("Copy-Item -LiteralPath $cachedPath -Destination $stagedPath -Force", update_script)

        self.assertIn("async function tryServeClientUpdate(pathname, req, res)", server)
        self.assertIn('req.headers.range || ""', server)
        self.assertIn('"Accept-Ranges": "bytes"', server)
        self.assertIn('"Content-Range": `bytes */${buffer.length}`', server)
        self.assertIn("statusCode = 206", server)
        self.assertIn("buffer.subarray(start, end + 1)", server)

    def test_client_manifest_uses_immutable_release_scoped_updater(self):
        publisher = read_text("scripts/publish_windows_client_update.ps1")

        self.assertIn(
            'updateScriptUrl = "$publicRoot/packages/$packageDirName/update.ps1"',
            publisher,
        )
        self.assertNotIn('updateScriptUrl = "$publicRoot/update.ps1"', publisher)

    def test_windows_update_uses_resumable_verified_compressed_differentials(self):
        update_script = read_text("update.ps1")
        publisher = read_text("scripts/publish_windows_client_update.ps1")

        self.assertIn("compression = 'gzip'", publisher)
        self.assertIn("transferSha256", publisher)
        self.assertIn("transferSizeBytes", publisher)
        self.assertIn(".sqlsync.gz", publisher)
        self.assertIn("function Expand-VerifiedGzipUpdateFile {", update_script)
        self.assertIn("Invoke-ResumableUpdateWebRequest -Uri $fileUrl", update_script)
        self.assertLess(
            update_script.index("Invoke-ResumableUpdateWebRequest -Uri $fileUrl"),
            update_script.index("Expand-VerifiedGzipUpdateFile -SourcePath $cachedPath"),
        )
        self.assertLess(
            update_script.index("Expand-VerifiedGzipUpdateFile -SourcePath $cachedPath"),
            update_script.index("Test-InstalledFileMatchesManifest -Path $stagedPath"),
        )

    def test_client_updates_pin_immutable_versioned_manifests_and_packages(self):
        publisher = read_text("scripts/publish_windows_client_update.ps1")
        updater = read_text("update.ps1")
        image_builder = read_text("scripts/build_production_images.ps1")
        dockerfile = read_text("frontend/Dockerfile")
        server = read_text("frontend/server.js")

        self.assertIn(
            'filesManifestUrl = "$publicRoot/packages/$packageDirName/files.json"',
            publisher,
        )
        self.assertIn("Immutable file manifest identity does not match", updater)
        self.assertIn("immutablePackageName", image_builder)
        self.assertIn("COPY client-updates/packages /app/public/client-updates/packages", dockerfile)
        self.assertIn('max-age=31536000, immutable', server)

    def test_server_requested_update_reports_durable_download_phase(self):
        agent_page = read_text("sync_windows_agent/lib/agent_page.dart")
        handler = agent_page.split(
            "Future<void> _handleRequestedClientUpdate(", 1
        )[1].split("Future<String> _buildDiagnosticsPayload()", 1)[0]
        clients_page = read_text("frontend/lib/clients_page.dart")

        self.assertIn("status: reportedStatus", handler)
        self.assertIn("'installing' => 'installing'", handler)
        self.assertIn("_ => 'downloading'", handler)
        self.assertIn("'failed' => 'failed'", handler)
        self.assertIn("durable updater accepted this request", handler)
        self.assertIn("Verified files and partial downloads will be reused", handler)
        self.assertIn("continuing the durable update", handler)
        self.assertIn("'downloading' => _clientUpdateDownloadLabel", clients_page)

    def test_clients_page_shows_active_phase_progress_and_speed(self):
        web = read_text("frontend/lib/clients_page.dart")
        status = web.split("String _clientActivityStatus(", 1)[1].split(
            "Color _clientActivityColor", 1
        )[0]
        self.assertIn("_primaryActiveJob(jobs)", status)
        self.assertIn("_activeJobProgressLabel(activeJob)", status)
        self.assertIn("job.progress.clamp(0, 100)", status)
        self.assertIn("rowsPerSecond", status)
        self.assertIn("percentPerMinute", status)
        self.assertIn("no movement", status)
        self.assertIn("status == 'waiting' || status == 'queued'", status)

    def test_client_update_download_progress_is_checkpointed_and_relayed(self):
        updater = read_text("update.ps1")
        agent = read_text("sync_windows_agent/lib/agent_page.dart")
        api = read_text("sync_windows_agent/lib/live_sync_api.dart")
        web = read_text("frontend/lib/clients_page.dart")

        self.assertIn("function Write-UpdateProgress", updater)
        self.assertIn("update-progress.json", updater)
        self.assertIn("Publish-UpdateDownloadProgress", updater)
        self.assertIn("Progress reporting is best effort", updater)
        self.assertIn("_readClientUpdateProgress(manifestVersion)", agent)
        self.assertIn("progress['version']", agent)
        self.assertIn("downloadedBytes: localProgress?['downloadedBytes']", agent)
        self.assertIn("if (downloadedBytes != null) 'downloadedBytes'", api)
        self.assertIn("Update downloading $percent%", web)
        self.assertIn("_formatBytes(downloaded)", web)

    def test_verified_download_reports_applying_before_atomic_sql_work(self):
        agent_page = read_text("sync_windows_agent/lib/agent_page.dart")
        download = agent_page.split(
            "Future<void> _processSnapshotRelayDownloadJob(", 1
        )[1].split("Future<", 1)[0]

        buffered = download.index("'sync.download.buffered'")
        applying = download.index("Verified download complete; atomically applying")
        sql_apply = download.index("await _applyDownloadedSnapshotToTarget(")
        self.assertLess(buffered, applying)
        self.assertLess(applying, sql_apply)
        self.assertIn("status: 'applying'", download[buffered:sql_apply])
        self.assertIn("progress: 55", download[buffered:sql_apply])

    def test_authenticated_shell_defers_updates_to_job_aware_agent_page(self):
        app = read_text("sync_windows_agent/lib/app.dart")
        shell_apply = app.split(
            "Future<void> _maybeAutoApplyShellClientUpdate(", 1
        )[1].split("void _migrateStoredClientState", 1)[0]
        agent = read_text("sync_windows_agent/lib/agent_page.dart")
        agent_apply = agent.split(
            "Future<void> _maybeAutoApplyClientUpdate(", 1
        )[1].split("String _clientUpdateCommand", 1)[0]

        self.assertIn("_authToken?.trim().isNotEmpty", shell_apply)
        self.assertLess(
            shell_apply.index("_authToken?.trim().isNotEmpty"),
            shell_apply.index("Process.start("),
        )
        self.assertIn("_processingJobIds.isNotEmpty", agent_apply)
        self.assertIn("job.status == 'running' || job.status == 'applying'", agent_apply)

    def test_large_content_comparison_uses_one_set_based_sqlcmd_launch(self):
        agent = read_text("sync_windows_agent/lib/agent_page.dart")
        lookup = agent.split(
            "Future<List<Map<String, dynamic>>> _fetchRowsByPrimaryKeys(", 1
        )[1].split("String _sourceBatchEncodedColumnExpression(", 1)[0]
        merge = read_text("sync_windows_agent/lib/sql_sync_merge.dart")
        builder = merge.split(
            "String buildTargetPrimaryKeyLookupSql(", 1
        )[1].split("String buildTargetSnapshotStageApplySql(", 1)[0]

        self.assertEqual(lookup.count("await _runSqlCmd("), 1)
        self.assertNotIn("const keyBatchSize = 100", lookup)
        self.assertIn("_targetSnapshotStageTableNameForOperation(", lookup)
        self.assertIn("replaceExisting: false", lookup)
        self.assertIn("_queryTargetSnapshotStageRowCount(", lookup)
        self.assertIn("while (stagedRowCount < keyRows.length)", lookup)
        self.assertIn("targetSnapshotInsertRowsPerStatement", lookup)
        self.assertIn("buildTargetPrimaryKeyLookupFromStageSql(", lookup)
        self.assertIn("SELECT DISTINCT", builder)
        self.assertIn("INNER JOIN requested ON", builder)
        self.assertIn("buildTargetSnapshotStageLoadSql(", builder)

    def test_large_content_comparison_stages_resumable_bounded_key_chunks(self):
        agent = read_text("sync_windows_agent/lib/agent_page.dart")
        comparison = agent.split(
            "Future<List<Map<String, dynamic>>> _fetchRowsByPrimaryKeys(", 1
        )[1].split("String _sourceBatchEncodedColumnExpression(", 1)[0]

        self.assertIn("required String operationId", comparison)
        self.assertIn("_targetSnapshotStageTableNameForOperation(", comparison)
        self.assertIn("replaceExisting: false", comparison)
        self.assertIn("_queryTargetSnapshotStageRowCount(", comparison)
        self.assertIn("while (stagedRowCount < keyRows.length)", comparison)
        self.assertIn("buildTargetSnapshotStageInsertSql(", comparison)
        self.assertIn("await onStageProgress?.call(stagedRowCount, keyRows.length)", comparison)
        self.assertIn("if (lookupCompleted || confirmedFailure)", comparison)
        self.assertIn("buildTargetPrimaryKeyLookupFromStageSql(", comparison)
        self.assertIn("Prepared $loadedRows of $totalRows keys", agent)

    def test_set_based_comparison_qualifies_every_target_projection_column(self):
        agent = read_text("sync_windows_agent/lib/agent_page.dart")
        lookup = agent.split(
            "Future<List<Map<String, dynamic>>> _fetchRowsByPrimaryKeys(", 1
        )[1].split("String _sourceBatchEncodedColumnExpression(", 1)[0]

        self.assertIn("'target_row.${_quoteIdentifier(column.name)}'", lookup)
        self.assertIn("columnReference:", lookup)

    def test_windows_client_updates_only_move_forward(self):
        app_source = read_text("sync_windows_agent/lib/app.dart")
        agent_page = read_text("sync_windows_agent/lib/agent_page.dart")
        version_source = read_text("sync_windows_agent/lib/client_version.dart")

        self.assertIn("isStrictlyNewerClientVersion(", app_source)
        self.assertIn("isStrictlyNewerClientVersion(", agent_page)
        self.assertIn("candidateVersion.compareTo(currentVersion) > 0", version_source)
        self.assertIn("if (currentVersion == null || candidateVersion == null)", version_source)

    def test_update_script_verifies_the_installed_payload_before_relaunch(self):
        update_script = read_text("update.ps1")
        self.assertIn("function Test-PayloadInstalled {", update_script)
        self.assertIn("Test-PayloadInstalled -PayloadDir $PayloadDir -InstallDir $InstallDir", update_script)
        self.assertIn("Verified installed client payload for version $Version.", update_script)
        self.assertIn("Start-Sleep -Milliseconds 500", update_script)

    def test_deferred_updater_persists_exact_failure_telemetry(self):
        update_script = read_text("update.ps1")
        helper = update_script.split("$helper = @'", 1)[1].split("\n'@", 1)[0]

        self.assertIn("function Write-FinalizerFailureProgress", helper)
        self.assertIn("trap {", helper)
        self.assertIn("$failureMessage = $_.Exception.Message", helper)
        self.assertIn("status = 'failed'", helper)
        self.assertIn("Move-Item -LiteralPath $temporaryPath", helper)

    def test_deferred_updater_decodes_encoded_supervisor_commands(self):
        update_script = read_text("update.ps1")
        helper = update_script.split("$helper = @'", 1)[1].split("\n'@", 1)[0]
        stop_supervisor = helper.split("function Stop-SupervisorProcesses", 1)[1].split(
            "function Start-SupervisorProcess", 1
        )[0]

        self.assertIn("function Get-PowerShellLaunchText", helper)
        self.assertIn("[Text.Encoding]::Unicode.GetString", helper)
        self.assertIn("-EncodedCommand|-enc", helper)
        self.assertIn("Get-PowerShellLaunchText -CommandLine", stop_supervisor)

    def test_windows_update_elevates_only_for_protected_install_handoff(self):
        update_script = read_text("update.ps1")

        self.assertGreaterEqual(update_script.count("Test-InstallNeedsElevation -TargetInstallDir"), 2)
        self.assertIn("if (-not $requiresElevation)", update_script)
        self.assertIn("Normal update handoff was denied", update_script)
        self.assertIn("if ($Elevated)", update_script)
        self.assertIn("-WindowStyle Hidden -Verb RunAs", update_script)
        self.assertGreaterEqual(update_script.count("-Elevated:$requiresElevation"), 2)

    def test_windows_update_escalates_stale_verified_handoff_retry(self):
        update_script = read_text("update.ps1")

        self.assertIn("function Test-PriorInstallHandoffNeedsElevation", update_script)
        self.assertIn("([string] $progress.status).Trim().ToLowerInvariant() -ne 'installing'", update_script)
        self.assertIn("[int] $progress.percent -lt 100", update_script)
        self.assertIn("$priorInstallHandoffNeedsElevation = Test-PriorInstallHandoffNeedsElevation", update_script)
        self.assertGreaterEqual(
            update_script.count("$priorInstallHandoffNeedsElevation -or (Test-InstallNeedsElevation"),
            2,
        )

    def test_windows_update_retry_grace_is_bounded_for_staggered_old_clients(self):
        update_script = read_text("update.ps1")
        retry_guard = update_script.split(
            "function Test-PriorInstallHandoffNeedsElevation", 1
        )[1].split("function Start-DeferredInstall", 1)[0]

        self.assertIn("[int] $MinimumAgeSeconds = 5", retry_guard)
        self.assertIn("[Math]::Max(1, $MinimumAgeSeconds)", retry_guard)

    def test_update_script_encodes_paths_passed_to_hidden_powershell(self):
        update_script = read_text("update.ps1")
        self.assertIn("[Text.Encoding]::Unicode.GetBytes($deferredCommand)", update_script)
        self.assertIn("'-EncodedCommand', $encodedCommand", update_script)
        self.assertIn("$helperPath.Replace(\"'\", \"''\")", update_script)
        self.assertIn("$TargetInstallDir.Replace(\"'\", \"''\")", update_script)
        self.assertNotIn("'-File', $helperPath", update_script)
        self.assertNotIn("'-File', $supervisorPath", update_script)

    def test_client_prefers_live_updater_with_local_offline_fallback(self):
        for source_path, function_name in (
            ("sync_windows_agent/lib/app.dart", "_shellClientUpdatePowerShellArgs"),
            ("sync_windows_agent/lib/agent_page.dart", "_clientUpdatePowerShellArgs"),
        ):
            source = read_text(source_path)
            body = source.split(f"List<String> {function_name}", 1)[1].split(
                "\n  }", 1
            )[0]
            self.assertLess(body.index("if (scriptUrl.isNotEmpty)"), body.index("if (localScriptPath != null)"))
            self.assertIn("updater-only fixes can repair an", body)
            self.assertIn("bundled script remains an offline fallback", body)

    def test_update_script_stops_supervisor_before_replacing_client_files(self):
        update_script = read_text("update.ps1")
        helper_install = update_script.split(
            'Write-UpdateLog -Message "Finalize update helper started.',
            1,
        )[1].split(
            "Get-ChildItem -LiteralPath $PayloadDir -Force |",
            1,
        )[0]
        self.assertLess(
            helper_install.index(
                "Stop-SupervisorProcesses -TargetInstallDir $InstallDir"
            ),
            helper_install.index(
                "Stop-AgentProcesses -TargetInstallDir $InstallDir"
            ),
        )
        differential_install = update_script.split(
            "Stopping the supervisor before scheduling differential replacement.",
            1,
        )[1].split("Start-DeferredInstall", 1)[0]
        self.assertLess(
            differential_install.index(
                "Stop-SupervisorProcesses -TargetInstallDir $InstallDir"
            ),
            differential_install.index(
                "Stop-AgentProcesses -TargetInstallDir $InstallDir"
            ),
        )
        package_install = update_script.split(
            "Stopping the supervisor before scheduling package replacement.",
            1,
        )[1].split("Start-DeferredInstall", 1)[0]
        self.assertLess(
            package_install.index(
                "Stop-SupervisorProcesses -TargetInstallDir $InstallDir"
            ),
            package_install.index(
                "Stop-AgentProcesses -TargetInstallDir $InstallDir"
            ),
        )
        supervisor = read_text("sync_windows_agent_supervisor.ps1")
        self.assertIn("function Invoke-IndependentUpdateCheck {", supervisor)
        self.assertIn("sync_windows_agent_update_requests.log", supervisor)
        self.assertIn("$updateProcess = Start-Process -FilePath 'powershell.exe'", supervisor)
        self.assertIn("-WindowStyle Hidden", supervisor)
        self.assertIn("-Wait", supervisor)
        self.assertIn("-PassThru", supervisor)
        self.assertNotIn("& powershell.exe -NoProfile", supervisor)
        self.assertIn("[int] $UpdateCheckSeconds = 600", supervisor)
        self.assertNotIn("the healthy client performs lightweight manifest checks in-process", supervisor)
        loop_body = supervisor.split("while ($true) {", 1)[1]
        self.assertEqual(loop_body.count("Invoke-IndependentUpdateCheck"), 1)
        self.assertNotIn("-NoStart", supervisor)

    def test_windows_agent_supervisor_runs_hidden_bounded_update_checks(self):
        supervisor = read_text("sync_windows_agent_supervisor.ps1")
        update_check_body = supervisor.split(
            "function Invoke-IndependentUpdateCheck {", 1
        )[1].split("$mutexName =", 1)[0]

        self.assertIn("[int] $UpdateCheckSeconds = 600", supervisor)
        self.assertIn("-WindowStyle Hidden", update_check_body)
        self.assertIn("-Wait", update_check_body)
        self.assertNotIn("Get-AgentProcesses).Count -gt 0", update_check_body)
        self.assertIn("Test-Path -LiteralPath $userStoppedMarkerPath", update_check_body)
        self.assertIn("WaitOne(0)", read_text("update.ps1"))

    def test_new_install_retires_obsolete_agent_install_processes(self):
        supervisor = read_text("sync_windows_agent_supervisor.ps1")
        self.assertIn(
            "function Stop-ObsoleteInstallProcesses {",
            supervisor,
        )
        self.assertIn(
            "$scriptPath = [System.IO.Path]::GetFullPath($MyInvocation.MyCommand.Path)",
            supervisor,
        )
        self.assertIn("sync_windows_agent_supervisor.ps1", supervisor)
        self.assertIn(
            "Name = 'sync_windows_agent.exe'",
            supervisor,
        )
        self.assertIn(
            "[System.StringComparison]::OrdinalIgnoreCase",
            supervisor,
        )
        self.assertIn(
            "Retired obsolete installs.",
            supervisor,
        )

    def test_supervisor_never_relaunches_an_incomplete_portable_install(self):
        supervisor = read_text("sync_windows_agent_supervisor.ps1")
        ensure_body = supervisor.split("function Ensure-AgentRunning {", 1)[1].split(
            "function Invoke-IndependentUpdateCheck {", 1
        )[0]

        self.assertIn("function Get-MissingAgentRuntimePaths {", supervisor)
        self.assertIn("flutter_windows.dll", supervisor)
        self.assertIn("data\\app.so", supervisor)
        self.assertIn("data\\icudtl.dat", supervisor)
        self.assertIn("$missingRuntimePaths = @(Get-MissingAgentRuntimePaths)", ensure_body)
        self.assertIn("launch suppressed", ensure_body)
        self.assertIn("Stop-ObsoleteInstallProcesses", supervisor.split("while ($true) {", 1)[1])

    def test_supervisor_retires_obsolete_windows_autostart_registrations(self):
        supervisor = read_text("sync_windows_agent_supervisor.ps1")
        cleanup = supervisor.split("function Remove-ObsoleteLaunchRegistrations {", 1)[1].split(
            "function Stop-ObsoleteInstallProcesses {", 1
        )[0]
        self.assertIn("WScript.Shell", cleanup)
        self.assertIn("CurrentVersion\\Run", cleanup)
        self.assertIn("Get-ScheduledTask", cleanup)
        self.assertIn("Disable-ScheduledTask", cleanup)
        self.assertIn("IndexOf($scriptPath", cleanup)
        self.assertIn("Retired obsolete launch registrations", cleanup)
        loop = supervisor.split("while ($true) {", 1)[1]
        self.assertIn("Remove-ObsoleteLaunchRegistrations", loop)

    def test_web_delivered_updater_retires_obsolete_autostart_before_install(self):
        updater = read_text("update.ps1")
        cleanup = updater.split("function Remove-ObsoleteLaunchRegistrations {", 1)[1].split(
            "function Stop-SupervisorProcesses {", 1
        )[0]
        self.assertIn("WScript.Shell", cleanup)
        self.assertIn("CurrentVersion\\Run", cleanup)
        self.assertIn("Disable-ScheduledTask", cleanup)
        self.assertIn("Updater retired obsolete launch registrations", cleanup)
        for marker in (
            "Stopping the supervisor before scheduling differential replacement.",
            "Stopping the supervisor before scheduling package replacement.",
        ):
            install_handoff = updater.split(marker, 1)[1].split("Start-DeferredInstall", 1)[0]
            self.assertIn("Remove-ObsoleteLaunchRegistrations", install_handoff)

    def test_web_delivered_updater_stops_obsolete_running_installs(self):
        updater = read_text("update.ps1")
        cleanup = updater.split("function Stop-ObsoleteInstallProcesses {", 1)[1].split(
            "function Start-SupervisorProcess {", 1
        )[0]
        self.assertIn("sync_windows_agent_supervisor.ps1", cleanup)
        self.assertIn("sync_windows_agent_watchdog.ps1", cleanup)
        self.assertIn("sync_windows_agent.exe", cleanup)
        self.assertIn("Updater retired obsolete running installs", cleanup)
        for marker in (
            "Stopping the supervisor before scheduling differential replacement.",
            "Stopping the supervisor before scheduling package replacement.",
        ):
            install_handoff = updater.split(marker, 1)[1].split("Start-DeferredInstall", 1)[0]
            self.assertIn("Stop-ObsoleteInstallProcesses", install_handoff)

    def test_updater_decodes_encoded_commands_when_stopping_supervisors(self):
        updater = read_text("update.ps1")
        decoder = updater.split("function Get-PowerShellLaunchText {", 1)[1].split(
            "function Remove-ObsoleteLaunchRegistrations {", 1
        )[0]
        self.assertIn("EncodedCommand", decoder)
        self.assertIn("FromBase64String", decoder)
        self.assertIn("Encoding]::Unicode.GetString", decoder)
        stop_target = updater.split("function Stop-SupervisorProcesses {", 1)[1].split(
            "function Stop-ObsoleteInstallProcesses {", 1
        )[0]
        self.assertIn("Get-PowerShellLaunchText", stop_target)
        stop_obsolete = updater.split("function Stop-ObsoleteInstallProcesses {", 1)[1].split(
            "function Start-SupervisorProcess {", 1
        )[0]
        self.assertIn("Get-PowerShellLaunchText", stop_obsolete)

    def test_updater_uses_exact_launcher_pid_and_verified_supervisor_shutdown(self):
        updater = read_text("update.ps1")
        supervisor = read_text("sync_windows_agent_supervisor.ps1")
        helper = updater.split("$helper = @'", 1)[1].split("\n'@", 1)[0]

        self.assertIn("[int] $LauncherSupervisorProcessId = 0", updater)
        self.assertIn("'-LauncherSupervisorProcessId', $PID", supervisor)
        self.assertIn("Get-LauncherSupervisorProcessId -TargetInstallDir", updater)
        self.assertIn(
            "-LauncherSupervisorProcessId $effectiveLauncherSupervisorProcessId",
            updater,
        )
        self.assertIn(
            "Stop-LauncherSupervisorProcess -ProcessId $LauncherSupervisorProcessId",
            helper,
        )
        self.assertGreaterEqual(
            updater.count("Timed out waiting for the target supervisor to stop"), 2
        )
        self.assertGreaterEqual(updater.count("Stop-Process -Id $ProcessId -Force"), 2)

    def test_bulk_diagnostics_requests_are_batched_from_the_dashboard(self):
        web_api = read_text("frontend/lib/live_sync_api.dart")
        dashboard = read_text("frontend/lib/dashboard_page.dart")
        verifier = read_text("scripts/verify_live_bulk_diagnostics.py")

        self.assertIn(
            "Future<AdminBulkDiagnosticsRequestResult> requestAgentDiagnosticsBatch({",
            web_api,
        )
        self.assertIn(
            "_invokeFunction('agent_diagnostics_request_batch', {",
            web_api,
        )
        self.assertIn("const int _bulkDiagnosticsBatchSize = 5;", dashboard)
        self.assertIn("index < uniqueClientNames.length;", dashboard)
        self.assertIn("index += _bulkDiagnosticsBatchSize", dashboard)
        self.assertIn("_api.requestAgentDiagnosticsBatch(", dashboard)
        self.assertIn("requestId: sharedRequestId,", dashboard)
        self.assertIn("in batches of $_bulkDiagnosticsBatchSize", dashboard)
        self.assertIn('parser.add_argument("--batch-size", type=int, default=5)', verifier)
        self.assertIn('args["batchSize"] = batch_size', verifier)

    def test_windows_agent_can_apply_server_requested_window_actions(self):
        control_plane = read_text("business/control_plane.tru")
        agent_page = read_text("sync_windows_agent/lib/agent_page.dart")
        client_api = read_text("sync_windows_agent/lib/live_sync_api.dart")
        web_api = read_text("frontend/lib/live_sync_api.dart")
        dashboard = read_text("frontend/lib/dashboard_page.dart")
        window_settings = read_text("sync_windows_agent/lib/window_settings.dart")

        self.assertIn("agent_window_action_request_all", control_plane)
        self.assertIn("agent_window_action_ack", control_plane)
        self.assertIn("await _handleRequestedWindowAction(heartbeat.windowAction);", agent_page)
        self.assertIn("Future<void> _handleRequestedWindowAction(", agent_page)
        self.assertIn("WindowsAgentWindowSettings.minimizeWindow()", agent_page)
        self.assertIn("class _PendingWindowActionAck {", agent_page)
        self.assertIn("Future<void> _flushPendingWindowActionAck() async {", agent_page)
        self.assertIn("Future<void> _queueWindowActionAck({", agent_page)
        self.assertIn("if (_matchesPendingWindowActionAck(heartbeat.windowAction)) {", agent_page)
        self.assertIn("Future<RemoteAgentWindowAction> acknowledgeWindowAction(", client_api)
        self.assertIn("class RemoteAgentWindowAction {", client_api)
        self.assertIn("requestAllAgentWindowActions({", web_api)
        self.assertIn("String action = 'minimize'", web_api)
        self.assertIn("_requestAllAgentWindowMinimize()", dashboard)
        self.assertIn("Minimize All Clients", dashboard)
        self.assertIn("minimizeWindow", window_settings)

    def test_windows_client_production_build_uses_live_control_plane(self):
        client_api = read_text("sync_windows_agent/lib/live_sync_api.dart")
        build_helpers = read_text("scripts/windows_agent_build.ps1")
        publish_script = read_text("scripts/publish_windows_client_update.ps1")
        build_script = read_text("build_portable.ps1")

        self.assertIn(
            "defaultValue: 'https://sync.velvet-leaf.com/call'",
            client_api,
        )
        self.assertIn("const String _liveControlPlaneUrl", client_api)
        self.assertIn("host == '127.0.0.1'", client_api)
        self.assertIn("return _liveControlPlaneUrl;", client_api)
        self.assertIn("'--dart-define', \"BACKEND_BASE_URL=$BackendBaseUrl\"", build_helpers)
        self.assertIn(
            "[string] $BackendBaseUrl = 'https://sync.velvet-leaf.com/call'",
            publish_script,
        )
        self.assertIn(
            "[string] $BackendBaseUrl = 'https://sync.velvet-leaf.com/call'",
            build_script,
        )
        self.assertIn("function Assert-LiveBackendBaseUrl", build_script)
        self.assertIn("Portable builds must target https://sync.velvet-leaf.com/call", build_script)
        self.assertIn("BackendBaseUrl: $BackendBaseUrl", build_script)
        self.assertIn("Never classify a shell host as a Flutter dev process.", build_helpers)
        self.assertIn("'powershell.exe', 'pwsh.exe', 'conhost.exe'", build_helpers)
        self.assertIn("$_.Name -eq 'cmd.exe'", build_helpers)
        self.assertNotIn(
            "defaultValue: 'http://127.0.0.1:6006/call'",
            client_api,
        )

    def test_windows_client_database_access_failure_is_actionable_not_periodic(self):
        agent_page = read_text("sync_windows_agent/lib/agent_page.dart")
        database_access = read_text("sync_windows_agent/lib/database_access.dart")

        self.assertIn("buildDatabaseAccessDiscoverySql()", agent_page)
        self.assertIn("_discoveredDatabaseAccessIssues()", agent_page)
        self.assertIn("Database access required", agent_page)
        self.assertIn("Copy grant scripts", agent_page)
        self.assertIn("Grant all access", agent_page)
        self.assertIn("'databaseAccessDiscovery':", agent_page)
        self.assertIn("database.access_grant.completed", agent_page)
        self.assertIn("buildWindowsUacLauncherPowerShell(", agent_page)
        self.assertIn("'databaseAccessIssue':", agent_page)
        self.assertNotIn("_automaticDatabaseTargetCheckInterval", agent_page)
        self.assertNotIn("_automaticDatabaseTargetCheckTimer", agent_page)
        self.assertNotIn("automaticDatabaseTargetForClient", agent_page)
        self.assertNotIn("AmnDb048", agent_page)
        self.assertNotIn("HAS_DBACCESS", database_access)
        self.assertIn("database_id > 4", database_access)
        self.assertIn("probeBatchSize = 4", agent_page)
        self.assertIn("'access_required'", agent_page)
        self.assertIn("'database_unavailable'", agent_page)
        self.assertIn("CREATE LOGIN", database_access)
        self.assertIn("sp_addrolemember", database_access)
        self.assertIn("GRANT ALTER TO", database_access)
        self.assertIn("GRANT VIEW CHANGE TRACKING ON SCHEMA::", database_access)
        self.assertNotIn("GRANT VIEW CHANGE TRACKING TO", database_access)
        self.assertIn("-Verb RunAs", database_access)
        self.assertNotIn("-Credential", database_access)
        self.assertNotIn("ALTER ROLE", database_access)

    def test_windows_client_update_manifest_ignores_localhost_overrides(self):
        app = read_text("sync_windows_agent/lib/app.dart")
        agent_page = read_text("sync_windows_agent/lib/agent_page.dart")

        for source in (app, agent_page):
            self.assertIn("_isLocalHttpUrl", source)
            self.assertIn("CLIENT_UPDATE_BASE_URL", source)
            self.assertIn("host == '127.0.0.1'", source)
            self.assertIn("uri?.port == 6006", source)
            self.assertIn("latest.json", source)
            self.assertNotIn("http://127.0.0.1:6006/client/latest.json", source)

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

    def test_windows_client_target_apply_uses_atomic_staging_without_missing_row_deletes(self):
        agent_page = read_text("sync_windows_agent/lib/agent_page.dart")
        merge_helper = read_text("sync_windows_agent/lib/sql_sync_merge.dart")
        target_apply = merge_helper.split("String buildTargetSnapshotStageApplySql(", 1)[1].split(
            "String _buildStagedDeltaDeleteStatements(", 1
        )[0]

        self.assertIn("SET XACT_ABORT ON;", target_apply)
        self.assertIn("BEGIN TRANSACTION;", target_apply)
        self.assertIn("COMMIT TRANSACTION;", target_apply)
        self.assertIn("stageTableReference(stageTableName)", target_apply)
        self.assertIn("INTO $workingSource", target_apply)
        self.assertEqual(target_apply.count("DROP TABLE $stageTarget"), 1)
        self.assertIn("if (mergeCompleted)", agent_page)
        self.assertIn("_dropTargetSnapshotStage(", agent_page)
        self.assertNotIn("DELETE TOP", target_apply)
        self.assertIn("WHERE NOT EXISTS (", merge_helper)
        self.assertIn("target snapshot merge", agent_page)
        self.assertIn("matchClauseForColumns(primaryKeyColumns, columns)", target_apply)
        self.assertNotIn("alternateUniqueKeys", target_apply)
        self.assertIn("COLLATE DATABASE_DEFAULT", merge_helper)
        self.assertNotIn("MERGE ", target_apply)
        self.assertIn("UPDATE target", merge_helper)
        self.assertIn("INSERT INTO", merge_helper)
        self.assertIn("$deltaDeleteStatements", target_apply)
        self.assertIn("COMMIT TRANSACTION;", target_apply)

    def test_change_tracking_upload_captures_a_fixed_version_bounded_snapshot(self):
        agent = read_text("sync_windows_agent/lib/agent_page.dart")
        capture = agent.split(
            "Future<List<Map<String, String?>>> _fetchChangeTrackingRows(", 1
        )[1].split("String? _decodeHexTransportField(", 1)[0]
        caller = agent.split(
            "final deltaRows = await _fetchChangeTrackingRows(", 1
        )[1].split("rows.addAll(deltaRows);", 1)[0]

        self.assertIn("snapshotVersion: tracking.currentVersion", caller)
        self.assertIn("required int snapshotVersion", capture)
        self.assertIn("SET XACT_ABORT ON;", capture)
        self.assertIn("SET TRANSACTION ISOLATION LEVEL SERIALIZABLE;", capture)
        self.assertIn("BEGIN TRANSACTION;", capture)
        self.assertIn("AND ct.SYS_CHANGE_VERSION <= $snapshotVersion", capture)
        self.assertIn("COMMIT TRANSACTION;", capture)

    def test_windows_client_delta_sync_reconciles_changes_and_advances_checkpoint(self):
        agent_page = read_text("sync_windows_agent/lib/agent_page.dart")
        merge_helper = read_text("sync_windows_agent/lib/sql_sync_merge.dart")

        self.assertNotIn("applySqlSyncRowsWithIsolation", agent_page)
        self.assertFalse(
            (ROOT / "sync_windows_agent/lib/sql_sync_row_isolation.dart").exists()
        )
        self.assertIn("insertOnly: false", agent_page)
        self.assertIn("manageTriggers: true", agent_page)
        self.assertIn("onChunk: null", agent_page)
        self.assertIn("Buffer the complete table delta before SQL apply", agent_page)
        self.assertIn("deltaDeleteRows: deleteRows.cast<Map<String, dynamic>>()", agent_page)
        self.assertIn("BEGIN TRANSACTION;", merge_helper)
        self.assertIn("ROLLBACK TRANSACTION;", merge_helper)
        self.assertIn("SET XACT_ABORT ON;", merge_helper)
        self.assertIn("status: converged ? 'completed' : 'failed'", agent_page)
        self.assertIn("success: converged", agent_page)
        self.assertIn("rowCount: applyStats.appliedRows", agent_page)
        self.assertIn("applyResult.protectedUpsertRows", agent_page)
        self.assertIn("protectLocalChangesAfterVersion:", agent_page)
        self.assertIn("sync.apply.post_upload_changes_protected", agent_page)
        self.assertIn("CREATE TABLE #sqlsync_protected_keys", merge_helper)
        self.assertIn("SET TRANSACTION ISOLATION LEVEL SERIALIZABLE", merge_helper)
        self.assertIn("CHANGETABLE(CHANGES $target, $changeTrackingVersion)", merge_helper)
        self.assertIn("ct.SYS_CHANGE_CONTEXT <> $sqlSyncChangeTrackingContextHex", agent_page)
        self.assertIn("changeTrackingVersion: appliedVersion", agent_page)
        self.assertNotIn("Change Tracking checkpoint was not advanced", agent_page)
        self.assertIn("bool insertOnly = false", merge_helper)
        self.assertNotIn("deleteMissing", merge_helper)
        self.assertIn("const sqlSyncDeletePolicy = 'explicit-tombstones-only'", merge_helper)
        self.assertIn("${insertOnly ? '' : _buildBatchedUpdateStatement", merge_helper)
        self.assertIn("__SQL_SYNC_INSERTED__=", merge_helper)
        self.assertIn("WITH CHANGE_TRACKING_CONTEXT ($sqlSyncChangeTrackingContextHex)", merge_helper)
        self.assertIn("captureOutputFile: true", agent_page)
        self.assertIn("arguments.addAll(['-o', outputFile.path])", agent_page)
        self.assertIn("counted $insertedRows inserted row(s) from target cardinality", agent_page)
        self.assertNotIn("Target insert-only apply did not report its inserted row count", agent_page)

    def test_table_policy_upsert_updates_existing_stored_key(self):
        control_plane = read_text("business/control_plane.tru")
        upsert_body = control_plane.split("function upsert_table_sync_policy(", 1)[1].split(
            "function apply_table_sync_policies(", 1
        )[0]
        lookup_body = control_plane.split("function table_sync_policy_for_table(", 1)[1].split(
            "function find_table_sync_policy(", 1
        )[0]

        self.assertIn("const existing = find_table_sync_policy(scope, table);", upsert_body)
        self.assertIn("table: string.from(existing.table).trim()", upsert_body)
        self.assertIn("syncMode: 'sync'", upsert_body)
        self.assertNotIn("table: table.trim()", upsert_body)
        self.assertIn("const reference = sync_table_reference(table);", lookup_body)
        self.assertIn("databaseName = referenceDatabase;", lookup_body)
        self.assertIn("const localTable = string.from(reference.table).trim();", lookup_body)

    def test_server_owns_periodic_sync_job_creation(self):
        control_plane = read_text("business/control_plane.tru")
        agent_page = read_text("sync_windows_agent/lib/agent_page.dart")
        heartbeat_body = control_plane.split("function agents_heartbeat(", 1)[1].split(
            "function auto_sync_tick(", 1
        )[0]
        scheduler_body = control_plane.split(
            "function queue_due_periodic_sync_jobs_for_owner(", 1
        )[1].split("function periodic_sync_scheduler_agent_limit(", 1)[0]

        self.assertNotIn("function queue_due_periodic_sync_jobs_for_agent", control_plane)
        self.assertIn("function queue_due_periodic_sync_jobs_for_owner", control_plane)
        self.assertIn("function claim_periodic_sync_scheduler_for_owner", control_plane)
        self.assertIn("function auto_sync_tick", control_plane)
        self.assertIn("class PeriodicSyncState", control_plane)
        self.assertIn("field manualPendingTables: array<json>?", control_plane)
        self.assertIn("function manual_sync_pending_tables_for_owner(", control_plane)
        self.assertIn("function set_manual_sync_pending_tables_for_owner(", control_plane)
        self.assertNotIn("queue_due_periodic_sync_jobs_for_owner", heartbeat_body)
        self.assertIn("const allAgents = list_scheduler_agent_rows();", control_plane)
        self.assertIn(
            "queue_due_periodic_sync_jobs_for_owner(ownerUserId, allAgents);",
            control_plane,
        )
        self.assertIn("function safe_date_diff_minutes_since", control_plane)
        self.assertIn(
            "safe_date_diff_minutes_since(string.from(existing.lastCheckedAt ?? ''))",
            control_plane,
        )
        self.assertIn("return 1;", control_plane)
        self.assertIn("function periodic_sync_scheduler_agent_limit", control_plane)
        self.assertIn("function periodic_sync_scheduler_owner_limit", control_plane)
        self.assertIn("function periodic_sync_scheduler_table_limit", control_plane)
        self.assertIn("function agent_recent_enough_for_periodic_sync", control_plane)
        self.assertIn("const ownerLimit = periodic_sync_scheduler_owner_limit();", control_plane)
        self.assertIn("!string_array_contains(ownerIds, ownerUserId)", control_plane)
        self.assertIn("if (ownerIds.length >= ownerLimit) {", control_plane)
        self.assertIn("queuedTableCount >= periodic_sync_scheduler_table_limit()", control_plane)
        self.assertIn("agent_sync_enabled(agent)", scheduler_body)
        self.assertIn("effective_agent_online(agent)", scheduler_body)
        self.assertIn("sync_table_baseline_plan(", scheduler_body)
        self.assertIn("!preserveChangeTrackingBaselines", scheduler_body)
        baseline_planner = control_plane.split(
            "function sync_table_baseline_plan(", 1
        )[1].split("function enabled_sync_policy_tables_for_agent(", 1)[0]
        self.assertIn("scheduler_table_change_tracking_ready(", baseline_planner)
        self.assertIn("function json_payload_changed", control_plane)
        self.assertIn(
            "if (tablesChanged || relationshipsChanged || fingerprintAuditChanged)",
            heartbeat_body,
        )
        self.assertEqual(heartbeat_body.count("syncEnabled: true,"), 0)
        self.assertIn("_scheduleSelectedTableFingerprintRefresh();", agent_page)
        self.assertNotIn("await _refreshSelectedTableFingerprints();", heartbeat_body)
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
        product = read_text("PRODUCT.md")
        self.assertIn("## Register", product)
        self.assertIn("product", product)
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

    def test_windows_comparison_snapshot_is_full_and_preserves_tracking_cursor(self):
        agent_page = read_text("sync_windows_agent/lib/agent_page.dart")
        cursor_policy = read_text(
            "sync_windows_agent/lib/change_tracking_cursor_policy.dart"
        )
        snapshot_body = agent_page.split(
            "Future<_RelaySnapshotDocument> _createRelaySnapshotForJob(", 1
        )[1].split("Future<void> _processSnapshotRelayUploadJob(", 1)[0]
        upload_body = agent_page.split(
            "Future<void> _processSnapshotRelayUploadJob(", 1
        )[1].split("Future<void> _processSnapshotRelayDownloadJob(", 1)[0]

        self.assertIn("job.sourceClientName == 'server-diff-preview'", snapshot_body)
        self.assertIn("final completeSnapshot", snapshot_body)
        self.assertIn("!comparisonSnapshot", snapshot_body)
        self.assertIn("if (completeSnapshot)", snapshot_body)
        self.assertIn("_fetchConsistentSourceTableSnapshot(", snapshot_body)
        consistent_snapshot_body = agent_page.split(
            "Future<_ConsistentSourceSnapshot> _fetchConsistentSourceTableSnapshot(", 1
        )[1].split("Future<_ChangeTrackingState?> _queryChangeTrackingState(", 1)[0]
        self.assertIn("SET TRANSACTION ISOLATION LEVEL SERIALIZABLE", consistent_snapshot_body)
        self.assertIn("BEGIN TRANSACTION", consistent_snapshot_body)
        self.assertIn("COUNT_BIG(1)", consistent_snapshot_body)
        self.assertIn("CHANGE_TRACKING_CURRENT_VERSION()", consistent_snapshot_body)
        self.assertIn("WITH (HOLDLOCK)", consistent_snapshot_body)
        self.assertIn("COMMIT TRANSACTION", consistent_snapshot_body)
        self.assertIn("rows.length != snapshotRowCount", consistent_snapshot_body)
        self.assertIn("captureOutputFile: true", consistent_snapshot_body)
        self.assertIn(
            "stripSqlCmdRowSentinelPadding(line, rowSentinel)",
            consistent_snapshot_body,
        )
        self.assertIn("uploadPreservesChangeTrackingBaseline", upload_body)
        self.assertIn("'server-diff-preview'", cursor_policy)
        self.assertIn("preserveChangeTrackingBaseline", upload_body)

    def test_live_copy_export_is_read_only_private_chunked_and_checksum_verified(self):
        agent_page = read_text("sync_windows_agent/lib/agent_page.dart")
        export_policy = read_text("sync_windows_agent/lib/data_export_policy.dart")
        api = read_text("sync_windows_agent/lib/live_sync_api.dart")
        frontend_server = read_text("frontend/server.js")
        collector = read_text("scripts/collect_live_client_database_copies.ps1")

        self.assertIn("WITH COPY_ONLY, INIT, COMPRESSION, CHECKSUM", agent_page)
        self.assertIn("RESTORE VERIFYONLY", agent_page)
        self.assertIn("SERVERPROPERTY('InstanceDefaultBackupPath')", agent_page)
        self.assertIn("FROM master.sys.master_files", agent_page)
        self.assertIn("kPrivateExportArtifactBytes = 256 * 1024", export_policy)
        self.assertIn("privateExportUploadTimeout(int bytes)", export_policy)
        self.assertIn("kPrivateExportArtifactBytes", agent_page)
        self.assertIn("privateExportUploadTimeout(bytes.length)", agent_page)
        self.assertIn("sha256.bind(backupFile.openRead())", agent_page)
        self.assertIn("await backupFile.delete()", agent_page)
        self.assertNotIn("DROP DATABASE", agent_page)
        self.assertIn("class RemoteAgentDataExport", api)
        self.assertIn("agent_data_export_ack", api)
        self.assertIn("agent_data_export_poll", api)
        self.assertIn("data_export.poll_failed", agent_page)
        self.assertIn("shouldRetryBackupWithoutCompression", agent_page)
        self.assertIn("WITH COPY_ONLY, INIT, CHECKSUM, STATS = 10", agent_page)
        self.assertIn('CLIENT_UPDATES_DIR, ".private-exports"', frontend_server)
        self.assertIn("crypto.timingSafeEqual", frontend_server)
        self.assertIn("private export chunk checksum mismatch", frontend_server)
        self.assertIn('requestedPath.startsWith(".private-exports/")', frontend_server)
        self.assertIn("Get-FileHash -Algorithm SHA256", collector)
        self.assertIn("kubectl exec -n $Namespace", collector)
        self.assertIn("Resuming pending read-only export", collector)
        self.assertIn("$existingExport.pending -eq $true", collector)
        self.assertIn("Skipping duplicate control-plane metadata row", collector)

        control_plane = read_text("business/control_plane.tru")
        self.assertIn("requestId is required", control_plane)
        self.assertIn("matchingAgent == null", control_plane)
        self.assertIn("stale: true", control_plane)
        self.assertIn("const nextRequestId = uuid.v4()", control_plane)
        self.assertIn("dataExportRequestId: acknowledgedRequestId", control_plane)
        self.assertIn("function agent_data_export_poll", control_plane)
        self.assertIn("authenticatedClientPoll", control_plane)
        self.assertIn("agent_data_export_payload(agent, true, true)", control_plane)
        self.assertIn("function authenticated_user_matches_client", control_plane)
        self.assertIn("diagnostics upload state unavailable", control_plane)
        self.assertIn("agent.dataExportRequestId", control_plane)
        self.assertIn("requestId` is reserved by the TRU call envelope", control_plane)
        heartbeat_body = control_plane.split("function agents_heartbeat(", 1)[1].split(
            "function auto_sync_tick", 1
        )[0]
        self.assertEqual(heartbeat_body.count("db.updateMany(Agent"), 2)

    def test_live_copy_collector_restarts_after_frontend_pod_replacement(self):
        collector = read_text("scripts/collect_live_client_database_copies.ps1")

        self.assertIn("[ValidateRange(1, 5)][int] $MaxExportAttempts = 3", collector)
        self.assertIn("function Get-ReadyFrontendPod", collector)
        self.assertIn("$_.status.phase -eq 'Running'", collector)
        self.assertIn("$_.type -eq 'Ready' -and $_.status -eq 'True'", collector)
        self.assertIn("function Assert-FrontendPodStable", collector)
        self.assertIn("FRONTEND_POD_REPLACED:", collector)
        self.assertIn("FRONTEND_EXPORT_MISSING:", collector)
        self.assertIn("$availableParts[0] -ne '00000000.part'", collector)
        self.assertIn("of $($manifest.chunkCount) required chunks", collector)
        self.assertIn("for ($attempt = 1; $attempt -le $MaxExportAttempts", collector)
        self.assertIn("agent_data_export_request", collector)
        self.assertIn("Reset-LocalAttemptDirectory $clientDirectory", collector)
        self.assertIn("Refusing to clear export attempt outside", collector)
        self.assertIn("[IO.FileAttributes]::ReparsePoint", collector)
        self.assertIn("if (-not $manifestCopied)", collector)
        self.assertLess(
            collector.index("if (-not $manifestCopied)"),
            collector.index("$destination = [IO.File]::Open($backupPath"),
        )

    def test_new_private_export_request_cancels_obsolete_client_work(self):
        agent = read_text("sync_windows_agent/lib/agent_page.dart")
        cancellation = read_text(
            "sync_windows_agent/lib/data_export_cancellation.dart"
        )
        dart_test = read_text(
            "sync_windows_agent/test/data_export_cancellation_test.dart"
        )

        self.assertIn("_activeDataExportCancellation?.cancel()", agent)
        self.assertIn("_queuedDataExportRequest = request", agent)
        self.assertIn("_startRequestedDataExport(queued)", agent)
        self.assertIn("DataExportSupersededException", agent)
        self.assertIn("cancellation.race(client.putUrl(uri))", agent)
        self.assertIn("cancellation.race(exitCodeFuture)", agent)
        self.assertIn("process.kill()", agent)
        self.assertIn("class DataExportCancellation", cancellation)
        self.assertIn("Future<T> race<T>", cancellation)
        self.assertIn(
            "new request interrupts an obsolete in-flight operation", dart_test
        )

    def test_client_publisher_defaults_to_live_and_requires_explicit_artifact_only(self):
        publisher = read_text("scripts/publish_windows_client_update.ps1")

        self.assertIn("[string] $Namespace = 'velvet-sql-server-sync'", publisher)
        self.assertIn("[string] $SshTarget = 'velvet-leaf-1'", publisher)
        self.assertIn("[switch] $ArtifactOnly", publisher)
        self.assertIn("if ($ArtifactOnly)", publisher)
        self.assertIn(
            "SshTarget is required unless -ArtifactOnly is explicitly supplied.",
            publisher,
        )

    def test_complete_snapshot_counts_only_content_changes(self):
        agent = read_text("sync_windows_agent/lib/agent_page.dart")
        apply_body = agent.split(
            "final rowsForApply = coalesceSqlSyncDeltaRows(", 1
        )[1].split("final deleteRows = contentCheckedRows", 1)[0]
        verification_body = agent.split(
            "if (fullSnapshotApply) {", 2
        )[2].split("if (_selectedDatabase == targetDatabase)", 1)[0]

        self.assertIn(
            "final contentCheckedRows = await _rowsWhoseContentChanged(",
            apply_body,
        )
        self.assertNotIn("applyDelta\n            ? await _rowsWhoseContentChanged", apply_body)
        self.assertIn(
            "rows: completeSnapshotRowsForContentVerification(rowsForApply)",
            verification_body,
        )


if __name__ == "__main__":
    unittest.main()
