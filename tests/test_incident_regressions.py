import pathlib
import re
import subprocess
import unittest


ROOT = pathlib.Path(__file__).resolve().parents[1]
ISSUES = ROOT / "issue.md"


def read_text(relative_path: str) -> str:
    return (ROOT / relative_path).read_text(encoding="utf-8")


class IncidentRegressionCatalogTests(unittest.TestCase):
    def test_every_catalog_incident_has_existing_automated_coverage(self):
        document = ISSUES.read_text(encoding="utf-8")
        rows = [line for line in document.splitlines() if line.startswith("| INC-")]
        expected_ids = {f"INC-{number:03d}" for number in range(1, 280)}
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

    def test_background_fingerprint_rotation_survives_client_restart(self):
        agent_page = read_text("sync_windows_agent/lib/agent_page.dart")
        sync_state = read_text("sync_windows_agent/lib/sync_state.dart")

        self.assertIn(
            "_tableFingerprintRefreshCursor = _syncState.fingerprintRefreshCursor",
            agent_page,
        )
        self.assertIn("fingerprintRefreshCursor: nextCursor", agent_page)
        self.assertIn("fingerprintAudit: nextAudit", agent_page)
        self.assertIn("final int fingerprintRefreshCursor", sync_state)
        self.assertIn("'fingerprintRefreshCursor': fingerprintRefreshCursor", sync_state)

    def test_integrity_rotation_exposes_progress_and_bounded_table_logs(self):
        agent = read_text("sync_windows_agent/lib/agent_page.dart")
        control_plane = read_text("business/control_plane.tru")
        clients = read_text("frontend/lib/clients_page.dart")

        self.assertIn("'checkedTables': checkedTables", agent)
        self.assertIn("'totalTables': targets.length", agent)
        self.assertIn("'lastBatchTables': batchTables", agent)
        self.assertIn(".take(20).toList()", agent)
        self.assertIn("if (history.length >= 20)", control_plane)
        self.assertIn("if (tables.length >= 8)", control_plane)
        self.assertIn("fingerprintAudit: nextFingerprintAudit", control_plane)
        self.assertIn("ValueKey('fingerprint-audit-log-${agent.clientName}')", clients)
        self.assertIn("Recent check batches", clients)

    def test_client_list_groups_each_sync_metric_by_workflow(self):
        clients = read_text("frontend/lib/clients_page.dart")
        summary = read_text("frontend/lib/sync_summary_cell.dart")

        self.assertIn("DataColumn(label: Text('Last result'))", clients)
        self.assertIn("DataColumn(label: Text('Totals / scope'))", clients)
        self.assertIn("DataColumn(label: Text('Last activity'))", clients)
        self.assertIn("DataColumn(label: Text('Duration'))", clients)
        self.assertNotIn("DataColumn(label: Text('Integrity check'))", clients)
        self.assertNotIn("DataColumn(label: Text('Last Sync All total'))", clients)
        self.assertIn("label: 'Changes'", clients)
        self.assertIn("label: 'Sync All'", clients)
        self.assertIn("label: 'Integrity'", clients)
        self.assertIn("assert(items.length == 3)", summary)

    def test_production_builder_discovers_the_live_immutable_probe_safely(self):
        builder = read_text("scripts/build_production_images.ps1")

        self.assertIn("function Resolve-LiveRegistryAccessProbeTag", builder)
        self.assertIn("kubectl get deployment sql-sync-back sql-sync-front", builder)
        self.assertIn("-n $KubernetesNamespace -o json", builder)
        self.assertIn("ConvertFrom-Json", builder)
        self.assertNotIn("-o jsonpath", builder)
        self.assertIn("$tags.backend -ne $tags.frontend", builder)
        self.assertIn("PSObject.Properties['initContainers']", builder)
        self.assertIn("Using current live immutable registry probe tag", builder)

    def test_live_copy_collection_survives_frontend_pod_replacement(self):
        collector = read_text("scripts/collect_live_client_database_copies.ps1")

        self.assertIn("Get-ReadyFrontendPod", collector)
        self.assertIn("Assert-FrontendPodStable $pod", collector)
        self.assertIn("FRONTEND_POD_REPLACED:", collector)
        self.assertIn("FRONTEND_EXPORT_MISSING:", collector)
        self.assertIn("$MaxExportAttempts", collector)
        self.assertIn("Reset-LocalAttemptDirectory $clientDirectory", collector)
        self.assertIn("$availableParts[0] -ne '00000000.part'", collector)

    def test_new_export_request_supersedes_stuck_client_export(self):
        agent = read_text("sync_windows_agent/lib/agent_page.dart")
        cancellation = read_text(
            "sync_windows_agent/lib/data_export_cancellation.dart"
        )

        self.assertIn("_activeDataExportCancellation?.cancel()", agent)
        self.assertIn("_queuedDataExportRequest = request", agent)
        self.assertIn("_startRequestedDataExport(queued)", agent)
        self.assertIn("cancellation.race(exitCodeFuture)", agent)
        self.assertIn("DataExportSupersededException", cancellation)

    def test_client_publication_cannot_silently_remain_local(self):
        publisher = read_text("scripts/publish_windows_client_update.ps1")

        self.assertIn("[string] $SshTarget = 'velvet-leaf-1'", publisher)
        self.assertIn("[switch] $ArtifactOnly", publisher)
        self.assertNotIn("No -SshTarget supplied; skipping live upload.", publisher)

    def test_live_copy_chunks_survive_until_whole_backup_is_verified(self):
        collector = read_text("scripts/collect_live_client_database_copies.ps1")

        self.assertNotIn("rm -f '$PodDirectory/$Artifact'", collector)
        self.assertIn("function Remove-VerifiedRemoteExport", collector)
        self.assertIn("Refusing to clean an invalid remote export request id", collector)
        self.assertLess(
            collector.index("backup length mismatch"),
            collector.index("Remove-VerifiedRemoteExport -Pod $pod"),
        )

    def test_unbounded_history_disk_incident_has_bounded_regression_fix(self):
        document = ISSUES.read_text(encoding="utf-8")
        incident = next(
            line for line in document.splitlines() if line.startswith("| INC-133 |")
        )

        self.assertIn("FreeDiskSpaceFailed", incident)
        self.assertIn("public.tru_history", incident)
        self.assertIn("unbounded default `full` audit history", incident)
        self.assertIn("persists after 10 seconds", incident)
        self.assertIn("updatedAt: now_iso()", incident)
        self.assertIn("quadratic amplification", incident)
        self.assertIn("retention or archival semantics", incident)
        self.assertIn("targeted class-level `history minimal`", incident)
        self.assertIn("7-day/100,000-entry bound", incident)

        control_plane = read_text("business/control_plane.tru")
        config = read_text("business/tru.json")
        maintenance = read_text(
            "deployment/chart/templates/history-maintenance-cronjob.yaml"
        )
        values = read_text("deployment/chart/values.yaml")
        self.assertIn("class Agent {\n  history minimal", control_plane)
        self.assertIn("class UploadSession {\n  history minimal", control_plane)
        self.assertIn("class DownloadSession {\n  history minimal", control_plane)
        self.assertNotIn('"historyMode": "minimal"', config)
        self.assertIn("updatedAt: normalizedUpdatedAt", control_plane)
        self.assertIn("string.from(relationship.updatedAt ?? '')", control_plane)
        self.assertIn(
            "bounded_table_relationships(database, tableRelationships, resolvedClientName, false)",
            control_plane,
        )
        self.assertIn("retentionDays: 7", values)
        self.assertIn("maxEntries: 100000", values)
        self.assertIn("DELETE FROM tru_history", maintenance)
        self.assertIn("VACUUM (ANALYZE, PARALLEL 0) tru_history", maintenance)

    def test_history_maintenance_is_bounded_secret_backed_and_scheduled(self):
        values = read_text("deployment/chart/values.yaml")
        template = read_text(
            "deployment/chart/templates/history-maintenance-cronjob.yaml"
        )

        self.assertIn('schedule: "17 3 * * *"', values)
        self.assertIn("retentionDays: 7", values)
        self.assertIn("maxEntries: 100000", values)
        self.assertIn("concurrencyPolicy: Forbid", template)
        self.assertIn("activeDeadlineSeconds:", template)
        self.assertIn("secretKeyRef:", template)
        self.assertIn("DELETE FROM tru_history", template)
        self.assertIn("VACUUM (ANALYZE, PARALLEL 0) tru_history", template)

    def test_history_maintenance_avoids_parallel_vacuum_shared_memory(self):
        template = read_text(
            "deployment/chart/templates/history-maintenance-cronjob.yaml"
        )

        self.assertIn("VACUUM (ANALYZE, PARALLEL 0) tru_history", template)
        self.assertNotIn("VACUUM (ANALYZE) tru_history", template)

    def test_backend_memory_limit_survives_helm_reuse_values(self):
        deployment = read_text("deployment/chart/templates/backend-deployment.yaml")
        self.assertIn(
            '.Values.backend.env.truExecutionMemoryMaxBytes | default "536870912"',
            deployment,
        )

    def test_production_builder_requires_root_and_submodule_commits_on_remote(self):
        builder = read_text("scripts/build_production_images.ps1")
        preflight = builder.split("function Assert-CommitAvailableOnRemote", 1)[1].split(
            "\n}\n", 1
        )[0]

        self.assertIn("git -C $RepositoryPath fetch --quiet origin master", preflight)
        self.assertIn("merge-base --is-ancestor $Commit origin/master", preflight)
        self.assertIn("force-pushing is not allowed", preflight)
        self.assertIn("-RepositoryPath $backendRepo -Commit $backendCommit", builder)
        self.assertIn("-RepositoryPath $repoRoot -Commit $commit", builder)

    def test_registry_probe_diagnostics_are_non_destructive_and_tag_aware(self):
        scripts = [
            read_text("scripts/build_production_images.ps1"),
            read_text("scripts/deploy_production_images.ps1"),
        ]
        builder = scripts[0]

        self.assertIn("RegistryAccessProbeTag is the exact existing immutable tag", builder)
        self.assertIn("Windows Docker client is authenticated", builder)
        for source in scripts:
            self.assertNotIn("docker logout", source.lower())

    def test_live_verifier_unit_harness_injects_fake_runtime_credentials(self):
        source = read_text("tests/test_live_verifier_scripts.py")

        setup = source.split("class LiveVerifierScriptsTests", 1)[1].split(
            "def test_client_update_read_retries", 1
        )[0]
        self.assertIn('"SQL_SYNC_ADMIN_USERNAME": "isolated-test-admin"', setup)
        self.assertIn('"SQL_SYNC_ADMIN_PASSWORD": "isolated-test-password"', setup)
        self.assertIn("self.addCleanup(self._credential_environment.stop)", setup)

    def test_client_state_commit_fixture_supplies_unrelated_version_prerequisite(self):
        source = read_text("tests/test_live_verifier_scripts.py")
        body = source.split(
            "def test_clients_state_main_returns_commit_mismatch_code", 1
        )[1].split("def test_clients_state_run_cli_converts_api_error", 1)[0]

        self.assertIn('"--expected-version"', body)
        self.assertIn('"1.0.282+286"', body)
        self.assertIn('"--expect-commit"', body)
        self.assertIn("self.assertEqual(exit_code, 2)", body)

    def test_hidden_standard_launcher_refreshes_exit_code_after_wait(self):
        launcher = read_text("tests/run_local_test_standard.ps1")
        wait_block = launcher.split("$childProcess.WaitForExit()", 1)[1].split(
            "$statusPath =", 1
        )[0]

        self.assertIn("$childProcess.Refresh()", wait_block)
        self.assertLess(
            wait_block.index("$childProcess.Refresh()"),
            wait_block.index("$exitCode = $childProcess.ExitCode"),
        )

    def test_hidden_process_waitfor_exit_returns_concrete_exit_code(self):
        probe = subprocess.run(
            [
                "powershell.exe",
                "-NoProfile",
                "-Command",
                "$p = Start-Process -FilePath 'powershell.exe' "
                "-ArgumentList @('-NoProfile', '-Command', 'exit 7') "
                "-WindowStyle Hidden -PassThru; "
                "$p.WaitForExit(); $p.Refresh(); "
                "if ($p.ExitCode -ne 7) { exit 1 }",
            ],
            capture_output=True,
            text=True,
            check=False,
            timeout=30,
        )
        self.assertEqual(probe.returncode, 0, probe.stderr)

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

        self.assertIn("[string] $ClientArtifactsDir", builder)
        self.assertIn(
            "'latest.json', 'latest-files.json', 'update.ps1', 'sync_windows_agent_latest.zip'",
            builder,
        )
        self.assertIn("Missing current Windows client artifact", builder)
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

    def test_production_image_build_fails_fast_without_registry_access(self):
        builder = read_text("scripts/build_production_images.ps1")

        preflight = builder.split(
            "function Assert-RegistryAccessBeforeBuild {", 1
        )[1].split("\n}\n", 1)[0]
        call_index = builder.index(
            "Assert-RegistryAccessBeforeBuild -RepositoryRoot $RegistryRoot"
        )
        context_index = builder.index(
            "New-Item -ItemType Directory -Force -Path $backendContext"
        )
        backend_build_index = builder.index(
            'Building $backendImage...'
        )

        self.assertIn("docker manifest inspect $probeImage", preflight)
        self.assertIn("docker login", preflight)
        self.assertIn("$ErrorActionPreference = 'Continue'", preflight)
        self.assertIn("$probeExitCode = $LASTEXITCODE", preflight)
        self.assertIn("[string] $RegistryAccessProbeTag = ''", builder)
        self.assertIn("Resolve-LiveRegistryAccessProbeTag", builder)
        self.assertIn("Production registry probe failed for $probeImage", builder)
        self.assertNotIn("[string] $RegistryAccessProbeTag = 'dev'", builder)
        self.assertLess(call_index, context_index)
        self.assertLess(call_index, backend_build_index)
        self.assertIn("if (-not $SkipPush)", builder)

    def test_production_deployer_uses_exact_container_mappings_and_namespace(self):
        deployer = read_text("scripts/deploy_production_images.ps1")

        self.assertIn("\"backend=$backendImage\"", deployer)
        self.assertIn("\"backend-data-permissions=$backendImage\"", deployer)
        self.assertIn("deployment/sql-sync-front', \"frontend=$frontendImage\"", deployer)
        self.assertNotIn("sql-sync-back=$backendImage", deployer)
        self.assertNotIn("sql-sync-front=$frontendImage", deployer)
        self.assertIn("kubectl @Arguments -n $Namespace", deployer)
        self.assertIn("docker manifest inspect $Image", deployer)
        self.assertIn("$health.build.git_commit", deployer)
        self.assertIn("for ($attempt = 1; $attempt -le 24; $attempt += 1)", deployer)
        self.assertIn("$stableObservations -ge 2", deployer)
        self.assertIn("Start-Sleep -Seconds 5", deployer)

    def test_backend_rollout_pins_init_and_main_containers_to_same_release(self):
        deployer = read_text("scripts/deploy_production_images.ps1")

        backend_rollout = deployer.split(
            "Invoke-RemoteKubectl @(\n    'set', 'image', 'deployment/sql-sync-back'",
            1,
        )[1].split("Invoke-RemoteKubectl", 1)[0]
        self.assertIn('"backend=$backendImage"', backend_rollout)
        self.assertIn('"backend-data-permissions=$backendImage"', backend_rollout)

    def test_backend_contract_rolls_out_before_frontend_release_is_exposed(self):
        deployer = read_text("scripts/deploy_production_images.ps1")

        backend_set = deployer.index("'set', 'image', 'deployment/sql-sync-back'")
        backend_ready = deployer.index(
            "'rollout', 'status', 'deployment/sql-sync-back'"
        )
        frontend_set = deployer.index(
            "'set', 'image', 'deployment/sql-sync-front'"
        )
        frontend_ready = deployer.index(
            "'rollout', 'status', 'deployment/sql-sync-front'"
        )
        self.assertLess(backend_set, backend_ready)
        self.assertLess(backend_ready, frontend_set)
        self.assertLess(frontend_set, frontend_ready)

    def test_production_rollout_retries_transient_ssh_disconnects(self):
        deployer = read_text("scripts/deploy_production_images.ps1")

        remote_helper = deployer.split("function Invoke-RemoteKubectl", 1)[1].split(
            "# Deployment names", 1
        )[0]
        self.assertIn("[ValidateRange(1, 5)][int] $Attempts = 3", remote_helper)
        self.assertIn("ServerAliveInterval=15", remote_helper)
        self.assertIn("ServerAliveCountMax=4", remote_helper)
        self.assertIn("for ($attempt = 1; $attempt -le $Attempts", remote_helper)
        self.assertIn("Start-Sleep -Seconds", remote_helper)
        self.assertIn("failed after $Attempts attempts", remote_helper)

    def test_live_update_verifier_never_embeds_admin_credentials(self):
        verifier_paths = sorted((ROOT / "scripts").glob("verify_live_*.py"))
        self.assertGreater(len(verifier_paths), 1)
        verifiers = "\n".join(path.read_text(encoding="utf-8") for path in verifier_paths)

        self.assertIn('os.environ.get("SQL_SYNC_ADMIN_USERNAME", "")', verifiers)
        self.assertIn('os.environ.get("SQL_SYNC_ADMIN_PASSWORD", "")', verifiers)
        self.assertIn("administrator credentials are required", verifiers)
        self.assertNotRegex(verifiers, r'DEFAULT_PASSWORD\s*=\s*["\'][^"\']+["\']')
        self.assertNotIn("dxfoso@gmail.com", verifiers)

    def test_live_client_state_resolves_current_manifest_version(self):
        verifier = read_text("scripts/verify_live_clients_state.py")

        self.assertIn('parser.add_argument("--expected-version", default="")', verifier)
        self.assertIn("def fetch_latest_client_version", verifier)
        self.assertIn('/client/latest.json"', verifier)
        self.assertIn(
            "args.expected_version.strip() or fetch_latest_client_version(args.base_url)",
            verifier,
        )
        self.assertNotIn('default="1.0.105+109"', verifier)

    def test_manual_sync_dispatch_helper_uses_valid_tru_function_declaration(self):
        control_plane = read_text("business/control_plane.tru")

        self.assertIn(
            "function begin_manual_sync_all_for_owner(ownerUserId: string, requestedAt: string): map<json> {",
            control_plane,
        )
        self.assertNotIn("function begin_manual_sync_all_for_owner(\n", control_plane)

    def test_clients_list_distinguishes_latest_sync_and_sync_all_durations(self):
        clients_page = read_text("frontend/lib/clients_page.dart")

        self.assertIn("DataColumn(label: Text('Duration'))", clients_page)
        self.assertNotIn("DataColumn(label: Text('Last Sync All total'))", clients_page)
        self.assertIn(
            "changes: formatSyncDuration(agent.lastSyncDuration)",
            clients_page,
        )
        self.assertIn(
            "syncAll: formatSyncDuration(operation?.duration())",
            clients_page,
        )
        self.assertIn("integrity: formatSyncDuration(audit.duration())", clients_page)
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
        self.assertIn("final updateLogTail = _readUpdateLogTail()", agent)
        self.assertIn("'updateLogTail': updateLogTail", agent)
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

    def test_updater_stops_exact_launcher_supervisor_before_mutex_handoff(self):
        updater = read_text("update.ps1")
        supervisor = read_text("sync_windows_agent_supervisor.ps1")
        helper = updater.split("$helper = @'", 1)[1].split("\n'@", 1)[0]

        self.assertIn("'-LauncherSupervisorProcessId', $PID", supervisor)
        self.assertIn("function Get-LauncherSupervisorProcessId", updater)
        self.assertGreaterEqual(
            updater.count("function Stop-LauncherSupervisorProcess"), 2
        )
        self.assertIn(
            "Stop-LauncherSupervisorProcess -ProcessId $LauncherSupervisorProcessId",
            helper,
        )
        self.assertIn(
            "Stop-LauncherSupervisorProcess -ProcessId $effectiveLauncherSupervisorProcessId",
            updater,
        )
        self.assertGreaterEqual(
            updater.count("Timed out waiting for the target supervisor to stop"), 2
        )

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
            'updateScriptUrl = "$publicRoot/packages/$packageDirName/bootstrap.ps1"',
            publisher,
        )
        self.assertNotIn('updateScriptUrl = "$publicRoot/update.ps1"', publisher)

    def test_outdated_client_reconnect_retargets_current_immutable_release(self):
        source = read_text("business/control_plane.tru")
        retarget = source.split(
            "function retarget_outdated_client_update_on_heartbeat(", 1
        )[1].split("function agent_client_update_payload", 1)[0]

        self.assertIn("latest_confirmed_client_release_for_owner", retarget)
        self.assertIn("client_update_retarget_cooldown_elapsed", retarget)
        self.assertIn("clientUpdateTargetVersion: null", retarget)
        self.assertIn("clientUpdateStatus: 'requested'", retarget)

    def test_protected_divergence_does_not_repeat_full_union_automatically(self):
        source = read_text("business/control_plane.tru")
        scheduler = source.split(
            "function queue_due_periodic_sync_jobs_for_owner(", 1
        )[1].split("function periodic_sync_scheduler_agent_limit(", 1)[0]

        self.assertIn(
            "latestUploadMode != null && latestUploadMode.union == true",
            scheduler,
        )
        completed_union = scheduler.split(
            "latestUploadMode != null && latestUploadMode.union == true", 1
        )[1].split("let retryDue = false", 1)[0]
        self.assertNotIn("dueTables.concat([table])", completed_union)
        self.assertIn("completedUnionWithoutFailedDownload = true", completed_union)
        self.assertIn("if (string_array_contains(dueTables, table))", scheduler)
        self.assertIn("raise_persistent_union_divergence_issues(", scheduler)

    def test_standard_verifier_initializes_pinned_backend_submodule(self):
        verifier = read_text("tests/run_sync_verification.ps1")
        initializer = verifier.split(
            "function Initialize-PinnedBackendSubmodule", 1
        )[1].split("function Invoke-DockerSyncSuite", 1)[0]

        self.assertIn("backend\\server\\src\\eval\\expr\\builtins\\part_01.rs", initializer)
        self.assertIn("'submodule', 'update', '--init', '--recursive', '--', 'backend'", initializer)
        self.assertIn("Initialize-PinnedBackendSubmodule", verifier.split(
            "Push-Location $repoRoot", 1
        )[1].split("if (-not $SkipPrerequisiteTests)", 1)[0])

    def test_failed_full_download_receives_only_one_automatic_retry(self):
        source = read_text("business/control_plane.tru")
        selector = source.split(
            "function retryable_failed_union_download_batch_id(", 1
        )[1].split("function sync_table_state_due_for_interval(", 1)[0]
        scheduler = source.split(
            "function queue_due_periodic_sync_jobs_for_owner(", 1
        )[1].split("function periodic_sync_scheduler_agent_limit(", 1)[0]

        self.assertIn("latestMode.union != true", selector)
        self.assertIn("== 'failed-download'", selector)
        self.assertIn("!= 'retry-scheduled'", selector)
        self.assertIn("batchId: latestBatchId", selector)
        self.assertIn("mark_failed_union_download_retry_scheduled(", scheduler)
        self.assertIn("planIsUnion && failedUnionRetryBatchId.length != 0", scheduler)

    def test_production_builder_retries_transient_remote_refresh(self):
        builder = read_text("scripts/build_production_images.ps1")
        remote_check = builder.split("function Assert-CommitAvailableOnRemote", 1)[1].split(
            "try {", 1
        )[0]

        self.assertIn("Invoke-NativeCheckedWithRetry", remote_check)
        self.assertIn("git -C $RepositoryPath fetch --quiet origin master", remote_check)
        self.assertIn("-Attempts 3", remote_check)
        self.assertIn("git -C $RepositoryPath merge-base --is-ancestor", remote_check)

    def test_failed_download_retry_uses_tru_strict_mode_safe_shapes(self):
        source = read_text("business/control_plane.tru")
        scheduler = source.split(
            "function queue_due_periodic_sync_jobs_for_owner(", 1
        )[1].split("function periodic_sync_scheduler_agent_limit(", 1)[0]
        rows = source.split("function multi_writer_job_rows(", 1)[1].split(
            "function create_multi_writer_batch(", 1
        )[0]
        marker = source.split(
            "function mark_failed_union_download_retry_scheduled(", 1
        )[1].split("function sync_table_state_due_for_interval(", 1)[0]

        self.assertNotIn("db.updateMany(SyncJob", scheduler)
        self.assertIn("mark_failed_union_download_retry_scheduled(", scheduler)
        self.assertIn("return db.updateMany(SyncJob", marker)
        self.assertEqual(rows.count("automaticRetryKind,"), 2)
        self.assertNotIn("? null : automaticRetryKind", rows)

    def test_validated_full_snapshot_delete_is_not_content_verified_as_a_row(self):
        merge = read_text("sync_windows_agent/lib/sql_sync_merge.dart")
        agent = read_text("sync_windows_agent/lib/agent_page.dart")
        tests = read_text("sync_windows_agent/test/sql_sync_merge_test.dart")

        self.assertIn(
            "List<Map<String, dynamic>> completeSnapshotRowsForContentVerification(",
            merge,
        )
        self.assertIn("!isSqlSyncDurableTombstoneReassertion(row)", merge)
        self.assertIn(
            "rows: completeSnapshotRowsForContentVerification(rowsForApply)",
            agent,
        )
        self.assertIn(
            "complete snapshot content verification excludes only validated deletes",
            tests,
        )

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

    def test_web_client_update_card_shows_progress_retry_and_restart(self):
        dashboard = read_text("frontend/lib/dashboard_page.dart")
        clients = read_text("frontend/lib/clients_page.dart")

        self.assertIn("_buildClientUpdateStatusCard(agent)", dashboard)
        self.assertIn("label: 'Client update progress'", dashboard)
        self.assertIn("Downloaded ${_formatClientUpdateBytes(downloaded)} of", dashboard)
        self.assertIn("Retrying update automatically", dashboard)
        self.assertIn("verified partial download is preserved", dashboard)
        self.assertIn("Restarting after update", dashboard)
        self.assertIn("Current ${_simpleClientVersion(agent)} • Target", dashboard)
        self.assertIn("clientUpdate.status.trim().toLowerCase() == 'installing'", clients)
        self.assertIn("return 'Update restarting';", clients)

    def test_web_update_recovery_dialog_uses_reported_local_script_path(self):
        dashboard = read_text("frontend/lib/dashboard_page.dart")
        model = read_text("frontend/lib/models.dart")
        agent = read_text("sync_windows_agent/lib/agent_page.dart")

        self.assertIn("clientUpdateScriptPath: _localClientUpdateScriptPath() ?? ''", agent)
        self.assertIn("final String scriptPath;", model)
        self.assertIn("_showClientUpdateRecoveryDialog(agent)", dashboard)
        self.assertIn("Show update recovery command", dashboard)
        self.assertIn("Updater script path", dashboard)
        self.assertIn("PowerShell recovery command", dashboard)
        self.assertIn("writeBrowserClipboardText(command)", dashboard)
        self.assertIn("-File '$quotedScript'", dashboard)

    def test_clients_table_places_recovery_icon_beside_version(self):
        clients = read_text("frontend/lib/clients_page.dart")
        version_cell = clients.split("DataRow _buildClientDataRow", 1)[1].split(
            "DataCell(_buildClientActiveCheckbox", 1
        )[0]

        self.assertIn("agent.clientVersion.trim()", version_cell)
        self.assertIn("Icons.terminal_rounded", version_cell)
        self.assertIn("_showClientUpdateRecoveryDialog(agent)", version_cell)
        self.assertIn("Show update recovery command", version_cell)
        self.assertIn("BoxConstraints.tightFor", version_cell)
        self.assertIn("writeBrowserClipboardText(command)", clients)
        self.assertIn("Updater script path", clients)
        self.assertIn("PowerShell recovery command", clients)

    def test_business_key_tombstone_reasserts_different_primary_key_zombie(self):
        backend = read_text("business/control_plane.tru")
        helper = backend.split(
            "function sync_row_durable_tombstone_for_reassertion(", 1
        )[1].split("function sync_timestamp_compare_ms(", 1)[0]
        upload = backend.split("function jobs_multi_writer_upload(", 1)[1].split(
            "function jobs_multi_writer_download(", 1
        )[0]

        self.assertIn("logicalWinnerRefs", helper)
        self.assertIn("currentPhysicalWinner.operation", helper)
        self.assertIn("logicalWinner.operation", helper)
        self.assertIn("resolvedTombstone.operationId", helper)
        self.assertIn("durableTombstoneWinner != null", upload)
        self.assertIn("durableTombstoneWinner.operationId", upload)
        self.assertIn("authoritativeOperation = 'D'", upload)

    def test_production_context_avoids_long_worktree_paths_and_cleans_safely(self):
        builder = read_text("scripts/build_production_images.ps1")

        self.assertIn("[System.IO.Path]::GetTempPath()", builder)
        self.assertIn('"sql-sync-production-{0}"', builder)
        self.assertIn("$expectedPrefix = $systemTempRoot + '\\sql-sync-production-'", builder)
        self.assertIn("[System.IO.FileAttributes]::ReparsePoint", builder)
        self.assertIn("Remove-Item -LiteralPath $resolvedContext -Recurse -Force -ErrorAction Stop", builder)

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

    def test_owner_resume_cannot_misreport_global_admin_pause(self):
        source = read_text("business/control_plane.tru")
        control = source.split(
            "function automatic_sync_control_set(", 1
        )[1].split("function row_key(", 1)[0]
        owner = control.split("if (is_owner_user(current))", 1)[1].split(
            "const controlOwnerUserId", 1
        )[0]

        guard = "if (!paused && automatic_sync_is_paused())"
        mutation = "set_owner_automatic_sync_paused(current.id, paused)"
        self.assertIn(guard, owner)
        self.assertIn("raw_json_error(", owner)
        self.assertIn("Automatic sync remains paused globally by an administrator", owner)
        self.assertLess(owner.index(guard), owner.index(mutation))

    def test_production_backend_context_uses_root_business_config(self):
        builder = read_text("scripts/build_production_images.ps1")
        extract = builder.split(
            "Invoke-NativeChecked 'Extracting root business context...'", 1
        )[1].split("Invoke-NativeChecked 'Extracting frontend context...'", 1)[0]

        self.assertIn("business\\tru.json", extract)
        self.assertIn("Join-Path $backendContext 'tru.json'", extract)
        self.assertIn("Test-Path -LiteralPath $rootBusinessConfig -PathType Leaf", extract)
        self.assertIn(
            "Copy-Item -LiteralPath $rootBusinessConfig -Destination $backendRuntimeConfig -Force",
            extract,
        )

    def test_complete_snapshot_download_metric_excludes_unchanged_rows(self):
        agent = read_text("sync_windows_agent/lib/agent_page.dart")
        apply_body = agent.split(
            "final rowsForApply = coalesceSqlSyncDeltaRows(", 1
        )[1].split("final deleteRows = contentCheckedRows", 1)[0]

        self.assertIn(
            "final contentCheckedRows = await _rowsWhoseContentChanged(",
            apply_body,
        )
        self.assertNotIn("applyDelta\n            ? await _rowsWhoseContentChanged", apply_body)
        self.assertIn(
            "Skipped ${rowsForApply.length - contentCheckedRows.length} unchanged",
            apply_body,
        )

    def test_client_log_request_is_not_blocked_by_complete_fingerprint_scan(self):
        agent = read_text("sync_windows_agent/lib/agent_page.dart")
        upload_body = agent.split(
            "Future<void> _uploadRequestedDiagnostics(", 1
        )[1].split("Future<void> _refreshAndUploadDiagnosticsFingerprints", 1)[0]
        enrichment_body = agent.split(
            "Future<void> _refreshAndUploadDiagnosticsFingerprints", 1
        )[1].split("void _scheduleRequestedDiagnosticsUpload", 1)[0]

        self.assertIn("refreshFingerprints: false", upload_body)
        self.assertIn("await _controlPlaneClient.uploadDiagnostics(", upload_body)
        self.assertIn("_refreshAndUploadDiagnosticsFingerprints(", upload_body)
        self.assertIn("refreshFingerprints: true", enrichment_body)
        self.assertIn("_diagnosticsUploadRequestId != requestId", enrichment_body)

    def test_large_client_diagnostics_cannot_be_truncated_mid_json(self):
        agent = read_text("sync_windows_agent/lib/agent_page.dart")
        encoder = agent.split(
            "String _encodeDiagnosticsPayloadForUpload", 1
        )[1].split("List<dynamic> _boundedUploadList", 1)[0]

        self.assertIn("_compactSelectedFingerprintsForUpload(", encoder)
        self.assertIn("selectedTableFingerprintsEncoding", encoder)
        self.assertIn("while (emergencyEncoded.length > _maxDiagnosticsUploadPayloadChars", encoder)
        self.assertIn("while (logBudget > 0)", encoder)
        self.assertIn("payloadLimitExceeded", encoder)

    def test_remote_support_report_excludes_account_identity_and_has_progress(self):
        agent = read_text("sync_windows_agent/lib/agent_page.dart")
        backend = read_text("business/control_plane.tru")
        frontend = read_text("frontend/lib/dashboard_page.dart")

        self.assertIn("'accountIdentityIncluded': false", agent)
        self.assertNotIn("'username': widget.authenticatedAccountUsername", agent)
        self.assertIn("function agent_diagnostics_progress", backend)
        self.assertIn("diagnosticProgressPercent", backend)
        self.assertIn("complete: false", agent)
        self.assertIn("complete: true", agent)
        self.assertIn("Download support report", frontend)

    def test_ac000_columns_remain_schema_discovered_and_synchronized(self):
        schema = read_text("sync_windows_agent/lib/sql_sync_schema.dart")
        agent = read_text("sync_windows_agent/lib/agent_page.dart")

        self.assertNotIn("filterApplicationMaintainedSyncColumns", schema)
        self.assertNotIn("filterApplicationMaintainedSyncColumns", agent)
        self.assertIn("final syncColumns = columnAssessment.writableColumns", agent)
        self.assertIn("columnDefinitions.where(", agent)
        self.assertIn("(column) => column.isWritable", agent)

    def test_durable_tombstone_reasserts_against_zombie_snapshot_row(self):
        backend = read_text("business/control_plane.tru")
        client = read_text("sync_windows_agent/lib/live_sync_api.dart")

        self.assertIn("reassertsDurableTombstone", backend)
        self.assertIn("authoritativeOperation = 'D'", backend)
        self.assertIn("durableTombstoneWinner.operationId", backend)
        self.assertIn("authoritativeOperationByOperation", client)
        self.assertIn("'__sync_op': authoritativeOperation", client)

    def test_updater_rollback_log_read_retries_transient_file_sharing(self):
        rollback_test = read_text("tests/test_windows_updater_rollback.ps1")

        self.assertIn("function Read-UpdateLogWithRetry", rollback_test)
        self.assertIn("catch [System.IO.IOException]", rollback_test)
        self.assertIn("Start-Sleep -Milliseconds 50", rollback_test)
        self.assertIn("Read-UpdateLogWithRetry -Path $logPath", rollback_test)

    def test_updater_rollback_observer_outlives_supervisor_retry_bound(self):
        rollback_test = read_text("tests/test_windows_updater_rollback.ps1")
        updater = read_text("update.ps1")

        self.assertIn("for ($attempt = 1; $attempt -le 45; $attempt++)", updater)
        self.assertIn("$deadline = [DateTime]::UtcNow.AddSeconds(75)", rollback_test)
        self.assertIn("Final update log: $logText", rollback_test)

    def test_complete_union_accepts_only_server_verified_tombstone_reassertions(self):
        backend = read_text("business/control_plane.tru")
        api = read_text("sync_windows_agent/lib/live_sync_api.dart")
        agent = read_text("sync_windows_agent/lib/agent_page.dart")
        merge = read_text("sync_windows_agent/lib/sql_sync_merge.dart")

        self.assertIn("durableTombstoneReassertion: reassertsDurableTombstone", backend)
        self.assertIn("candidateOperation.durableTombstoneReassertion == true", backend)
        self.assertIn("durableTombstoneReassertionOperations", api)
        self.assertIn("isSqlSyncDurableTombstoneReassertion", agent)
        self.assertIn("deltaDeleteRows: deleteRows.cast<Map<String, dynamic>>()", agent)
        self.assertIn("rowCountBefore.value - deleteRows.length", agent)
        self.assertIn("sqlSyncDurableTombstoneReassertionField", merge)

    def test_selective_range_union_is_safe_and_backward_compatible(self):
        backend = read_text("business/control_plane.tru")
        client = read_text("sync_windows_agent/lib/agent_page.dart")
        fingerprint = read_text("sync_windows_agent/lib/sql_sync_fingerprint.dart")

        self.assertIn("function sync_selective_range_plan", backend)
        self.assertIn("rangeManifests.length != participantCount", backend)
        self.assertIn("differingBuckets.length < 16", backend)
        self.assertIn("mode: 'range_union'", backend)
        self.assertIn("mode: 'union_bootstrap'", backend)
        self.assertIn("sync_source_is_union_bootstrap", backend)
        self.assertIn("rangeUnionSnapshot", client)
        self.assertIn("selectedBuckets.contains", client)
        self.assertIn("selectiveRangeReconcile", client)
        self.assertIn("canonicalFullMerge", backend)
        self.assertIn("SqlSyncRangeFingerprintManifest", fingerprint)

    def test_range_manifest_helper_declares_tru_optional_default(self):
        backend = read_text("business/control_plane.tru")

        self.assertIn(
            "function sync_range_manifest_parts(state: map<json>? = null): array<string>",
            backend,
        )

    def test_zero_winner_union_chunks_are_not_downloaded(self):
        backend = read_text("business/control_plane.tru")
        download = backend.split("function jobs_multi_writer_download(", 1)[1].split(
            "function jobs_upload_chunk(", 1
        )[0]

        self.assertIn(
            "where: { sourceJobId: batch.id, rowCount: { gt: 0 } }",
            download,
        )
        self.assertIn("chunkPayloadBase64.length != 0", download)
        self.assertIn("acceptedOperationIds.length == 0", download)
        self.assertIn("chunkPayloadBase64 = ''", download)
        self.assertIn("snapshot.snapshotBytes = 0", download)
        self.assertIn("if (canonicalFullMerge) {", download)
        self.assertIn("chunkIsDelta = false", download)

    def test_adaptive_parallel_transfer_preserves_atomic_finalization(self):
        policy = read_text("sync_windows_agent/lib/sync_transfer_policy.dart")
        agent = read_text("sync_windows_agent/lib/agent_page.dart")
        api = read_text("sync_windows_agent/lib/live_sync_api.dart")
        packages = read_text("sync_windows_agent/lib/delta_package.dart")
        docker_gate = read_text("tests/docker-sync/run.ps1")

        self.assertIn("kSyncTransferHealthyParallelism = 2", policy)
        self.assertIn("kSyncTransferConstrainedParallelism = 1", policy)
        self.assertIn("void recordFailure()", policy)
        self.assertIn("runBoundedSyncTransfers", policy)
        self.assertIn("final uploadWave = <RemoteSyncJob>[]", agent)
        self.assertIn("nextJob.direction == 'upload'", agent)
        self.assertIn("runBoundedSyncTransfers<bool>", agent)
        self.assertIn("!await _processPendingJob(nextJob)", agent)
        self.assertIn("finalChunk: chunkIndex == packages.length - 1", agent)
        self.assertIn("_transferPolicy.recordFailure()", api)
        self.assertIn("_transferPolicy.recordSuccess", api)
        self.assertIn("GZipCodec(level: gzipLevel)", packages)
        self.assertIn("test/sync_transfer_policy_test.dart", docker_gate)

    def test_same_batch_packages_remain_serial_under_cross_table_parallelism(self):
        backend = read_text("business/control_plane.tru")
        agent = read_text("sync_windows_agent/lib/agent_page.dart")

        self.assertIn(
            "db.updateMany(SyncBatch, { id: batch.id, revision: batch.revision }",
            backend,
        )
        self.assertIn(
            "A batch has one optimistic revision register, so packages for the same",
            agent,
        )
        self.assertIn(
            "for (var chunkIndex = 0; chunkIndex < packages.length; chunkIndex += 1)",
            agent,
        )
        self.assertIn(
            "uploadedJob = await uploadPackage(packages[chunkIndex], chunkIndex)",
            agent,
        )
        upload_body = agent.split("Future<RemoteSyncJob> uploadPackage(", 1)[1].split(
            "_applyRemoteJobState(", 1
        )[0]
        self.assertNotIn("runBoundedSyncTransfers", upload_body)

    def test_generic_bounded_runner_empty_result_is_not_const(self):
        policy = read_text("sync_windows_agent/lib/sync_transfer_policy.dart")

        self.assertIn("if (pending.isEmpty) return <T>[];", policy)
        self.assertNotIn("const <T>[]", policy)

    def test_dns_client_update_failure_keeps_durable_request_pending(self):
        source = read_text("business/control_plane.tru")
        retry = source.split(
            "function client_update_ack_should_retry(", 1
        )[1].split("function latest_confirmed_client_release_for_owner(", 1)[0]
        ack = source.split("function agent_client_update_ack(", 1)[1].split(
            "function agent_window_action_request_all(", 1
        )[0]

        self.assertIn(
            "resumable update payload download failed after 3 bounded attempts:",
            retry,
        )
        self.assertIn("remote name could not be resolved", retry)
        self.assertIn("no such host is known", retry)
        self.assertIn("name resolution", retry)
        self.assertIn("client_update_ack_should_retry(status, message)", ack)
        self.assertIn("nextStatus = 'retrying'", ack)
        self.assertIn("nextLastRequestId = resolvedRequestIdOrNull", ack)

    def test_client_and_updater_have_tls_preserving_dns_fallback(self):
        resilient = read_text("sync_windows_agent/lib/resilient_http_client.dart")
        live_api = read_text("sync_windows_agent/lib/live_sync_api.dart")
        agent = read_text("sync_windows_agent/lib/agent_page.dart")
        updater = read_text("update.ps1")
        verification = read_text("tests/run_sync_verification.ps1")

        self.assertIn("class ResilientDnsResolver", resilient)
        self.assertIn("cloudflare-dns.com", resilient)
        self.assertIn("bootstrapAddress: '1.1.1.1'", resilient)
        self.assertIn("dns.google", resilient)
        self.assertIn("bootstrapAddress: '8.8.8.8'", resilient)
        self.assertIn("SecureSocket.secure(", resilient)
        self.assertIn("host: tlsHost", resilient)
        self.assertNotIn("onBadCertificate:", resilient)
        self.assertIn("where(isSafePublicIpv4Address)", resilient)
        self.assertIn("client ?? createResilientHttpClient()", live_api)
        self.assertIn("createResilientDartHttpClient()", agent)

        self.assertIn("$script:TrustedUpdateHost = 'sync.velvet-leaf.com'", updater)
        self.assertIn("Invoke-UpdateDnsOverHttps", updater)
        self.assertIn("'--resolve'", updater)
        self.assertIn("'--retry-all-errors'", updater)
        self.assertIn("Invoke-UpdateCurlResumableDownload", updater)
        self.assertIn("Test-InstalledFileMatchesManifest -Path $partialFile", updater)
        self.assertNotIn("--insecure", updater)
        self.assertNotIn("ServerCertificateValidationCallback", updater)
        self.assertIn("test_windows_updater_dns_fallback.ps1", verification)

    def test_delta_sync_refreshes_complete_inventory_and_bounds_background_audit(self):
        agent = read_text("sync_windows_agent/lib/agent_page.dart")
        fingerprint = read_text("sync_windows_agent/lib/sql_sync_fingerprint.dart")
        dart_tests = read_text("sync_windows_agent/test/sql_sync_fingerprint_test.dart")

        self.assertIn("_tableFingerprintRefreshBatchSize = 8", agent)
        self.assertIn("Duration(minutes: 1)", agent)
        self.assertIn("_tableFingerprintRefreshCursor", agent)
        self.assertIn("tables: [target.value]", agent)
        self.assertIn("_refreshSelectedTableFingerprints(bounded: true)", agent)
        self.assertIn("if (isDelta) {", agent)
        self.assertIn("deltaInventoryFingerprint = await _computeTableFingerprint", agent)
        self.assertIn("resolveSqlSyncUploadInventoryMetadata", agent)
        self.assertIn("class SqlSyncUploadInventoryMetadata", fingerprint)
        self.assertIn("completeRowCount!", fingerprint)
        self.assertIn(
            "empty delta publishes its fresh complete inventory for anti-entropy",
            dart_tests,
        )

    def test_complete_inventory_uses_versioned_sha256_for_close_float_drift(self):
        backend = read_text("business/control_plane.tru")
        fingerprint = read_text("sync_windows_agent/lib/sql_sync_fingerprint.dart")
        dart_tests = read_text("sync_windows_agent/test/sql_sync_fingerprint_test.dart")

        self.assertIn("kSqlSyncTableFingerprintVersion = 'v2'", fingerprint)
        self.assertIn("sha256.startChunkedConversion", fingerprint)
        self.assertIn("utf8.encode(value)", fingerprint)
        self.assertNotIn("_fnv64OffsetBasis", fingerprint)
        self.assertIn("kSqlSyncRangeFingerprintVersion = 'v2'", fingerprint)
        self.assertIn("string.from(parts[0]) != 'v2'", backend)
        self.assertIn(
            "fingerprint distinguishes close lossless SQL float values",
            dart_tests,
        )

    def test_client_publish_fails_before_partial_output_when_disk_is_full(self):
        publish = read_text("scripts/publish_windows_client_update.ps1")

        self.assertIn("function Assert-ClientPublishFreeSpace", publish)
        self.assertIn("[System.IO.DriveInfo]::new($outputRoot)", publish)
        self.assertIn("(2 * $zipBytes) + (2 * $expandedBytes) + $safetyBytes", publish)
        self.assertIn("retry with -SkipBuild", publish)
        preflight = publish.index(
            "Assert-ClientPublishFreeSpace -ZipPath $PortableZip -DestinationPath $OutputDir"
        )
        first_output_write = publish.index(
            "New-Item -Path $OutputDir -ItemType Directory -Force"
        )
        self.assertLess(preflight, first_output_write)

    def test_automatic_numbering_incident_is_visible_and_idempotent(self):
        backend = read_text("business/control_plane.tru")
        client_api = read_text("sync_windows_agent/lib/live_sync_api.dart")
        fingerprint = read_text("sync_windows_agent/lib/sql_sync_fingerprint.dart")
        agent = read_text("sync_windows_agent/lib/agent_page.dart")
        web = read_text("frontend/lib/clients_page.dart")
        web_model = read_text("frontend/lib/models.dart")

        self.assertIn("operationId: string min=64 max=64", backend)
        self.assertIn("class AutoNumberReservation", backend)
        self.assertIn("db.insertMany(AutoNumberReservation", backend)
        self.assertIn("db.upsertMany(AutoNumberIncident", backend)
        self.assertIn("automatic_number_incident_find_by_operation", backend)
        self.assertIn("automaticNumberIncidentCount", backend)
        self.assertIn("function automatic_number_incidents_list(", backend)
        self.assertIn("automaticNumberByOperation", client_api)
        self.assertIn("__sync_auto_number_before", fingerprint)
        self.assertGreaterEqual(
            agent.count("resolveUniqueConflictsLatestWins: false"), 2
        )
        self.assertIn("DataColumn(label: Text('Auto numbering'))", web)
        self.assertIn("_showAutomaticNumberIncidentsDialog", web)
        self.assertIn("Tooltip(", web)
        self.assertNotIn("tooltip: 'Show automatic-number incident history'", web)
        self.assertIn("Before", web)
        self.assertIn("After", web)
        self.assertIn("class AdminAutomaticNumberIncident", web_model)

    def test_collision_rollback_helper_preserves_unique_index_metadata(self):
        scenario = read_text("tests/docker-sync/run_scenarios.py")

        helper_start = scenario.index("def expect_apply_failure(")
        helper_end = scenario.index("\n\ndef assert_business_trigger_enabled", helper_start)
        helper = scenario[helper_start:helper_end]
        self.assertIn("unique_index_column_sets=None", helper)
        self.assertIn("unique_index_column_sets=unique_index_column_sets", helper)

    def test_private_export_retries_small_units_on_slow_links(self):
        policy = read_text("sync_windows_agent/lib/data_export_policy.dart")
        agent = read_text("sync_windows_agent/lib/agent_page.dart")
        dart_tests = read_text(
            "sync_windows_agent/test/data_export_policy_test.dart"
        )

        self.assertIn("kPrivateExportArtifactBytes = 256 * 1024", policy)
        self.assertIn("privateExportUploadTimeout(int bytes)", policy)
        self.assertIn("assumedMinimumBytesPerSecond = 512", policy)
        self.assertIn("Duration(minutes: 15)", policy)
        self.assertIn("kPrivateExportArtifactBytes", agent)
        self.assertIn("privateExportUploadTimeout(bytes.length)", agent)
        self.assertNotIn("_dataExportChunkBytes = 4 * 1024 * 1024", agent)
        self.assertIn(
            "private export uses small retry units and a slow-link timeout",
            dart_tests,
        )


if __name__ == "__main__":
    unittest.main()
