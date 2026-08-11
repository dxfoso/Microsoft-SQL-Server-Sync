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
        expected_ids = {f"INC-{number:03d}" for number in range(1, 87)}
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


if __name__ == "__main__":
    unittest.main()
