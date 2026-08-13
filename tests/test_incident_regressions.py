import pathlib
import re
import unittest


ROOT = pathlib.Path(__file__).resolve().parents[1]
ISSUES = ROOT / "issue.md"


def read_text(relative_path: str) -> str:
    return (ROOT / relative_path).read_text(encoding="utf-8")


class IncidentRegressionCatalogTests(unittest.TestCase):
    def test_every_catalog_incident_has_existing_automated_coverage(self):
        document = ISSUES.read_text(encoding="utf-8")
        rows = [line for line in document.splitlines() if line.startswith("| INC-")]
        expected_ids = {f"INC-{number:03d}" for number in range(1, 118)}
        observed_ids = set()

        for row in rows:
            cells = [cell.strip() for cell in row.strip().strip("|").split("|")]
            self.assertEqual(len(cells), 6, row)
            incident_id = cells[0]
            self.assertNotIn(incident_id, observed_ids)
            observed_ids.add(incident_id)

            references = re.findall(r"`([^`]+)`", cells[5])
            self.assertGreater(len(references), 0, incident_id)
            for reference in references:
                path_text, separator, selector = reference.partition("::")
                path = ROOT / path_text
                self.assertTrue(path.is_file(), f"{incident_id}: missing {path_text}")
                if separator:
                    source = path.read_text(encoding="utf-8")
                    self.assertIn(selector, source, f"{incident_id}: missing {reference}")

        self.assertEqual(observed_ids, expected_ids)

    def test_optional_windows_theme_api_is_guarded(self):
        source = read_text("sync_windows_agent/windows/runner/win32_window.cpp")
        body = source.split("void ApplyThemeIfAvailable(", 1)[1].split("\n}", 1)[0]

        self.assertIn('LoadLibraryA("Dwmapi.dll")', body)
        self.assertIn("if (!dwmapi_module)", body)
        self.assertIn('GetProcAddress(dwmapi_module, "DwmSetWindowAttribute")', body)
        self.assertIn("if (set_window_attribute != nullptr)", body)
        self.assertIn("FreeLibrary(dwmapi_module)", body)
        self.assertNotIn("DwmSetWindowAttribute(window", body)

    def test_repo_owned_background_launchers_are_hidden(self):
        supervisor = read_text("sync_windows_agent_supervisor.ps1")
        updater = read_text("update.ps1")
        window_settings = read_text("sync_windows_agent/lib/window_settings.dart")
        app = read_text("sync_windows_agent/lib/app.dart")
        agent = read_text("sync_windows_agent/lib/agent_page.dart")
        document = ISSUES.read_text(encoding="utf-8")

        self.assertIn("-WindowStyle Hidden", supervisor)
        self.assertIn("-WindowStyle Hidden", updater)
        self.assertIn("'-WindowStyle',\n      'Hidden'", window_settings)
        self.assertNotIn("Process.start('cmd.exe'", app)
        self.assertNotIn("Process.start('cmd.exe'", agent)
        self.assertIn("external FlutterFalcon builder", document)
        self.assertIn("Win32_Process.Create", document)
        self.assertIn("must not persist access credentials", document)

    def test_incomplete_obsolete_client_cannot_be_relaunched(self):
        supervisor = read_text("sync_windows_agent_supervisor.ps1")
        self.assertIn("function Get-MissingAgentRuntimePaths {", supervisor)
        self.assertIn("flutter_windows.dll", supervisor)
        self.assertIn("data\\app.so", supervisor)
        self.assertIn("data\\icudtl.dat", supervisor)
        self.assertIn("launch suppressed", supervisor)
        loop = supervisor.split("while ($true) {", 1)[1]
        self.assertIn("Stop-ObsoleteInstallProcesses", loop)

    def test_persistent_obsolete_autostart_is_retired_before_launch(self):
        supervisor = read_text("sync_windows_agent_supervisor.ps1")
        self.assertIn("function Remove-ObsoleteLaunchRegistrations {", supervisor)
        self.assertIn("CurrentVersion\\Run", supervisor)
        self.assertIn("Disable-ScheduledTask", supervisor)
        self.assertIn("Retired obsolete launch registrations", supervisor)

    def test_updater_retires_obsolete_autostart_before_file_replacement(self):
        updater = read_text("update.ps1")
        self.assertIn("function Remove-ObsoleteLaunchRegistrations {", updater)
        differential = updater.split(
            "Stopping the supervisor before scheduling differential replacement.", 1
        )[1].split("Start-DeferredInstall", 1)[0]
        package = updater.split(
            "Stopping the supervisor before scheduling package replacement.", 1
        )[1].split("Start-DeferredInstall", 1)[0]
        self.assertIn("Remove-ObsoleteLaunchRegistrations", differential)
        self.assertIn("Remove-ObsoleteLaunchRegistrations", package)

    def test_updater_stops_obsolete_running_installs_before_replacement(self):
        updater = read_text("update.ps1")
        self.assertIn("function Stop-ObsoleteInstallProcesses {", updater)
        self.assertIn("Updater retired obsolete running installs", updater)
        for marker in (
            "Stopping the supervisor before scheduling differential replacement.",
            "Stopping the supervisor before scheduling package replacement.",
        ):
            handoff = updater.split(marker, 1)[1].split("Start-DeferredInstall", 1)[0]
            self.assertIn("Stop-ObsoleteInstallProcesses", handoff)

    def test_updater_recognizes_encoded_supervisor_commands(self):
        updater = read_text("update.ps1")
        self.assertIn("function Get-PowerShellLaunchText {", updater)
        self.assertIn("FromBase64String", updater)
        stop_target = updater.split("function Stop-SupervisorProcesses {", 1)[1].split(
            "function Stop-ObsoleteInstallProcesses {", 1
        )[0]
        self.assertIn("Get-PowerShellLaunchText", stop_target)

    def test_upload_and_backend_execution_memory_are_bounded(self):
        agent = read_text("sync_windows_agent/lib/agent_page.dart")
        packages = read_text("sync_windows_agent/lib/delta_package.dart")
        values = read_text("deployment/chart/values.yaml")
        deployment = read_text("deployment/chart/templates/backend-deployment.yaml")

        self.assertIn("100 ~/ (uniqueKeyColumnSets.length + 1)", agent)
        self.assertIn("math.min(kDeltaPackageMaxRows", agent)
        self.assertIn("const int kDeltaPackageMaxRows = 100;", packages)
        self.assertIn(
            "const int kDeltaPackageMaxUncompressedBytes = 512000;", packages
        )
        self.assertIn(
            "const int kDeltaPackageMaxCompressedBytes = 384000;", packages
        )
        self.assertIn('truExecutionMemoryMaxBytes: "536870912"', values)
        self.assertIn("TRU_EXECUTION_MEMORY_MAX_BYTES", deployment)
        self.assertIn(".Values.backend.env.truExecutionMemoryMaxBytes", deployment)

    def test_local_architecture_commands_and_release_contract_are_documented(self):
        document = ISSUES.read_text(encoding="utf-8")
        runner = read_text("tests/run_sync_verification.ps1")

        self.assertIn(".\\tests\\run_sync_verification.ps1 -Profile Standard", document)
        self.assertIn(".\\tests\\run_sync_verification.ps1 -Profile All", document)
        self.assertIn("three fake Docker clients", document)
        self.assertIn("never justify testing against active production databases", document)
        self.assertIn("tests/test_incident_regressions.py", runner)

    def test_agents_requires_issue_documentation_and_automated_regression(self):
        rules = read_text("AGENTS.md")

        self.assertIn("## Issue Documentation and Regression Rule", rules)
        self.assertIn("must be documented in the root `issue.md` incident matrix", rules)
        self.assertIn("do not merely report it: document it in `issue.md`, implement the long-term fix", rules)
        self.assertIn("report the exact blocker instead of ignoring it or applying an unsafe workaround", rules)
        self.assertIn("must add or extend an automated unit, contract, integration", rules)
        self.assertIn("A manual check alone is not sufficient", rules)
        self.assertIn("tests/run_sync_verification.ps1", rules)
        self.assertIn("Never use active production client databases to reproduce an issue", rules)

    def test_local_test_standard_is_hidden_documented_and_delegates_to_gate(self):
        runner = read_text("tests/run_local_test_standard.ps1")
        documentation = read_text("docs/local-testing.md")
        readme = read_text("README.md")

        self.assertIn("-WindowStyle Hidden", runner)
        self.assertIn("run_sync_verification.ps1", runner)
        self.assertIn("task-status.json", runner)
        self.assertIn("tests/run_local_test_standard.ps1", documentation)
        self.assertIn("workspace/tests/local-standard/", documentation)
        self.assertIn("run_local_test_standard.ps1", readme)

    def test_production_image_builder_excludes_local_caches_by_construction(self):
        builder = read_text("scripts/build_production_images.ps1")

        self.assertIn("git -C (Join-Path $repoRoot 'backend') archive", builder)
        self.assertIn("git -C $repoRoot archive", builder)
        self.assertIn("$commit business", builder)
        self.assertIn("$commit frontend", builder)
        self.assertNotIn("Copy-Item -LiteralPath 'backend/server'", builder)
        self.assertIn("sync_windows_agent_latest.zip", builder)
        self.assertIn('backend:$commit', builder)
        self.assertIn('frontend:$commit', builder)
        self.assertIn("docker push $backendImage", builder)
        self.assertIn("docker push $frontendImage", builder)

    def test_production_image_push_retries_transient_registry_failures(self):
        builder = read_text("scripts/build_production_images.ps1")
        deployer = read_text("scripts/deploy_production_images.ps1")
        retry = builder.split("function Invoke-NativeCheckedWithRetry {", 1)[1].split(
            "\n}\n", 1
        )[0]

        self.assertIn("[ValidateRange(1, 5)][int] $Attempts = 3", retry)
        self.assertIn("for ($attempt = 1; $attempt -le $Attempts", retry)
        self.assertIn("Start-Sleep -Seconds ([Math]::Pow(2, $attempt - 1))", retry)
        self.assertIn("failed after $Attempts attempts", retry)
        self.assertIn(
            'Invoke-NativeCheckedWithRetry "Pushing $backendImage..."', builder
        )
        self.assertIn(
            'Invoke-NativeCheckedWithRetry "Pushing $frontendImage..."', builder
        )
        self.assertIn(
            "docker manifest inspect $backendImage *> $null", builder
        )
        self.assertIn(
            "docker manifest inspect $frontendImage *> $null", builder
        )
        self.assertIn("$null -ne $Verify", builder)
        self.assertIn("function Assert-RegistryManifestAvailable {", deployer)
        self.assertIn("[ValidateRange(1, 5)][int] $Attempts = 3", deployer)
        self.assertIn("docker manifest inspect $Image", deployer)
        self.assertIn("Start-Sleep -Seconds ([Math]::Pow(2, $attempt - 1))", deployer)
        self.assertIn("Assert-RegistryManifestAvailable -Image $image", deployer)

    def test_production_deployer_uses_exact_container_mappings_and_namespace(self):
        deployer = read_text("scripts/deploy_production_images.ps1")

        self.assertIn("deployment/sql-sync-back', \"backend=$backendImage\"", deployer)
        self.assertIn("deployment/sql-sync-front', \"frontend=$frontendImage\"", deployer)
        self.assertNotIn("sql-sync-back=$backendImage", deployer)
        self.assertNotIn("sql-sync-front=$frontendImage", deployer)
        self.assertIn("kubectl @Arguments -n $Namespace", deployer)
        self.assertIn("docker manifest inspect $Image", deployer)
        self.assertIn("$health.build.git_commit", deployer)
        self.assertIn("for ($attempt = 1; $attempt -le 24; $attempt += 1)", deployer)
        self.assertIn("$stableObservations -ge 2", deployer)
        self.assertIn("Start-Sleep -Seconds 5", deployer)

    def test_manual_sync_dispatch_helper_uses_valid_tru_function_declaration(self):
        control_plane = read_text("business/control_plane.tru")

        self.assertIn(
            "function begin_manual_sync_all_for_owner(ownerUserId: string, requestedAt: string): map<json> {",
            control_plane,
        )
        self.assertNotIn("function begin_manual_sync_all_for_owner(\n", control_plane)

    def test_clients_list_distinguishes_latest_sync_and_sync_all_durations(self):
        clients_page = read_text("frontend/lib/clients_page.dart")

        self.assertIn("DataColumn(label: Text('Last sync duration'))", clients_page)
        self.assertIn("DataColumn(label: Text('Last Sync All total'))", clients_page)
        self.assertIn(
            "DataCell(Text(formatSyncDuration(agent.lastSyncDuration)))",
            clients_page,
        )
        self.assertIn(
            "formatSyncDuration(_syncAllOperationForAgent(agent)?.duration())",
            clients_page,
        )
        self.assertIn("DataColumn(label: Text('Client version'))", clients_page)
        self.assertIn("agent.clientVersion.trim()", clients_page)

    def test_web_download_button_displays_latest_client_manifest_version(self):
        app = read_text("frontend/lib/app.dart")
        parser = read_text("frontend/lib/client_update_manifest.dart")

        self.assertIn("/client/latest.json?release=$nonce", app)
        self.assertIn("parseLatestWindowsClientVersion(response.body)", app)
        self.assertIn("Download Windows Client · v$version", app)
        self.assertIn("decoded['version']", parser)

    def test_slow_network_sync_transfers_are_durable_and_content_verified(self):
        control_plane = read_text("business/control_plane.tru")
        api = read_text("sync_windows_agent/lib/live_sync_api.dart")
        agent = read_text("sync_windows_agent/lib/agent_page.dart")
        cache = read_text("sync_windows_agent/lib/sync_transfer_cache.dart")

        self.assertIn("transferManifest", control_plane)
        self.assertIn("transferChunk", control_plane)
        self.assertIn("crypto.hash(transferChunkPayload, 'sha256')", control_plane)
        self.assertIn("loadDownloadPages", api)
        self.assertIn("Multi-writer transfer chunk failed SHA-256", api)
        self.assertIn("loadUploadSnapshot", agent)
        self.assertIn("saveUploadSnapshot", agent)
        self.assertIn("Buffer the complete table delta before SQL apply", agent)
        self.assertIn("maxBytes = 2 * 1024 * 1024 * 1024", cache)
        self.assertIn("maxAge = Duration(days: 7)", cache)

    def test_transfer_payload_uses_tru_type_stable_assignment(self):
        control_plane = read_text("business/control_plane.tru")

        self.assertIn(
            "let transferChunkPayload = string.from(chunkPayloadBase64);",
            control_plane,
        )
        self.assertIn(
            "transferChunkPayload = json.stringify(chunkRows);", control_plane
        )
        self.assertNotIn(
            "const transferChunkPayload = chunkPayloadBase64.length != 0",
            control_plane,
        )

    def test_online_client_update_reports_and_resumes_durable_transfer(self):
        control_plane = read_text("business/control_plane.tru")
        agent = read_text("sync_windows_agent/lib/agent_page.dart")
        updater = read_text("update.ps1")

        self.assertIn("normalizedStatus == 'downloading'", control_plane)
        self.assertIn("normalizedNextStatus != 'downloading'", control_plane)
        self.assertIn("status: 'downloading'", agent)
        self.assertIn("'updateLogTail': _readUpdateLogTail()", agent)
        self.assertIn('$partialFile = "$OutFile.part"', updater)
        self.assertIn('ChildPath ".update-cache\\$safeTargetVersion"', updater)

    def test_completed_transfer_reports_atomic_apply_phase(self):
        agent = read_text("sync_windows_agent/lib/agent_page.dart")
        download = agent.split(
            "Future<void> _processSnapshotRelayDownloadJob(", 1
        )[1].split("Future<", 1)[0]

        self.assertIn("Verified download complete; atomically applying", download)
        self.assertLess(
            download.index("Verified download complete; atomically applying"),
            download.index("await _applyDownloadedSnapshotToTarget("),
        )

    def test_authenticated_update_waits_for_active_sync_work(self):
        app = read_text("sync_windows_agent/lib/app.dart")
        shell = app.split(
            "Future<void> _maybeAutoApplyShellClientUpdate(", 1
        )[1].split("void _migrateStoredClientState", 1)[0]
        agent = read_text("sync_windows_agent/lib/agent_page.dart")

        self.assertIn("_authToken?.trim().isNotEmpty", shell)
        self.assertIn("_processingJobIds.isNotEmpty", agent)
        self.assertIn("_activeJobs.any(", agent)

    def test_large_row_comparison_is_set_based_not_process_per_page(self):
        agent = read_text("sync_windows_agent/lib/agent_page.dart")
        lookup = agent.split(
            "Future<List<Map<String, dynamic>>> _fetchRowsByPrimaryKeys(", 1
        )[1].split("String _sourceBatchEncodedColumnExpression(", 1)[0]

        self.assertIn("buildTargetPrimaryKeyLookupFromStageSql(", lookup)
        self.assertEqual(lookup.count("await _runSqlCmd("), 1)
        self.assertNotIn("keyBatchSize", lookup)

    def test_client_differential_updates_compress_large_changed_files(self):
        publisher = read_text("scripts/publish_windows_client_update.ps1")
        updater = read_text("update.ps1")

        self.assertIn("[System.IO.Compression.CompressionLevel]::Optimal", publisher)
        self.assertIn("$entry.transferSizeBytes = $compressedSize", publisher)
        self.assertIn("$request.AddRange($existingBytes)", updater)
        self.assertIn("Expand-VerifiedGzipUpdateFile", updater)
        self.assertIn(
            "Test-InstalledFileMatchesManifest -Path $stagedPath",
            updater,
        )

    def test_set_based_target_hash_projection_is_alias_qualified(self):
        agent = read_text("sync_windows_agent/lib/agent_page.dart")
        lookup = agent.split(
            "Future<List<Map<String, dynamic>>> _fetchRowsByPrimaryKeys(", 1
        )[1].split("String _sourceBatchEncodedColumnExpression(", 1)[0]

        self.assertIn("target_row.${_quoteIdentifier(column.name)}", lookup)

    def test_interrupted_client_update_remains_on_its_immutable_release(self):
        publisher = read_text("scripts/publish_windows_client_update.ps1")
        updater = read_text("update.ps1")

        self.assertIn("$packageDirName/files.json", publisher)
        self.assertIn("$fileEntry.transferUrl", updater)
        self.assertIn("$request.AddRange($existingBytes)", updater)
        self.assertIn("filesManifest.commit", updater)

    def test_atomic_apply_staging_resumes_chunks_and_keeps_final_merge_atomic(self):
        agent = read_text("sync_windows_agent/lib/agent_page.dart")
        merge = read_text("sync_windows_agent/lib/sql_sync_merge.dart")
        apply_body = agent.split(
            "Future<_TargetApplyResult> _applySourceRowsToTarget(", 1
        )[1].split("String _nextTargetSnapshotStageTableName(", 1)[0]

        self.assertIn("_targetSnapshotStageTableNameForOperation(", apply_body)
        self.assertIn("replaceExisting: false", apply_body)
        self.assertIn("_queryTargetSnapshotStageRowCount(", apply_body)
        self.assertIn("while (stagedRowCount < rows.length)", apply_body)
        self.assertIn("buildTargetSnapshotStageInsertSql(", apply_body)
        self.assertIn("await onStageProgress?.call(stagedRowCount, rows.length)", apply_body)
        self.assertIn("if (mergeCompleted)", apply_body)
        self.assertIn("SELECT __row_num, $sourceColumnList", merge)
        self.assertIn("INTO $workingSource", merge)
        self.assertIn("BEGIN TRANSACTION;", merge)
        merge_body = merge.split(
            "String buildTargetSnapshotStageApplySql(", 1
        )[1].split("String _buildStagedDeltaDeleteStatements(", 1)[0]
        self.assertEqual(merge_body.count("DROP TABLE $stageTarget"), 1)
        self.assertIn("Transport/process interruption", merge_body)

    def test_active_client_status_reports_progress_rate_or_stall(self):
        source = read_text("frontend/lib/clients_page.dart")
        self.assertIn("_recordJobProgress(nextState.jobs)", source)
        self.assertIn("'$phase ${job.progress.clamp(0, 100)}%'", source)
        self.assertIn("rows/s", source)
        self.assertIn("%/min", source)
        self.assertIn("no movement ${formatSyncDuration(unchangedFor)}", source)
        self.assertIn("_jobProgressSamples.removeWhere", source)

    def test_active_sync_job_cannot_disappear_from_bounded_web_history(self):
        source = read_text("business/control_plane.tru")
        live_state = source.split("function live_state(token:", 1)[1].split(
            "function agents_heartbeat", 1
        )[0]
        prioritizer = source.split(
            "function prioritized_live_state_job_rows(", 1
        )[1].split("function ensure_agent", 1)[0]
        self.assertIn("activeRows.concat(historyRows)", prioritizer)
        self.assertIn("string_array_contains(seenIds, id)", prioritizer)
        self.assertIn("prioritized_live_state_job_rows(activeJobRows, recentJobRows)", live_state)

    def test_updater_launch_failure_enters_transactional_rollback(self):
        updater = read_text("update.ps1")
        finalizer = updater.split("if (-not $NoStart) {", 1)[1].split(
            "Write-UpdateLog -Message \"Finalize helper cleaning work root", 1
        )[0]
        self.assertIn("$updatedClientStable = $false", finalizer)
        self.assertIn("try {\n            Start-UpdatedClient", finalizer)
        self.assertIn("catch {", finalizer)
        self.assertIn("if (-not $updatedClientStable)", finalizer)
        self.assertIn("Restore-InstallRollbackSnapshot", finalizer)

    def test_deferred_update_failure_is_reported_after_safe_rollback(self):
        updater = read_text("update.ps1")
        agent = read_text("sync_windows_agent/lib/agent_page.dart")

        self.assertIn("function Write-FinalizerFailureProgress", updater)
        self.assertIn("Finalize update helper failed: $failureMessage", updater)
        self.assertIn("Write-FinalizerFailureProgress -InstallDir $InstallDir", updater)
        self.assertIn("status = 'failed'", updater)
        self.assertIn("'failed' => 'failed'", agent)

    def test_deferred_finalizer_stops_encoded_target_supervisor(self):
        updater = read_text("update.ps1")
        helper = updater.split("$helper = @'", 1)[1].split("\n'@", 1)[0]
        stop_supervisor = helper.split("function Stop-SupervisorProcesses", 1)[1].split(
            "function Start-SupervisorProcess", 1
        )[0]

        self.assertIn("function Get-PowerShellLaunchText", helper)
        self.assertIn("[Convert]::FromBase64String", helper)
        self.assertIn("$launchText = Get-PowerShellLaunchText", stop_supervisor)
        self.assertIn("$launchText.IndexOf($supervisorPath", stop_supervisor)
        self.assertNotIn("$_.CommandLine.IndexOf($supervisorPath", stop_supervisor)

    def test_protected_install_retries_handoff_with_standard_uac(self):
        updater = read_text("update.ps1")

        self.assertIn("function Test-InstallNeedsElevation", updater)
        self.assertIn("[string]::IsNullOrWhiteSpace($_.ExecutablePath)", updater)
        self.assertIn("-Verb RunAs", updater)
        self.assertIn("-Elevated:$requiresElevation", updater)
        self.assertIn("Windows administrator approval is required once", updater)

    def test_stale_verified_install_retry_requests_standard_uac(self):
        updater = read_text("update.ps1")

        self.assertIn("function Test-PriorInstallHandoffNeedsElevation", updater)
        self.assertIn("$priorInstallHandoffNeedsElevation", updater)
        self.assertIn("A prior verified install handoff did not finish", updater)
        self.assertGreaterEqual(
            updater.count("$priorInstallHandoffNeedsElevation -or (Test-InstallNeedsElevation"),
            2,
        )

    def test_staggered_old_client_retries_cannot_suppress_uac(self):
        updater = read_text("update.ps1")

        retry_guard = updater.split(
            "function Test-PriorInstallHandoffNeedsElevation", 1
        )[1].split("function Start-DeferredInstall", 1)[0]
        self.assertIn("[int] $MinimumAgeSeconds = 5", retry_guard)
        self.assertIn("TotalSeconds -ge", retry_guard)

    def test_direct_web_updater_has_obsolete_install_cleanup_in_parent_scope(self):
        updater = read_text("update.ps1")

        helper_start = updater.index("$helper = @'")
        definitions = [
            match.start()
            for match in re.finditer(
                r"function Stop-ObsoleteInstallProcesses \{", updater
            )
        ]
        self.assertEqual(len(definitions), 2)
        self.assertLess(definitions[0], helper_start)

    def test_existing_supervisor_mutex_does_not_force_update_rollback(self):
        updater = read_text("update.ps1")

        self.assertGreaterEqual(updater.count("$attempt -le 45"), 2)
        self.assertGreaterEqual(
            updater.count("Get-AgentProcesses -TargetInstallDir $TargetInstallDir"),
            6,
        )
        self.assertIn("no target client appeared", updater)

    def test_non_exec_scheduled_task_actions_do_not_break_scoped_cleanup(self):
        updater = read_text("update.ps1")
        supervisor = read_text("sync_windows_agent_supervisor.ps1")

        for source in (updater, supervisor):
            self.assertIn("$_.PSObject.Properties['Execute']", source)
            self.assertIn("$null -ne $executeProperty", source)

    def test_incomplete_install_fixture_waits_for_agent_validation(self):
        test_script = read_text("tests/test_windows_supervisor.ps1")
        lifecycle_launch = test_script.split("$supervisorProcess = Start-Process", 1)[1]

        self.assertIn("Agent install is incomplete; launch suppressed", lifecycle_launch)
        self.assertNotIn("'-SkipAgentStart'", lifecycle_launch)
        self.assertIn("$logDeadline = [DateTime]::UtcNow.AddSeconds(15)", lifecycle_launch)
        self.assertIn("do {", lifecycle_launch)
        self.assertIn("isolated_supervisor_fixture.ps1", test_script)

    def test_client_updater_url_is_immutable_per_release(self):
        publisher = read_text("scripts/publish_windows_client_update.ps1")

        self.assertIn(
            'updateScriptUrl = "$publicRoot/packages/$packageDirName/update.ps1"',
            publisher,
        )
        self.assertNotIn('updateScriptUrl = "$publicRoot/update.ps1"', publisher)

    def test_client_update_retrying_has_one_reachable_color_case(self):
        source = read_text("frontend/lib/clients_page.dart")
        color_mapper = source.split(
            "Color _clientActivityColor(String status)", 1
        )[1].split("Widget _buildClientListItem", 1)[0]
        self.assertEqual(color_mapper.count("case 'update retrying':"), 1)

    def test_resumable_client_update_progress_is_visible_without_credentials(self):
        updater = read_text("update.ps1")
        agent = read_text("sync_windows_agent/lib/agent_page.dart")
        backend = read_text("business/control_plane.tru")
        web = read_text("frontend/lib/clients_page.dart")

        self.assertIn("update-progress.json", updater)
        self.assertIn("Move-Item -LiteralPath $temporaryPath", updater)
        self.assertIn("Progress reporting is best effort", updater)
        self.assertIn("_readClientUpdateProgress", agent)
        self.assertNotIn("token", updater.lower())
        self.assertIn("clientUpdateProgressPercent", backend)
        self.assertIn("Update downloading $percent%", web)

    def test_large_hash_comparison_resumes_bounded_key_staging(self):
        agent = read_text("sync_windows_agent/lib/agent_page.dart")
        lookup = agent.split(
            "Future<List<Map<String, dynamic>>> _fetchRowsByPrimaryKeys(", 1
        )[1].split("String _sourceBatchEncodedColumnExpression(", 1)[0]

        self.assertIn("_targetSnapshotStageTableNameForOperation(", lookup)
        self.assertIn("replaceExisting: false", lookup)
        self.assertIn("_queryTargetSnapshotStageRowCount(", lookup)
        self.assertIn("while (stagedRowCount < keyRows.length)", lookup)
        self.assertIn("targetSnapshotInsertRowsPerStatement", lookup)
        self.assertIn("buildTargetPrimaryKeyLookupFromStageSql(", lookup)
        self.assertIn("lookupCompleted || confirmedFailure", lookup)
        self.assertIn("onLookupStageProgress", agent)

    def test_slow_literal_staging_uses_bounded_resumable_bulk_copy(self):
        agent = read_text("sync_windows_agent/lib/agent_page.dart")
        bulk_source = read_text("sync_windows_agent/assets/SqlBulkStage.cs")
        benchmark = read_text("tests/benchmark_sql_bulk_stage.ps1")

        self.assertGreaterEqual(agent.count("_runSqlBulkStageRows("), 3)
        self.assertIn("durableRowCount = await _queryTargetSnapshotStageRowCount", agent)
        self.assertIn("bulkCopyAvailable = false", agent)
        self.assertIn("SqlBulkCopyOptions.UseInternalTransaction", bulk_source)
        self.assertIn("bulkCopy.BatchSize", bulk_source)
        self.assertIn("MinimumSpeedup = 1.25", benchmark)
        self.assertIn("SqlBulkCopy speedup", benchmark)

    def test_frontend_image_retries_transient_flutter_web_sdk_downloads(self):
        dockerfile = read_text("frontend/Dockerfile")
        builder = read_text("scripts/build_production_images.ps1")

        self.assertIn("until flutter precache --web", dockerfile)
        self.assertIn('if [ "$attempt" -ge 3 ]; then exit 1; fi', dockerfile)
        self.assertIn('Invoke-NativeCheckedWithRetry "Building $frontendImage..."', builder)
        self.assertIn("docker image inspect $frontendImage", builder)

    def test_server_update_cannot_interrupt_active_sql_apply(self):
        agent = read_text("sync_windows_agent/lib/agent_page.dart")
        update_body = agent.split(
            "Future<void> _maybeAutoApplyClientUpdate(", 1
        )[1].split("String _clientUpdateCommand", 1)[0]
        queue_body = agent.split(
            "Future<void> _processPendingJobs() async", 1
        )[1].split("void _checkSyncJobNotCancelled", 1)[0]

        self.assertIn("if (_clientUpdateMustWaitForSafeSyncBoundary ||", update_body)
        self.assertIn("_processingJobIds.isNotEmpty", agent)
        self.assertIn("_pendingForcedClientUpdateInfo = updateInfo", update_body)
        self.assertIn("Pausing the local sync queue at a safe boundary", queue_body)
        self.assertIn("_retryAutomaticClientUpdateIfReady();", queue_body)


if __name__ == "__main__":
    unittest.main()
