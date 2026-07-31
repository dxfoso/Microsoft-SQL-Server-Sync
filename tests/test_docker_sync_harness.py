import pathlib
import unittest


ROOT = pathlib.Path(__file__).resolve().parents[1]


class DockerSyncHarnessContracts(unittest.TestCase):
    def test_harness_uses_production_sql_and_real_sql_server(self):
        compose = (ROOT / "tests/docker-sync/compose.yaml").read_text(encoding="utf-8")
        runner = (ROOT / "tests/docker-sync/run_scenarios.py").read_text(encoding="utf-8")
        bridge = (ROOT / "sync_windows_agent/tool/sync_sql_harness.dart").read_text(encoding="utf-8")

        self.assertIn("mcr.microsoft.com/mssql/server:2022-latest", compose)
        self.assertIn("buildTargetDeltaDeleteSql(", bridge)
        self.assertIn("buildTargetSnapshotStageApplySql(", bridge)
        self.assertIn("coalesceSqlSyncDeltaRows(", bridge)
        self.assertIn('"primary-key-change"', runner)
        self.assertIn('"offline-catch-up"', runner)
        self.assertIn('"large-1200-row-batch"', runner)
        self.assertIn('"exact-unicode-arabic-emoji-cjk"', runner)
        self.assertIn('"rejected-row-rollback-and-recovery"', runner)
        self.assertIn("assert_atomic_fault_rollback", runner)
        self.assertIn("assert_connection_loss_atomicity", runner)
        self.assertIn("assert_commit_response_loss_is_idempotent", runner)
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

    def test_agents_requires_the_docker_suite_before_client_publication(self):
        agents = (ROOT / "AGENTS.md").read_text(encoding="utf-8")

        self.assertIn(r".\tests\docker-sync\run.ps1", agents)
        self.assertIn("Before publishing sync logic changes", agents)

    def test_standard_launcher_writes_action_compatible_task_artifacts(self):
        launcher = (ROOT / "tests/run_sync_verification.ps1").read_text(
            encoding="utf-8"
        )

        self.assertIn("task-status.json", launcher)
        self.assertIn("task-results.json", launcher)
        self.assertIn("task-step-results.json", launcher)
        self.assertIn("final-summary.txt", launcher)
        self.assertIn("ACTION_SERVER_TRIGGER", launcher)
        self.assertIn("SQL Server 2017 compatibility", launcher)
        self.assertIn("SQL Server 2019 compatibility", launcher)
        self.assertIn("SQL Server 2022 compatibility", launcher)

    def test_action_server_registers_sync_robustness_workflow(self):
        workflow = (
            ROOT / ".action-server/workflows/sync-verification.yaml"
        ).read_text(encoding="utf-8")
        task = (
            ROOT / ".action-server/tasks/sync-verification.sh"
        ).read_text(encoding="utf-8")
        settings = (ROOT / ".action-server/settings.yaml").read_text(
            encoding="utf-8"
        )

        self.assertIn("nightly-sync-robustness", workflow)
        self.assertIn(".action-server/tasks/sync-verification.sh", workflow)
        self.assertIn("run_sql_suite robustness", task)
        self.assertIn("run_sql_suite soak", task)
        self.assertIn("mssql/server:2017-latest", task)
        self.assertIn("mssql/server:2019-latest", task)
        self.assertIn("mssql/server:2022-latest", task)
        self.assertIn("workspace/tests/sync-verification/task-status.json", settings)


if __name__ == "__main__":
    unittest.main()
