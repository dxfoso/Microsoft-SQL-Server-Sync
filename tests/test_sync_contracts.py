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
        self.assertIn("unawaited(_queryChangeTrackingDiagnostics());", agent_page)
        self.assertIn("changeTrackingStatus", read_text("sync_windows_agent/lib/sync_state.dart"))

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
        self.assertIn("$stoppedProcessIds = [System.Collections.Generic.List[int]]::new()", build_script)
        self.assertIn("Get-Process -Id $processId -ErrorAction SilentlyContinue", build_script)
        self.assertIn("Start-Sleep -Milliseconds 250", build_script)
        self.assertNotIn('Write-Host "Splitting zip archive into 10 parts..."', build_script)
        self.assertNotIn('$zipPartsDir = Join-Path -Path $OutputRoot -ChildPath "$PortableName-zip-parts"', build_script)
        self.assertNotIn('Write-Host "Parts:  $($zipPartsInfo.PartsDir)"', build_script)
        self.assertIn("function New-PortableZipParts {", publish_script)
        self.assertIn("if ([System.IO.Path]::IsPathRooted(`$OutputZip)) {", publish_script)
        self.assertIn("if ([System.IO.Path]::IsPathRooted(`$OutputDir)) {", publish_script)
        self.assertIn("New-PortableZipParts `", publish_script)
        self.assertNotIn("$PortableZipPartsDir = Join-Path -Path $RepoRoot -ChildPath \"$PortableName-zip-parts\"", publish_script)

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

    def test_web_workspace_has_dashboard_and_client_log_navigation(self):
        app = read_text("frontend/lib/app.dart")
        clients_page = read_text("frontend/lib/clients_page.dart")

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
        self.assertIn("New / changed", clients_page)
        self.assertIn("Not reported", clients_page)
        self.assertIn("Filter clients", clients_page)
        self.assertIn("_ClientSortField", clients_page)
        self.assertIn("label: const Text('View')", clients_page)
        self.assertIn("Table & data viewer", clients_page)
        self.assertIn("Rows uploaded", clients_page)
        self.assertIn("Rows downloaded", clients_page)
        self.assertIn("_changedRowsLabel", clients_page)
        self.assertIn("_replaceRoute", clients_page)
        self.assertIn("Additional rows not reported", clients_page)
        self.assertIn("+${_number(changedRows)} rows", clients_page)
        self.assertIn("Filter log", clients_page)
        self.assertIn("Added rows", clients_page)
        self.assertIn("Uploaded new", clients_page)
        self.assertIn("_buildLogDataRow", clients_page)
        self.assertIn("_ClientScreen", clients_page)
        self.assertIn("Sync logs", clients_page)
        self.assertIn("Back to clients", clients_page)
        self.assertIn("Back to client", clients_page)
        self.assertIn("_buildTableDetailPage", clients_page)

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
        self.assertIn("field syncMode: string min=1 max=32", control_plane)
        self.assertNotIn("direction: 'sync'", control_plane)
        self.assertNotIn("Queued SymmetricDS sync", control_plane)

    def test_windows_snapshot_apply_matches_unique_indexes(self):
        agent_page = read_text("sync_windows_agent/lib/agent_page.dart")
        merge_helper = read_text("sync_windows_agent/lib/sql_sync_merge.dart")

        self.assertIn("Future<List<List<String>>> _queryUniqueIndexColumnSets(", agent_page)
        self.assertIn("i.is_unique = 1", agent_page)
        self.assertIn("i.is_primary_key = 0", agent_page)
        self.assertIn("required List<List<String>> matchColumnSets", agent_page)
        self.assertIn("_targetMatchColumnSets(", agent_page)
        self.assertIn("matchClauseForColumnSets(matchColumnSets, columns)", merge_helper)
        self.assertIn("uniqueIndexColumnSets: uniqueIndexColumnSets", agent_page)
        self.assertIn(
            "final updatePrimaryKeysFromUniqueMatch = matchColumnSets.length > 1;",
            merge_helper,
        )
        self.assertIn("!updatePrimaryKeysFromUniqueMatch", merge_helper)
        self.assertIn("int targetMergeInsertBatchSize = 100", merge_helper)
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
        heartbeat_body = agent_page.split("Future<void> _syncWithControlPlane() async {", 1)[
            1
        ].split("Future<void> _uploadRequestedDiagnostics(", 1)[0]

        self.assertIn(
            "const Duration _tableFingerprintRefreshCooldown = Duration(minutes: 5);",
            agent_page,
        )
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

    def test_sync_loop_suppresses_temporary_control_plane_errors_but_records_hard_failures(self):
        agent_page = read_text("sync_windows_agent/lib/agent_page.dart")
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
        self.assertIn("_serverConnected = false;", heartbeat_body)
        self.assertIn("_checkingServerConnection = false;", heartbeat_body)
        self.assertIn("_lastServerCheck = DateTime.now();", heartbeat_body)
        self.assertIn(
            "_errorMessage =\n            temporaryControlPlaneUnavailable ? null : error.toString();",
            heartbeat_body,
        )

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
        self.assertIn("await _processPendingJobs();", heartbeat_body)
        self.assertLess(
            heartbeat_body.index("_scheduleRequestedDiagnosticsUpload(heartbeat.diagnostics);"),
            heartbeat_body.index("await _processPendingJobs();"),
        )
        self.assertLess(
            heartbeat_body.index("_refreshAutoRequiredTables();"),
            heartbeat_body.index("await _processPendingJobs();"),
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

    def test_snapshot_apply_refreshes_target_fingerprint_after_success(self):
        agent_page = read_text("sync_windows_agent/lib/agent_page.dart")
        apply_body = agent_page.split(
            "Future<int> _applyDownloadedSnapshotToTarget({", 1
        )[1].split("Future<void> _markRemoteJobFailed(", 1)[0]

        self.assertIn("final targetFingerprints = await _queryTableFingerprints(", apply_body)
        self.assertIn("_applyTableFingerprints(", apply_body)
        self.assertIn("tables: [visibleTableName]", apply_body)

    def test_snapshot_upload_job_advances_through_start_progress_and_chunk_upload_only(self):
        agent_page = read_text("sync_windows_agent/lib/agent_page.dart")
        upload_body = agent_page.split(
            "Future<void> _processSnapshotRelayUploadJob(RemoteSyncJob job) async {", 1
        )[1].split("Future<void> _processSnapshotRelayDownloadJob(RemoteSyncJob job) async {", 1)[0]

        self.assertIn("await _controlPlaneClient.startJob(", upload_body)
        self.assertIn("status: 'snapshotting',", upload_body)
        self.assertIn("progress: 10,", upload_body)
        self.assertIn("await _controlPlaneClient.updateJobProgress(", upload_body)
        self.assertIn("status: 'uploading',", upload_body)
        self.assertIn("progress: 35,", upload_body)
        self.assertIn("final uploadResult = await _controlPlaneClient.uploadSnapshot(", upload_body)
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
        self.assertIn("final snapshot = await _controlPlaneClient.downloadSnapshot(job.id);", download_body)
        self.assertIn("await _controlPlaneClient.updateJobProgress(", download_body)
        self.assertIn("status: 'applying',", download_body)
        self.assertIn("progress: 80,", download_body)
        self.assertIn("final targetRowCount = await _applyDownloadedSnapshotToTarget(", download_body)
        self.assertIn("await _controlPlaneClient.completeJob(", download_body)
        self.assertIn("status: 'completed',", download_body)
        self.assertIn("progress: 100,", download_body)
        self.assertLess(
            download_body.index("final targetRowCount = await _applyDownloadedSnapshotToTarget("),
            download_body.index("await _controlPlaneClient.completeJob("),
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
        self.assertIn("status: 'failed',", pending_jobs_body)
        self.assertIn("progress: 100,", pending_jobs_body)
        self.assertIn("completedAt: DateTime.now().toIso8601String(),", pending_jobs_body)
        self.assertIn("appendHistory: true,", pending_jobs_body)
        self.assertIn("success: false,", pending_jobs_body)
        self.assertIn("overrideMessage: errorMessage,", pending_jobs_body)
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

        self.assertIn("if (_processingJobIds.contains(job.id)) {", pending_jobs_body)
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

        self.assertIn("if (jobs.length < 2 || _remoteTableDependencies.isEmpty) {", sort_body)
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

    def test_sqlcmd_calls_are_bounded_by_timeout(self):
        agent_page = read_text("sync_windows_agent/lib/agent_page.dart")
        client_api = read_text("sync_windows_agent/lib/live_sync_api.dart")

        self.assertIn("const Duration _defaultSqlCmdTimeout = Duration(minutes: 2);", agent_page)
        self.assertIn("const Duration _snapshotSqlCmdTimeout = Duration(minutes: 10);", agent_page)
        self.assertIn("await process.exitCode.timeout(timeout);", agent_page)
        self.assertIn("sqlcmd timed out after ${_formatDurationForLog(timeout)}.", agent_page)
        self.assertIn("timeout: _snapshotSqlCmdTimeout,", agent_page)
        self.assertIn("'-y',", agent_page)
        self.assertIn("'0',", agent_page)
        self.assertNotIn("'-h',", agent_page)
        self.assertIn("List<String> _dataOutputLines(String output)", agent_page)
        self.assertIn("bool _looksLikeHeaderLine(List<String> lines, int index)", agent_page)
        self.assertIn("bool _isHeaderSeparatorLine(String line)", agent_page)
        self.assertIn(
            "const Duration _diagnosticsChangeTrackingTimeout = Duration(seconds: 20);",
            agent_page,
        )
        self.assertIn(
            "const int _maxDiagnosticsUploadPayloadChars = 60000;",
            agent_page,
        )
        self.assertIn(
            "Future<Map<String, dynamic>> _buildChangeTrackingDiagnosticsForUpload() async {",
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
            "const expandedTables = expand_sync_job_tables_for_owner(agent.ownerUserId, tables)",
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
        self.assertIn("function Get-WatchdogScriptPath {", update_script)
        self.assertIn("function Start-WatchdogProcess {", update_script)
        self.assertIn("function Update-StartupShortcutToWatchdog {", update_script)
        self.assertIn("sync_windows_agent_watchdog.ps1", update_script)
        self.assertIn("ensureWatchdogInstalledAndRunning", read_text("sync_windows_agent/lib/window_settings.dart"))
        self.assertIn("unawaited(", read_text("sync_windows_agent/lib/app.dart"))
        self.assertIn("WindowsAgentWindowSettings.ensureWatchdogInstalledAndRunning()", read_text("sync_windows_agent/lib/app.dart"))
        self.assertIn("ArgumentList '--start-minimized'", update_script)
        self.assertIn("-WindowStyle Minimized", update_script)
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
        self.assertIn("if (_syncLoopBusy) {", agent_page)
        self.assertIn("_pendingForcedClientUpdateInfo = updateInfo;", agent_page)
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

    def test_update_script_relaunches_after_noop_and_failure(self):
        update_script = read_text("update.ps1")
        self.assertIn("No installation required. Relaunching the current client.", update_script)
        self.assertIn("Attempting recovery relaunch of the current client.", update_script)
        self.assertIn("Start-UpdatedClient -ExecutablePath $currentExe", update_script)
        self.assertIn("Updater failed:", update_script)

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
        self.assertNotIn(
            "defaultValue: 'http://127.0.0.1:6006/call'",
            client_api,
        )

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

    def test_windows_client_target_apply_uses_small_transactional_batches(self):
        agent_page = read_text("sync_windows_agent/lib/agent_page.dart")
        merge_helper = read_text("sync_windows_agent/lib/sql_sync_merge.dart")
        target_apply = merge_helper.split("String buildTargetSnapshotMergeSql(", 1)[1].split(
            "String sourceBatchTargetLiteral(", 1
        )[0]

        self.assertIn("SET XACT_ABORT ON;", target_apply)
        self.assertIn("BEGIN TRANSACTION;", target_apply)
        self.assertIn("COMMIT TRANSACTION;", target_apply)
        self.assertIn("targetMergeInsertBatchSize = 100", target_apply)
        self.assertIn("targetMergeApplyBatchSize = 500", target_apply)
        self.assertIn("CREATE TABLE #source_rows", target_apply)
        self.assertIn(
            "CREATE UNIQUE CLUSTERED INDEX IX_source_rows_row_num ON #source_rows (__row_num);",
            target_apply,
        )
        self.assertIn("INSERT INTO #source_rows ($sourceColumnList)", target_apply)
        self.assertIn("DROP TABLE #source_rows;", target_apply)
        self.assertIn("__row_num INT IDENTITY(1,1) NOT NULL", target_apply)
        self.assertEqual(target_apply.count("CREATE TABLE #source_rows"), 1)
        self.assertIn("DELETE TOP ($targetMergeApplyBatchSize) target", target_apply)
        self.assertIn("WHERE NOT EXISTS (", target_apply)
        self.assertIn("target snapshot merge", agent_page)
        self.assertIn("matchClauseForColumnSets(matchColumnSets, columns)", target_apply)
        self.assertNotIn("alternateUniqueKeys", target_apply)
        self.assertIn("COLLATE DATABASE_DEFAULT", merge_helper)
        self.assertNotIn("MERGE ", target_apply)
        self.assertIn("UPDATE target", merge_helper)
        self.assertIn("INSERT INTO", merge_helper)
        query_template = target_apply.split("return '''", 1)[1].split("''';", 1)[0]
        self.assertLess(
            query_template.index("BEGIN TRANSACTION;"),
            query_template.index("${insertStatements.toString()}"),
        )
        self.assertLess(
            query_template.index("${applyStatements.toString()}"),
            query_template.index("COMMIT TRANSACTION;"),
        )

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
            "function queue_due_periodic_sync_jobs_for_agent(", 1
        )[1].split("function queue_due_periodic_sync_jobs_for_owner(", 1)[0]

        self.assertIn("function queue_due_periodic_sync_jobs_for_agent", control_plane)
        self.assertIn("function queue_due_periodic_sync_jobs_for_owner", control_plane)
        self.assertIn("function claim_periodic_sync_scheduler_for_owner", control_plane)
        self.assertIn("function auto_sync_tick", control_plane)
        self.assertIn("class PeriodicSyncState", control_plane)
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
        self.assertNotIn("!effective_agent_online(agent)", scheduler_body)
        self.assertIn("function json_payload_changed", control_plane)
        self.assertIn("if (tablesChanged || relationshipsChanged)", heartbeat_body)
        self.assertIn("_scheduleSelectedTableFingerprintRefresh();", agent_page)
        self.assertNotIn("await _refreshSelectedTableFingerprints();", agent_page)
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
