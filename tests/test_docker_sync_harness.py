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
        self.assertIn('"-f", "65001"', runner)
        self.assertIn('encode("utf-16-le")', runner)
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


if __name__ == "__main__":
    unittest.main()
