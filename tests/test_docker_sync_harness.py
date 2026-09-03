import pathlib
import unittest


ROOT = pathlib.Path(__file__).resolve().parents[1]


class DockerSyncHarnessContracts(unittest.TestCase):
    def test_harness_uses_production_sql_and_real_sql_server(self):
        compose = (ROOT / "tests/docker-sync/compose.yaml").read_text(encoding="utf-8")
        runner = (ROOT / "tests/docker-sync/run_scenarios.py").read_text(encoding="utf-8")
        bridge = (ROOT / "sync_windows_agent/tool/sync_sql_harness.dart").read_text(encoding="utf-8")

        self.assertIn("mcr.microsoft.com/mssql/server:2022-latest", compose)
        self.assertIn("buildTargetSnapshotStageApplySql(", bridge)
        self.assertIn("deltaDeleteRows: deletes", bridge)
        self.assertIn("coalesceSqlSyncDeltaRows(", bridge)
        self.assertIn('"primary-key-change"', runner)
        self.assertIn(
            '"offline-peer-online-continuity-and-reconnect-catch-up"',
            runner,
        )
        self.assertIn(
            '"initial-three-client-primary-key-union-bootstrap"',
            runner,
        )
        self.assertIn("Initial union did not retain every client's unique rows", runner)
        self.assertIn(
            "An offline peer blocked client 1 changes from reaching client 2",
            runner,
        )
        self.assertIn("accumulated_offline_delta = coalesce", runner)
        self.assertIn('"large-1200-row-batch"', runner)
        self.assertIn('"exact-unicode-arabic-emoji-cjk"', runner)
        self.assertIn('"rejected-row-rollback-and-recovery"', runner)
        self.assertIn("assert_atomic_fault_rollback", runner)
        self.assertIn("assert_connection_loss_atomicity", runner)
        self.assertIn("assert_commit_response_loss_is_idempotent", runner)
        visibility = '"Commit did not become visible before response loss."'
        response_loss = runner[
            runner.index("def assert_commit_response_loss_is_idempotent"):
            runner.index("\ndef relational_rows")
        ]
        self.assertIn(visibility, response_loss)
        self.assertLess(
            response_loss.index(visibility),
            response_loss.index('sqlcmd(f"KILL {spid};")'),
        )
        self.assertIn("run_concurrency_scenarios", runner)
        self.assertIn("run_relational_scenarios", runner)
        self.assertIn("run_fuzz_scenarios", runner)
        self.assertIn("run_scale_scenario", runner)
        self.assertIn("run_soak_scenario", runner)
        self.assertIn('"duplicate-reordered-delivery"', runner)
        self.assertIn('"sql-restart-mid-transaction-rollback"', runner)
        self.assertIn('"-f", "65001"', runner)
        self.assertIn('encode("utf-16-le")', runner)
        self.assertIn("assert_unicode_hex_transport", runner)
        self.assertIn('decode("utf-16-le")', runner)
        self.assertIn("0x53514C53594E43", runner)

    def test_production_backup_is_copy_only_and_ignored_by_git(self):
        exporter = (ROOT / "scripts/export_sync_test_database.ps1").read_text(encoding="utf-8")
        gitignore = (ROOT / ".gitignore").read_text(encoding="utf-8")

        self.assertIn("COPY_ONLY", exporter)
        self.assertIn("RESTORE VERIFYONLY", exporter)
        self.assertIn("*.bak", gitignore)

    def test_go_sqlcmd_disables_tls_only_for_local_sql_2017_matrix(self):
        runner = (ROOT / "tests/docker-sync/run_scenarios.py").read_text(
            encoding="utf-8"
        )

        self.assertIn("SQLCMD_GO_VERSION = go_sqlcmd_version(SQLCMD)", runner)
        self.assertIn(
            '":2017-" in os.environ.get("SQL_SYNC_TEST_IMAGE", "")', runner
        )
        self.assertIn('["-N", "disable"]', runner)
        self.assertGreaterEqual(runner.count("*SQLCMD_TLS_ARGS"), 3)

    def test_windows_launcher_ignores_store_alias_and_uses_container_sqlcmd(self):
        launcher = (ROOT / "tests/docker-sync/run.ps1").read_text(
            encoding="utf-8"
        )
        runner = (ROOT / "tests/docker-sync/run_scenarios.py").read_text(
            encoding="utf-8"
        )
        compose = (ROOT / "tests/docker-sync/compose.yaml").read_text(
            encoding="utf-8"
        )

        self.assertIn("$candidateExitCode = $LASTEXITCODE", launcher)
        self.assertIn("Programs\\Python\\Python*\\python.exe", launcher)
        self.assertIn("CONTAINER_SQLCMD = SQLCMD is None", runner)
        self.assertIn('"exec", "-T", "sql"', runner)
        self.assertIn('input_path = f"/harness/{sql_path.name}"', runner)
        self.assertIn("./:/harness:ro", compose)

    def test_agents_requires_the_docker_suite_before_client_publication(self):
        agents = (ROOT / "AGENTS.md").read_text(encoding="utf-8")

        self.assertIn(r".\tests\docker-sync\run.ps1", agents)
        self.assertIn("Before publishing sync logic changes", agents)

    def test_standard_launcher_writes_cloud_task_artifacts(self):
        launcher = (ROOT / "tests/run_sync_verification.ps1").read_text(
            encoding="utf-8"
        )

        self.assertIn("task-status.json", launcher)
        self.assertIn("task-results.json", launcher)
        self.assertIn("task-step-results.json", launcher)
        self.assertIn("task-summary.txt", launcher)
        self.assertIn("final-summary.txt", launcher)
        self.assertLess(
            launcher.index("task-summary.txt"),
            launcher.index("final-summary.txt"),
        )
        self.assertIn("CLOUD_CI_EVENT_NAME", launcher)
        self.assertIn('("history\\{0}" -f $runId)', launcher)
        self.assertIn("SQL Server 2017 compatibility", launcher)
        self.assertIn("SQL Server 2019 compatibility", launcher)
        self.assertIn("SQL Server 2022 compatibility", launcher)

    def test_standard_launcher_supports_detached_release_worktrees(self):
        launcher = (ROOT / "tests/run_sync_verification.ps1").read_text(
            encoding="utf-8"
        )

        self.assertIn("$gitRefOutput = & git -C $repoRoot branch --show-current", launcher)
        self.assertIn("$null -eq $gitRefOutput", launcher)
        self.assertIn('"detached/$commit"', launcher)

    def test_cloud_tests_registers_sync_robustness_workflow(self):
        workflow = (
            ROOT / ".cloud-ci/workflows/sync-verification.yaml"
        ).read_text(encoding="utf-8")
        task = (
            ROOT / ".cloud-ci/tasks/sync-verification.sh"
        ).read_text(encoding="utf-8")
        settings = (ROOT / ".cloud-ci/settings.yaml").read_text(
            encoding="utf-8"
        )

        self.assertIn("nightly-sync-robustness", workflow)
        self.assertIn(".cloud-ci/tasks/sync-verification.sh", workflow)
        self.assertIn("run_sql_suite robustness", task)
        self.assertIn("run_sql_suite soak", task)
        self.assertIn("mssql/server:2017-latest", task)
        self.assertIn("mssql/server:2019-latest", task)
        self.assertIn("mssql/server:2022-latest", task)
        self.assertIn("workspace/tests/sync-verification/task-status.json", settings)

    def test_local_sql_harness_resets_only_its_disposable_volume_before_start(self):
        runner = (ROOT / "tests/docker-sync/run_scenarios.py").read_text(
            encoding="utf-8"
        )

        cleanup = 'run(COMPOSE + ["down", "-v"], check=False)'
        startup = 'run(COMPOSE + ["up", "-d"])'
        self.assertIn(cleanup, runner)
        self.assertIn(startup, runner)
        self.assertLess(runner.index(cleanup), runner.index(startup))
        self.assertIn("disposable SQL volume", runner)


if __name__ == "__main__":
    unittest.main()
