import pathlib
import unittest


ROOT = pathlib.Path(__file__).resolve().parents[1]
PROJECT_ROOT = ROOT.parents[1]


class ChartContractsTests(unittest.TestCase):
    def test_backend_deployment_requires_admin_key_env(self):
        backend_deployment = (
            ROOT / "templates" / "backend-deployment.yaml"
        ).read_text(encoding="utf-8")
        self.assertIn("TRU_ADMIN_REQUIRE_KEY", backend_deployment)
        self.assertIn("TRU_ADMIN_KEY", backend_deployment)
        self.assertIn("secretKeyRef", backend_deployment)

    def test_backend_secret_manages_postgres_and_admin_key(self):
        backend_secret = (ROOT / "templates" / "backend-secret.yaml").read_text(
            encoding="utf-8"
        )
        self.assertIn("TRU_POSTGRESQL_URL", backend_secret)
        self.assertIn("admin secret", backend_secret)
        self.assertIn("TRU_ADMIN_KEY", backend_secret)

    def test_values_expose_admin_secret_contract(self):
        values_yaml = (ROOT / "values.yaml").read_text(encoding="utf-8")
        self.assertIn("\nadmin:\n", values_yaml)
        self.assertIn("sql-sync-admin", values_yaml)

    def test_runtime_config_requires_admin_key(self):
        tru_json = (PROJECT_ROOT / "business" / "tru.json").read_text(
            encoding="utf-8"
        )
        self.assertIn('"adminRequireKey": true', tru_json)
        self.assertIn('"requireKey": true', tru_json)


if __name__ == "__main__":
    unittest.main()
