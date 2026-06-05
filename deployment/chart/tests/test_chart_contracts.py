import pathlib
import unittest


ROOT = pathlib.Path(__file__).resolve().parents[1]
PROJECT_ROOT = ROOT.parents[1]


class ChartContractsTests(unittest.TestCase):
    def test_backend_does_not_require_admin_key_for_public_health(self):
        backend_deployment = (
            ROOT / "templates" / "backend-deployment.yaml"
        ).read_text(encoding="utf-8")
        self.assertNotIn("TRU_ADMIN_REQUIRE_KEY", backend_deployment)
        self.assertNotIn("TRU_ADMIN_KEY", backend_deployment)

    def test_backend_secret_only_manages_postgres_url(self):
        backend_secret = (ROOT / "templates" / "backend-secret.yaml").read_text(
            encoding="utf-8"
        )
        self.assertIn("TRU_POSTGRESQL_URL", backend_secret)
        self.assertNotIn("admin secret", backend_secret)
        self.assertNotIn("TRU_ADMIN_KEY", backend_secret)

    def test_values_do_not_expose_dead_admin_block(self):
        values_yaml = (ROOT / "values.yaml").read_text(encoding="utf-8")
        self.assertNotIn("\nadmin:\n", values_yaml)
        self.assertNotIn("sql-sync-admin", values_yaml)

    def test_runtime_config_keeps_public_admin_health_ungated(self):
        tru_json = (PROJECT_ROOT / "business" / "tru.json").read_text(
            encoding="utf-8"
        )
        self.assertIn('"adminRequireKey": false', tru_json)
        self.assertIn('"requireKey": false', tru_json)


if __name__ == "__main__":
    unittest.main()
